// claude-notifier: ещё восемь плоских маскотов шторки — динозаврик, лягушка с чашкой, жнец, онигири,
// котик в чашке, лисёнок, листик и пчёлка. Рисунок и поведение — как у остальных FlatPals: общая мордочка
// (FlatState: глаза, ротик, облачко, агенты), своё тело. Работает — покачивается, взгляд гуляет, облачко «…»;
// «Ага!» — глаза «> <» и чёрточки; ждёт решения — янтарный оттенок, подпрыгивает, «!» или «?»; ошибка —
// красноватый; остановился и спит — тусклый, «z».
using System;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace ClaudeNotifier.Ui {
    public static partial class FlatPals {
        // «?» над головой (динозаврик: ждёт ответа или решения).
        static void Question(Graphics g, PointF p, float u, Color c, float k) {
            if (k <= 0.05f || u < 16) return;
            using (Font f = new Font("Segoe UI", Math.Max(6f, u * 0.26f), FontStyle.Bold, GraphicsUnit.Pixel))
            using (StringFormat sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(255 * FlatFx.Clamp(k, 0, 1)), c)))
                g.DrawString("?", f, b, p, sf);
        }

        // Пар над чашкой: три волнистые струйки.
        static void Steam(Graphics g, PointF c, float u, float t, float A, float k) {
            if (k <= 0.05f || u < 18) return;
            using (Pen pen = new Pen(Color.FromArgb((int)(190 * FlatFx.Clamp(k, 0, 1)), 236, 236, 240), Math.Max(1.4f, u * 0.035f))) {
                pen.StartCap = pen.EndCap = LineCap.Round;
                for (int i = -1; i <= 1; i++) {
                    float x = c.X + i * u * 0.09f, w = u * 0.035f * (float)Math.Sin(t * 2.2 + i) * A;
                    float y0 = c.Y, y1 = c.Y - u * (0.20f + 0.03f * i * i);
                    g.DrawBezier(pen, x, y0, x - u * 0.04f + w, y0 - u * 0.06f, x + u * 0.04f - w, y1 + u * 0.06f, x, y1);
                }
            }
        }

        // Звёздочка-блик (котик в чашке).
        static void Sparkle(Graphics g, PointF c, float r, Color col) {
            if (r < 1.5f) return;
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddPolygon(new PointF[] {
                    new PointF(c.X, c.Y - r), new PointF(c.X + r * 0.25f, c.Y - r * 0.25f), new PointF(c.X + r, c.Y),
                    new PointF(c.X + r * 0.25f, c.Y + r * 0.25f), new PointF(c.X, c.Y + r), new PointF(c.X - r * 0.25f, c.Y + r * 0.25f),
                    new PointF(c.X - r, c.Y), new PointF(c.X - r * 0.25f, c.Y - r * 0.25f) });
                using (SolidBrush b = new SolidBrush(col)) g.FillPath(b, p);
            }
        }

        // Довольные дужки «^ ^» вместо открытых глаз.
        static void HappyArcs(Graphics g, PointF l, PointF r, float u, Color ink, float size) {
            using (Pen ep = new Pen(ink, Math.Max(1.2f, u * 0.042f))) {
                ep.StartCap = ep.EndCap = LineCap.Round;
                float es = u * 0.07f * size;
                foreach (PointF e in new PointF[] { l, r }) g.DrawArc(ep, e.X - es * 0.5f, e.Y - es * 0.2f, es, es * 0.7f, 200, 140);
            }
        }

        static SmoothingMode Begin(Graphics g, FlatState s, PointF glow, Color glowColor) {
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            FlatFx.Shadow(g, s.Cx, s.By, s.U, s.Sleep);
            if (!s.Sleep && s.U >= 16) FlatFx.Glow(g, glow, 0.6f * s.U, glowColor, (int)((s.Perm ? 60 : 30) + 50 * s.Aha));
            return sm;
        }

        // Динозаврик: сиреневый, сидит, светлое пузико, гребень на спине, хвост; ждёт — над головой «?».
        public static void Dino(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            if (s.Perm) by -= Math.Abs(s.Sin(4.2, 1)) * u * 0.035f * s.A;
            float tilt = 0.05f * s.Gx + (s.Working ? 0.03f * s.Sin(1.6, 1) * s.A : 0f) + (s.Deep ? 0.05f : 0f);
            float breath = 1f + 0.02f * s.Sin(s.Working ? 2.4 : 1.6, 1) * s.A;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + (x - tilt * y) * u, by + y * breath * u); };
            Color body = s.Tint(Theme.Hex(0xB9A8EC), 0.5f), bodyBot = s.Tint(Theme.Hex(0x9A86D8), 0.5f), spike = s.Tint(Theme.Hex(0x7F68C6), 0.5f);
            Color belly = s.Tint(Theme.Hex(0xF4EFE2), 0.4f);
            SmoothingMode sm = Begin(g, s, P(0, -0.45f), Theme.Hex(0xC9B8F5));
            float wag = (s.Working ? 0.04f : 0.02f) * s.Sin(2.0, 1) * s.A;
            using (GraphicsPath tail = Poly(P(-0.20f, -0.10f), P(-0.50f - wag, -0.04f), P(-0.22f, -0.28f))) Fill(g, tail, body, bodyBot);
            for (int i = 0; i < 4; i++) {
                float y = -0.80f + i * 0.17f, x = -0.22f - 0.03f * i;
                using (GraphicsPath sp = Poly(P(x + 0.03f, y - 0.06f), P(x - 0.11f, y + 0.02f), P(x + 0.03f, y + 0.09f))) using (SolidBrush b = new SolidBrush(spike)) g.FillPath(b, sp);
            }
            FillOval(g, P(0, -0.27f), 0.30f * u, 0.27f * u, body, bodyBot);
            FillOval(g, P(0.02f, -0.64f), 0.25f * u, 0.22f * u, body, Draw.Mix(body, bodyBot, 0.5f));
            FillOval(g, P(0.05f, -0.24f), 0.17f * u, 0.18f * u, belly, Draw.Mix(belly, bodyBot, 0.2f));
            FillOval(g, P(-0.11f, -0.02f), 0.09f * u, 0.045f * u, body, bodyBot);
            FillOval(g, P(0.15f, -0.02f), 0.09f * u, 0.045f * u, body, bodyBot);
            FillOval(g, P(0.22f, -0.36f), 0.05f * u, 0.07f * u, body, bodyBot);
            Color ink = Theme.Hex(0x2E2640);
            float fx = s.Gx * 0.05f, fy = -s.Gy * 0.04f;
            FlatFx.Eyes(g, P(-0.06f + fx, -0.66f + fy), P(0.12f + fx, -0.66f + fy), cx + (0.03f + fx) * u, u, s.Eyes, ink, 0.9f);
            Blush(g, P(-0.12f + fx, -0.58f + fy), P(0.19f + fx, -0.58f + fy), u, Theme.Hex(0xF2A6C4), s.Sleep ? 30 : 80);
            FlatFx.Mouth(g, P(0.03f + fx * 0.8f, -0.57f + fy * 0.8f), u * 0.85f, s.Mouth("smile"), ink);
            float q = s.Perm ? s.Spark : (s.Waiting ? 0.85f : 0f);
            Question(g, P(0.30f, -1.0f + 0.02f * s.Sin(2.0, 1) * s.A), u, Theme.Hex(0xEDEAF6), s.Aha > 0.05f ? 0f : q);
            Exclaim(g, P(0.34f, -1.06f), u, Theme.Hex(0xFFB340), s.Aha);
            Finish(g, s, mood, new PointF(cx + 0.62f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }

        // Лягушка с чашкой: зелёная, глаза-бугорки сверху, румянец; держит белую кружку с сердечком, над ней пар.
        public static void Frog(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            if (s.Perm) by -= Math.Abs(s.Sin(4.2, 1)) * u * 0.03f * s.A;
            float sway = 0.04f * s.Gx + (s.Working ? 0.025f * s.Sin(1.4, 1) * s.A : 0f);
            float breath = 1f + 0.02f * s.Sin(s.Working ? 2.4 : 1.6, 1) * s.A;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + (x - sway * y) * u, by + y * breath * u); };
            Color skin = s.Tint(Theme.Hex(0xA9DB9A), 0.5f), skinBot = s.Tint(Theme.Hex(0x86C276), 0.5f);
            SmoothingMode sm = Begin(g, s, P(0, -0.42f), Theme.Hex(0xBDE8B0));
            FillOval(g, P(0, -0.33f), 0.42f * u, 0.32f * u, skin, skinBot);
            FillOval(g, P(-0.20f, -0.62f), 0.12f * u, 0.11f * u, skin, skin);
            FillOval(g, P(0.20f, -0.62f), 0.12f * u, 0.11f * u, skin, skin);
            Color ink = Theme.Hex(0x22301F);
            float fx = s.Gx * 0.04f, fy = -s.Gy * 0.03f;
            FlatFx.Eyes(g, P(-0.20f + fx, -0.62f + fy), P(0.20f + fx, -0.62f + fy), cx + fx * u, u, s.Eyes, ink, 0.85f);
            Blush(g, P(-0.27f + fx, -0.46f + fy), P(0.27f + fx, -0.46f + fy), u, Theme.Hex(0xF29AA8), s.Sleep ? 40 : 110);
            if (u >= 22) using (SolidBrush nb = new SolidBrush(Draw.Mix(skinBot, ink, 0.4f))) {
                PointF n = P(fx, -0.52f + fy);
                g.FillEllipse(nb, n.X - u * 0.04f, n.Y - u * 0.01f, u * 0.02f, u * 0.02f);
                g.FillEllipse(nb, n.X + u * 0.02f, n.Y - u * 0.01f, u * 0.02f, u * 0.02f);
            }
            Color mug = s.Tint(Theme.Hex(0xFAF9F6), 0.3f), mugBot = s.Tint(Theme.Hex(0xE1DDD6), 0.3f);
            RectangleF mr = new RectangleF(cx - 0.15f * u, by - 0.36f * u, 0.30f * u, 0.30f * u);
            using (Pen hp = new Pen(mugBot, Math.Max(1.5f, u * 0.045f))) g.DrawArc(hp, mr.Right - 0.05f * u, mr.Y + 0.07f * u, 0.14f * u, 0.14f * u, -80, 160);
            using (GraphicsPath mp = Draw.Round(mr, u * 0.05f)) Fill(g, mp, mug, mugBot);
            if (u >= 20) using (SolidBrush hb = new SolidBrush(Theme.Hex(0x2A2A2E))) {
                PointF h = new PointF(mr.X + mr.Width / 2, mr.Y + mr.Height * 0.5f);
                float hs = u * 0.045f;
                g.FillEllipse(hb, h.X - hs, h.Y - hs * 0.8f, hs, hs);
                g.FillEllipse(hb, h.X, h.Y - hs * 0.8f, hs, hs);
                g.FillPolygon(hb, new PointF[] { new PointF(h.X - hs * 0.95f, h.Y - hs * 0.15f), new PointF(h.X + hs * 0.95f, h.Y - hs * 0.15f), new PointF(h.X, h.Y + hs * 0.95f) });
            }
            FillOval(g, P(-0.17f, -0.20f), 0.07f * u, 0.06f * u, skin, skinBot);
            FillOval(g, P(0.17f, -0.20f), 0.07f * u, 0.06f * u, skin, skinBot);
            Steam(g, P(0, -0.80f), u, t, s.A, s.Sleep || s.Err ? 0f : s.Working ? 1f : 0.6f);   // пар — над головой, как на картинке
            Exclaim(g, P(0.40f, -0.96f), u, Theme.Hex(0xFFB340), s.Spark);
            Finish(g, s, mood, new PointF(cx + 0.66f * u, by - 0.98f * u));
            g.SmoothingMode = sm;
        }

        // Жнец: тёмный балахон с капюшоном, белое лицо с большими тёмными глазами, коса справа;
        // при «Ага!» и запросе — жёлтые чёрточки, при ошибке коса опускается.
        public static void Reaper(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            float hover = 0.015f * s.Sin(s.Perm ? 4.2 : 1.6, 1) * s.A;
            float lean = 0.04f * s.Gx + (s.Working ? 0.03f * s.Sin(1.2, 1) * s.A : 0f);
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + (x - lean * y) * u, by + (y - hover) * u); };
            Color cloak = s.Tint(Theme.Hex(0x4D4660), 0.4f), cloakBot = s.Tint(Theme.Hex(0x2E293A), 0.4f);
            Color bone = s.Tint(Theme.Hex(0xF3EEE6), 0.3f);
            SmoothingMode sm = Begin(g, s, P(0, -0.45f), Theme.Hex(0x9A8FC0));
            float drop = s.Err ? 0.12f : 0f;
            using (Pen shaft = new Pen(s.Tint(Theme.Hex(0xC79A6B), 0.3f), Math.Max(1.6f, u * 0.045f))) {
                shaft.StartCap = shaft.EndCap = LineCap.Round;
                g.DrawLine(shaft, P(0.30f, -0.02f), P(0.40f, -0.98f + drop));
            }
            using (GraphicsPath blade = new GraphicsPath()) {
                blade.AddBezier(P(0.40f, -0.98f + drop), P(0.58f, -1.02f + drop), P(0.74f, -0.88f + drop), P(0.76f, -0.66f + drop));
                blade.AddBezier(P(0.76f, -0.66f + drop), P(0.66f, -0.84f + drop), P(0.54f, -0.90f + drop), P(0.40f, -0.88f + drop));
                blade.CloseFigure();
                Fill(g, blade, s.Tint(Theme.Hex(0xE4E2F0), 0.3f), s.Tint(Theme.Hex(0xA9A5C2), 0.3f));
            }
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddBezier(P(-0.34f, -0.02f), P(-0.36f, -0.40f), P(-0.32f, -0.90f), P(0f, -0.90f));
                p.AddBezier(P(0f, -0.90f), P(0.32f, -0.90f), P(0.36f, -0.40f), P(0.34f, -0.02f));
                float w = 0.02f * s.Sin(2.6, 1) * s.A;
                p.AddBezier(P(0.34f, -0.02f), P(0.18f, 0.02f + w), P(-0.18f, 0.02f - w), P(-0.34f, -0.02f));
                p.CloseFigure();
                Fill(g, p, cloak, cloakBot);
            }
            using (SolidBrush hood = new SolidBrush(Draw.Mix(cloakBot, Color.Black, 0.35f))) { PointF h = P(0, -0.58f); g.FillEllipse(hood, h.X - 0.22f * u, h.Y - 0.20f * u, 0.44f * u, 0.40f * u); }
            FillOval(g, P(0, -0.56f), 0.17f * u, 0.15f * u, bone, Draw.Mix(bone, cloakBot, 0.15f));
            Color ink = Theme.Hex(0x1C1824);
            float fx = s.Gx * 0.035f, fy = -s.Gy * 0.025f;
            FlatFx.Eyes(g, P(-0.07f + fx, -0.57f + fy), P(0.07f + fx, -0.57f + fy), cx + fx * u, u, s.Eyes == "open" ? "round" : s.Eyes, ink, 1.0f);
            if (u >= 22) using (SolidBrush nb = new SolidBrush(ink)) { PointF n = P(fx, -0.49f + fy); g.FillEllipse(nb, n.X - u * 0.015f, n.Y - u * 0.012f, u * 0.03f, u * 0.022f); }
            FillOval(g, P(0.31f, -0.36f), 0.055f * u, 0.05f * u, bone, bone);
            Marks(g, P(-0.36f, -0.98f), u, Theme.Hex(0xFFC93D), s.Spark, 0.5f);
            Finish(g, s, mood, new PointF(cx - 0.62f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }

        // Онигири: рисовый треугольник со скруглёнными углами, полоска нори, румянец и «ω»; жёлтые чёрточки.
        public static void Onigiri(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            float hop = s.Perm ? Math.Abs(s.Sin(4.2, 1)) * s.A : s.Aha;
            float squash = 1f + (s.Working ? 0.035f * s.Sin(2.6, 1) : 0.02f * s.Sin(1.5, 1)) * s.A;
            float lift = hop * 0.05f;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x / squash * u, by + (y * squash - lift) * u); };
            Color rice = s.Tint(Theme.Hex(0xFBFAF7), 0.5f), riceBot = s.Tint(Theme.Hex(0xE4E0D8), 0.5f);
            SmoothingMode sm = Begin(g, s, P(0, -0.40f), Theme.Hex(0xEDE9DF));
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddBezier(P(-0.40f, -0.06f), P(-0.46f, -0.18f), P(-0.30f, -0.50f), P(-0.12f, -0.78f));
                p.AddBezier(P(-0.12f, -0.78f), P(-0.04f, -0.90f), P(0.04f, -0.90f), P(0.12f, -0.78f));
                p.AddBezier(P(0.12f, -0.78f), P(0.30f, -0.50f), P(0.46f, -0.18f), P(0.40f, -0.06f));
                p.AddBezier(P(0.40f, -0.06f), P(0.34f, 0.0f), P(-0.34f, 0.0f), P(-0.40f, -0.06f));
                p.CloseFigure();
                Fill(g, p, rice, riceBot);
            }
            if (u >= 30) using (Pen gp = new Pen(Color.FromArgb(70, 160, 150, 135), Math.Max(1f, u * 0.015f))) {
                gp.StartCap = gp.EndCap = LineCap.Round;
                g.DrawLine(gp, P(-0.05f, -0.70f), P(-0.02f, -0.67f));
                g.DrawLine(gp, P(0.10f, -0.62f), P(0.13f, -0.64f));
            }
            PointF n0 = P(-0.17f, -0.30f), n1 = P(0.17f, 0f);
            using (GraphicsPath n = Draw.Round(new RectangleF(n0.X, n0.Y, n1.X - n0.X, n1.Y - n0.Y - 0.01f * u), u * 0.03f))
                Fill(g, n, Theme.Hex(0x2C3330), Theme.Hex(0x1A1F1D));
            Color ink = Theme.Hex(0x2A2A2E);
            float fx = s.Gx * 0.05f, fy = -s.Gy * 0.035f;
            PointF eL = P(-0.13f + fx, -0.47f + fy), eR = P(0.13f + fx, -0.47f + fy);
            if (s.Eyes == "open") HappyArcs(g, eL, eR, u, ink, 1f);   // онигири жмурится от удовольствия
            else FlatFx.Eyes(g, eL, eR, cx + fx * u, u, s.Eyes, ink, 0.9f);
            Blush(g, P(-0.23f + fx, -0.39f + fy), P(0.23f + fx, -0.39f + fy), u, Theme.Hex(0xF4A3AE), s.Sleep ? 40 : 110);
            FlatFx.Mouth(g, P(fx * 0.8f, -0.40f + fy * 0.8f), u * 0.9f, s.Mouth("cat"), ink);
            Marks(g, P(0.30f, -0.98f), u, Theme.Hex(0xFFC93D), Math.Max(s.Spark, s.Waiting ? 0.7f : 0f), -0.55f);
            Finish(g, s, mood, new PointF(cx + 0.64f * u, by - 0.96f * u));
            g.SmoothingMode = sm;
        }

        // Котик в чашке: чёрный котик выглядывает из кремовой чашки с месяцем, лапки на краю, над ним пар и звёздочки.
        public static void CupCat(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + y * u); };
            float rise = s.Sleep ? 0.04f : s.Perm ? 0.14f + 0.03f * Math.Abs(s.Sin(4.2, 1)) * s.A : 0.08f + 0.05f * s.Aha;
            float hx = 0.04f * s.Gx + (s.Working ? 0.025f * s.Sin(0.9, 1) * s.A : 0f);
            Color fur = s.Tint(Theme.Hex(0x3A3445), 0.5f), furBot = s.Tint(Theme.Hex(0x221E2A), 0.5f);
            Color cup = s.Tint(Theme.Hex(0xF4EEE4), 0.35f), cupBot = s.Tint(Theme.Hex(0xDCD3C6), 0.35f);
            SmoothingMode sm = Begin(g, s, P(0, -0.50f), Theme.Hex(0xC8B9E8));
            float rim = -0.46f, hcy = rim - 0.12f - rise;
            for (int side = -1; side <= 1; side += 2)
                using (GraphicsPath ear = Poly(P(hx + side * 0.06f, hcy - 0.14f), P(hx + side * 0.25f, hcy - 0.06f), P(hx + side * 0.21f, hcy - 0.34f))) Fill(g, ear, fur, furBot);
            FillOval(g, P(hx, hcy), 0.27f * u, 0.21f * u, fur, furBot);
            Color eyeInk = Theme.Hex(0xD8CFEA);
            float fx = s.Gx * 0.04f, fy = -s.Gy * 0.03f;
            string eyes = s.Eyes == "open" && !s.Working ? "closed" : s.Eyes;   // котик сонный: глаза прикрыты
            FlatFx.Eyes(g, P(hx - 0.10f + fx, hcy + 0.01f + fy), P(hx + 0.10f + fx, hcy + 0.01f + fy), cx + (hx + fx) * u, u, eyes, eyeInk, 0.95f);
            FlatFx.Mouth(g, P(hx + fx, hcy + 0.09f + fy), u * 0.75f, s.Mouth("cat"), eyeInk);
            using (Pen hp = new Pen(cupBot, Math.Max(2f, u * 0.06f))) g.DrawArc(hp, cx - 0.52f * u, by - 0.36f * u, 0.20f * u, 0.20f * u, 90, 180);
            using (GraphicsPath cp = new GraphicsPath()) {
                cp.AddLine(P(-0.40f, rim), P(0.40f, rim));
                cp.AddBezier(P(0.40f, rim), P(0.40f, -0.14f), P(0.24f, -0.02f), P(0.10f, -0.02f));
                cp.AddLine(P(0.10f, -0.02f), P(-0.10f, -0.02f));
                cp.AddBezier(P(-0.10f, -0.02f), P(-0.24f, -0.02f), P(-0.40f, -0.14f), P(-0.40f, rim));
                cp.CloseFigure();
                Fill(g, cp, cup, cupBot);
            }
            FillOval(g, P(hx - 0.13f, rim + 0.005f), 0.065f * u, 0.04f * u, fur, furBot);
            FillOval(g, P(hx + 0.13f, rim + 0.005f), 0.065f * u, 0.04f * u, fur, furBot);
            if (u >= 20) using (GraphicsPath moon = new GraphicsPath()) {
                PointF m = P(0.02f, -0.24f); float mr = 0.07f * u;
                moon.AddEllipse(m.X - mr, m.Y - mr, mr * 2, mr * 2);
                using (Region reg = new Region(moon)) {
                    using (GraphicsPath cut = new GraphicsPath()) { cut.AddEllipse(m.X - mr * 0.45f, m.Y - mr * 1.15f, mr * 2, mr * 2); reg.Exclude(cut); }
                    using (SolidBrush mb = new SolidBrush(Theme.Hex(0x8E86A8))) g.FillRegion(mb, reg);
                }
            }
            Steam(g, P(hx, hcy - 0.24f), u, t, s.A, s.Sleep || s.Err ? 0f : s.Working ? 0.9f : 0.5f);
            float tw = 0.5f + 0.5f * (float)Math.Abs(Math.Sin(t * 1.7 + s.Ph)) * s.A;
            if (!s.Sleep && u >= 22) { Sparkle(g, P(-0.52f, -0.62f), u * 0.05f * tw, Theme.Hex(0xF2C57C)); Sparkle(g, P(0.50f, -0.30f), u * 0.035f * (1.4f - tw), Theme.Hex(0xF2C57C)); }
            Exclaim(g, P(0.34f, hcy - 0.48f), u, Theme.Hex(0xFFB340), s.Spark);
            Finish(g, s, mood, new PointF(cx + 0.64f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }

        // Лисёнок: рыжий, свернулся, пушистый хвост с белым кончиком обнимает спереди; ушки с тёмными кончиками.
        public static void Fox(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            if (s.Perm) by -= Math.Abs(s.Sin(4.2, 1)) * u * 0.03f * s.A;
            float tilt = 0.05f * s.Gx + (s.Deep ? 0.07f : 0f) + (s.Perm ? 0.05f : 0f);
            float breath = 1f + 0.02f * s.Sin(s.Working ? 2.4 : 1.6, 1) * s.A;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + y * breath * u); };
            Func<float, float, PointF> H = delegate (float x, float y) { float hy = y + 0.60f; return new PointF(cx + (x - tilt * hy * 1.2f) * u, by + y * breath * u); };
            Color fur = s.Tint(Theme.Hex(0xEE8A4E), 0.5f), furBot = s.Tint(Theme.Hex(0xD66F33), 0.5f);
            Color cream = s.Tint(Theme.Hex(0xFBF1E6), 0.4f), dark = s.Tint(Theme.Hex(0x6E4B40), 0.4f);
            SmoothingMode sm = Begin(g, s, P(0, -0.42f), Theme.Hex(0xF6B98E));
            FillOval(g, P(0.04f, -0.24f), 0.34f * u, 0.24f * u, fur, furBot);
            for (int side = -1; side <= 1; side += 2) {
                float droop = s.Err ? 0.06f : 0f;
                using (GraphicsPath ear = Poly(H(side * 0.07f, -0.76f), H(side * (0.29f + droop), -0.66f), H(side * (0.24f + droop * 1.4f), -0.98f + droop))) Fill(g, ear, fur, furBot);
                using (GraphicsPath ie = Poly(H(side * 0.12f, -0.75f), H(side * (0.24f + droop), -0.69f), H(side * (0.22f + droop * 1.4f), -0.88f + droop))) using (SolidBrush b = new SolidBrush(cream)) g.FillPath(b, ie);
                using (GraphicsPath tip = Poly(H(side * (0.20f + droop), -0.88f + droop * 0.6f), H(side * (0.265f + droop), -0.83f + droop * 0.6f), H(side * (0.24f + droop * 1.4f), -0.98f + droop))) using (SolidBrush b = new SolidBrush(dark)) g.FillPath(b, tip);
            }
            FillOval(g, H(0, -0.58f), 0.30f * u, 0.23f * u, fur, Draw.Mix(fur, furBot, 0.6f));
            FillOval(g, H(-0.12f, -0.50f), 0.14f * u, 0.10f * u, cream, cream);
            FillOval(g, H(0.12f, -0.50f), 0.14f * u, 0.10f * u, cream, cream);
            Color ink = Theme.Hex(0x3A2622);
            float fx = s.Gx * 0.05f, fy = -s.Gy * 0.04f;
            PointF eL = H(-0.12f + fx, -0.60f + fy), eR = H(0.12f + fx, -0.60f + fy);
            if (s.Eyes == "open") HappyArcs(g, eL, eR, u, ink, 1.05f);   // лисёнок улыбается глазами «^ ^»
            else FlatFx.Eyes(g, eL, eR, cx + fx * u, u, s.Eyes, ink, 0.9f);
            if (u >= 20) { PointF n = H(fx, -0.53f + fy); using (SolidBrush nb = new SolidBrush(ink)) g.FillEllipse(nb, n.X - u * 0.028f, n.Y - u * 0.02f, u * 0.056f, u * 0.04f); }
            FlatFx.Mouth(g, H(fx * 0.8f, -0.48f + fy * 0.8f), u * 0.85f, s.Mouth("cat"), ink);
            float sw = (s.Working ? 0.04f : 0.02f) * s.Sin(2.0, 1) * s.A + 0.04f * s.Aha;
            using (GraphicsPath tail = new GraphicsPath()) {
                tail.AddBezier(P(0.36f, -0.20f), P(0.42f, -0.02f), P(0.10f, 0.03f), P(-0.30f + sw, -0.06f));
                tail.AddBezier(P(-0.30f + sw, -0.06f), P(-0.40f + sw, -0.10f), P(-0.36f + sw, -0.24f), P(-0.20f + sw, -0.20f));
                tail.AddBezier(P(-0.20f + sw, -0.20f), P(0.05f, -0.14f), P(0.28f, -0.16f), P(0.36f, -0.20f));
                tail.CloseFigure();
                Fill(g, tail, fur, furBot);
            }
            using (GraphicsPath tip = new GraphicsPath()) {
                tip.AddBezier(P(-0.14f + sw, -0.04f), P(-0.26f + sw, -0.03f), P(-0.40f + sw, -0.08f), P(-0.32f + sw, -0.20f));
                tip.AddBezier(P(-0.32f + sw, -0.20f), P(-0.26f + sw, -0.22f), P(-0.20f + sw, -0.20f), P(-0.14f + sw, -0.18f));
                tip.CloseFigure();
                using (SolidBrush b = new SolidBrush(cream)) g.FillPath(b, tip);
            }
            Marks(g, H(0.30f, -1.02f), u, Theme.Hex(0xFFC93D), Math.Max(s.Spark, s.Waiting ? 0.7f : 0f), -0.55f);
            Finish(g, s, mood, new PointF(cx + 0.64f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }

        // Листик: зелёный семипалый листок с мордочкой; в лапке самокрутка с огоньком, над ней завиток дыма.
        public static void Leaf(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            if (s.Perm) by -= Math.Abs(s.Sin(4.2, 1)) * u * 0.03f * s.A;
            float sway = 0.04f * s.Gx + (s.Working ? 0.04f : 0.025f) * s.Sin(1.3, 1) * s.A;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + (x - sway * (y + 0.5f)) * u, by + y * u); };
            Color leaf = s.Tint(Theme.Hex(0x9DBA74), 0.5f), leafBot = s.Tint(Theme.Hex(0x7E9C58), 0.5f), vein = s.Tint(Theme.Hex(0x6E8A4B), 0.5f);
            SmoothingMode sm = Begin(g, s, P(0, -0.50f), Theme.Hex(0xBFD79A));
            PointF root = P(0, -0.16f);
            using (Pen st = new Pen(leafBot, Math.Max(1.5f, u * 0.04f))) { st.StartCap = st.EndCap = LineCap.Round; g.DrawLine(st, root, P(0, -0.02f)); }
            float[] ang = { -88, -58, -32, 0, 32, 58, 88 };
            float[] len = { 0.36f, 0.52f, 0.66f, 0.82f, 0.66f, 0.52f, 0.36f };
            for (int i = 0; i < 7; i++) {
                double a = (ang[i] - 90) * Math.PI / 180;
                float L = len[i] * u, W = (i == 3 ? 0.11f : 0.09f) * u;
                float dx = (float)Math.Cos(a), dy = (float)Math.Sin(a), nx = -dy, ny = dx;
                PointF tip = new PointF(root.X + dx * L, root.Y + dy * L);
                PointF m1 = new PointF(root.X + dx * L * 0.45f + nx * W, root.Y + dy * L * 0.45f + ny * W);
                PointF m2 = new PointF(root.X + dx * L * 0.45f - nx * W, root.Y + dy * L * 0.45f - ny * W);
                using (GraphicsPath p = new GraphicsPath()) {
                    p.AddBezier(root, m1, new PointF(tip.X + nx * W * 0.3f, tip.Y + ny * W * 0.3f), tip);
                    p.AddBezier(tip, new PointF(tip.X - nx * W * 0.3f, tip.Y - ny * W * 0.3f), m2, root);
                    p.CloseFigure();
                    Fill(g, p, leaf, leafBot);
                }
                if (u >= 30) using (Pen vp = new Pen(Color.FromArgb(120, vein), Math.Max(1f, u * 0.012f))) g.DrawLine(vp, root, new PointF(root.X + dx * L * 0.8f, root.Y + dy * L * 0.8f));
            }
            FillOval(g, P(0, -0.50f), 0.18f * u, 0.15f * u, leaf, Draw.Mix(leaf, leafBot, 0.4f));
            Color ink = Theme.Hex(0x2C3322);
            float fx = s.Gx * 0.04f, fy = -s.Gy * 0.03f;
            PointF eL = P(-0.08f + fx, -0.52f + fy), eR = P(0.08f + fx, -0.52f + fy);
            if (s.Eyes == "open") HappyArcs(g, eL, eR, u, ink, 0.85f);
            else FlatFx.Eyes(g, eL, eR, cx + fx * u, u, s.Eyes, ink, 0.8f);
            Blush(g, P(-0.13f + fx, -0.45f + fy), P(0.13f + fx, -0.45f + fy), u, Theme.Hex(0xF29AA0), s.Sleep ? 40 : 110);
            FlatFx.Mouth(g, P(fx * 0.8f, -0.45f + fy * 0.8f), u * 0.8f, s.Mouth("smile"), ink);
            PointF j0 = P(0.14f, -0.40f), j1 = P(0.40f, -0.50f);
            using (Pen jp = new Pen(Theme.Hex(0xF5F2EA), Math.Max(1.6f, u * 0.045f))) { jp.StartCap = jp.EndCap = LineCap.Round; g.DrawLine(jp, j0, j1); }
            if (!s.Sleep) {
                float ember = 0.6f + 0.4f * (float)Math.Abs(Math.Sin(t * 2.5 + s.Ph)) * s.A;
                using (SolidBrush eb = new SolidBrush(Color.FromArgb((int)(255 * ember), 0xF0, 0x7A, 0x3A))) g.FillEllipse(eb, j1.X - u * 0.025f, j1.Y - u * 0.025f, u * 0.05f, u * 0.05f);
                if (u >= 18) using (Pen sp = new Pen(Color.FromArgb(150, 230, 226, 232), Math.Max(1.4f, u * 0.035f))) {
                    sp.StartCap = sp.EndCap = LineCap.Round;
                    float w = u * 0.05f * (float)Math.Sin(t * 1.6 + s.Ph) * s.A;
                    g.DrawBezier(sp, j1.X, j1.Y - u * 0.04f, j1.X + u * 0.10f + w, j1.Y - u * 0.18f, j1.X - u * 0.06f - w, j1.Y - u * 0.30f, j1.X + u * 0.06f, j1.Y - u * 0.44f);
                }
            }
            FillOval(g, P(0.15f, -0.39f), 0.045f * u, 0.04f * u, leaf, leafBot);
            Exclaim(g, P(-0.36f, -1.02f), u, Theme.Hex(0xFFB340), s.Spark);
            Finish(g, s, mood, new PointF(cx - 0.64f * u, by - 0.98f * u));
            g.SmoothingMode = sm;
        }

        // Пчёлка: жёлто-коричневая полосатая, прозрачные крылышки машут, усики; за ней — пунктирный след-сердечко.
        public static void Bee(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            float hover = s.Sleep ? 0f : 0.04f + (s.Working || s.Perm ? 0.035f : 0.02f) * s.Sin(s.Perm ? 4.2 : 2.0, 1) * s.A;
            float lean = 0.05f * s.Gx;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + (x - lean * y) * u, by + (y - hover) * u); };
            Color yel = s.Tint(Theme.Hex(0xF7CF6E), 0.5f), yelBot = s.Tint(Theme.Hex(0xE8B44B), 0.5f), brown = s.Tint(Theme.Hex(0x4A3428), 0.4f);
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush sh = new SolidBrush(Color.FromArgb(s.Sleep ? 50 : 70, 0, 0, 0))) g.FillEllipse(sh, cx - 0.30f * u, by - 0.03f * u, 0.60f * u, 0.06f * u);
            if (!s.Sleep && u >= 16) FlatFx.Glow(g, P(0, -0.42f), 0.6f * u, Theme.Hex(0xF9DD93), (int)((s.Perm ? 60 : 30) + 50 * s.Aha));
            if ((s.Working || s.Aha > 0.05f) && u >= 22) using (Pen dp = new Pen(Color.FromArgb(200, 245, 240, 232), Math.Max(1.2f, u * 0.025f))) {
                dp.DashStyle = DashStyle.Dash; dp.DashOffset = animate ? -t * 4f : 0f;
                using (GraphicsPath hp = new GraphicsPath()) {
                    hp.AddBezier(P(0.36f, -0.40f), P(0.52f, -0.40f), P(0.56f, -0.60f), P(0.66f, -0.70f));
                    hp.AddBezier(P(0.66f, -0.70f), P(0.58f, -0.86f), P(0.44f, -0.80f), P(0.50f, -0.66f));
                    hp.AddBezier(P(0.50f, -0.66f), P(0.56f, -0.80f), P(0.74f, -0.80f), P(0.66f, -0.70f));
                    g.DrawPath(dp, hp);
                }
            }
            float flap = s.Sleep ? 0.2f : (float)Math.Abs(Math.Sin(t * (s.Working ? 18 : 9) + s.Ph)) * s.A;
            Color wing = Color.FromArgb(200, 236, 238, 244);
            for (int i = 0; i < 2; i++) {
                PointF pivot = P(-0.04f + i * 0.10f, -0.62f);
                GraphicsState gs = g.Save();
                g.TranslateTransform(pivot.X, pivot.Y);
                g.RotateTransform(-20f + i * 25f - 25f * flap);
                using (GraphicsPath w = Oval(new PointF(0, -u * 0.15f), 0.10f * u, 0.16f * u)) using (SolidBrush b = new SolidBrush(wing)) g.FillPath(b, w);
                g.Restore(gs);
            }
            using (GraphicsPath body = Oval(P(0, -0.40f), 0.36f * u, 0.25f * u)) {
                Fill(g, body, yel, yelBot);
                GraphicsState gs = g.Save();
                g.SetClip(body, CombineMode.Intersect);
                using (SolidBrush sb = new SolidBrush(brown)) {
                    foreach (float sx in new float[] { -0.06f, 0.10f, 0.26f }) { PointF a = P(sx, -0.40f); g.FillRectangle(sb, a.X - 0.045f * u, a.Y - 0.30f * u, 0.09f * u, 0.60f * u); }
                }
                g.Restore(gs);
            }
            using (GraphicsPath st = Poly(P(0.35f, -0.43f), P(0.45f, -0.40f), P(0.35f, -0.37f))) using (SolidBrush b = new SolidBrush(brown)) g.FillPath(b, st);
            using (Pen ap = new Pen(brown, Math.Max(1.2f, u * 0.025f))) {
                ap.StartCap = ap.EndCap = LineCap.Round;
                float wob = 0.02f * s.Sin(3.0, 1) * s.A;
                g.DrawBezier(ap, P(-0.24f, -0.58f), P(-0.26f, -0.70f), P(-0.32f, -0.76f + wob), P(-0.36f, -0.78f + wob));
                g.DrawBezier(ap, P(-0.16f, -0.60f), P(-0.16f, -0.72f), P(-0.20f, -0.80f - wob), P(-0.22f, -0.82f - wob));
            }
            Color ink = Theme.Hex(0x2E2018);
            float fx = s.Gx * 0.04f, fy = -s.Gy * 0.03f;
            PointF eL = P(-0.24f + fx, -0.44f + fy), eR = P(-0.08f + fx, -0.44f + fy);
            if (s.Eyes == "open") HappyArcs(g, eL, eR, u, ink, 0.85f);
            else FlatFx.Eyes(g, eL, eR, cx + (-0.16f + fx) * u, u, s.Eyes, ink, 0.85f);
            Blush(g, P(-0.30f + fx, -0.36f + fy), P(-0.02f + fx, -0.36f + fy), u, Theme.Hex(0xF2A0A0), s.Sleep ? 40 : 100);
            FlatFx.Mouth(g, P(-0.16f + fx * 0.8f, -0.37f + fy * 0.8f), u * 0.8f, s.Mouth("smile"), ink);
            Exclaim(g, P(-0.40f, -1.0f), u, Theme.Hex(0xFFB340), s.Spark);
            Finish(g, s, mood, new PointF(cx - 0.64f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }
    }
}
