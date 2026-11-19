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
        // Сжатие при прыжках: радость — шлёпается при касании и вытягивается в воздухе; испуг — приседает и подскакивает.
        public static float ReactSquash(CatMood m) {
            float k = 1f;
            if (m.Reacting && m.React == "joy") {
                float a = m.ReactAge, h = (float)Math.Abs(Math.Sin(a * Math.PI * 2.4)), fade = 1f - a / 2.5f;
                k *= 1f + fade * (h < 0.2f ? -0.16f * (1f - h / 0.2f) : 0.10f * (h - 0.2f) / 0.8f);
            }
            if (m.Startle > 0) {
                float s = 1f - m.Startle;
                k *= s < 0.15f ? 1f - 0.15f * (s / 0.15f) : 1f + 0.12f * (float)Math.Sin(Math.PI * Math.Min(1f, (s - 0.15f) / 0.85f));
            }
            return k;
        }

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
            if (m == null || !(m.Play || m.Reacting || m.Dust >= 0) || r.Height < 8) return;
            SmoothingMode sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            GraphicsState gs = g.Save();
            try {
                float u = r.Height * 0.86f, cx = r.X + r.Width / 2f;
                if (m.Dust >= 0 && m.Dust < 0.5f) Dust(g, cx, r.Bottom - r.Height * 0.07f, u, m.Dust / 0.5f);
                // Голова: где её нарисовал сам маскот (с его наклоном и прыжком); иначе — по общей разметке.
                Head h;
                if (HeadAnchor.Has) {
                    g.Transform = HeadAnchor.Transform;
                    h = new Head(HeadAnchor.Top.X, HeadAnchor.Top.Y, HeadAnchor.HalfW, HeadAnchor.FaceY, u);
                } else h = new Head(cx, r.Bottom - r.Height * 0.07f - u * 0.86f, u * 0.27f, r.Bottom - r.Height * 0.07f - u * 0.55f, u);
                if (m.Play && m.Outfit != null) Season(g, new string[] { m.Outfit }, t, h);
                else if (m.Play && Seasonal) Season(g, Outfits(Now()), t, h);
                if (m.Pet > 0.02f) Petting(g, kind, m.Pet, t, h);
                if (m.Startle > 0.02f) Bang(g, new PointF(h.X + h.W + h.U * 0.06f, h.Top - h.U * 0.02f), h.U, m.Startle);
                if (m.Grumpy) Anger(g, new PointF(h.X + h.W * 0.85f, h.Top + h.U * 0.06f), h.U, t);
                if (m.Sad) Cloud(g, new PointF(h.X, h.Top - h.U * 0.14f), h.U, t);
                if (m.Wave > 0.02f) Wave(g, new PointF(h.X + h.W + h.U * 0.05f, h.Face + h.U * 0.16f), h.U, m.Wave, t, PawColor(kind));
                if (m.Reacting) Reaction(g, m.React, m.ReactAge, t, h);
            } finally { g.Restore(gs); g.SmoothingMode = sm; }
        }

        // Голова для украшений: X — середина, Top — макушка, W — полуширина, Face — высота глаз, U — масштаб маскота.
        struct Head {
            public float X, Top, W, Face, U;
            public Head(float x, float top, float w, float face, float u) { X = x; Top = top; W = w; Face = face; U = u; }
        }

        static int A(float v) { return Math.Max(0, Math.Min(255, (int)v)); }

        static void Petting(Graphics g, string kind, float pet, float t, Head h) {
            float u = h.U;
            // Сердечки: всплывают по очереди слева и справа от головы, тают наверху.
            for (int i = 0; i < 3; i++) {
                float ph = (float)(((t * 0.75 + i / 3.0) % 1.0 + 1.0) % 1.0);
                float side = i % 2 == 0 ? 1f : -1f;
                float x = h.X + side * (h.W + u * (0.04f + 0.04f * (float)Math.Sin(t * 3 + i))), y = h.Face - u * (0.05f + 0.55f * ph);
                float pop = MascotMotion.EaseOutBack(Math.Min(1f, ph / 0.25f));
                x += (float)Math.Sin(ph * Math.PI * 3 + i) * u * 0.04f;
                MascotSig.Heart(g, new PointF(x, y), u * (0.07f + 0.03f * ph) * pop, Color.FromArgb(A(255 * pet * Math.Min(1f, (1f - ph) * 1.6f)), 255, 105, 140));
            }
            if (pet < 0.3f) return;
            float k = (pet - 0.3f) / 0.7f;
            if (Cat(kind)) {
                // Мурчание: дрожащие дужки по бокам мордочки.
                using (Pen p = new Pen(Color.FromArgb(A(200 * k), 255, 220, 200), Math.Max(1f, u * 0.025f))) {
                    p.StartCap = p.EndCap = LineCap.Round;
                    for (int i = 0; i < 2; i++) {
                        float d = h.W + u * (0.08f + 0.07f * i) + (float)Math.Sin(t * 30 + i) * u * 0.01f, y = h.Face + u * 0.04f;
                        g.DrawArc(p, h.X + d - u * 0.06f, y - u * 0.08f, u * 0.12f, u * 0.16f, -50, 100);
                        g.DrawArc(p, h.X - d - u * 0.06f, y - u * 0.08f, u * 0.12f, u * 0.16f, 130, 100);
                    }
                }
            } else if (kind == "flame") {
                // Огонёк вспыхивает: искры летят вверх с макушки.
                for (int i = 0; i < 5; i++) {
                    float ph = (float)(((t * 1.4 + i * 0.21) % 1.0 + 1.0) % 1.0);
                    float x = h.X + (float)Math.Sin(i * 2.3 + t * 2) * h.W * 1.2f, y = h.Top + u * (0.15f - 0.45f * ph);
                    float s = u * 0.035f * (1 - ph);
                    if (s < 0.3f) continue;
                    using (SolidBrush b = new SolidBrush(Color.FromArgb(A(230 * k * (1 - ph)), 255, 190, 80))) g.FillEllipse(b, x - s, y - s, s * 2, s * 2);
                }
            } else if (kind == "ghost") {
                // Привидение краснеет: розовые щёки под глазами.
                using (SolidBrush b = new SolidBrush(Color.FromArgb(A(150 * k), 255, 120, 150))) {
                    float y = h.Face + u * 0.08f;
                    g.FillEllipse(b, h.X - u * 0.27f, y - u * 0.04f, u * 0.14f, u * 0.08f);
                    g.FillEllipse(b, h.X + u * 0.13f, y - u * 0.04f, u * 0.14f, u * 0.08f);
                }
            } else if (kind == "bee") {
                // Пчёлка кружит: пунктир следа вокруг неё.
                using (Pen p = new Pen(Color.FromArgb(A(140 * k), 255, 230, 140), Math.Max(1f, u * 0.02f))) {
                    p.DashStyle = DashStyle.Dot;
                    g.DrawEllipse(p, h.X - u * 0.40f, h.Top - u * 0.05f, u * 1.0f, u * 0.62f);
                }
            } else {
                // Остальные — блёстки над головой.
                for (int i = 0; i < 3; i++) {
                    float ph = (float)(((t * 1.1 + i / 3.0) % 1.0 + 1.0) % 1.0);
                    float s = u * 0.06f * (float)Math.Sin(Math.PI * ph);
                    PointF c = new PointF(h.X + (i - 1) * (h.W + u * 0.10f), h.Top - u * (0.02f + 0.10f * (i % 2)));
                    Star(g, c, s, Color.FromArgb(A(230 * k), 255, 240, 170));
                }
            }
        }

        // Реакции на события: конфетти (готово), лапки на голове и капли пота (ошибка), капля пота (лимит).
        static void Reaction(Graphics g, string react, float age, float t, Head h) {
            float u = h.U, cx = h.X, top = h.Top - u * 0.30f;
            float fade = Math.Min(1f, (2.5f - age) / 0.5f);
            if (react == "joy") {
                Color[] cols = { Color.FromArgb(255, 214, 10), Color.FromArgb(255, 105, 140), Color.FromArgb(100, 210, 255), Color.FromArgb(48, 209, 88), Color.FromArgb(191, 90, 242) };
                for (int i = 0; i < 16; i++) {
                    // Начальная скорость — веером вверх; тяжесть и сопротивление воздуха; лёгкое покачивание.
                    float ang = (float)(-Math.PI / 2 + (i / 15.0 - 0.5) * 2.2), sp = u * (1.5f + 0.6f * (float)Math.Sin(i * 1.7));
                    float tt = age, drag = (float)(1 - Math.Exp(-2.2 * tt)) / 2.2f;
                    float x = cx + (float)Math.Cos(ang) * sp * drag + (float)Math.Sin(tt * 6 + i) * u * 0.04f;
                    float y = top + u * 0.3f + (float)Math.Sin(ang) * sp * drag + 0.9f * u * tt * tt;
                    float w = u * 0.055f, ch = u * 0.028f;
                    float flip = (float)Math.Cos(tt * (9 + i % 4) + i);   // переворачивается
                    GraphicsState st = g.Save();
                    g.TranslateTransform(x, y); g.RotateTransform(i * 40 + tt * 120); g.ScaleTransform(Math.Max(0.15f, Math.Abs(flip)), 1f);
                    Color c = cols[i % cols.Length];
                    if (flip < 0) c = Color.FromArgb(c.R * 3 / 4, c.G * 3 / 4, c.B * 3 / 4);   // обратная сторона темнее
                    float life = Math.Max(0f, 1f - tt / 1.5f);   // конфетти тает, не долетев далеко вниз
                    using (SolidBrush b = new SolidBrush(Color.FromArgb(A(255 * fade * life), c))) g.FillRectangle(b, -w / 2, -ch / 2, w, ch);
                    g.Restore(st);
                }
            } else if (react == "panic") {
                float sh = (float)Math.Sin(t * 30) * u * 0.02f;
                using (SolidBrush b = new SolidBrush(Color.FromArgb(A(240 * fade), 250, 236, 228)))
                using (Pen p = new Pen(Color.FromArgb(A(200 * fade), 120, 90, 80), Math.Max(1f, u * 0.015f))) {
                    foreach (float side in new float[] { -1f, 1f }) {
                        float x = cx + side * h.W * 0.95f + sh, y = h.Top + u * 0.08f, d = u * 0.15f;
                        g.FillEllipse(b, x - d / 2, y - d / 2, d, d);
                        g.DrawEllipse(p, x - d / 2, y - d / 2, d, d);
                    }
                }
                Sweat(g, cx + h.W + u * 0.05f, h.Top + u * (0.08f + 0.12f * (age % 0.8f)), u, fade);
                Sweat(g, cx - h.W - u * 0.07f, h.Top + u * (0.16f + 0.12f * ((age + 0.4f) % 0.8f)), u, fade * 0.8f);
            } else {
                Sweat(g, cx + h.W + u * 0.04f, h.Top + u * (0.10f + 0.15f * (age % 1.2f) / 1.2f), u, fade);
            }
        }

        // Облачко пыли у ног при приземлении: два клубка расходятся в стороны и тают.
        static void Dust(Graphics g, float cx, float by, float u, float k) {
            for (int s = -1; s <= 1; s += 2) {
                for (int i = 0; i < 3; i++) {
                    float d = u * (0.10f + 0.06f * i) * (0.6f + 0.6f * k);
                    float x = cx + s * u * (0.25f + 0.35f * k + 0.08f * i), y = by - u * (0.03f + 0.05f * k + 0.02f * i);
                    using (SolidBrush b = new SolidBrush(Color.FromArgb(A(110 * (1 - k)), 210, 205, 200))) g.FillEllipse(b, x - d / 2, y - d / 2, d, d);
                }
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

        static void Season(Graphics g, string[] outfits, float t, Head h) {
            foreach (string o in outfits) {
                if (o == "night") NightCap(g, h, t);
                else if (o == "newyear") Garland(g, h, t);
                else if (o == "halloween") Bat(g, h, t);
                else if (o == "valentine") MascotSig.Heart(g, new PointF(h.X - h.W - h.U * 0.08f, h.Top + h.U * (0.12f + 0.04f * (float)Math.Sin(t * 2))), h.U * 0.08f, Color.FromArgb(230, 255, 80, 120));
            }
        }

        // Ночной колпак: синий мягкий конус сидит на макушке во всю ширину головы, кончик свисает вбок, помпон.
        static void NightCap(Graphics g, Head h, float t) {
            float u = h.U, w = Math.Min(h.W, 0.27f * u) * 0.95f, sc = w / (0.27f * 0.95f * u);   // по голове, но не больше обычного
            float sway = (float)Math.Sin(t * 1.3) * u * 0.02f;
            float baseY = h.Top + u * 0.07f * sc;
            PointF a = new PointF(h.X - w, baseY), b = new PointF(h.X + w, baseY);
            PointF tip = new PointF(h.X + w * 1.45f + sway, h.Top - u * 0.02f * sc);
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddBezier(a, new PointF(h.X - w * 0.7f, h.Top - u * 0.22f * sc), new PointF(h.X + w * 0.6f, h.Top - u * 0.30f * sc), tip);
                p.AddBezier(tip, new PointF(h.X + w * 1.0f, h.Top - u * 0.08f * sc), new PointF(h.X + w * 0.95f, h.Top + u * 0.0f), b);
                p.CloseFigure();
                using (LinearGradientBrush br = new LinearGradientBrush(p.GetBounds(), Color.FromArgb(245, 92, 124, 214), Color.FromArgb(245, 58, 84, 170), LinearGradientMode.Vertical)) g.FillPath(br, p);
                // Звёздочки на колпаке.
                if (u >= 30) { Star(g, new PointF(h.X - w * 0.2f, h.Top - u * 0.08f * sc), u * 0.025f, Color.FromArgb(220, 255, 236, 150)); Star(g, new PointF(h.X + w * 0.55f, h.Top - u * 0.13f * sc), u * 0.02f, Color.FromArgb(200, 255, 236, 150)); }
            }
            using (Pen rim = new Pen(Color.FromArgb(250, 245, 245, 252), Math.Max(1.5f, u * 0.065f * sc))) { rim.StartCap = rim.EndCap = LineCap.Round; g.DrawLine(rim, a, b); }
            float d = u * 0.11f * sc;
            using (SolidBrush wb = new SolidBrush(Color.FromArgb(250, 248, 248, 255))) g.FillEllipse(wb, tip.X - d / 2, tip.Y - d / 2, d, d);
        }

        // Новогодняя гирлянда: дуга с мигающими огоньками поверх макушки и падающие снежинки.
        static void Garland(Graphics g, Head h, float t) {
            float u = h.U, w = h.W * 1.25f;
            PointF a = new PointF(h.X - w, h.Top + u * 0.16f), c = new PointF(h.X + w, h.Top + u * 0.16f);
            PointF m1 = new PointF(h.X - w * 0.45f, h.Top - u * 0.05f), m2 = new PointF(h.X + w * 0.45f, h.Top - u * 0.05f);
            using (Pen wire = new Pen(Color.FromArgb(220, 60, 120, 60), Math.Max(1f, u * 0.02f))) g.DrawBezier(wire, a, m1, m2, c);
            Color[] cols = { Color.FromArgb(255, 69, 58), Color.FromArgb(255, 214, 10), Color.FromArgb(48, 209, 88), Color.FromArgb(100, 210, 255) };
            for (int i = 0; i <= 6; i++) {
                float k = i / 6f, q = 1 - k;
                float x = q * q * q * a.X + 3 * q * q * k * m1.X + 3 * q * k * k * m2.X + k * k * k * c.X;
                float y = q * q * q * a.Y + 3 * q * q * k * m1.Y + 3 * q * k * k * m2.Y + k * k * k * c.Y;
                bool on = ((int)(t * 3) + i) % 3 != 0;
                float d = u * 0.06f;
                if (on) FlatFx.Glow(g, new PointF(x, y + d * 0.6f), d * 1.4f, cols[i % cols.Length], 90);
                using (SolidBrush b = new SolidBrush(Color.FromArgb(on ? 255 : 110, cols[i % cols.Length]))) g.FillEllipse(b, x - d / 2, y, d, d * 1.3f);
            }
            for (int i = 0; i < 3; i++) {
                float ph = (float)(((t * 0.35 + i / 3.0) % 1.0 + 1.0) % 1.0);
                Star(g, new PointF(h.X + (i - 1) * (h.W + u * 0.2f) + (float)Math.Sin(t + i) * u * 0.05f, h.Top - u * 0.18f + ph * u * 0.9f), u * 0.04f, Color.FromArgb(A(220 * (1 - ph)), 235, 245, 255));
            }
        }

        // Летучая мышка порхает над головой.
        static void Bat(Graphics g, Head h, float t) {
            float u = h.U;
            float x = h.X + (float)Math.Sin(t * 0.9) * (h.W + u * 0.15f), y = h.Top - u * 0.16f + (float)Math.Sin(t * 2.3) * u * 0.05f;
            BatBody(g, x, y, u, t);
        }

        // Светлая сиреневая мышка с жёлтыми глазками — на чёрной шторке тёмную не видно.
        static void BatBody(Graphics g, float x, float y, float u, float t) {
            float flap = (float)Math.Sin(t * 14) * u * 0.08f, w = u * 0.24f;
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
        // Цвет лапки маскота (для взмаха): как у его тела.
        static Color PawColor(string kind) {
            switch (kind) {
                case "flame": return Color.FromArgb(255, 207, 107);
                case "boxcat": return Color.FromArgb(62, 62, 71);
                case "penguin": return Color.FromArgb(52, 59, 74);
                case "kitty": return Color.FromArgb(252, 250, 248);
                case "ghost": return Color.FromArgb(244, 241, 255);
                case "mochi": return Color.FromArgb(253, 243, 245);
                case "dino": return Color.FromArgb(183, 164, 238);
                case "frog": return Color.FromArgb(168, 218, 152);
                case "reaper": return Color.FromArgb(244, 239, 232);
                case "onigiri": return Color.FromArgb(251, 249, 245);
                case "cupcat": return Color.FromArgb(59, 53, 71);
                case "fox": return Color.FromArgb(240, 138, 75);
                case "leaf": return Color.FromArgb(156, 187, 114);
                case "bee": return Color.FromArgb(246, 200, 90);
                default: return Color.FromArgb(242, 185, 164);
            }
        }

        // Машет лапкой: лапка цвета маскота поднята сбоку от мордочки и качается из стороны в сторону,
        // рядом — дужки движения.
        static void Wave(Graphics g, PointF pivot, float u, float k, float t, Color fur) {
            int a = A(255 * Math.Min(1f, k));
            if (a < 8) return;
            float ang = (float)Math.Sin(t * 11) * 28f * k;
            GraphicsState st = g.Save();
            g.TranslateTransform(pivot.X, pivot.Y);
            g.RotateTransform(ang);
            float pw = u * 0.13f, ph = u * 0.16f, lift = u * 0.10f * k;
            RectangleF pr = new RectangleF(-pw / 2, -ph - lift, pw, ph);
            using (GraphicsPath paw = new GraphicsPath()) {
                paw.AddEllipse(pr);
                using (SolidBrush b = new SolidBrush(Color.FromArgb(a, fur))) g.FillPath(b, paw);
                using (Pen rim = new Pen(Color.FromArgb(a * 2 / 3, Draw.Mix(fur, Color.Black, 0.35f)), Math.Max(1f, u * 0.018f))) g.DrawPath(rim, paw);
                // Пальчики: три бороздки сверху.
                if (u >= 24) using (Pen tp = new Pen(Color.FromArgb(a / 2, Draw.Mix(fur, Color.Black, 0.4f)), Math.Max(0.8f, u * 0.012f))) {
                    for (int i = -1; i <= 1; i += 2) g.DrawLine(tp, i * pw * 0.17f, pr.Y + ph * 0.05f, i * pw * 0.17f, pr.Y + ph * 0.32f);
                }
            }
            g.Restore(st);
            using (Pen p = new Pen(Color.FromArgb(a * 2 / 3, 255, 255, 255), Math.Max(1f, u * 0.02f))) {
                p.StartCap = p.EndCap = LineCap.Round;
                float r = u * 0.16f, cy = pivot.Y - u * 0.18f - u * 0.10f * k;
                g.DrawArc(p, pivot.X - r, cy - r * 0.5f, r * 2, r * 1.4f, -70, 30);
                g.DrawArc(p, pivot.X - r, cy - r * 0.5f, r * 2, r * 1.4f, -140, 30);
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
