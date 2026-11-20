// claude-notifier: окно обновления в духе macOS — живые состояния вместо полоски.
// Значок приложения (силуэт сфинкса на градиентной плитке) в кольце прогресса; справа — заголовок, шаг и полоса.
//   download — кольцо и полоса заполняются по мере скачивания, у значка прыгает стрелка «вниз»;
//   verify / extract — кольцо бежит по кругу, значок мягко «дышит»;
//   install — бегущий отрезок на полосе с бликом, кольцо крутится быстрее;
//   restart — значок вращается на месте (перезапуск);
//   done — кольцо зеленеет и замыкается, значок подпрыгивает (пружина), выскакивает галочка и искры;
//   error — кольцо краснеет, окно вздрагивает, «!» в бейдже.
// Шаги «Скачивание · Установка · Запуск» — точки: пройденные зелёные, текущая пульсирует.
// Появление — снизу с пружиной и проявлением; уход — растворение. 60 кадров/с, работа обновления — в другом потоке.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClaudeNotifier.Update {
    // Общее состояние: пишет поток обновления, читает окно.
    public sealed class UpdateState {
        public volatile string Phase = "download";   // download | verify | extract | install | restart | done | error
        public volatile string Detail = "";          // «128 КБ», текст ошибки
        public double Pct = -1;                       // 0..1, < 0 — неизвестно
        public volatile bool Finished;                // работа закончена (окно может закрываться)
    }

    public sealed class UpdateWindow : Form {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);

        readonly UpdateState st;
        readonly Timer tick = new Timer();
        readonly DateTime born = DateTime.UtcNow;
        DateTime phaseAt = DateTime.UtcNow, closeAt = DateTime.MaxValue;
        string phaseShown = "", prevText = "", curText = "", lastWork = "download";
        double ring, bar;              // показанные (сглаженные) значения прогресса
        double ringSpin;               // угол бегущего кольца
        double popVel, pop;            // пружина «подпрыгнуть» при успехе
        double shake;                  // вздрагивание при ошибке
        readonly List<float[]> sparks = new List<float[]>();   // искры: x, y, vx, vy, жизнь
        readonly Random rnd = new Random(7);
        Point home;
        Font fTitle, fText, fSmall, fGlyph;
        public static readonly string[] Steps = { "Скачивание", "Установка", "Запуск" };

        public UpdateWindow(UpdateState state) {
            st = state;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = true; TopMost = true; StartPosition = FormStartPosition.Manual;
            Text = "Обновление Claude Notifier";
            BackColor = Color.FromArgb(28, 28, 30);
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            ClientSize = new Size(440, 156);
            fTitle = new Font("Segoe UI Semibold", 11.5f); fText = new Font("Segoe UI", 9.75f); fSmall = new Font("Segoe UI", 8.25f);
            fGlyph = new Font("Segoe MDL2 Assets", 11f);
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            home = new Point(wa.Right - Width - 24, wa.Bottom - Height - 24);
            Location = new Point(home.X, home.Y + 28);
            Opacity = 0;
            tick.Interval = 15;
            tick.Tick += delegate { Step(); };
        }

        protected override CreateParams CreateParams { get { CreateParams cp = base.CreateParams; cp.ClassStyle |= 0x20000; return cp; } }   // тень (CS_DROPSHADOW)

        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e);
            try { int v = 2; DwmSetWindowAttribute(Handle, 33, ref v, 4); int d = 1; DwmSetWindowAttribute(Handle, 20, ref d, 4); int b = ColorTranslator.ToWin32(Color.FromArgb(58, 58, 60)); DwmSetWindowAttribute(Handle, 34, ref b, 4); } catch { }
        }

        protected override void OnShown(EventArgs e) { base.OnShown(e); tick.Start(); }

        static double Ease(double t) { t = Math.Max(0, Math.Min(1, t)); return 1 - Math.Pow(1 - t, 3); }
        static double EaseBack(double t) { t = Math.Max(0, Math.Min(1, t)); double c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * Math.Pow(t - 1, 3) + c1 * Math.Pow(t - 1, 2); }
        double Since(DateTime t) { return (DateTime.UtcNow - t).TotalSeconds; }

        public static string TextFor(string phase, string detail) {
            switch (phase) {
                case "download": return string.IsNullOrEmpty(detail) ? "Скачиваю обновление…" : "Скачиваю обновление… " + detail;
                case "verify": return "Проверяю подпись архива…";
                case "extract": return "Распаковываю…";
                case "install": return "Устанавливаю — трей перезапустится";
                case "restart": return "Запускаю новую версию…";
                case "done": return "Готово — приложение обновлено";
                case "error": return string.IsNullOrEmpty(detail) ? "Не удалось обновить" : "Не удалось: " + detail;
                default: return "";
            }
        }

        public static int StepOf(string phase) {
            switch (phase) { case "download": case "verify": case "extract": return 0; case "install": return 1; default: return 2; }
        }

        Color Accent { get { return st.Phase == "error" ? Color.FromArgb(255, 69, 58) : st.Phase == "done" ? Color.FromArgb(48, 209, 88) : Color.FromArgb(10, 132, 255); } }

        // Кадр: появление, смена шага, пружины, искры; закрытие после «Готово» или ошибки.
        void Step() {
            double age = Since(born);
            double inK = EaseBack(age / 0.42);
            if (closeAt == DateTime.MaxValue || DateTime.UtcNow < closeAt) {
                Opacity = Math.Min(1, age / 0.22);
                Location = new Point(home.X + (int)Math.Round(shake), home.Y + (int)Math.Round(28 * (1 - inK)));
            }
            string phase = st.Phase;
            if (phase != phaseShown) {
                if (phase != "error" && phase != "done") lastWork = phase;   // на каком шаге были (для ошибки)
                prevText = curText; curText = TextFor(phase, st.Detail);
                phaseShown = phase; phaseAt = DateTime.UtcNow;
                if (phase == "done") { popVel = -9; Burst(); closeAt = DateTime.UtcNow.AddSeconds(2.4); }
                if (phase == "error") { shake = 14; closeAt = DateTime.UtcNow.AddSeconds(7); }
            } else curText = TextFor(phase, st.Detail);
            double target = phase == "done" ? 1 : st.Pct;
            if (target >= 0) { ring += (target - ring) * 0.18; bar += (target - bar) * 0.18; }
            ringSpin += phase == "install" || phase == "restart" ? 7.5 : 4.2;
            popVel += -pop * 0.35; popVel *= 0.80; pop += popVel * 0.016 * 6;
            if (shake != 0) { shake = -shake * 0.82; if (Math.Abs(shake) < 0.4) shake = 0; }
            for (int i = sparks.Count - 1; i >= 0; i--) {
                float[] s = sparks[i]; s[0] += s[2]; s[1] += s[3]; s[3] += 0.12f; s[4] -= 0.022f;
                if (s[4] <= 0) sparks.RemoveAt(i);
            }
            if (st.Finished && closeAt == DateTime.MaxValue) closeAt = DateTime.UtcNow.AddSeconds(0.4);   // закончили без «Готово»/ошибки
            if (DateTime.UtcNow >= closeAt && st.Finished) {
                double k = Since(closeAt) / 0.28;
                Opacity = Math.Max(0, 1 - k);
                Location = new Point(home.X, home.Y + (int)(10 * Ease(k)));
                if (k >= 1) { tick.Stop(); Close(); return; }
            }
            Invalidate();
        }

        void Burst() {
            for (int i = 0; i < 18; i++) {
                double a = rnd.NextDouble() * Math.PI * 2, v = 2.2 + rnd.NextDouble() * 2.6;
                sparks.Add(new float[] { 60, 66, (float)(Math.Cos(a) * v), (float)(Math.Sin(a) * v - 1.2), 1f });
            }
        }

        static GraphicsPath RoundRect(RectangleF r, float rad) {
            GraphicsPath p = new GraphicsPath(); float d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure(); return p;
        }

        // Силуэт сфинкса — как в трее и на логотипе (16-единичная сетка).
        static void Glyph(Graphics g, RectangleF r, Color c) {
            float u = r.Width / 16f, x = r.X, y = r.Y;
            using (SolidBrush b = new SolidBrush(c)) {
                g.FillEllipse(b, x + 1.2f * u, y + 4.8f * u, 13.6f * u, 10.4f * u);
                g.FillPolygon(b, new PointF[] { new PointF(x + 1.4f * u, y + 9.4f * u), new PointF(x + 2.0f * u, y + 0.8f * u), new PointF(x + 7.4f * u, y + 5.4f * u) });
                g.FillPolygon(b, new PointF[] { new PointF(x + 14.6f * u, y + 9.4f * u), new PointF(x + 14.0f * u, y + 0.8f * u), new PointF(x + 8.6f * u, y + 5.4f * u) });
            }
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            g.Clear(BackColor);
            string phase = st.Phase;
            Color acc = Accent;
            double t = Since(born);
            // --- Значок в кольце ---
            float cx = 60, cy = 66, R = 40;
            using (Pen track = new Pen(Color.FromArgb(48, 255, 255, 255), 4f)) g.DrawEllipse(track, cx - R, cy - R, R * 2, R * 2);
            using (Pen arc = new Pen(acc, 4f)) {
                arc.StartCap = arc.EndCap = LineCap.Round;
                bool indeterminate = st.Pct < 0 && phase != "done" && phase != "error";
                if (indeterminate) g.DrawArc(arc, cx - R, cy - R, R * 2, R * 2, (float)ringSpin, 90 + 50 * (float)Math.Sin(t * 2.4));
                else { float sweep = (float)(360 * Math.Max(0.001, phase == "error" ? 1 : ring)); g.DrawArc(arc, cx - R, cy - R, R * 2, R * 2, -90, sweep); }
            }
            if (phase == "done") {
                double k = Math.Max(0, 1 - Since(phaseAt) / 1.2);
                if (k > 0) using (Pen glow = new Pen(Color.FromArgb((int)(110 * k), acc), 10f)) g.DrawEllipse(glow, cx - R, cy - R, R * 2, R * 2);
            }
            GraphicsState gs = g.Save();
            float scale = 1f + (float)pop * 0.12f;
            if (phase == "verify" || phase == "extract") scale *= 1f + 0.035f * (float)Math.Sin(t * 4.2);   // «дышит»
            g.TranslateTransform(cx, cy);
            g.ScaleTransform(scale, scale);
            RectangleF tile = new RectangleF(-27, -27, 54, 54);
            using (GraphicsPath p = RoundRect(tile, 14))
            using (LinearGradientBrush lg = new LinearGradientBrush(tile, Color.FromArgb(10, 132, 255), Color.FromArgb(94, 92, 230), 90f)) {
                lg.WrapMode = WrapMode.TileFlipXY; g.FillPath(lg, p);
                // Блик, скользящий по плитке.
                float sx = (float)(((t * 0.55) % 1.6) * 90 - 50);
                using (LinearGradientBrush shine = new LinearGradientBrush(new RectangleF(sx - 18, -27, 36, 54), Color.FromArgb(0, 255, 255, 255), Color.FromArgb(0, 255, 255, 255), 0f)) {
                    ColorBlend cb = new ColorBlend(); cb.Colors = new Color[] { Color.FromArgb(0, 255, 255, 255), Color.FromArgb(46, 255, 255, 255), Color.FromArgb(0, 255, 255, 255) }; cb.Positions = new float[] { 0, 0.5f, 1 };
                    shine.InterpolationColors = cb;
                    Region old = g.Clip; g.SetClip(p, CombineMode.Intersect); g.FillRectangle(shine, sx - 18, -27, 36, 54); g.Clip = old;
                }
            }
            Glyph(g, new RectangleF(-17, -16, 34, 34), Color.White);
            using (SolidBrush eye = new SolidBrush(Color.FromArgb(70, 98, 240))) { g.FillEllipse(eye, -9.3f, 1.3f, 5.6f, 4.4f); g.FillEllipse(eye, 2.0f, 1.3f, 5.6f, 4.4f); }
            g.Restore(gs);
            // Бейдж у значка: стрелка вниз при скачивании (прыгает), стрелка перезапуска (крутится), галочка при
            // успехе, «!» при ошибке. Появляется с пружиной.
            if (phase == "download" || phase == "restart" || phase == "done" || phase == "error") {
                float bob = phase == "download" ? (float)(Math.Abs(Math.Sin(t * 5)) * -4) : 0f;
                float bs = phase == "download" ? 1f : (float)EaseBack(Since(phaseAt) / 0.4);
                float bx = cx + 22, by = cy + 22 + bob, br = 11 * bs;
                if (br > 0.5f) {
                    using (SolidBrush ring2 = new SolidBrush(BackColor)) g.FillEllipse(ring2, bx - br - 2.5f, by - br - 2.5f, (br + 2.5f) * 2, (br + 2.5f) * 2);
                    using (SolidBrush bb = new SolidBrush(acc)) g.FillEllipse(bb, bx - br, by - br, br * 2, br * 2);
                    string glyph = phase == "download" ? "" : phase == "restart" ? "" : phase == "done" ? "" : "";
                    if (bs > 0.6f) {
                        GraphicsState bgs = g.Save();
                        if (phase == "restart") { g.TranslateTransform(bx, by); g.RotateTransform((float)(Since(phaseAt) * 300 % 360)); g.TranslateTransform(-bx, -by); }
                        TextRenderer.DrawText(g, glyph, fGlyph, new Rectangle((int)(bx - 12), (int)(by - 12), 24, 24), Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
                        g.Restore(bgs);
                    }
                }
            }
            foreach (float[] s in sparks) {
                Color c = s[0] % 2 < 1 ? Color.FromArgb((int)(255 * s[4]), 48, 209, 88) : Color.FromArgb((int)(255 * s[4]), 255, 214, 10);
                using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, s[0] - 2.2f, s[1] - 2.2f, 4.4f, 4.4f);
            }
            // --- Текст ---
            float tx = 118;
            TextRenderer.DrawText(g, "Обновление Claude Notifier", fTitle, new Point((int)tx, 22), Color.White, TextFormatFlags.NoPrefix);
            // Смена текста шага: прежний уходит вверх и тает, новый приходит снизу.
            double ch = Ease(Since(phaseAt) / 0.28);
            if (ch < 1 && !string.IsNullOrEmpty(prevText))
                TextRenderer.DrawText(g, prevText, fText, new Rectangle((int)tx, (int)(48 - 8 * ch), Width - (int)tx - 18, 20), Mix(BackColor, Color.FromArgb(170, 170, 176), 1 - ch), TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
            Color textCol = phase == "error" ? Color.FromArgb(255, 120, 110) : Color.FromArgb(178, 178, 184);
            TextRenderer.DrawText(g, curText, fText, new Rectangle((int)tx, (int)(48 + 8 * (1 - ch)), Width - (int)tx - 18, 20), Mix(BackColor, textCol, ch), TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
            // --- Шаги ---
            int cur = phase == "done" ? 3 : StepOf(phase == "error" ? lastWork : phase);
            float sx2 = tx;
            for (int i = 0; i < Steps.Length; i++) {
                bool doneStep = i < cur, now = i == cur;   // при ошибке «текущий» — шаг, на котором она случилась (красный)
                float d = 8;
                Color dc = doneStep ? Color.FromArgb(48, 209, 88) : now ? acc : Color.FromArgb(72, 72, 76);
                if (now) { float pulse = (float)(0.5 + 0.5 * Math.Sin(t * 5)); using (SolidBrush halo = new SolidBrush(Color.FromArgb((int)(70 * pulse), acc))) g.FillEllipse(halo, sx2 - 3, 82 - 3, d + 6, d + 6); }
                using (SolidBrush b = new SolidBrush(dc)) g.FillEllipse(b, sx2, 82, d, d);
                Color lc = doneStep || now ? Color.FromArgb(220, 220, 226) : Color.FromArgb(110, 110, 116);
                Size ls = TextRenderer.MeasureText(Steps[i], fSmall);
                TextRenderer.DrawText(g, Steps[i], fSmall, new Point((int)sx2 + 12, 78), lc, TextFormatFlags.NoPrefix);
                sx2 += 12 + ls.Width + 12;
            }
            // --- Полоса ---
            RectangleF track2 = new RectangleF(tx, 110, Width - tx - 22, 7);
            using (GraphicsPath tp = RoundRect(track2, 3.5f)) using (SolidBrush tb = new SolidBrush(Color.FromArgb(52, 52, 56))) g.FillPath(tb, tp);
            bool ind = st.Pct < 0 && phase != "done" && phase != "error";
            RectangleF fill;
            if (ind) {
                double ph = (t * 0.75) % 1.0, k = (Math.Sin((ph - 0.5) * Math.PI) + 1) / 2;   // плавный ход
                float w = track2.Width * 0.34f, x = track2.X - w + (float)((track2.Width + w) * k);
                fill = RectangleF.Intersect(track2, new RectangleF(x, track2.Y, w, track2.Height));
            } else fill = new RectangleF(track2.X, track2.Y, (float)(track2.Width * Math.Max(0, Math.Min(1, phase == "error" ? 1 : bar))), track2.Height);
            if (fill.Width > 1) {
                Color c2 = phase == "done" ? Color.FromArgb(52, 199, 89) : phase == "error" ? Color.FromArgb(255, 69, 58) : Color.FromArgb(94, 92, 230);
                using (GraphicsPath fp = RoundRect(fill, Math.Min(3.5f, fill.Width / 2)))
                using (LinearGradientBrush fb = new LinearGradientBrush(new RectangleF(fill.X - 1, fill.Y, fill.Width + 2, fill.Height), acc, c2, 0f)) {
                    fb.WrapMode = WrapMode.TileFlipXY; g.FillPath(fb, fp);
                    float hx = fill.X + (float)(((t * 0.9) % 1.4) * fill.Width) - 20;
                    using (LinearGradientBrush hb = new LinearGradientBrush(new RectangleF(hx, fill.Y, 40, fill.Height), Color.FromArgb(0, 255, 255, 255), Color.FromArgb(0, 255, 255, 255), 0f)) {
                        ColorBlend cb = new ColorBlend(); cb.Colors = new Color[] { Color.FromArgb(0, 255, 255, 255), Color.FromArgb(90, 255, 255, 255), Color.FromArgb(0, 255, 255, 255) }; cb.Positions = new float[] { 0, 0.5f, 1 };
                        hb.InterpolationColors = cb;
                        Region old = g.Clip; g.SetClip(fp, CombineMode.Intersect); g.FillRectangle(hb, hx, fill.Y, 40, fill.Height); g.Clip = old;
                    }
                }
            }
            if (!ind && phase == "download" && st.Pct >= 0) TextRenderer.DrawText(g, ((int)Math.Round(bar * 100)) + "%", fSmall, new Rectangle((int)track2.Right - 40, 122, 40, 16), Color.FromArgb(150, 150, 156), TextFormatFlags.Right | TextFormatFlags.NoPrefix);
        }

        static Color Mix(Color a, Color b, double k) {
            k = Math.Max(0, Math.Min(1, k));
            return Color.FromArgb((int)(a.R + (b.R - a.R) * k), (int)(a.G + (b.G - a.G) * k), (int)(a.B + (b.B - a.B) * k));
        }

        // Тесты и снимки: кадр состояния без окна на экране (seconds — сколько «прошло» с начала шага).
        public Bitmap Snapshot(int frames) {
            for (int i = 0; i < frames; i++) Step();
            Bitmap b = new Bitmap(ClientSize.Width, ClientSize.Height);
            DrawToBitmap(b, new Rectangle(0, 0, b.Width, b.Height));
            return b;
        }

        protected override void Dispose(bool disposing) {
            if (disposing) { tick.Dispose(); fTitle.Dispose(); fText.Dispose(); fSmall.Dispose(); fGlyph.Dispose(); }
            base.Dispose(disposing);
        }
    }
}
