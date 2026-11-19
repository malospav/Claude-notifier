// claude-notifier: реакции главного маскота шторки на вас — поверх любого маскота.
// Гладят — летят сердечки, у каждого свой вкус (котики мурлычут, огонёк вспыхивает, призрак краснеет, пчёлка
// кружит); разбудили — «!»; подкинули слишком сильно — злится (значок злости и пар); давно не заходили — скучает
// (тучка с каплями); любит вас — иногда машет лапкой. Глаза и ротик меняет FlatState (MoodEyes / MoodMouth).
using System;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace ClaudeNotifier.Ui {
    public static class MascotPlay {
        static bool Cat(string kind) { return kind == "flatsphynx" || kind == "kitty" || kind == "boxcat" || kind == "cupcat" || kind == "fox"; }

        // Сдвиг и масштаб фигуры от взаимодействия: пчёлка кружит, котики дрожат от мурчания, огонёк разгорается,
        // проснувшийся подпрыгивает, обиженный трясётся.
        public static RectangleF Body(RectangleF r, string kind, CatMood m, float t) {
            if (m == null || !m.Play) return r;
            float u = r.Height;
            if (m.Pet > 0.05f) {
                if (kind == "bee") r.Offset((float)Math.Cos(t * 5.5) * u * 0.10f * m.Pet, (float)Math.Sin(t * 5.5) * u * 0.06f * m.Pet);
                else if (Cat(kind)) r.Offset((float)Math.Sin(t * 70) * Math.Max(0.5f, u * 0.012f) * m.Pet, 0);
                else if (kind == "flame") { float k = 1f + 0.10f * m.Pet; r = new RectangleF(r.X - r.Width * (k - 1) / 2, r.Y - r.Height * (k - 1), r.Width * k, r.Height * k); }
            }
            if (m.Startle > 0) r.Offset(0, -u * 0.16f * (float)Math.Sin(Math.PI * Math.Min(1f, 1f - m.Startle)) * Math.Min(1f, m.Startle * 3));
            if (m.Grumpy) r.Offset((float)Math.Sin(t * 40) * u * 0.015f, 0);
            return r;
        }

        public static void Overlay(Graphics g, RectangleF r, string kind, CatMood m, float t) {
            if (m == null || !m.Play || r.Height < 8) return;
            SmoothingMode sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            try {
                float u = r.Height * 0.86f, cx = r.X + r.Width / 2f, top = r.Bottom - r.Height * 0.07f - u * 0.95f;
                if (m.Pet > 0.02f) Petting(g, kind, m.Pet, t, u, cx, top);
                if (m.Startle > 0.02f) Bang(g, new PointF(cx + u * 0.38f, top + u * 0.05f), u, m.Startle);
                if (m.Grumpy) Anger(g, new PointF(cx + u * 0.36f, top + u * 0.18f), u, t);
                if (m.Sad) Cloud(g, new PointF(cx, top - u * 0.02f), u, t);
                if (m.Wave > 0.02f) Wave(g, new PointF(cx + u * 0.48f, top + u * 0.55f), u, m.Wave, t);
            } finally { g.SmoothingMode = sm; }
        }

        static int A(float v) { return Math.Max(0, Math.Min(255, (int)v)); }

        static void Petting(Graphics g, string kind, float pet, float t, float u, float cx, float top) {
            // Сердечки: всплывают по очереди слева и справа, тают наверху.
            for (int i = 0; i < 3; i++) {
                float ph = (float)(((t * 0.75 + i / 3.0) % 1.0 + 1.0) % 1.0);
                float side = i % 2 == 0 ? 1f : -1f;
                float x = cx + side * u * (0.30f + 0.06f * (float)Math.Sin(t * 3 + i)), y = top + u * (0.35f - 0.55f * ph);
                MascotSig.Heart(g, new PointF(x, y), u * (0.07f + 0.03f * ph), Color.FromArgb(A(255 * pet * Math.Min(1f, (1f - ph) * 1.6f)), 255, 105, 140));
            }
            if (pet < 0.3f) return;
            float k = (pet - 0.3f) / 0.7f;
            if (Cat(kind)) {
                // Мурчание: дрожащие дужки по бокам.
                using (Pen p = new Pen(Color.FromArgb(A(200 * k), 255, 220, 200), Math.Max(1f, u * 0.025f))) {
                    p.StartCap = p.EndCap = LineCap.Round;
                    for (int i = 0; i < 2; i++) {
                        float d = u * (0.42f + 0.08f * i) + (float)Math.Sin(t * 30 + i) * u * 0.01f, y = top + u * 0.62f;
                        g.DrawArc(p, cx + d - u * 0.06f, y - u * 0.08f, u * 0.12f, u * 0.16f, -50, 100);
                        g.DrawArc(p, cx - d - u * 0.06f, y - u * 0.08f, u * 0.12f, u * 0.16f, 130, 100);
                    }
                }
            } else if (kind == "flame") {
                // Огонёк вспыхивает: искры летят вверх.
                for (int i = 0; i < 5; i++) {
                    float ph = (float)(((t * 1.4 + i * 0.21) % 1.0 + 1.0) % 1.0);
                    float x = cx + (float)Math.Sin(i * 2.3 + t * 2) * u * 0.25f, y = top + u * (0.2f - 0.5f * ph);
                    float s = u * 0.035f * (1 - ph);
                    if (s < 0.3f) continue;
                    using (SolidBrush b = new SolidBrush(Color.FromArgb(A(230 * k * (1 - ph)), 255, 190, 80))) g.FillEllipse(b, x - s, y - s, s * 2, s * 2);
                }
            } else if (kind == "ghost") {
                // Призрак краснеет: розовые щёки.
                using (SolidBrush b = new SolidBrush(Color.FromArgb(A(150 * k), 255, 120, 150))) {
                    float y = top + u * 0.50f;
                    g.FillEllipse(b, cx - u * 0.30f, y - u * 0.04f, u * 0.14f, u * 0.08f);
                    g.FillEllipse(b, cx + u * 0.16f, y - u * 0.04f, u * 0.14f, u * 0.08f);
                }
            } else if (kind == "bee") {
                // Пчёлка кружит: пунктир следа.
                using (Pen p = new Pen(Color.FromArgb(A(140 * k), 255, 230, 140), Math.Max(1f, u * 0.02f))) {
                    p.DashStyle = DashStyle.Dot;
                    g.DrawEllipse(p, cx - u * 0.55f, top + u * 0.25f, u * 1.1f, u * 0.7f);
                }
            } else {
                // Остальные — блёстки.
                for (int i = 0; i < 3; i++) {
                    float ph = (float)(((t * 1.1 + i / 3.0) % 1.0 + 1.0) % 1.0);
                    float s = u * 0.06f * (float)Math.Sin(Math.PI * ph);
                    PointF c = new PointF(cx + (i - 1) * u * 0.4f, top + u * (0.05f + 0.12f * (i % 2)));
                    Star(g, c, s, Color.FromArgb(A(230 * k), 255, 240, 170));
                }
            }
        }

        static void Star(Graphics g, PointF c, float s, Color col) {
            if (s < 0.8f) return;
            using (SolidBrush b = new SolidBrush(col))
                g.FillPolygon(b, new PointF[] { new PointF(c.X, c.Y - s), new PointF(c.X + s * 0.25f, c.Y - s * 0.25f), new PointF(c.X + s, c.Y),
                    new PointF(c.X + s * 0.25f, c.Y + s * 0.25f), new PointF(c.X, c.Y + s), new PointF(c.X - s * 0.25f, c.Y + s * 0.25f),
                    new PointF(c.X - s, c.Y), new PointF(c.X - s * 0.25f, c.Y - s * 0.25f) });
        }

        // «!» — проснулся от щелчка.
        static void Bang(Graphics g, PointF p, float u, float k) {
            if (u < 12) return;
            using (Font f = new Font("Segoe UI", Math.Max(6f, u * 0.34f), FontStyle.Bold, GraphicsUnit.Pixel))
            using (StringFormat sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            using (SolidBrush b = new SolidBrush(Color.FromArgb(A(255 * Math.Min(1f, k * 1.5f)), 255, 214, 10)))
                g.DrawString("!", f, b, p, sf);
        }

        // Значок злости: четыре красные скобки углами друг к другу, пульсирует.
        static void Anger(Graphics g, PointF c, float u, float t) {
            float s = u * (0.09f + 0.015f * (float)Math.Sin(t * 9)), gap = s * 0.35f;
            using (Pen p = new Pen(Color.FromArgb(235, 255, 69, 58), Math.Max(1.2f, u * 0.035f))) {
                p.StartCap = p.EndCap = LineCap.Round;
                for (int q = 0; q < 4; q++) {
                    float sx = q == 0 || q == 3 ? -1 : 1, sy = q < 2 ? -1 : 1;
                    PointF a = new PointF(c.X + sx * gap, c.Y + sy * (gap + s)), m = new PointF(c.X + sx * gap, c.Y + sy * gap), b = new PointF(c.X + sx * (gap + s), c.Y + sy * gap);
                    g.DrawBezier(p, a, new PointF(m.X + sx * s * 0.1f, m.Y + sy * s * 0.6f), new PointF(m.X + sx * s * 0.6f, m.Y + sy * s * 0.1f), b);
                }
            }
        }

        // Скучает: серая тучка над головой, из неё капает.
        static void Cloud(Graphics g, PointF c, float u, float t) {
            float w = u * 0.5f, h = u * 0.16f;
            using (SolidBrush b = new SolidBrush(Color.FromArgb(200, 142, 142, 150))) {
                g.FillEllipse(b, c.X - w / 2, c.Y - h / 2, w * 0.55f, h);
                g.FillEllipse(b, c.X - w * 0.15f, c.Y - h * 0.85f, w * 0.45f, h * 1.2f);
                g.FillEllipse(b, c.X + w * 0.05f, c.Y - h / 2, w * 0.45f, h);
            }
            for (int i = 0; i < 3; i++) {
                float ph = (float)(((t * 1.2 + i * 0.37) % 1.0 + 1.0) % 1.0);
                float x = c.X + (i - 1) * w * 0.28f, y = c.Y + h * 0.5f + ph * u * 0.25f, d = u * 0.03f;
                if (d < 0.5f) continue;
                using (SolidBrush b = new SolidBrush(Color.FromArgb(A(200 * (1 - ph)), 100, 170, 255))) g.FillEllipse(b, x - d / 2, y, d, d * 1.6f);
            }
        }

        // Машет лапкой: кружок-ладошка качается, рядом дужки движения.
        static void Wave(Graphics g, PointF c, float u, float k, float t) {
            float ang = (float)Math.Sin(t * 12) * 35f, len = u * 0.22f;
            double rad = (ang - 90) * Math.PI / 180;
            PointF hand = new PointF(c.X + (float)Math.Cos(rad) * len, c.Y + (float)Math.Sin(rad) * len);
            int a = A(255 * Math.Min(1f, k));
            using (Pen arm = new Pen(Color.FromArgb(a, 245, 230, 220), Math.Max(1.5f, u * 0.06f))) { arm.StartCap = arm.EndCap = LineCap.Round; g.DrawLine(arm, c, hand); }
            float d = u * 0.12f;
            using (SolidBrush b = new SolidBrush(Color.FromArgb(a, 250, 238, 230))) g.FillEllipse(b, hand.X - d / 2, hand.Y - d / 2, d, d);
            using (Pen p = new Pen(Color.FromArgb(a * 2 / 3, 255, 255, 255), Math.Max(1f, u * 0.02f))) {
                g.DrawArc(p, hand.X - d, hand.Y - d, d * 2, d * 2, -60, 40);
                g.DrawArc(p, hand.X - d, hand.Y - d, d * 2, d * 2, 200, 40);
            }
        }
    }
}
