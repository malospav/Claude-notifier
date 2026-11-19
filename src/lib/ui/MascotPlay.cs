// claude-notifier: реакции главного маскота шторки на вас — поверх любого маскота.
// Гладят — летят сердечки, у каждого свой вкус (котики мурлычут, огонёк вспыхивает, призрак краснеет, пчёлка
// кружит); разбудили — «!»; подкинули слишком сильно — злится (значок злости и пар); давно не заходили — скучает
// (тучка с каплями); любит вас — иногда машет лапкой. Глаза и ротик меняет FlatState (MoodEyes / MoodMouth).
using System;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace ClaudeNotifier.Ui {
    public static class MascotPlay {
        // Наряды по времени суток и праздникам (настройка «Наряды»); FixedNow — для тестов и эталонных картинок.
        public static volatile bool Seasonal = true;
        public static DateTime? FixedNow;
        static DateTime Now() { return FixedNow.HasValue ? FixedNow.Value : DateTime.Now; }
        static bool Cat(string kind) { return kind == "flatsphynx" || kind == "kitty" || kind == "boxcat" || kind == "cupcat" || kind == "fox"; }

        // Сдвиг и масштаб фигуры от взаимодействия: пчёлка кружит, котики дрожат от мурчания, огонёк разгорается,
        // проснувшийся подпрыгивает, обиженный трясётся.
        public static RectangleF Body(RectangleF r, string kind, CatMood m, float t) {
            if (m == null || !(m.Play || m.Reacting)) return r;
            float u = r.Height;
            if (m.Reacting) {
                float a = m.ReactAge;
                if (m.React == "joy") r.Offset(0, -u * 0.20f * (float)Math.Abs(Math.Sin(a * Math.PI * 2.4)) * (1 - a / 2.5f));   // прыгает от радости
                else if (m.React == "panic") r.Offset((float)Math.Sin(t * 55) * u * 0.03f, 0);                                   // трясётся
                else r.Offset((float)Math.Sin(t * 28) * u * 0.012f, 0);                                                         // мелко дрожит
            }
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
            if (m == null || !(m.Play || m.Reacting) || r.Height < 8) return;
            SmoothingMode sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            try {
                float u = r.Height * 0.86f, cx = r.X + r.Width / 2f, top = r.Bottom - r.Height * 0.07f - u * 0.95f;
                if (m.Pet > 0.02f) Petting(g, kind, m.Pet, t, u, cx, top);
                if (m.Startle > 0.02f) Bang(g, new PointF(cx + u * 0.38f, top + u * 0.05f), u, m.Startle);
                if (m.Grumpy) Anger(g, new PointF(cx + u * 0.36f, top + u * 0.18f), u, t);
                if (m.Sad) Cloud(g, new PointF(cx, top - u * 0.02f), u, t);
                if (m.Wave > 0.02f) Wave(g, new PointF(cx + u * 0.48f, top + u * 0.55f), u, m.Wave, t);
                if (m.Reacting) Reaction(g, m.React, m.ReactAge, t, u, cx, top);
                if (m.Play && Seasonal) Season(g, Now(), t, u, cx, top);
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

        // Реакции на события: конфетти (готово), лапки на голове и капли пота (ошибка), капля пота (лимит).
        static void Reaction(Graphics g, string react, float age, float t, float u, float cx, float top) {
            float fade = Math.Min(1f, (2.5f - age) / 0.5f);
            if (react == "joy") {
                Color[] cols = { Color.FromArgb(255, 214, 10), Color.FromArgb(255, 105, 140), Color.FromArgb(100, 210, 255), Color.FromArgb(48, 209, 88), Color.FromArgb(191, 90, 242) };
                for (int i = 0; i < 12; i++) {
                    float ph = Math.Min(1f, age / 1.6f + (i % 3) * 0.08f);
                    float x = cx + (float)Math.Sin(i * 2.17) * u * (0.25f + 0.35f * ph), y = top + u * (-0.1f + 0.9f * ph * ph) - u * 0.25f * (float)Math.Sin(Math.PI * Math.Min(1f, ph * 1.4f));
                    float w = u * 0.05f, h = u * 0.025f;
                    GraphicsState st = g.Save();
                    g.TranslateTransform(x, y); g.RotateTransform(t * 300 + i * 40);
                    using (SolidBrush b = new SolidBrush(Color.FromArgb(A(255 * fade * (1 - ph * 0.5f)), cols[i % cols.Length]))) g.FillRectangle(b, -w / 2, -h / 2, w, h);
                    g.Restore(st);
                }
            } else if (react == "panic") {
                float sh = (float)Math.Sin(t * 30) * u * 0.02f;
                using (SolidBrush b = new SolidBrush(Color.FromArgb(A(240 * fade), 250, 236, 228)))
                using (Pen p = new Pen(Color.FromArgb(A(200 * fade), 120, 90, 80), Math.Max(1f, u * 0.015f))) {
                    foreach (float side in new float[] { -1f, 1f }) {
                        float x = cx + side * u * 0.30f + sh, y = top + u * 0.20f, d = u * 0.15f;
                        g.FillEllipse(b, x - d / 2, y - d / 2, d, d);
                        g.DrawEllipse(p, x - d / 2, y - d / 2, d, d);
                    }
                }
                Sweat(g, cx + u * 0.36f, top + u * (0.18f + 0.12f * (age % 0.8f)), u, fade);
                Sweat(g, cx - u * 0.40f, top + u * (0.26f + 0.12f * ((age + 0.4f) % 0.8f)), u, fade * 0.8f);
            } else {
                Sweat(g, cx + u * 0.34f, top + u * (0.22f + 0.15f * (age % 1.2f) / 1.2f), u, fade);
            }
        }

        static void Sweat(Graphics g, float x, float y, float u, float k) {
            float w = u * 0.07f, h = u * 0.11f;
            if (w < 1) return;
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddBezier(x, y - h / 2, x + w * 0.2f, y - h * 0.1f, x + w / 2, y + h * 0.1f, x + w / 2, y + h * 0.22f);
                p.AddArc(x - w / 2, y - h * 0.05f, w, h * 0.55f, 0, 180);
                p.AddBezier(x - w / 2, y + h * 0.22f, x - w / 2, y + h * 0.1f, x - w * 0.2f, y - h * 0.1f, x, y - h / 2);
                using (SolidBrush b = new SolidBrush(Color.FromArgb(A(220 * k), 120, 190, 255))) g.FillPath(b, p);
            }
        }

        // Какой наряд сейчас: night — ночной колпак (23:00–6:00); newyear — гирлянда и снежинки (20 дек – 10 янв);
        // halloween — летучая мышка (25 окт – 1 ноя); valentine — сердечко (13–15 фев).
        public static string[] Outfits(DateTime now) {
            System.Collections.Generic.List<string> l = new System.Collections.Generic.List<string>();
            if ((now.Month == 12 && now.Day >= 20) || (now.Month == 1 && now.Day <= 10)) l.Add("newyear");
            if ((now.Month == 10 && now.Day >= 25) || (now.Month == 11 && now.Day <= 1)) l.Add("halloween");
            if (now.Month == 2 && now.Day >= 13 && now.Day <= 15) l.Add("valentine");
            if (now.Hour >= 23 || now.Hour < 6) l.Add("night");
            return l.ToArray();
        }

        static void Season(Graphics g, DateTime now, float t, float u, float cx, float top) {
            foreach (string o in Outfits(now)) {
                if (o == "night") NightCap(g, u, cx, top, t);
                else if (o == "newyear") Garland(g, u, cx, top, t);
                else if (o == "halloween") Bat(g, u, cx, top, t);
                else if (o == "valentine") MascotSig.Heart(g, new PointF(cx - u * 0.42f, top + u * (0.1f + 0.05f * (float)Math.Sin(t * 2))), u * 0.08f, Color.FromArgb(230, 255, 80, 120));
            }
        }

        // Ночной колпак: синий мягкий конус, свисает вбок, с белым помпоном.
        static void NightCap(Graphics g, float u, float cx, float top, float t) {
            float sway = (float)Math.Sin(t * 1.3) * u * 0.02f;
            PointF a = new PointF(cx - u * 0.26f, top + u * 0.10f), b = new PointF(cx + u * 0.24f, top + u * 0.10f);
            PointF tip = new PointF(cx + u * 0.42f + sway, top + u * 0.02f);
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddBezier(a, new PointF(cx - u * 0.18f, top - u * 0.20f), new PointF(cx + u * 0.20f, top - u * 0.26f), tip);
                p.AddBezier(tip, new PointF(cx + u * 0.30f, top - u * 0.06f), new PointF(cx + u * 0.26f, top + u * 0.02f), b);
                p.CloseFigure();
                using (SolidBrush br = new SolidBrush(Color.FromArgb(240, 70, 100, 190))) g.FillPath(br, p);
            }
            using (Pen rim = new Pen(Color.FromArgb(245, 240, 240, 250), Math.Max(1.5f, u * 0.06f))) { rim.StartCap = rim.EndCap = LineCap.Round; g.DrawLine(rim, a, b); }
            float d = u * 0.10f;
            using (SolidBrush w = new SolidBrush(Color.FromArgb(250, 245, 245, 255))) g.FillEllipse(w, tip.X - d / 2, tip.Y - d / 2, d, d);
        }

        // Новогодняя гирлянда: дуга с мигающими огоньками над головой и падающие снежинки.
        static void Garland(Graphics g, float u, float cx, float top, float t) {
            PointF a = new PointF(cx - u * 0.42f, top + u * 0.16f), c = new PointF(cx + u * 0.42f, top + u * 0.16f);
            PointF m1 = new PointF(cx - u * 0.18f, top - u * 0.06f), m2 = new PointF(cx + u * 0.18f, top - u * 0.06f);
            using (Pen wire = new Pen(Color.FromArgb(200, 60, 120, 60), Math.Max(1f, u * 0.02f))) g.DrawBezier(wire, a, m1, m2, c);
            Color[] cols = { Color.FromArgb(255, 69, 58), Color.FromArgb(255, 214, 10), Color.FromArgb(48, 209, 88), Color.FromArgb(100, 210, 255) };
            for (int i = 0; i <= 6; i++) {
                float k = i / 6f, q = 1 - k;
                float x = q * q * q * a.X + 3 * q * q * k * m1.X + 3 * q * k * k * m2.X + k * k * k * c.X;
                float y = q * q * q * a.Y + 3 * q * q * k * m1.Y + 3 * q * k * k * m2.Y + k * k * k * c.Y;
                bool on = ((int)(t * 3) + i) % 3 != 0;
                float d = u * 0.06f;
                using (SolidBrush b = new SolidBrush(Color.FromArgb(on ? 255 : 90, cols[i % cols.Length]))) g.FillEllipse(b, x - d / 2, y, d, d * 1.3f);
            }
            for (int i = 0; i < 3; i++) {
                float ph = (float)(((t * 0.35 + i / 3.0) % 1.0 + 1.0) % 1.0);
                Star(g, new PointF(cx + (i - 1) * u * 0.5f + (float)Math.Sin(t + i) * u * 0.05f, top - u * 0.15f + ph * u * 0.9f), u * 0.04f, Color.FromArgb(A(220 * (1 - ph)), 235, 245, 255));
            }
        }

        // Летучая мышка порхает над головой.
        static void Bat(Graphics g, float u, float cx, float top, float t) {
            float x = cx + (float)Math.Sin(t * 0.9) * u * 0.35f, y = top - u * 0.08f + (float)Math.Sin(t * 2.3) * u * 0.05f;
            float flap = (float)Math.Sin(t * 14) * u * 0.08f, w = u * 0.24f;
            // Светлая сиреневая мышка с жёлтыми глазками — на чёрной шторке тёмную не видно.
            using (SolidBrush b = new SolidBrush(Color.FromArgb(245, 150, 120, 190))) {
                g.FillPolygon(b, new PointF[] { new PointF(x, y), new PointF(x - w, y - flap), new PointF(x - w * 0.75f, y + u * 0.05f), new PointF(x - w * 0.45f, y + u * 0.02f), new PointF(x - w * 0.25f, y + u * 0.05f) });
                g.FillPolygon(b, new PointF[] { new PointF(x, y), new PointF(x + w, y - flap), new PointF(x + w * 0.75f, y + u * 0.05f), new PointF(x + w * 0.45f, y + u * 0.02f), new PointF(x + w * 0.25f, y + u * 0.05f) });
                float d = u * 0.11f;
                g.FillEllipse(b, x - d / 2, y - d / 2, d, d);
                g.FillPolygon(b, new PointF[] { new PointF(x - d * 0.45f, y - d * 0.2f), new PointF(x - d * 0.3f, y - d * 0.85f), new PointF(x - d * 0.05f, y - d * 0.35f) });
                g.FillPolygon(b, new PointF[] { new PointF(x + d * 0.45f, y - d * 0.2f), new PointF(x + d * 0.3f, y - d * 0.85f), new PointF(x + d * 0.05f, y - d * 0.35f) });
                using (SolidBrush e = new SolidBrush(Color.FromArgb(255, 255, 214, 10))) {
                    float ed = Math.Max(1f, d * 0.22f);
                    g.FillEllipse(e, x - d * 0.25f - ed / 2, y - ed / 2, ed, ed);
                    g.FillEllipse(e, x + d * 0.25f - ed / 2, y - ed / 2, ed, ed);
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

    // Сравнение кадров с эталоном (тесты): сколько пикселей отличаются больше чем на threshold в любом канале.
    public static class PixelDiff {
        public static int Count(byte[] a, byte[] b, int threshold) {
            int n = Math.Min(a.Length, b.Length), bad = 0;
            for (int i = 0; i + 3 < n; i += 4) {
                int d = Math.Max(Math.Abs(a[i] - b[i]), Math.Max(Math.Abs(a[i + 1] - b[i + 1]), Math.Abs(a[i + 2] - b[i + 2])));
                if (d > threshold) bad++;
            }
            return bad;
        }
    }
}
