// claude-notifier: «сочность» раскрытой шторки — живые переходы поверх обычного отклика (NotchUi.cs).
//  • Вкладки: подсветка выбранной — одна капсула, переезжает к новой на пружине (с лёгким перелётом и
//    вытягиванием в полёте), под значком — светящаяся акцентная чёрточка.
//  • Страница и раздел настроек: строки въезжают каскадом — снизу вверх с проявлением, одна за другой.
//  • Нажатие: от точки касания по строке, кнопке, вкладке расходится мягкая волна.
//  • Тумблер: ползунок «желейный» — вытягивается на ходу; включили — вокруг вспыхивает зелёное кольцо.
//  • Графики статистики: столбики вырастают по очереди с пружинкой.
//  • Полоски лимитов: при раскрытии наполняются с нуля, по ним пробегает блик.
// «Меньше движения» в Windows — всё сразу, без анимации.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ClaudeNotifier.Ui {
    public sealed partial class NotchView {
        DateTime pageShownAt = DateTime.MinValue;

        // Страница (или раздел) только что показана: строки въедут каскадом. expanded — шторку раскрыли:
        // полоски лимитов наполнятся с нуля.
        public void MarkPageShown(bool expanded) {
            pageShownAt = DateTime.UtcNow;
            if (expanded && Animate) {
                foreach (string k in new string[] { "lim:5 ч", "lim:Неделя" }) { AnimValue a; if (anims.TryGetValue(k, out a)) a.Cur = 0; }
            }
            WakeUi();
        }

        public double PageShownSeconds { get { return pageShownAt == DateTime.MinValue ? 99 : (DateTime.UtcNow - pageShownAt).TotalSeconds; } }

        // Ход въезда i-й строки: 0 → 1 (по 40 мс друг за другом, каждая ~0,34 с).
        float EnterK(int i) {
            if (!Animate || pageShownAt == DateTime.MinValue) return 1f;
            double t = (DateTime.UtcNow - pageShownAt).TotalSeconds - 0.05 - Math.Min(i, 12) * 0.04;
            float k = (float)Math.Max(0, Math.Min(1, t / 0.34));
            if (k < 1f) WakeUi();
            return k;
        }

        static float EaseOut(float t) { t = Math.Max(0, Math.Min(1, t)); return 1 - (1 - t) * (1 - t) * (1 - t); }
        static float EaseBack(float t) { t = Math.Max(0, Math.Min(1, t)); float c1 = 1.70158f, c3 = c1 + 1; return 1 + c3 * (float)Math.Pow(t - 1, 3) + c1 * (float)Math.Pow(t - 1, 2); }

        // Строка въезжает: сдвиг снизу и проявление из фона шторки.
        void PaintEntering(Graphics g, Rectangle r, int index, Action<Rectangle> paint) {
            float k = EnterK(index);
            if (k >= 1f) { paint(r); return; }
            int dy = (int)Math.Round((1 - EaseOut(k)) * theme.S(16));
            Rectangle rr = r; rr.Offset(0, dy);
            paint(rr);
            int a = (int)(255 * (1 - EaseOut(Math.Min(1f, k * 1.3f))));
            if (a > 2) using (SolidBrush veil = new SolidBrush(Color.FromArgb(a, Bg))) g.FillRectangle(veil, rr.X - 1, rr.Y - 1, rr.Width + 2, rr.Height + 2);
        }

        // Капсула-ссылка (изменения, очередь): значок, текст, подсветка при наведении. Возвращает занятую ширину.
        int PaintLinkChip(Graphics g, int x, int y, int maxRight, string hit, string glyph, string text, Color accent) {
            int h = theme.S(22), iw = theme.S(18);
            int w = TextRenderer.MeasureText(text, fSmall).Width + iw + theme.S(14);
            if (x + w > maxRight) return 0;
            Rectangle r = new Rectangle(x, y, w, h);
            float hot = Hot(hit);
            Draw.Fill(g, r, h / 2f, Draw.Mix(Pal(0x232326), Pal(0x2E2E32), hot));
            PaintRipple(g, hit, r, h / 2f);
            TextRenderer.DrawText(g, glyph, fIconSmall, new Rectangle(x + theme.S(7), y, iw, h), accent, TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPrefix);
            TextRenderer.DrawText(g, text, fSmall, new Rectangle(x + theme.S(7) + iw, y, w - iw - theme.S(7), h), Draw.Mix(Pal(0xC7C7CC), Fg, hot), TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            Hit(r, hit);
            return w + theme.S(8);
        }

        // --- Пружины: значение с перелётом (вкладки) ---
        sealed class SpringValue { public float Pos, Vel; public DateTime At; public bool Init; }
        readonly Dictionary<string, SpringValue> springs = new Dictionary<string, SpringValue>();

        float Spring(string key, float target, float stiffness, float damping, out float vel) {
            SpringValue s;
            if (!springs.TryGetValue(key, out s)) { s = new SpringValue(); springs[key] = s; }
            DateTime now = DateTime.UtcNow;
            if (!s.Init || !Animate) { s.Pos = target; s.Vel = 0; s.Init = true; s.At = now; vel = 0; return target; }
            float dt = (float)Math.Max(0, Math.Min(0.05, (now - s.At).TotalSeconds)); s.At = now;
            int steps = Math.Max(1, (int)Math.Ceiling(dt / 0.004f)); float h = dt / steps;
            for (int i = 0; i < steps; i++) { float f = -stiffness * (s.Pos - target) - damping * s.Vel; s.Vel += f * h; s.Pos += s.Vel * h; }
            if (Math.Abs(s.Pos - target) < 0.3f && Math.Abs(s.Vel) < 4f) { s.Pos = target; s.Vel = 0; }
            else WakeUi();
            vel = s.Vel;
            return s.Pos;
        }

        // Подсветка выбранной вкладки: капсула едет к ней, в полёте вытягивается; под значком — светящаяся чёрточка.
        void PaintTabIndicator(Graphics g, int x, int y, int size, bool visible) {
            float vel;
            float ax = Spring("tabx", x, 420f, 30f, out vel);
            float show = Anim("tabshow", visible ? 1f : 0f, 14f);
            if (show <= 0.01f) return;
            float stretch = Math.Min(size * 0.45f, Math.Abs(vel) * 0.035f);
            float sx = vel > 0 ? ax - stretch : ax;   // хвост тянется за капсулой
            RectangleF pill = new RectangleF(sx, y, size + stretch, size);
            Draw.Fill(g, pill, size / 2f, Color.FromArgb((int)(255 * show), Pal(0x2C2C2E)));
            float bw = theme.S(14) + stretch * 0.5f, bh = Math.Max(2f, theme.S(3));
            RectangleF bar = new RectangleF(ax + size / 2f - bw / 2f + (vel > 0 ? -stretch / 2 : 0), y + size - bh - theme.S(3), bw, bh);
            using (GraphicsPath gp = new GraphicsPath()) {
                RectangleF glow = RectangleF.Inflate(bar, theme.S(6), theme.S(4));
                gp.AddEllipse(glow);
                using (PathGradientBrush pg = new PathGradientBrush(gp)) {
                    pg.CenterColor = Color.FromArgb((int)(90 * show), theme.Accent); pg.SurroundColors = new Color[] { Color.FromArgb(0, theme.Accent) };
                    g.FillPath(pg, gp);
                }
            }
            Draw.Fill(g, bar, bh / 2f, Color.FromArgb((int)(255 * show), theme.Accent));
        }

        // --- Волна от нажатия ---
        readonly Dictionary<string, KeyValuePair<PointF, DateTime>> ripples = new Dictionary<string, KeyValuePair<PointF, DateTime>>();

        void AddRipple(string id, Point windowPt) {
            if (id == null || !Animate) return;
            ripples[id] = new KeyValuePair<PointF, DateTime>(new PointF(windowPt.X - origin.X, windowPt.Y - origin.Y), DateTime.UtcNow);
            WakeUi();
        }

        void PaintRipple(Graphics g, string id, RectangleF shape, float radius) {
            KeyValuePair<PointF, DateTime> rp;
            if (id == null || !ripples.TryGetValue(id, out rp)) return;
            float t = (float)((DateTime.UtcNow - rp.Value).TotalSeconds / 0.55);
            if (t >= 1f) { ripples.Remove(id); return; }
            WakeUi();
            PointF c = rp.Key;
            if (!shape.Contains(c)) c = new PointF(shape.X + shape.Width / 2, shape.Y + shape.Height / 2);
            float far = 0;
            foreach (PointF p in new PointF[] { new PointF(shape.Left, shape.Top), new PointF(shape.Right, shape.Top), new PointF(shape.Left, shape.Bottom), new PointF(shape.Right, shape.Bottom) })
                far = Math.Max(far, (float)Math.Sqrt((p.X - c.X) * (p.X - c.X) + (p.Y - c.Y) * (p.Y - c.Y)));
            float rad = far * EaseOut(t);
            int alpha = (int)((Light ? 34 : 46) * (1 - t));
            using (GraphicsPath clip = new GraphicsPath()) {
                float d = Math.Min(radius * 2, Math.Min(shape.Width, shape.Height));
                if (d > 0.5f) {
                    clip.AddArc(shape.X, shape.Y, d, d, 180, 90); clip.AddArc(shape.Right - d, shape.Y, d, d, 270, 90);
                    clip.AddArc(shape.Right - d, shape.Bottom - d, d, d, 0, 90); clip.AddArc(shape.X, shape.Bottom - d, d, d, 90, 90);
                    clip.CloseFigure();
                } else clip.AddRectangle(shape);
                Region old = g.Clip; g.SetClip(clip, CombineMode.Intersect);
                using (SolidBrush b = new SolidBrush(Color.FromArgb(alpha, Fg))) g.FillEllipse(b, c.X - rad, c.Y - rad, rad * 2, rad * 2);
                g.Clip = old; old.Dispose();
            }
        }

        // --- Тумблер: вспышка при включении ---
        readonly Dictionary<string, bool> swPrev = new Dictionary<string, bool>();
        readonly Dictionary<string, DateTime> swFlash = new Dictionary<string, DateTime>();

        void PaintSwitchFlash(Graphics g, Rectangle t, string key, bool on) {
            bool prev;
            if (swPrev.TryGetValue(key, out prev) && prev != on && on && Animate) swFlash[key] = DateTime.UtcNow;
            swPrev[key] = on;
            DateTime at;
            if (!swFlash.TryGetValue(key, out at)) return;
            float k = (float)((DateTime.UtcNow - at).TotalSeconds / 0.6);
            if (k >= 1f) { swFlash.Remove(key); return; }
            WakeUi();
            float grow = theme.S(10) * EaseOut(k);
            RectangleF ring = RectangleF.Inflate(t, grow, grow);
            using (GraphicsPath p = new GraphicsPath()) {
                float d = ring.Height;
                p.AddArc(ring.X, ring.Y, d, d, 90, 180); p.AddArc(ring.Right - d, ring.Y, d, d, 270, 180); p.CloseFigure();
                using (Pen pen = new Pen(Color.FromArgb((int)(170 * (1 - k)), 48, 209, 88), Math.Max(1f, theme.S(2.5f) * (1 - k * 0.6f)))) g.DrawPath(pen, p);
            }
        }

        // «Желе» ползунка: насколько он сейчас в пути (0 — стоит, 1 — посередине).
        static float SwitchTravel(float k) { return 4f * k * (1f - k); }

        // --- Блик по полоске лимита после раскрытия ---
        void PaintLimitShine(Graphics g, RectangleF fill) {
            double t = PageShownSeconds - 0.35;
            if (!Animate || t < 0 || t > 1.1 || fill.Width < 4) { if (t >= 0 && t <= 1.1) WakeUi(); return; }
            WakeUi();
            float w = Math.Max(theme.S(30), fill.Width * 0.3f);
            float x = fill.X - w + (float)(t / 1.1) * (fill.Width + w);
            RectangleF hr = new RectangleF(x, fill.Y, w, fill.Height);
            using (LinearGradientBrush hb = new LinearGradientBrush(hr, Color.Transparent, Color.Transparent, 0f)) {
                ColorBlend cb = new ColorBlend();
                cb.Colors = new Color[] { Color.FromArgb(0, 255, 255, 255), Color.FromArgb(150, 255, 255, 255), Color.FromArgb(0, 255, 255, 255) };
                cb.Positions = new float[] { 0, 0.5f, 1 };
                hb.InterpolationColors = cb;
                Region old = g.Clip; g.SetClip(fill, CombineMode.Intersect); g.FillRectangle(hb, hr); g.Clip = old; old.Dispose();
            }
        }

        // Рост i-го столбика графика: 0 → 1 с пружинкой, по очереди.
        float BarGrow(int i) {
            if (!Animate || pageShownAt == DateTime.MinValue) return 1f;
            double t = (DateTime.UtcNow - pageShownAt).TotalSeconds - 0.12 - i * 0.05;
            float k = (float)Math.Max(0, Math.Min(1, t / 0.5));
            if (k < 1f) WakeUi();
            return Math.Max(0, EaseBack(k));
        }
    }
}
