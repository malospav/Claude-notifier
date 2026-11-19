// claude-notifier: маскот растёт вместе с вами.
//   * Дружба (гладите маскота — она растёт): от 40 % — бантик, от 60 % — искры, когда гладят, от 80 % — корона.
//   * Настроение дня: много «Готово» к вечеру — праздничный колпачок; много ошибок — чашка чая рядом (сочувствует).
//   * Цвет: свой оттенок маскота этого ПК (сдвиг оттенка, пастель, чёрно-белый) — настройка «Цвет маскота».
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace ClaudeNotifier.Ui {
    public static class MascotStyle {
        // Уровни дружбы (0..100): с какого значения открывается украшение или реакция.
        public const float BowAt = 40f, SparkAt = 60f, CrownAt = 80f;

        public static string[] Unlocked(float friend) {
            System.Collections.Generic.List<string> l = new System.Collections.Generic.List<string>();
            if (friend >= BowAt) l.Add("bow");
            if (friend >= SparkAt) l.Add("sparks");
            if (friend >= CrownAt) l.Add("crown");
            return l.ToArray();
        }

        static int A(float v) { return Math.Max(0, Math.Min(255, (int)v)); }

        // Украшения дружбы и настроения дня поверх головы. top — на макушке уже что-то есть (колпак, гирлянда).
        internal static void Paint(Graphics g, float hx, float htop, float hw, float hface, float u, CatMood m, float t, bool top) {
            if (m == null || !m.Play) return;
            bool crown = m.Friend >= CrownAt && !top;
            bool party = m.DayMood == "cheer" && !top && !crown;
            if (crown) Crown(g, hx, htop, hw, u, t);
            else if (m.Friend >= BowAt) Bow(g, hx - hw * 0.78f, htop + u * 0.07f, u, t);
            if (party) PartyHat(g, hx, htop, hw, u, t);
            if (m.DayMood == "tea") Tea(g, hx + hw + u * 0.2f, hface + u * 0.36f, u, t);
            if (m.Pet > 0.02f && m.Friend >= SparkAt) Sparks(g, hx, htop, hw, hface, u, t, m.Pet);
        }

        static void Bow(Graphics g, float x, float y, float u, float t) {
            float s = u * 0.085f, wob = (float)Math.Sin(t * 2.2) * s * 0.08f;
            Color c = Color.FromArgb(240, 255, 99, 146), d = Color.FromArgb(240, 214, 60, 110);
            using (SolidBrush b = new SolidBrush(c)) {
                g.FillPolygon(b, new PointF[] { new PointF(x, y), new PointF(x - s * 1.3f, y - s * 0.75f + wob), new PointF(x - s * 1.25f, y + s * 0.8f - wob) });
                g.FillPolygon(b, new PointF[] { new PointF(x, y), new PointF(x + s * 1.3f, y - s * 0.75f - wob), new PointF(x + s * 1.25f, y + s * 0.8f + wob) });
            }
            using (SolidBrush b = new SolidBrush(d)) g.FillEllipse(b, x - s * 0.38f, y - s * 0.38f, s * 0.76f, s * 0.76f);
        }

        static void Crown(Graphics g, float hx, float htop, float hw, float u, float t) {
            float w = Math.Min(hw, u * 0.26f) * 0.9f, h = u * 0.15f, by = htop + u * 0.06f;
            PointF[] pts = {
                new PointF(hx - w, by), new PointF(hx - w * 1.05f, by - h * 0.95f), new PointF(hx - w * 0.5f, by - h * 0.45f),
                new PointF(hx, by - h * 1.15f), new PointF(hx + w * 0.5f, by - h * 0.45f), new PointF(hx + w * 1.05f, by - h * 0.95f), new PointF(hx + w, by)
            };
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddPolygon(pts);
                using (LinearGradientBrush br = new LinearGradientBrush(new RectangleF(hx - w, by - h * 1.2f, w * 2, h * 1.3f), Color.FromArgb(250, 255, 224, 102), Color.FromArgb(250, 230, 160, 20), LinearGradientMode.Vertical))
                    g.FillPath(br, p);
            }
            // Камушки мерцают.
            Color[] gems = { Color.FromArgb(255, 69, 58), Color.FromArgb(100, 210, 255), Color.FromArgb(48, 209, 88) };
            for (int i = 0; i < 3; i++) {
                float gx = hx + (i - 1) * w * 0.6f, d = u * 0.035f;
                float tw = 0.75f + 0.25f * (float)Math.Sin(t * 3 + i * 2);
                using (SolidBrush b = new SolidBrush(Color.FromArgb(A(255 * tw), gems[i]))) g.FillEllipse(b, gx - d / 2, by - h * 0.32f - d / 2, d, d);
            }
        }

        static void PartyHat(Graphics g, float hx, float htop, float hw, float u, float t) {
            float w = Math.Min(hw, u * 0.26f) * 0.55f, h = u * 0.3f, by = htop + u * 0.05f;
            float lean = 0.18f + (float)Math.Sin(t * 1.6) * 0.03f;
            GraphicsState gs = g.Save();
            g.TranslateTransform(hx + w * 0.4f, by); g.RotateTransform(lean * 57.3f);
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddPolygon(new PointF[] { new PointF(-w, 0), new PointF(0, -h), new PointF(w, 0) });
                using (SolidBrush b = new SolidBrush(Color.FromArgb(245, 120, 90, 230))) g.FillPath(b, p);
                Region old = g.Clip; g.SetClip(p, CombineMode.Intersect);
                using (Pen stripe = new Pen(Color.FromArgb(230, 255, 214, 10), Math.Max(1f, u * 0.035f)))
                    for (int i = 1; i <= 3; i++) g.DrawLine(stripe, -w, -h * i / 4f + h * 0.12f, w, -h * i / 4f - h * 0.12f);
                g.Clip = old; old.Dispose();
            }
            float d = u * 0.075f;
            using (SolidBrush b = new SolidBrush(Color.FromArgb(250, 255, 105, 140))) g.FillEllipse(b, -d / 2, -h - d / 2, d, d);
            g.Restore(gs);
            // Конфетти падают.
            Color[] cols = { Color.FromArgb(255, 69, 58), Color.FromArgb(255, 214, 10), Color.FromArgb(48, 209, 88), Color.FromArgb(100, 210, 255) };
            for (int i = 0; i < 4; i++) {
                float ph = (float)(((t * 0.4 + i / 4.0) % 1.0 + 1.0) % 1.0);
                float x = hx + (i - 1.5f) * hw * 0.9f + (float)Math.Sin(t * 2 + i) * u * 0.04f, y = htop - u * 0.25f + ph * u * 0.8f;
                using (SolidBrush b = new SolidBrush(Color.FromArgb(A(220 * (1 - ph)), cols[i]))) g.FillRectangle(b, x, y, u * 0.03f, u * 0.05f);
            }
        }

        static void Tea(Graphics g, float x, float y, float u, float t) {
            float w = u * 0.16f, h = u * 0.12f;
            using (SolidBrush b = new SolidBrush(Color.FromArgb(240, 245, 245, 250))) {
                using (GraphicsPath p = new GraphicsPath()) {
                    p.AddLine(x - w / 2, y - h / 2, x + w / 2, y - h / 2);
                    p.AddBezier(x + w / 2, y - h / 2, x + w / 2, y + h * 0.4f, x + w * 0.25f, y + h / 2, x, y + h / 2);
                    p.AddBezier(x, y + h / 2, x - w * 0.25f, y + h / 2, x - w / 2, y + h * 0.4f, x - w / 2, y - h / 2);
                    g.FillPath(b, p);
                }
            }
            using (Pen handle = new Pen(Color.FromArgb(240, 245, 245, 250), Math.Max(1f, u * 0.025f))) g.DrawArc(handle, x + w * 0.35f, y - h * 0.35f, w * 0.35f, h * 0.5f, -90, 180);
            using (SolidBrush tea = new SolidBrush(Color.FromArgb(230, 196, 120, 60))) g.FillEllipse(tea, x - w * 0.45f, y - h * 0.58f, w * 0.9f, h * 0.18f);
            // Пар.
            using (Pen steam = new Pen(Color.FromArgb(150, 230, 230, 240), Math.Max(1f, u * 0.018f))) {
                steam.StartCap = steam.EndCap = LineCap.Round;
                for (int i = 0; i < 2; i++) {
                    float ph = (float)(((t * 0.6 + i * 0.5) % 1.0 + 1.0) % 1.0), sx = x + (i - 0.5f) * w * 0.35f, sy = y - h * 0.6f - ph * u * 0.12f;
                    float sw = (float)Math.Sin(t * 3 + i) * u * 0.015f;
                    using (Pen p2 = new Pen(Color.FromArgb(A(150 * (1 - ph)), 230, 230, 240), steam.Width)) {
                        p2.StartCap = p2.EndCap = LineCap.Round;
                        g.DrawBezier(p2, sx, sy, sx + sw + u * 0.02f, sy - u * 0.03f, sx - sw - u * 0.02f, sy - u * 0.06f, sx, sy - u * 0.09f);
                    }
                }
            }
        }

        static void Sparks(Graphics g, float hx, float htop, float hw, float hface, float u, float t, float pet) {
            for (int i = 0; i < 4; i++) {
                float ph = (float)(((t * 1.1 + i / 4.0) % 1.0 + 1.0) % 1.0);
                float ang = (float)(i * Math.PI / 2 + t * 0.8), r = hw + u * (0.12f + 0.1f * ph);
                float x = hx + (float)Math.Cos(ang) * r, y = (htop + hface) / 2 + (float)Math.Sin(ang) * r * 0.7f;
                float s = u * 0.05f * (float)Math.Sin(Math.PI * ph);
                if (s < 0.8f) continue;
                using (SolidBrush b = new SolidBrush(Color.FromArgb(A(240 * pet), 255, 236, 140)))
                    g.FillPolygon(b, new PointF[] { new PointF(x, y - s), new PointF(x + s * 0.25f, y - s * 0.25f), new PointF(x + s, y),
                        new PointF(x + s * 0.25f, y + s * 0.25f), new PointF(x, y + s), new PointF(x - s * 0.25f, y + s * 0.25f), new PointF(x - s, y), new PointF(x - s * 0.25f, y - s * 0.25f) });
            }
        }
    }

    // Цвет маскота этого ПК: none | h60 | h120 | h180 | h240 | h300 (сдвиг оттенка) | pastel | mono.
    public static class MascotColor {
        static volatile string mode = "none";
        public static readonly string[] Modes = { "none", "h60", "h120", "h180", "h240", "h300", "pastel", "mono" };
        public static string Mode { get { return mode; } set { mode = Array.IndexOf(Modes, value) >= 0 ? value : "none"; } }
        public static bool Active { get { return mode != "none"; } }

        // Матрица цвета (строка-вектор × матрица, как в GDI+): сдвиг оттенка с сохранением яркости и насыщенность.
        public static ColorMatrix Matrix(string m) {
            double deg = 0, sat = 1;
            switch (m) {
                case "h60": deg = 60; break; case "h120": deg = 120; break; case "h180": deg = 180; break;
                case "h240": deg = 240; break; case "h300": deg = 300; break;
                case "pastel": sat = 0.5; break; case "mono": sat = 0; break;
            }
            double c = Math.Cos(deg * Math.PI / 180), s = Math.Sin(deg * Math.PI / 180);
            const double lr = 0.213, lg = 0.715, lb = 0.072;
            double[,] hue = {
                { lr + c * (1 - lr) - s * lr, lg - c * lg - s * lg, lb - c * lb + s * (1 - lb) },
                { lr - c * lr + s * 0.143, lg + c * (1 - lg) + s * 0.140, lb - c * lb - s * 0.283 },
                { lr - c * lr - s * (1 - lr), lg - c * lg + s * lg, lb + c * (1 - lb) + s * lb }
            };
            double[,] st = {
                { lr + (1 - lr) * sat, lg - lg * sat, lb - lb * sat },
                { lr - lr * sat, lg + (1 - lg) * sat, lb - lb * sat },
                { lr - lr * sat, lg - lg * sat, lb + (1 - lb) * sat }
            };
            double[,] mm = new double[3, 3];
            for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) { double v = 0; for (int k = 0; k < 3; k++) v += st[i, k] * hue[k, j]; mm[i, j] = v; }
            ColorMatrix cm = new ColorMatrix();
            // В GDI+ выход j = Σ вход i · M[i][j] — транспонируем.
            for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) cm[i, j] = (float)mm[j, i];
            cm.Matrix33 = 1; cm.Matrix44 = 1;
            return cm;
        }

        public static Color Apply(Color c, string m) {
            ColorMatrix cm = Matrix(m);
            float r = c.R / 255f, g = c.G / 255f, b = c.B / 255f;
            float[] o = new float[3];
            for (int j = 0; j < 3; j++) o[j] = r * cm[0, j] + g * cm[1, j] + b * cm[2, j];
            return Color.FromArgb(c.A, Clamp(o[0]), Clamp(o[1]), Clamp(o[2]));
        }
        static int Clamp(float v) { return Math.Max(0, Math.Min(255, (int)Math.Round(v * 255))); }

        public static void Blit(Graphics g, Bitmap img, int x, int y) {
            using (ImageAttributes ia = new ImageAttributes()) {
                ia.SetColorMatrix(Matrix(mode));
                g.DrawImage(img, new Rectangle(x, y, img.Width, img.Height), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, ia);
            }
        }
    }
}
