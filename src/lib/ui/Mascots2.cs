// claude-notifier: ещё восемь плоских маскотов шторки — динозаврик, лягушка с чашкой, жнец, онигири,
// котик в чашке, лисёнок, листик и пчёлка (по картинкам пользователя).
// Каждый — одна цельная фигура: покачивание, наклон и подъём применяются ко всему телу сразу (Rigid), а части
// заходят друг на друга, поэтому в движении ничего не отрывается. Отдельно двигается только то, что крепится
// внутри тела: хвост, крылышки, пар, дым. Мордочка и поведение — общие (FlatState): работает — покачивается и
// смотрит по сторонам, облачко «…»; «Ага!» — глаза «> <»; ждёт решения — подпрыгивает, «!»; ошибка — глаза-
// крестики и красноватый оттенок; остановился и спит — глаза закрыты, «z».
using System;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace ClaudeNotifier.Ui {
    public static partial class FlatPals {
        // Поворот всей фигуры вокруг точки опоры и подъём (в пикселях) — части двигаются вместе.
        static GraphicsState Rigid(Graphics g, float cx, float by, float tiltDeg, float liftPx) {
            GraphicsState st = g.Save();
            g.TranslateTransform(cx, by);
            g.RotateTransform(tiltDeg);
            g.TranslateTransform(-cx, -by - liftPx);
            return st;
        }

        // Подъём «ждёт решения» и «Ага!» (подпрыгивает), в долях u.
        static float Hop(FlatState s) {
            if (s.Perm) return 0.045f * Math.Abs(s.Sin(4.2, 1)) * s.A;
            return 0.04f * s.Aha;
        }

        // Наклон в градусах: взгляд, покачивание в работе, кивок во сне.
        static float Tilt(FlatState s, float work) {
            float d = 4f * s.Gx;
            if (s.Working) d += work * s.Sin(1.3, 1) * s.A;
            if (s.Sleep) d += 2f * s.Sin(0.8, 1) * s.A;
            if (s.Deep) d += 4f;
            return d;
        }

        static void Question(Graphics g, PointF p, float u, Color c, float k) {
            if (k <= 0.05f || u < 16) return;
            using (Font f = new Font("Segoe UI", Math.Max(6f, u * 0.24f), FontStyle.Bold, GraphicsUnit.Pixel))
            using (StringFormat sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(255 * FlatFx.Clamp(k, 0, 1)), c)))
                g.DrawString("?", f, b, p, sf);
        }

        // Пар: три волнистые струйки снизу вверх от точки c.
        static void Steam(Graphics g, PointF c, float u, float t, float A, float k) {
            if (k <= 0.05f || u < 18) return;
            using (Pen pen = new Pen(Color.FromArgb((int)(170 * FlatFx.Clamp(k, 0, 1)), 230, 230, 236), Math.Max(1.4f, u * 0.032f))) {
                pen.StartCap = pen.EndCap = LineCap.Round;
                for (int i = -1; i <= 1; i++) {
                    float x = c.X + i * u * 0.085f, w = u * 0.03f * (float)Math.Sin(t * 2.2 + i * 1.3) * A;
                    float y0 = c.Y, y1 = c.Y - u * (0.19f - 0.03f * Math.Abs(i));
                    g.DrawBezier(pen, x, y0, x - u * 0.045f + w, y0 - u * 0.06f, x + u * 0.045f - w, y1 + u * 0.06f, x, y1);
                }
            }
        }

        static void Sparkle(Graphics g, PointF c, float r, Color col) {
            if (r < 1.5f) return;
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddPolygon(new PointF[] {
                    new PointF(c.X, c.Y - r), new PointF(c.X + r * 0.22f, c.Y - r * 0.22f), new PointF(c.X + r, c.Y),
                    new PointF(c.X + r * 0.22f, c.Y + r * 0.22f), new PointF(c.X, c.Y + r), new PointF(c.X - r * 0.22f, c.Y + r * 0.22f),
                    new PointF(c.X - r, c.Y), new PointF(c.X - r * 0.22f, c.Y - r * 0.22f) });
                using (SolidBrush b = new SolidBrush(col)) g.FillPath(b, p);
            }
        }

        // Довольные дужки «^ ^».
        static void HappyArcs(Graphics g, PointF l, PointF r, float u, Color ink, float size) {
            using (Pen ep = new Pen(ink, Math.Max(1.2f, u * 0.04f))) {
                ep.StartCap = ep.EndCap = LineCap.Round;
                float es = u * 0.075f * size;
                foreach (PointF e in new PointF[] { l, r }) g.DrawArc(ep, e.X - es * 0.5f, e.Y - es * 0.15f, es, es * 0.75f, 200, 140);
            }
        }

        // Глаза: «^ ^», когда просто ждёт (happyIdle); иначе общие (крестики, круглые, закрытые…).
        static void FaceEyes(Graphics g, FlatState s, PointF l, PointF r, float u, Color ink, float size, bool happyIdle) {
            if (happyIdle && s.Eyes == "open" && !s.Working) HappyArcs(g, l, r, u, ink, size);
            else FlatFx.Eyes(g, l, r, (l.X + r.X) / 2f, u, s.Eyes, ink, size);
        }

        // Скруглённый треугольник (уши, шипы): заливка и обводка того же цвета с круглыми углами.
        static void Spike(Graphics g, PointF a, PointF tip, PointF b, Color c, float u) {
            using (GraphicsPath p = Poly(a, tip, b))
            using (SolidBrush br = new SolidBrush(c))
            using (Pen pen = new Pen(c, Math.Max(1f, u * 0.035f))) {
                pen.LineJoin = LineJoin.Round;
                g.FillPath(br, p); g.DrawPath(pen, p);
            }
        }

        static SmoothingMode Begin(Graphics g, FlatState s, PointF glow, Color glowColor, float shadowW) {
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush sh = new SolidBrush(Color.FromArgb(s.Sleep ? 50 : 85, 0, 0, 0)))
                g.FillEllipse(sh, s.Cx - shadowW * s.U, s.By - 0.035f * s.U, shadowW * 2 * s.U, 0.07f * s.U);
            if (!s.Sleep && s.U >= 16) FlatFx.Glow(g, glow, 0.6f * s.U, glowColor, (int)((s.Perm ? 55 : 28) + 45 * s.Aha));
            return sm;
        }

        // ---------------------------------------------------------------- Динозаврик
        // Сиреневый, сидит: круглая голова на груше-теле, светлое пузико, мягкий гребень по спине, хвост.
        public static void Dino(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + y * u); };
            Color body = s.Tint(Theme.Hex(0xB7A4EE), 0.5f), bodyBot = s.Tint(Theme.Hex(0x9682DD), 0.5f);
            Color spike = s.Tint(Theme.Hex(0x8A73D4), 0.5f), belly = s.Tint(Theme.Hex(0xF5F0E4), 0.35f);
            SmoothingMode sm = Begin(g, s, P(0, -0.45f), Theme.Hex(0xC9B8F5), 0.36f);
            GraphicsState st = Rigid(g, cx, by, Tilt(s, 3f), Hop(s) * u);
            // Хвост и гребень — за телом, основания спрятаны внутри силуэта.
            float wag = (s.Working ? 0.03f : 0.015f) * s.Sin(2.0, 1) * s.A;
            using (GraphicsPath tail = new GraphicsPath()) {
                tail.AddBezier(P(-0.10f, -0.30f), P(-0.30f, -0.26f), P(-0.42f - wag, -0.12f), P(-0.50f - wag, -0.04f));
                tail.AddBezier(P(-0.50f - wag, -0.04f), P(-0.36f, -0.02f), P(-0.20f, -0.04f), P(-0.06f, -0.10f));
                tail.CloseFigure();
                Fill(g, tail, body, bodyBot);
            }
            float[][] sp = {
                new float[] { 0.02f, -0.66f, 0.26f, 0.23f, 118 }, new float[] { 0.02f, -0.66f, 0.26f, 0.23f, 148 },
                new float[] { 0f, -0.30f, 0.30f, 0.28f, 140 }, new float[] { 0f, -0.30f, 0.30f, 0.28f, 168 }, new float[] { 0f, -0.30f, 0.30f, 0.28f, 196 } };
            foreach (float[] e in sp) {
                double a = e[4] * Math.PI / 180;
                float dx = (float)Math.Cos(a), dy = -(float)Math.Sin(a);
                float ex = e[0] + e[2] * dx, ey = e[1] + e[3] * dy;
                float tx = -dy, ty = dx;
                Spike(g, P(ex - dx * 0.04f + tx * 0.055f, ey - dy * 0.04f + ty * 0.055f), P(ex + dx * 0.10f, ey + dy * 0.10f),
                    P(ex - dx * 0.04f - tx * 0.055f, ey - dy * 0.04f - ty * 0.055f), spike, u);
            }
            FillOval(g, P(0, -0.30f), 0.30f * u, 0.28f * u, body, bodyBot);
            FillOval(g, P(0.02f, -0.66f), 0.26f * u, 0.23f * u, body, Draw.Mix(body, bodyBot, 0.45f));
            FillOval(g, P(0.06f, -0.27f), 0.18f * u, 0.19f * u, belly, Draw.Mix(belly, bodyBot, 0.15f));
            FillOval(g, P(0.22f, -0.40f), 0.06f * u, 0.08f * u, body, bodyBot);
            FillOval(g, P(-0.12f, -0.04f), 0.10f * u, 0.05f * u, body, bodyBot);
            FillOval(g, P(0.16f, -0.04f), 0.10f * u, 0.05f * u, body, bodyBot);
            Color ink = Theme.Hex(0x2E2640);
            float fx = s.Gx * 0.05f, fy = -s.Gy * 0.035f;
            FaceEyes(g, s, P(-0.05f + fx, -0.68f + fy), P(0.12f + fx, -0.68f + fy), u, ink, 0.9f, false);
            Blush(g, P(-0.11f + fx, -0.59f + fy), P(0.19f + fx, -0.59f + fy), u, Theme.Hex(0xF2A6C4), s.Sleep ? 30 : 85);
            FlatFx.Mouth(g, P(0.035f + fx * 0.8f, -0.585f + fy * 0.8f), u * 0.8f, s.Mouth("smile"), ink);
            float q = s.Aha > 0.05f ? 0f : s.Perm ? s.Spark : s.Waiting ? 0.9f : 0f;
            Question(g, P(0.30f, -1.0f), u, Theme.Hex(0xEEEAF8), q);
            Exclaim(g, P(0.32f, -1.08f), u, Theme.Hex(0xFFB340), s.Aha);
            g.Restore(st);
            Finish(g, s, mood, new PointF(cx + 0.62f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }

        // ---------------------------------------------------------------- Лягушка с чашкой
        // Зелёная, широкая, глаза на бугорках, румянец; двумя лапками держит белую кружку с сердечком, над головой пар.
        public static void Frog(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + y * u); };
            Color skin = s.Tint(Theme.Hex(0xA8DA98), 0.5f), skinBot = s.Tint(Theme.Hex(0x84C173), 0.5f);
            SmoothingMode sm = Begin(g, s, P(0, -0.40f), Theme.Hex(0xBDE8B0), 0.44f);
            GraphicsState st = Rigid(g, cx, by, Tilt(s, 2.5f), Hop(s) * u);
            FillOval(g, P(-0.21f, -0.58f), 0.13f * u, 0.12f * u, skin, Draw.Mix(skin, skinBot, 0.3f));
            FillOval(g, P(0.21f, -0.58f), 0.13f * u, 0.12f * u, skin, Draw.Mix(skin, skinBot, 0.3f));
            FillOval(g, P(0, -0.31f), 0.44f * u, 0.31f * u, skin, skinBot);
            Color ink = Theme.Hex(0x23301F);
            float fx = s.Gx * 0.035f, fy = -s.Gy * 0.025f;
            FaceEyes(g, s, P(-0.21f + fx, -0.59f + fy), P(0.21f + fx, -0.59f + fy), u, ink, 0.85f, false);
            Blush(g, P(-0.29f, -0.45f), P(0.29f, -0.45f), u, Theme.Hex(0xF29AA8), s.Sleep ? 40 : 110);
            FlatFx.Mouth(g, P(fx * 0.6f, -0.47f), u * 0.75f, s.Mouth("smile"), ink);
            Color mug = s.Tint(Theme.Hex(0xFAF8F4), 0.3f), mugBot = s.Tint(Theme.Hex(0xDFDAD2), 0.3f);
            PointF m0 = P(-0.15f, -0.40f), m1 = P(0.15f, -0.08f);
            RectangleF mr = new RectangleF(m0.X, m0.Y, m1.X - m0.X, m1.Y - m0.Y);
            using (Pen hp = new Pen(mugBot, Math.Max(1.6f, u * 0.045f))) g.DrawArc(hp, mr.Right - 0.06f * u, mr.Y + 0.07f * u, 0.15f * u, 0.15f * u, -75, 150);
            using (GraphicsPath mp = Draw.Round(mr, u * 0.05f)) Fill(g, mp, mug, mugBot);
            if (u >= 18) using (SolidBrush hb = new SolidBrush(Theme.Hex(0x2B2B30))) {
                PointF h = new PointF(mr.X + mr.Width / 2, mr.Y + mr.Height * 0.48f);
                float hs = u * 0.042f;
                g.FillEllipse(hb, h.X - hs, h.Y - hs * 0.75f, hs, hs);
                g.FillEllipse(hb, h.X, h.Y - hs * 0.75f, hs, hs);
                g.FillPolygon(hb, new PointF[] { new PointF(h.X - hs * 0.95f, h.Y - hs * 0.1f), new PointF(h.X + hs * 0.95f, h.Y - hs * 0.1f), new PointF(h.X, h.Y + hs * 0.95f) });
            }
            // Лапки обнимают кружку с боков (заходят и на кружку, и на тело).
            FillOval(g, P(-0.15f, -0.22f), 0.065f * u, 0.075f * u, skin, skinBot);
            FillOval(g, P(0.13f, -0.22f), 0.065f * u, 0.075f * u, skin, skinBot);
            Exclaim(g, P(0.42f, -0.98f), u, Theme.Hex(0xFFB340), s.Spark);
            g.Restore(st);
            Steam(g, new PointF(cx, by - 0.76f * u - Hop(s) * u), u, t, s.A, s.Sleep || s.Err || s.Stalled ? 0f : s.Working ? 1f : 0.65f);
            Finish(g, s, mood, new PointF(cx + 0.66f * u, by - 0.98f * u));
            g.SmoothingMode = sm;
        }

        // ---------------------------------------------------------------- Жнец
        // Тёмный балахон-колокол с капюшоном, в глубине — белое лицо с большими тёмными глазами; лапка держит косу.
        public static void Reaper(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + y * u); };
            Color cloak = s.Tint(Theme.Hex(0x4B4560), 0.4f), cloakBot = s.Tint(Theme.Hex(0x2D2939), 0.4f);
            Color bone = s.Tint(Theme.Hex(0xF4EFE8), 0.25f);
            SmoothingMode sm = Begin(g, s, P(0, -0.45f), Theme.Hex(0x9A8FC0), 0.36f);
            float lift = (0.015f + 0.015f * s.Sin(s.Perm ? 4.2 : 1.4, 1)) * s.A * u + Hop(s) * u * 0.5f;
            GraphicsState st = Rigid(g, cx, by, Tilt(s, 2f), lift);
            float drop = s.Err ? 0.10f : 0f;   // ошибка — коса чуть опущена
            PointF top = P(0.40f, -1.00f + drop), bottom = P(0.27f, -0.02f);
            using (Pen shaft = new Pen(s.Tint(Theme.Hex(0xC59A6C), 0.3f), Math.Max(1.6f, u * 0.045f))) {
                shaft.StartCap = shaft.EndCap = LineCap.Round;
                g.DrawLine(shaft, bottom, top);
            }
            using (GraphicsPath blade = new GraphicsPath()) {
                blade.AddBezier(top, P(0.56f, -1.06f + drop), P(0.74f, -0.94f + drop), P(0.78f, -0.70f + drop));
                blade.AddBezier(P(0.78f, -0.70f + drop), P(0.66f, -0.86f + drop), P(0.54f, -0.92f + drop), P(0.39f, -0.92f + drop));
                blade.CloseFigure();
                Fill(g, blade, s.Tint(Theme.Hex(0xE6E4F2), 0.3f), s.Tint(Theme.Hex(0xA7A3C2), 0.3f));
            }
            float w = 0.018f * s.Sin(2.6, 1) * s.A;
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddBezier(P(-0.33f, -0.02f), P(-0.36f, -0.44f), P(-0.30f, -0.90f), P(0f, -0.90f));
                p.AddBezier(P(0f, -0.90f), P(0.30f, -0.90f), P(0.36f, -0.44f), P(0.33f, -0.02f));
                p.AddBezier(P(0.33f, -0.02f), P(0.16f, 0.015f + w), P(-0.16f, 0.015f - w), P(-0.33f, -0.02f));
                p.CloseFigure();
                Fill(g, p, cloak, cloakBot);
            }
            using (SolidBrush hood = new SolidBrush(Draw.Mix(cloakBot, Color.Black, 0.4f))) { PointF h = P(0, -0.60f); g.FillEllipse(hood, h.X - 0.21f * u, h.Y - 0.19f * u, 0.42f * u, 0.38f * u); }
            FillOval(g, P(0, -0.58f), 0.16f * u, 0.145f * u, bone, Draw.Mix(bone, cloakBot, 0.12f));
            Color ink = Theme.Hex(0x1B1722);
            float fx = s.Gx * 0.03f, fy = -s.Gy * 0.02f;
            if (s.Eyes == "open" || s.Eyes == "round") {
                using (SolidBrush eb = new SolidBrush(ink)) using (SolidBrush hl = new SolidBrush(Color.FromArgb(200, 255, 255, 255))) {
                    foreach (float ex in new float[] { -0.065f, 0.065f }) {
                        PointF e = P(ex + fx, -0.585f + fy); float ew = 0.075f * u, eh = 0.085f * u;
                        g.FillEllipse(eb, e.X - ew / 2, e.Y - eh / 2, ew, eh);
                        if (u >= 26) g.FillEllipse(hl, e.X - ew * 0.05f, e.Y - eh * 0.35f, ew * 0.35f, ew * 0.35f);
                    }
                }
            }
            else FlatFx.Eyes(g, P(-0.065f + fx, -0.585f + fy), P(0.065f + fx, -0.585f + fy), cx + fx * u, u, s.Eyes, ink, 0.95f);
            if (u >= 22) using (SolidBrush nb = new SolidBrush(ink)) { PointF n = P(fx, -0.515f + fy); g.FillEllipse(nb, n.X - u * 0.012f, n.Y - u * 0.01f, u * 0.024f, u * 0.018f); }
            FillOval(g, P(0.31f, -0.40f), 0.055f * u, 0.05f * u, bone, Draw.Mix(bone, cloakBot, 0.1f));   // лапка на древке
            Marks(g, P(-0.34f, -0.98f), u, Theme.Hex(0xFFC93D), s.Spark, 0.5f);
            g.Restore(st);
            Finish(g, s, mood, new PointF(cx - 0.62f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }

        // ---------------------------------------------------------------- Онигири
        // Рисовый треугольник со скруглёнными углами, снизу полоска нори; жмурится «^ ^», румянец, «ω».
        public static void Onigiri(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            float sq = 1f + (s.Working ? 0.03f * s.Sin(2.6, 1) : 0.018f * s.Sin(1.5, 1)) * s.A;   // мягко сплющивается целиком
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x / sq * u, by + y * sq * u); };
            Color rice = s.Tint(Theme.Hex(0xFBF9F5), 0.5f), riceBot = s.Tint(Theme.Hex(0xE6E1D8), 0.5f);
            SmoothingMode sm = Begin(g, s, P(0, -0.40f), Theme.Hex(0xEDE9DF), 0.40f);
            GraphicsState st = Rigid(g, cx, by, Tilt(s, 2.5f), Hop(s) * u);
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddBezier(P(-0.42f, -0.10f), P(-0.44f, -0.24f), P(-0.28f, -0.52f), P(-0.12f, -0.78f));
                p.AddBezier(P(-0.12f, -0.78f), P(-0.05f, -0.89f), P(0.05f, -0.89f), P(0.12f, -0.78f));
                p.AddBezier(P(0.12f, -0.78f), P(0.28f, -0.52f), P(0.44f, -0.24f), P(0.42f, -0.10f));
                p.AddBezier(P(0.42f, -0.10f), P(0.40f, -0.01f), P(-0.40f, -0.01f), P(-0.42f, -0.10f));
                p.CloseFigure();
                Fill(g, p, rice, riceBot);
                GraphicsState cs = g.Save();
                g.SetClip(p, CombineMode.Intersect);   // нори — по форме низа
                PointF n0 = P(-0.16f, -0.31f), n1 = P(0.16f, 0.02f);
                using (GraphicsPath n = Draw.Round(new RectangleF(n0.X, n0.Y, n1.X - n0.X, n1.Y - n0.Y), u * 0.03f))
                    Fill(g, n, Theme.Hex(0x2C3431), Theme.Hex(0x1A1F1D));
                g.Restore(cs);
            }
            if (u >= 30) using (Pen gp = new Pen(Color.FromArgb(70, 160, 150, 135), Math.Max(1f, u * 0.014f))) {
                gp.StartCap = gp.EndCap = LineCap.Round;
                g.DrawLine(gp, P(-0.06f, -0.71f), P(-0.03f, -0.68f));
                g.DrawLine(gp, P(0.11f, -0.62f), P(0.14f, -0.64f));
                g.DrawLine(gp, P(-0.20f, -0.40f), P(-0.17f, -0.42f));
            }
            Color ink = Theme.Hex(0x2A2A2E);
            float fx = s.Gx * 0.045f, fy = -s.Gy * 0.03f;
            FaceEyes(g, s, P(-0.13f + fx, -0.48f + fy), P(0.13f + fx, -0.48f + fy), u, ink, 0.95f, true);
            Blush(g, P(-0.24f + fx, -0.40f + fy), P(0.24f + fx, -0.40f + fy), u, Theme.Hex(0xF4A3AE), s.Sleep ? 40 : 110);
            FlatFx.Mouth(g, P(fx * 0.8f, -0.415f + fy * 0.8f), u * 0.85f, s.Mouth("cat"), ink);
            Marks(g, P(0.30f, -0.98f), u, Theme.Hex(0xFFC93D), Math.Max(s.Spark, s.Waiting ? 0.75f : 0f), -0.55f);
            g.Restore(st);
            Finish(g, s, mood, new PointF(cx + 0.64f * u, by - 0.96f * u));
            g.SmoothingMode = sm;
        }

        // ---------------------------------------------------------------- Котик в чашке
        // Чёрный котик сидит в кремовой чашке с месяцем: голова и ушки над краем, лапки на краю; пар между ушками.
        public static void CupCat(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + y * u); };
            Color fur = s.Tint(Theme.Hex(0x3B3547), 0.5f), furBot = s.Tint(Theme.Hex(0x231F2B), 0.5f), furIn = s.Tint(Theme.Hex(0x5A4F66), 0.4f);
            Color cup = s.Tint(Theme.Hex(0xF4EEE4), 0.35f), cupBot = s.Tint(Theme.Hex(0xD9CFC1), 0.35f);
            SmoothingMode sm = Begin(g, s, P(0, -0.40f), Theme.Hex(0xC8B9E8), 0.40f);
            const float rim = -0.48f;
            // Голова только чуть приподнимается: её низ всегда спрятан в чашке.
            float rise = s.Sleep ? 0f : s.Perm ? 0.04f + 0.02f * Math.Abs(s.Sin(4.2, 1)) * s.A : 0.02f * s.Aha + 0.008f * s.Sin(1.5, 1) * s.A;
            float hcy = rim - 0.13f - rise;
            GraphicsState hs = Rigid(g, cx, by + rim * u, Tilt(s, 3f), 0f);   // голова с ушками наклоняется вокруг края
            for (int side = -1; side <= 1; side += 2) {
                Spike(g, P(side * 0.05f, hcy - 0.10f), P(side * 0.22f, hcy - 0.33f), P(side * 0.26f, hcy - 0.02f), fur, u);
                if (u >= 22) Spike(g, P(side * 0.11f, hcy - 0.12f), P(side * 0.205f, hcy - 0.27f), P(side * 0.22f, hcy - 0.08f), furIn, u);
            }
            FillOval(g, P(0, hcy), 0.27f * u, 0.21f * u, fur, furBot);
            Color eyeInk = Theme.Hex(0xDAD2EC);
            float fx = s.Gx * 0.04f, fy = -s.Gy * 0.025f;
            string eyes = s.Eyes == "open" && !s.Working ? "closed" : s.Eyes;   // сонный котик: глаза прикрыты
            FlatFx.Eyes(g, P(-0.10f + fx, hcy + 0.01f + fy), P(0.10f + fx, hcy + 0.01f + fy), cx + fx * u, u, eyes, eyeInk, 0.95f);
            FlatFx.Mouth(g, P(fx, hcy + 0.09f + fy), u * 0.7f, s.Mouth("cat"), eyeInk);
            g.Restore(hs);
            if (!s.Sleep && !s.Err && !s.Stalled) Steam(g, P(0, hcy - 0.22f), u, t, s.A, s.Working ? 0.85f : 0.5f);
            using (Pen hp = new Pen(cupBot, Math.Max(2f, u * 0.055f))) g.DrawArc(hp, cx - 0.53f * u, by - 0.40f * u, 0.22f * u, 0.22f * u, 90, 180);
            using (GraphicsPath cp = new GraphicsPath()) {
                cp.AddLine(P(-0.41f, rim), P(0.41f, rim));
                cp.AddBezier(P(0.41f, rim), P(0.41f, -0.14f), P(0.25f, -0.02f), P(0.10f, -0.02f));
                cp.AddLine(P(0.10f, -0.02f), P(-0.10f, -0.02f));
                cp.AddBezier(P(-0.10f, -0.02f), P(-0.25f, -0.02f), P(-0.41f, -0.14f), P(-0.41f, rim));
                cp.CloseFigure();
                Fill(g, cp, cup, cupBot);
            }
            FillOval(g, P(-0.13f, rim + 0.005f), 0.07f * u, 0.042f * u, fur, furBot);
            FillOval(g, P(0.13f, rim + 0.005f), 0.07f * u, 0.042f * u, fur, furBot);
            if (u >= 20) using (GraphicsPath moon = new GraphicsPath()) {
                PointF m = P(0.02f, -0.25f); float mr = 0.07f * u;
                moon.AddEllipse(m.X - mr, m.Y - mr, mr * 2, mr * 2);
                using (Region reg = new Region(moon)) {
                    using (GraphicsPath cut = new GraphicsPath()) { cut.AddEllipse(m.X - mr * 0.45f, m.Y - mr * 1.15f, mr * 2, mr * 2); reg.Exclude(cut); }
                    using (SolidBrush mb = new SolidBrush(Theme.Hex(0x8C84A6))) g.FillRegion(mb, reg);
                }
            }
            float tw = 0.5f + 0.5f * (float)Math.Abs(Math.Sin(t * 1.7 + s.Ph)) * s.A;
            if (!s.Sleep && u >= 22) { Sparkle(g, P(-0.54f, -0.64f), u * 0.05f * tw, Theme.Hex(0xF2C57C)); Sparkle(g, P(0.52f, -0.30f), u * 0.035f * (1.4f - tw), Theme.Hex(0xF2C57C)); }
            Exclaim(g, P(0.36f, hcy - 0.46f), u, Theme.Hex(0xFFB340), s.Spark);
            Finish(g, s, mood, new PointF(cx + 0.64f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }

        // ---------------------------------------------------------------- Лисёнок
        // Рыжий, сидит, большие ушки с тёмными кончиками, белая мордочка; пушистый хвост с белым кончиком обнимает спереди.
        public static void Fox(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + y * u); };
            Color fur = s.Tint(Theme.Hex(0xEF8B4F), 0.5f), furBot = s.Tint(Theme.Hex(0xD76E34), 0.5f);
            Color cream = s.Tint(Theme.Hex(0xFBF2E8), 0.35f), dark = s.Tint(Theme.Hex(0x6B4A3F), 0.4f);
            SmoothingMode sm = Begin(g, s, P(0, -0.42f), Theme.Hex(0xF6B98E), 0.40f);
            GraphicsState st = Rigid(g, cx, by, Tilt(s, 3f), Hop(s) * u);
            FillOval(g, P(0.02f, -0.27f), 0.30f * u, 0.25f * u, fur, furBot);
            // Ушки: основание внутри головы; при ошибке — чуть разведены.
            float spread = s.Err ? 0.04f : 0f;
            for (int side = -1; side <= 1; side += 2) {
                PointF tip = P(side * (0.25f + spread), -1.00f + spread);
                Spike(g, P(side * 0.07f, -0.74f), tip, P(side * (0.27f + spread * 0.5f), -0.66f), fur, u);
                Spike(g, P(side * 0.205f, -0.86f + spread * 0.7f), tip, P(side * (0.25f + spread * 0.7f), -0.84f + spread * 0.7f), dark, u);
                if (u >= 22) Spike(g, P(side * 0.12f, -0.74f), P(side * (0.215f + spread), -0.88f + spread), P(side * 0.225f, -0.70f), cream, u);
            }
            FillOval(g, P(0, -0.60f), 0.29f * u, 0.23f * u, fur, Draw.Mix(fur, furBot, 0.5f));
            using (GraphicsPath muzzle = new GraphicsPath()) {
                muzzle.AddBezier(P(-0.26f, -0.56f), P(-0.20f, -0.44f), P(-0.08f, -0.40f), P(0f, -0.42f));
                muzzle.AddBezier(P(0f, -0.42f), P(0.08f, -0.40f), P(0.20f, -0.44f), P(0.26f, -0.56f));
                muzzle.AddBezier(P(0.26f, -0.56f), P(0.14f, -0.60f), P(0.06f, -0.56f), P(0f, -0.52f));
                muzzle.AddBezier(P(0f, -0.52f), P(-0.06f, -0.56f), P(-0.14f, -0.60f), P(-0.26f, -0.56f));
                muzzle.CloseFigure();
                using (SolidBrush cb = new SolidBrush(cream)) g.FillPath(cb, muzzle);
            }
            Color ink = Theme.Hex(0x3A2622);
            float fx = s.Gx * 0.04f, fy = -s.Gy * 0.03f;
            FaceEyes(g, s, P(-0.12f + fx, -0.62f + fy), P(0.12f + fx, -0.62f + fy), u, ink, 1.0f, true);
            if (u >= 18) { PointF n = P(fx * 0.7f, -0.525f); using (SolidBrush nb = new SolidBrush(ink)) g.FillEllipse(nb, n.X - u * 0.03f, n.Y - u * 0.02f, u * 0.06f, u * 0.042f); }
            FlatFx.Mouth(g, P(fx * 0.7f, -0.48f), u * 0.75f, s.Mouth("cat"), ink);
            // Хвост спереди: толстая дуга от бока к другому, белый кончик; виляет кончиком.
            float sw = (s.Working ? 0.03f : 0.015f) * s.Sin(2.0, 1) * s.A + 0.03f * s.Aha;
            using (GraphicsPath tail = new GraphicsPath()) {
                tail.AddBezier(P(0.30f, -0.30f), P(0.44f, -0.12f), P(0.30f, 0.00f), P(0.0f, -0.01f));
                tail.AddBezier(P(0.0f, -0.01f), P(-0.22f, -0.01f), P(-0.40f + sw, -0.04f), P(-0.44f + sw, -0.14f));
                tail.AddBezier(P(-0.44f + sw, -0.14f), P(-0.40f + sw, -0.22f), P(-0.24f, -0.20f), P(-0.04f, -0.17f));
                tail.AddBezier(P(-0.04f, -0.17f), P(0.14f, -0.15f), P(0.22f, -0.20f), P(0.30f, -0.30f));
                tail.CloseFigure();
                Fill(g, tail, fur, furBot);
                GraphicsState cs = g.Save();
                g.SetClip(tail, CombineMode.Intersect);
                using (SolidBrush cb = new SolidBrush(cream)) { PointF c = P(-0.46f + sw, -0.10f); g.FillEllipse(cb, c.X - 0.17f * u, c.Y - 0.14f * u, 0.30f * u, 0.28f * u); }
                g.Restore(cs);
            }
            Marks(g, P(0.30f, -1.02f), u, Theme.Hex(0xFFC93D), Math.Max(s.Spark, s.Waiting ? 0.7f : 0f), -0.55f);
            g.Restore(st);
            Finish(g, s, mood, new PointF(cx + 0.64f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }

        // ---------------------------------------------------------------- Шмалючька (leaf)
        // Зелёный семипалый листок курит самокрутку. Цикл ~6 с, у каждого сеанса свой сдвиг (seed):
        //   затяжка (0–1,3 с) — огонёк разгорается, самокрутка приподнимается, глаза зажмурены, щёки надуваются;
        //   задержка (1,3–1,9) — щёки круглые, лист чуть приподнимается от удовольствия;
        //   выдох (1,9–3,4) — ротик «о», изо рта плывут клубы дыма (через раз — колечко), лист откидывается назад;
        //   отдых (3,4–6) — блаженные «^ ^», лист покачивается, от огонька вьётся струйка, пепел растёт и в конце падает.
        // Работает — цикл быстрее и облачко «…»; ждёт решения — замирает с круглыми глазами, огонёк тлеет, «!»;
        // ошибка — кашляет: трясётся, дым вылетает рывками; остановился — курит медленно; спит — огонёк погас,
        // самокрутка опущена, «z».
        const float ShmalCycle = 6f;

        static float Smooth01(float x) { x = FlatFx.Clamp(x, 0, 1); return x * x * (3 - 2 * x); }

        // Мягкий клуб дыма: прозрачный по краям круг.
        static void SmokePuff(Graphics g, PointF c, float radius, int alpha, Color col) {
            if (radius < 1f || alpha <= 2) return;
            using (GraphicsPath gp = new GraphicsPath()) {
                gp.AddEllipse(c.X - radius, c.Y - radius, radius * 2, radius * 2);
                using (PathGradientBrush pg = new PathGradientBrush(gp)) {
                    pg.CenterColor = Color.FromArgb(Math.Min(255, alpha), col);
                    pg.SurroundColors = new Color[] { Color.FromArgb(0, col) };
                    pg.FocusScales = new PointF(0.45f, 0.45f);
                    g.FillPath(pg, gp);
                }
            }
        }

        public static void Leaf(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + y * u); };
            Color leaf = s.Tint(Theme.Hex(0x9CBB72), 0.5f), leafBot = s.Tint(Theme.Hex(0x7A9A54), 0.5f), vein = s.Tint(Theme.Hex(0x6C8A4A), 0.5f);
            Color smoke = Theme.Hex(0xECE8F2);

            // Фаза цикла курения.
            bool smoking = !s.Sleep && !s.Perm && !s.Err;
            float speed = s.Working ? 1.35f : s.Stalled ? 0.6f : 1f;
            double clock = t * speed + seed * 1.37;
            float c = animate ? (float)(((clock % ShmalCycle) + ShmalCycle) % ShmalCycle) : 4.5f;
            long cycleNo = animate ? (long)Math.Floor(clock / ShmalCycle) : 0;
            bool inhale = smoking && c < 1.3f, hold = smoking && c >= 1.3f && c < 1.9f, exhale = smoking && c >= 1.9f && c < 3.4f;
            float puff = !smoking ? 0f : c < 1.3f ? Smooth01(c / 1.3f) : c < 1.9f ? 1f : c < 2.4f ? 1f - Smooth01((c - 1.9f) / 0.5f) : 0f;   // щёки
            float glow = s.Sleep ? 0f : !smoking ? 0.45f + 0.1f * s.Sin(1.2, 1) * s.A
                : c < 1.3f ? 0.5f + 0.5f * Smooth01(c / 1.3f) : c < 2.4f ? 1f - 0.45f * Smooth01((c - 1.3f) / 1.1f) : 0.55f + 0.08f * s.Sin(3.1, 1) * s.A;
            float cough = s.Err ? (float)Math.Max(0, Math.Sin(t * 7.5)) * s.A : 0f;

            // Поза: покачивание в отдыхе, откидывается на выдохе, приподнимается на задержке, трясётся при кашле.
            float tilt = Tilt(s, 4f);
            if (smoking && animate) {
                if (exhale) tilt -= 4f * (float)Math.Sin(Math.PI * (c - 1.9f) / 1.5f);
                else if (c >= 3.4f) tilt += 3f * (float)Math.Sin((c - 3.4f) * 2.4f);
            }
            if (s.Err) tilt += 3.5f * (float)Math.Sin(t * 34) * cough;
            float lift = (Hop(s) + 0.012f * puff) * u;
            SmoothingMode sm = Begin(g, s, P(0, -0.45f), Theme.Hex(0xBFD79A), 0.34f);
            GraphicsState st = Rigid(g, cx, by, tilt, lift);

            // Лист.
            PointF root = P(0, -0.20f);
            using (Pen stem = new Pen(leafBot, Math.Max(1.6f, u * 0.045f))) { stem.StartCap = stem.EndCap = LineCap.Round; g.DrawLine(stem, P(0, -0.24f), P(0, -0.01f)); }
            float[] ang = { -84, -56, -29, 0, 29, 56, 84 };
            float[] len = { 0.34f, 0.50f, 0.64f, 0.78f, 0.64f, 0.50f, 0.34f };
            for (int i = 0; i < 7; i++) {
                // Кончики лепестков чуть «дышат» (основание у всех в одной точке — лист не рассыпается).
                float flutter = animate ? 2.5f * (float)Math.Sin(t * 1.7 + i * 0.9 + s.Ph) * (i == 3 ? 0.3f : 1f) : 0f;
                double a = (ang[i] + flutter - 90) * Math.PI / 180;
                float L = len[i] * u * (1f + 0.02f * puff), W = (i == 3 ? 0.12f : 0.10f) * u;
                float dx = (float)Math.Cos(a), dy = (float)Math.Sin(a), nx = -dy, ny = dx;
                PointF tip = new PointF(root.X + dx * L, root.Y + dy * L);
                PointF m1 = new PointF(root.X + dx * L * 0.42f + nx * W, root.Y + dy * L * 0.42f + ny * W);
                PointF m2 = new PointF(root.X + dx * L * 0.42f - nx * W, root.Y + dy * L * 0.42f - ny * W);
                using (GraphicsPath p = new GraphicsPath()) {
                    p.AddBezier(root, m1, new PointF(tip.X + nx * W * 0.35f, tip.Y + ny * W * 0.35f), tip);
                    p.AddBezier(tip, new PointF(tip.X - nx * W * 0.35f, tip.Y - ny * W * 0.35f), m2, root);
                    p.CloseFigure();
                    Fill(g, p, leaf, leafBot);
                }
                if (u >= 30 && i != 3) using (Pen vp = new Pen(Color.FromArgb(110, vein), Math.Max(1f, u * 0.012f))) g.DrawLine(vp, root, new PointF(root.X + dx * L * 0.8f, root.Y + dy * L * 0.8f));
            }

            // Мордочка: щёки надуваются на затяжке.
            float cheek = 1f + 0.13f * puff;
            FillOval(g, P(0, -0.50f), 0.17f * u * cheek, 0.15f * u * (1f + 0.04f * puff), leaf, Draw.Mix(leaf, leafBot, 0.35f));
            Color ink = Theme.Hex(0x2C3322);
            float fx = s.Gx * 0.035f, fy = -s.Gy * 0.025f;
            PointF eL = P(-0.075f + fx, -0.525f + fy), eR = P(0.075f + fx, -0.525f + fy);
            if (smoking && (inhale || hold)) FlatFx.Eyes(g, eL, eR, (eL.X + eR.X) / 2, u, "closed", ink, 0.85f);   // зажмурился
            else if (smoking) HappyArcs(g, eL, eR, u, ink, 0.8f);                                                   // блаженство
            else FlatFx.Eyes(g, eL, eR, (eL.X + eR.X) / 2, u, s.Eyes, ink, 0.8f);
            Blush(g, P(-0.125f * cheek, -0.455f), P(0.125f * cheek, -0.455f), u, Theme.Hex(0xF29AA0), s.Sleep ? 40 : (int)(110 + 60 * puff));
            PointF mouth = P(-0.012f + fx * 0.5f, -0.455f);
            string mk = exhale || cough > 0.3f ? "o" : inhale || hold ? "flat" : s.Mouth("smile");
            FlatFx.Mouth(g, mouth, u * 0.75f, mk, ink);

            // Самокрутка в уголке рта: на затяжке приподнимается, во сне повисает.
            float jangDeg = -12f - 8f * puff + (s.Sleep ? 22f : 0f) + (s.Err ? 6f * (float)Math.Sin(t * 30) * cough : 0f);
            double ja = jangDeg * Math.PI / 180;
            float jl = 0.27f * u;
            PointF j0 = P(0.03f + fx * 0.5f, -0.452f);
            PointF jd = new PointF((float)Math.Cos(ja), (float)Math.Sin(ja));
            Func<float, PointF> J = delegate (float k) { return new PointF(j0.X + jd.X * jl * k, j0.Y + jd.Y * jl * k); };
            float jw = Math.Max(1.6f, u * 0.042f);
            using (Pen paper = new Pen(Theme.Hex(0xF6F3EC), jw)) { paper.StartCap = paper.EndCap = LineCap.Round; g.DrawLine(paper, J(0.05f), J(0.92f)); }
            using (Pen filter = new Pen(Theme.Hex(0xD9B07A), jw)) { filter.StartCap = LineCap.Round; g.DrawLine(filter, J(0f), J(0.14f)); }
            // Пепел растёт за цикл и падает в конце отдыха.
            float ash = smoking ? 0.03f + 0.10f * Smooth01(c / 5.6f) : 0.06f;
            if (smoking && c > 5.65f) ash = 0.03f;
            using (Pen ap = new Pen(Theme.Hex(0x9A968F), jw)) { ap.StartCap = ap.EndCap = LineCap.Round; g.DrawLine(ap, J(0.92f), J(0.92f + ash)); }
            PointF ember = J(0.92f + ash + 0.02f);
            if (glow > 0.02f) {
                if (u >= 16) FlatFx.Glow(g, ember, u * (0.06f + 0.07f * glow), Theme.Hex(0xFF8A3D), (int)(60 + 150 * glow));
                float er = u * (0.020f + 0.010f * glow);
                using (SolidBrush eb = new SolidBrush(Color.FromArgb((int)(150 + 105 * glow), 0xF2, (int)(0x6A + 0x40 * glow), 0x2E))) g.FillEllipse(eb, ember.X - er, ember.Y - er, er * 2, er * 2);
            }
            Exclaim(g, P(-0.34f, -1.0f), u, Theme.Hex(0xFFB340), s.Spark);
            g.Restore(st);

            // Дальше — дым и пепел в пространстве экрана (поднимаются вверх, не наклоняются с листом).
            using (Matrix rm = new Matrix()) {
                rm.Translate(cx, by); rm.Rotate(tilt); rm.Translate(-cx, -by - lift);
                PointF[] pts = { mouth, ember };
                rm.TransformPoints(pts);
                PointF mw = pts[0], ew = pts[1];
                if (u >= 18 && animate) {
                    // Струйка от огонька: две тонкие волнистые нити, на затяжке почти пропадает (дым втягивается).
                    if (glow > 0.02f) {
                        float wa = (inhale ? 0.35f : 1f) * (s.Perm ? 0.7f : 1f);
                        for (int k = 0; k < 2; k++) {
                            using (Pen sp = new Pen(Color.FromArgb((int)(120 * wa), smoke), Math.Max(1.2f, u * (0.026f - 0.008f * k)))) {
                                sp.StartCap = sp.EndCap = LineCap.Round;
                                float ph = (float)(t * (1.3 + 0.4 * k) + s.Ph + k * 2.1);
                                float w1 = u * 0.06f * (float)Math.Sin(ph), w2 = u * 0.07f * (float)Math.Sin(ph * 1.3 + 1.1);
                                float h = u * (0.42f + 0.06f * k);
                                g.DrawBezier(sp, ew.X, ew.Y - u * 0.02f, ew.X + w1, ew.Y - h * 0.35f, ew.X - w2 + k * u * 0.03f, ew.Y - h * 0.7f, ew.X + w1 * 0.6f + k * u * 0.05f, ew.Y - h);
                            }
                        }
                    }
                    // Выдох: клубы дыма изо рта (и хвосты прошлого цикла), плывут вверх-влево, растут и тают.
                    if (smoking) {
                        for (int prev = 0; prev <= 1; prev++) {
                            for (int i = 0; i < 6; i++) {
                                float born = 1.95f + i * 0.24f;
                                float age = c - born + prev * ShmalCycle;
                                if (age < 0 || age > 2.8f) continue;
                                float life = age / 2.8f;
                                float drift = (i % 2 == 0 ? -1f : -0.6f);
                                PointF pc = new PointF(
                                    mw.X + u * (drift * 0.12f * age - 0.03f * i + 0.035f * (float)Math.Sin(age * 2.3 + i)),
                                    mw.Y - u * (0.06f + 0.20f * age + 0.02f * age * age));
                                float rad = u * (0.04f + 0.07f * (float)Math.Sqrt(age));
                                int al = (int)(215 * (1 - life) * Math.Min(1f, age / 0.12f));
                                SmokePuff(g, pc, rad, al, smoke);
                            }
                            // Через цикл — колечко: выплывает после клубов, растёт и поднимается.
                            if (((cycleNo - prev) & 1) == 0) {
                                float age = c - 2.95f + prev * ShmalCycle;
                                if (age >= 0 && age < 2.4f) {
                                    float life = age / 2.4f;
                                    float rr = u * (0.035f + 0.07f * Smooth01(age / 1.2f));
                                    PointF rc = new PointF(mw.X - u * (0.05f + 0.10f * age), mw.Y - u * (0.10f + 0.24f * age));
                                    using (Pen ring = new Pen(Color.FromArgb((int)(170 * (1 - life) * Math.Min(1f, age / 0.15f)), smoke), Math.Max(1.4f, u * 0.03f)))
                                        g.DrawEllipse(ring, rc.X - rr, rc.Y - rr * 0.62f, rr * 2, rr * 1.24f);
                                }
                            }
                        }
                        // Пепел падает с кончика в конце отдыха.
                        if (c > 5.65f) {
                            float fa = (c - 5.65f) / 0.35f;
                            float fy2 = u * (0.02f + 0.30f * fa * fa);
                            using (SolidBrush ab = new SolidBrush(Color.FromArgb((int)(200 * (1 - fa)), 0x9A, 0x96, 0x8F)))
                                g.FillEllipse(ab, ew.X - u * 0.04f - u * 0.015f, ew.Y + fy2 - u * 0.012f, u * 0.03f, u * 0.024f);
                        }
                    }
                    // Кашель: рывки дыма изо рта.
                    if (s.Err) {
                        float ca = (float)((t % 0.84) / 0.84);
                        for (int i = 0; i < 3; i++) {
                            float age = ca * 1.2f - i * 0.12f;
                            if (age <= 0) continue;
                            PointF pc = new PointF(mw.X - u * (0.08f + 0.25f * age) + i * u * 0.03f, mw.Y - u * (0.02f + 0.10f * age) + i * u * 0.02f);
                            SmokePuff(g, pc, u * (0.03f + 0.05f * age), (int)(140 * (1 - age / 1.2f)), smoke);
                        }
                    }
                }
                else if (u >= 18 && glow > 0.02f) {
                    // Неподвижный кадр (превью): одна спокойная струйка.
                    using (Pen sp = new Pen(Color.FromArgb(120, smoke), Math.Max(1.2f, u * 0.026f))) {
                        sp.StartCap = sp.EndCap = LineCap.Round;
                        g.DrawBezier(sp, ew.X, ew.Y - u * 0.02f, ew.X + u * 0.06f, ew.Y - u * 0.15f, ew.X - u * 0.05f, ew.Y - u * 0.28f, ew.X + u * 0.03f, ew.Y - u * 0.42f);
                    }
                }
            }
            Finish(g, s, mood, new PointF(cx - 0.64f * u, by - 0.98f * u));
            g.SmoothingMode = sm;
        }

        // ---------------------------------------------------------------- Пчёлка
        // Жёлто-коричневая полосатая пчёлка летит боком: крылышки машут (крепятся внутри спинки), усики, жало;
        // за ней пунктирный след с петлёй-сердечком.
        public static void Bee(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + y * u); };
            Color yel = s.Tint(Theme.Hex(0xF8D274), 0.5f), yelBot = s.Tint(Theme.Hex(0xE7B24A), 0.5f), brown = s.Tint(Theme.Hex(0x4B3428), 0.4f);
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush sh = new SolidBrush(Color.FromArgb(s.Sleep ? 50 : 65, 0, 0, 0))) g.FillEllipse(sh, cx - 0.30f * u, by - 0.03f * u, 0.60f * u, 0.06f * u);
            if (!s.Sleep && u >= 16) FlatFx.Glow(g, P(0, -0.42f), 0.6f * u, Theme.Hex(0xF9DD93), (int)((s.Perm ? 55 : 28) + 45 * s.Aha));
            float lift = s.Sleep ? 0.02f * u : (0.06f + (s.Working || s.Perm ? 0.03f : 0.018f) * s.Sin(s.Perm ? 4.2 : 2.0, 1) * s.A) * u;
            if ((s.Working || s.Aha > 0.05f) && u >= 22) using (Pen dp = new Pen(Color.FromArgb(190, 245, 240, 232), Math.Max(1.2f, u * 0.024f))) {
                dp.DashStyle = DashStyle.Dash; dp.DashOffset = animate ? -t * 4f : 0f;
                using (GraphicsPath hp = new GraphicsPath()) {
                    hp.AddBezier(P(0.40f, -0.44f - lift / u), P(0.54f, -0.44f - lift / u), P(0.56f, -0.62f), P(0.66f, -0.70f));
                    hp.AddBezier(P(0.66f, -0.70f), P(0.58f, -0.86f), P(0.45f, -0.80f), P(0.50f, -0.67f));
                    hp.AddBezier(P(0.50f, -0.67f), P(0.56f, -0.80f), P(0.74f, -0.80f), P(0.66f, -0.70f));
                    g.DrawPath(dp, hp);
                }
            }
            GraphicsState st = Rigid(g, cx, by, Tilt(s, 4f) - 4f, lift);
            float flap = s.Sleep ? 0.15f : (float)Math.Abs(Math.Sin(t * (s.Working ? 16 : 8) + s.Ph)) * s.A;
            using (SolidBrush wb = new SolidBrush(Color.FromArgb(215, 238, 240, 246)))
            using (Pen wp = new Pen(Color.FromArgb(120, 200, 205, 220), Math.Max(1f, u * 0.015f))) {
                for (int i = 0; i < 2; i++) {
                    PointF pivot = P(0.00f + i * 0.12f, -0.58f);   // внутри спинки — крыло не отрывается
                    GraphicsState ws = g.Save();
                    g.TranslateTransform(pivot.X, pivot.Y);
                    g.RotateTransform(-18f + i * 26f - 22f * flap);
                    RectangleF wr = new RectangleF(-0.095f * u, -0.30f * u, 0.19f * u, 0.32f * u);
                    g.FillEllipse(wb, wr); g.DrawEllipse(wp, wr);
                    g.Restore(ws);
                }
            }
            using (GraphicsPath sting = Poly(P(0.32f, -0.45f), P(0.46f, -0.41f), P(0.32f, -0.36f))) using (SolidBrush b = new SolidBrush(brown)) g.FillPath(b, sting);
            using (Pen ap = new Pen(brown, Math.Max(1.2f, u * 0.026f))) {
                ap.StartCap = ap.EndCap = LineCap.Round;
                float wob = 0.02f * s.Sin(3.0, 1) * s.A;
                g.DrawBezier(ap, P(-0.24f, -0.54f), P(-0.27f, -0.68f), P(-0.33f, -0.75f + wob), P(-0.38f, -0.76f + wob));
                g.DrawBezier(ap, P(-0.15f, -0.58f), P(-0.16f, -0.71f), P(-0.20f, -0.79f - wob), P(-0.24f, -0.81f - wob));
                using (SolidBrush ab = new SolidBrush(brown)) {
                    PointF a1 = P(-0.38f, -0.76f + wob), a2 = P(-0.24f, -0.81f - wob); float d = u * 0.035f;
                    g.FillEllipse(ab, a1.X - d / 2, a1.Y - d / 2, d, d); g.FillEllipse(ab, a2.X - d / 2, a2.Y - d / 2, d, d);
                }
            }
            using (GraphicsPath body = Oval(P(0, -0.40f), 0.36f * u, 0.26f * u)) {
                Fill(g, body, yel, yelBot);
                GraphicsState cs = g.Save();
                g.SetClip(body, CombineMode.Intersect);
                using (SolidBrush sb = new SolidBrush(brown)) {
                    foreach (float sx in new float[] { -0.02f, 0.13f, 0.28f }) {
                        using (GraphicsPath stripe = new GraphicsPath()) {
                            stripe.AddBezier(P(sx - 0.03f, -0.70f), P(sx + 0.03f, -0.50f), P(sx + 0.03f, -0.30f), P(sx - 0.03f, -0.10f));
                            stripe.AddLine(P(sx - 0.03f, -0.10f), P(sx + 0.06f, -0.10f));
                            stripe.AddBezier(P(sx + 0.06f, -0.10f), P(sx + 0.12f, -0.30f), P(sx + 0.12f, -0.50f), P(sx + 0.06f, -0.70f));
                            stripe.CloseFigure();
                            g.FillPath(sb, stripe);
                        }
                    }
                }
                g.Restore(cs);
            }
            Color ink = Theme.Hex(0x2E2018);
            float fx = s.Gx * 0.035f, fy = -s.Gy * 0.025f;
            FaceEyes(g, s, P(-0.25f + fx, -0.44f + fy), P(-0.10f + fx, -0.44f + fy), u, ink, 0.85f, true);
            Blush(g, P(-0.30f, -0.36f), P(-0.05f, -0.36f), u, Theme.Hex(0xF2A0A0), s.Sleep ? 40 : 100);
            FlatFx.Mouth(g, P(-0.175f + fx * 0.6f, -0.37f), u * 0.75f, s.Mouth("smile"), ink);
            Exclaim(g, P(-0.40f, -1.0f), u, Theme.Hex(0xFFB340), s.Spark);
            g.Restore(st);
            Finish(g, s, mood, new PointF(cx - 0.64f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }
    }
}
