// claude-notifier: особые страницы и строки шторки.
//  • Таймлайн дня (строка timeline на «Статистике»): по проекту полоса, на ней отрезки — работал (зелёный),
//    ждал вас (янтарный), запрос разрешения (оранжевый), ошибка (красный); отметка «сейчас». Полосы
//    прорисовываются слева направо при открытии страницы.
//  • Отчёт за неделю (страница report): слева маскот вручает листок отчёта, справа — строки итогов.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Windows.Forms;

namespace ClaudeNotifier.Ui {
    public sealed partial class NotchView {
        static Color TimelineColor(string state) {
            switch (state) {
                case "working": return Color.FromArgb(48, 209, 88);
                case "permission": return Color.FromArgb(191, 90, 242);   // запрос — фиолетовый, не путать с ожиданием
                case "error": return Color.FromArgb(255, 69, 58);
                default: return Color.FromArgb(255, 179, 64);   // ждал вас
            }
        }

        void PaintTimeline(Graphics g, NotchRow row, Rectangle r) {
            int pad = theme.S(16);
            TextRenderer.DrawText(g, row.Title, fBold, new Rectangle(r.X + pad, r.Y + theme.S(10), r.Width - pad * 2, theme.S(20)), Fg, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            TextRenderer.DrawText(g, row.Subtitle, fSmall, new Rectangle(r.X + pad, r.Y + theme.S(30), r.Width - pad * 2, theme.S(18)), theme.Muted, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            // Отрезки: "полоса|от|до|статус" (минуты от полуночи).
            double nowMin = row.Values.Length > 0 ? row.Values[0] : DateTime.Now.TimeOfDay.TotalMinutes;
            double minFrom = nowMin;
            foreach (string a in row.Actions) {
                string[] p = a.Split('|'); double f;
                if (p.Length >= 4 && double.TryParse(p[1], NumberStyles.Float, CultureInfo.InvariantCulture, out f)) minFrom = Math.Min(minFrom, f);
            }
            double h0 = Math.Max(0, Math.Floor(minFrom / 60)), h1 = Math.Min(24, Math.Max(h0 + 3, Math.Ceiling((nowMin + 1) / 60)));
            int labelW = theme.S(120), top = r.Y + theme.S(58), laneH = theme.S(24), barH = theme.S(12);
            int x0 = r.X + pad + labelW, x1 = r.Right - pad;
            Func<double, float> X = delegate (double min) { return (float)(x0 + (x1 - x0) * Math.Max(0, Math.Min(1, (min - h0 * 60) / ((h1 - h0) * 60)))); };
            // Часы: тонкие линии и подписи.
            int step = h1 - h0 > 12 ? 3 : h1 - h0 > 6 ? 2 : 1;
            int lanes = Math.Max(1, row.Labels.Length);
            using (Pen grid = new Pen(Pal(0x2C2C2E), 1f)) {
                for (double h = h0; h <= h1; h += 1) {
                    float x = X(h * 60);
                    g.DrawLine(grid, x, top - theme.S(4), x, top + lanes * laneH - theme.S(6));
                    if (((int)h - (int)h0) % step == 0)
                        TextRenderer.DrawText(g, ((int)h % 24).ToString("00") + ":00", fSmall, new Rectangle((int)x - theme.S(24), top + lanes * laneH - theme.S(4), theme.S(48), theme.S(16)), Pal(0x6E6E73), TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPrefix);
                }
            }
            // Прорисовка слева направо при открытии страницы.
            double reveal = 1;
            if (Animate) { double t = PageShownSeconds - 0.15; reveal = t <= 0 ? 0 : Math.Min(1, 1 - Math.Pow(1 - Math.Min(1, t / 0.9), 3)); if (reveal < 1) WakeUi(); }
            float revealX = x0 + (float)((x1 - x0) * reveal);
            for (int i = 0; i < row.Labels.Length; i++) {
                int ly = top + i * laneH;
                TextRenderer.DrawText(g, row.Labels[i], fSmall, new Rectangle(r.X + pad, ly, labelW - theme.S(10), barH + theme.S(4)), Pal(0xC7C7CC), TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter);
                Draw.Fill(g, new RectangleF(x0, ly + theme.S(2), x1 - x0, barH), barH / 2f, Pal(0x1F1F22));
            }
            Region old = g.Clip;
            g.SetClip(new RectangleF(x0, top - theme.S(2), Math.Max(0, revealX - x0), lanes * laneH), CombineMode.Intersect);
            foreach (string a in row.Actions) {
                string[] p = a.Split('|');
                int lane; double f, t2;
                if (p.Length < 4 || !int.TryParse(p[0], out lane) || !double.TryParse(p[1], NumberStyles.Float, CultureInfo.InvariantCulture, out f) || !double.TryParse(p[2], NumberStyles.Float, CultureInfo.InvariantCulture, out t2)) continue;
                float a0 = X(f), a1 = Math.Max(a0 + theme.S(3), X(t2));
                RectangleF seg = new RectangleF(a0, top + lane * laneH + theme.S(2), a1 - a0, barH);
                Draw.Fill(g, seg, Math.Min(barH / 2f, seg.Width / 2f), TimelineColor(p[3]));
            }
            g.Clip = old; old.Dispose();
            // «Сейчас»: вертикальная отметка с точкой.
            float nx = X(nowMin);
            if (nx <= revealX + 1) {
                using (Pen np = new Pen(Color.FromArgb(200, Fg), Math.Max(1f, theme.S(1.5f)))) g.DrawLine(np, nx, top - theme.S(6), nx, top + lanes * laneH - theme.S(8));
                float d = theme.S(6);
                using (SolidBrush b = new SolidBrush(Fg)) g.FillEllipse(b, nx - d / 2, top - theme.S(6) - d / 2, d, d);
            }
            // Легенда.
            int lx = r.Right - pad, ly2 = r.Y + theme.S(12);
            string[][] legend = { new[] { "error", "ошибка" }, new[] { "permission", "запрос" }, new[] { "waiting", "ждал вас" }, new[] { "working", "работал" } };
            foreach (string[] it in legend) {
                int tw = TextRenderer.MeasureText(it[1], fSmall).Width;
                lx -= tw;
                TextRenderer.DrawText(g, it[1], fSmall, new Point(lx, ly2), theme.Muted, TextFormatFlags.NoPrefix);
                lx -= theme.S(12);
                using (SolidBrush b = new SolidBrush(TimelineColor(it[0]))) g.FillEllipse(b, lx, ly2 + theme.S(4), theme.S(8), theme.S(8));
                lx -= theme.S(10);
            }
        }

        // Отчёт за неделю: слева маскот вручает листок (листок вылетает к вам и покачивается), справа — итоги.
        void PaintReport(Graphics g, Rectangle area) {
            int lw = Math.Min(theme.S(250), area.Width / 3);
            Rectangle left = new Rectangle(area.X, area.Y, lw, area.Height), right = new Rectangle(area.X + lw + theme.S(14), area.Y, area.Width - lw - theme.S(14), area.Height);
            Draw.Fill(g, left, theme.S(18), Pal(0x161618));
            double t = PageShownSeconds;
            if (Animate && t < 30) WakeUi();
            float msz = Math.Min(theme.S(120), left.Height - theme.S(70));
            RectangleF mr = new RectangleF(left.X + theme.S(18), left.Bottom - msz - theme.S(34), msz, msz);
            CatMood md = new CatMood { Play = true, Friend = (float)Affection, Level = MascotLevel, HasLook = true, LookX = 0.8f, LookY = 0.2f, LookW = 1f };
            if (t < 2.5) { md.React = "joy"; md.ReactAge = (float)t; }
            else { double wp = (t - 2.5) % 5.0; if (wp < 1.6) md.Wave = (float)Math.Sin(Math.PI * wp / 1.6); }
            try { Mascot.PaintKind(g, mr, Mascot.For(null), "waiting", T, 5, Animate, md); } catch { }
            // Листок: вылетает из лап на пружинке, потом покачивается.
            float k = Animate ? (float)Math.Max(0, Math.Min(1, (t - 0.3) / 0.7)) : 1f;
            float e = 1 + 2.70158f * (float)Math.Pow(k - 1, 3) + 1.70158f * (float)Math.Pow(k - 1, 2);
            float pw = theme.S(78), ph = theme.S(96);
            float px = mr.Right - pw * 0.35f + (left.Right - theme.S(14) - pw - (mr.Right - pw * 0.35f)) * e;
            float py = mr.Y + theme.S(10) - theme.S(26) * e + (float)Math.Sin(T * 2.2) * theme.S(3) * k;
            GraphicsState st = g.Save();
            g.TranslateTransform(px + pw / 2, py + ph / 2); g.RotateTransform(-8f + 14f * e + (float)Math.Sin(T * 1.7) * 2f * k); g.TranslateTransform(-pw / 2, -ph / 2);
            if (k > 0.02f) {
                Draw.Fill(g, new RectangleF(theme.S(3), theme.S(4), pw, ph), theme.S(8), Color.FromArgb(70, 0, 0, 0));
                Draw.Fill(g, new RectangleF(0, 0, pw, ph), theme.S(8), Color.FromArgb(250, 248, 244));
                using (SolidBrush acc = new SolidBrush(theme.Accent)) g.FillRectangle(acc, theme.S(10), theme.S(12), pw * 0.5f, theme.S(5));
                using (SolidBrush line = new SolidBrush(Color.FromArgb(200, 210, 210, 216)))
                    for (int i = 0; i < 5; i++) g.FillRectangle(line, theme.S(10), theme.S(26) + i * theme.S(11), (pw - theme.S(20)) * (i % 2 == 0 ? 1f : 0.7f), theme.S(4));
                // Столбики-график внизу листка.
                Color[] cols = { Color.FromArgb(48, 209, 88), Color.FromArgb(10, 132, 255), Color.FromArgb(255, 179, 64) };
                for (int i = 0; i < 3; i++) {
                    float bh = theme.S(8) + theme.S(6) * i;
                    using (SolidBrush b = new SolidBrush(cols[i])) g.FillRectangle(b, pw - theme.S(36) + i * theme.S(9), ph - theme.S(10) - bh, theme.S(6), bh);
                }
            }
            g.Restore(st);
            TextRenderer.DrawText(g, "Отчёт за неделю", fBold, new Rectangle(left.X, left.Bottom - theme.S(30), left.Width, theme.S(22)), Fg, TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            PaintRows(g, right);
        }
    }
}
