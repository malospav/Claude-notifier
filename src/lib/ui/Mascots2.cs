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
    // Фирменные движения маскотов: у каждого своё (рык, глоток, прятки, танец…), раз в Period секунд на Dur секунд,
    // со сдвигом по сеансу (seed), чтобы несколько маскотов не двигались хором. Идут, когда маскот работает или ждёт
    // ответа; при запросе, ошибке, остановке и во сне — нет (там свои реакции).
    internal static class MascotSig {
        // Секунд с «тыка» по главному маскоту (ставит Mascot.PaintKind на время рисования); < 0 — не тыкали.
        // Пока идёт движение (Dur), At отдаёт его ход в любом состоянии — фирменный номер по требованию.
        [ThreadStatic] public static float Poke;
        public static float At(float t, int seed, float period, float dur, float salt, bool animate, string state) {
            if (animate && Poke > 0 && Poke < dur) return Poke / dur;
            if (!animate || string.IsNullOrEmpty(state)) return -1f;
            if (state != "working" && state != "waiting") return -1f;
            double c = ((t + seed * 2.37 + salt) % period + period) % period;
            return c < dur ? (float)(c / dur) : -1f;
        }
        // Колокол 0 → 1 → 0 по ходу движения (0 вне движения).
        public static float Bell(float p) { return p < 0 ? 0f : (float)Math.Sin(Math.PI * p); }
        // Плато: быстро нарастает, держится, быстро спадает (доля фронта — edge).
        public static float Plateau(float p, float edge) {
            if (p < 0) return 0f;
            float a = Smooth(p / edge), b = Smooth((1 - p) / edge);
            return Math.Min(a, b);
        }
        public static float Smooth(float x) { x = Math.Max(0f, Math.Min(1f, x)); return x * x * (3 - 2 * x); }
        // Доля отрезка [a, b] внутри хода p (0..1), сглаженная.
        public static float Span(float p, float a, float b) { return p < 0 ? 0f : Smooth((p - a) / (b - a)); }
        // Маленькое сердечко (после глотка, после петли).
        public static void Heart(Graphics g, PointF c, float s, Color col) {
            if (s < 1.5f) return;
            using (SolidBrush b = new SolidBrush(col)) {
                g.FillEllipse(b, c.X - s, c.Y - s * 0.8f, s, s);
                g.FillEllipse(b, c.X, c.Y - s * 0.8f, s, s);
                g.FillPolygon(b, new PointF[] { new PointF(c.X - s * 0.97f, c.Y - s * 0.12f), new PointF(c.X + s * 0.97f, c.Y - s * 0.12f), new PointF(c.X, c.Y + s * 0.95f) });
            }
        }
    }

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
            // Фирменное: «Рык» — подпрыгивает, гребень пробегает волной, хвост виляет, рот открыт, звуковые дуги.
            float roar = MascotSig.At(t, seed, 8f, 1.6f, 0.3f, animate, state);
            float rk = MascotSig.Plateau(roar, 0.2f);
            // Работает — топает: лапки по очереди, тело переваливается. Ждёт — с любопытством наклоняет голову к «?».
            float step = s.Working && animate && rk <= 0.05f ? (float)Math.Sin(t * 5.2 + s.Ph) : 0f;
            float stompL = Math.Max(0f, step), stompR = Math.Max(0f, -step);
            float curious = s.Waiting && animate ? 6f * MascotSig.Smooth((float)Math.Sin(t * 0.7 + s.Ph) * 1.6f) : 0f;
            SmoothingMode sm = Begin(g, s, P(0, -0.45f), Theme.Hex(0xC9B8F5), 0.36f);
            GraphicsState st = Rigid(g, cx, by, Tilt(s, 0f) - 5f * rk + 3.5f * step + curious,
                (Hop(s) + 0.05f * MascotSig.Bell(MascotSig.Span(roar, 0f, 0.35f)) + 0.012f * Math.Abs(step)) * u);   // прыжок в начале рыка
            // Хвост и гребень — за телом, основания спрятаны внутри силуэта.
            float wag = (s.Working ? 0.03f : 0.015f) * s.Sin(2.0, 1) * s.A + 0.05f * rk * (float)Math.Sin(t * 16);
            using (GraphicsPath tail = new GraphicsPath()) {
                tail.AddBezier(P(-0.10f, -0.30f), P(-0.30f, -0.26f), P(-0.42f - wag, -0.12f), P(-0.50f - wag, -0.04f));
                tail.AddBezier(P(-0.50f - wag, -0.04f), P(-0.36f, -0.02f), P(-0.20f, -0.04f), P(-0.06f, -0.10f));
                tail.CloseFigure();
                Fill(g, tail, body, bodyBot);
            }
            float[][] sp = {
                new float[] { 0.02f, -0.66f, 0.26f, 0.23f, 118 }, new float[] { 0.02f, -0.66f, 0.26f, 0.23f, 148 },
                new float[] { 0f, -0.30f, 0.30f, 0.28f, 140 }, new float[] { 0f, -0.30f, 0.30f, 0.28f, 168 }, new float[] { 0f, -0.30f, 0.30f, 0.28f, 196 } };
            for (int si = 0; si < sp.Length; si++) {
                float[] e = sp[si];
                double a = e[4] * Math.PI / 180;
                float dx = (float)Math.Cos(a), dy = -(float)Math.Sin(a);
                float ex = e[0] + e[2] * dx, ey = e[1] + e[3] * dy;
                float tx = -dy, ty = dx;
                // Волна по гребню во время рыка: шипы по очереди вытягиваются.
                float rip = roar < 0 ? 0f : (float)Math.Max(0, Math.Sin(Math.PI * (roar * 2.4f - si * 0.22f)));
                float sl = 0.10f + 0.06f * rip;
                Spike(g, P(ex - dx * 0.04f + tx * 0.055f, ey - dy * 0.04f + ty * 0.055f), P(ex + dx * sl, ey + dy * sl),
                    P(ex - dx * 0.04f - tx * 0.055f, ey - dy * 0.04f - ty * 0.055f), spike, u);
            }
            FillOval(g, P(0, -0.30f), 0.30f * u, 0.28f * u, body, bodyBot);
            FillOval(g, P(0.02f, -0.66f), 0.26f * u, 0.23f * u, body, Draw.Mix(body, bodyBot, 0.45f));
            FillOval(g, P(0.06f, -0.27f), 0.18f * u, 0.19f * u, belly, Draw.Mix(belly, bodyBot, 0.15f));
            FillOval(g, P(0.22f, -0.40f), 0.06f * u, 0.08f * u, body, bodyBot);
            FillOval(g, P(-0.12f, -0.04f - 0.09f * stompL), 0.10f * u, 0.05f * u, body, bodyBot);
            FillOval(g, P(0.16f, -0.04f - 0.09f * stompR), 0.10f * u, 0.05f * u, body, bodyBot);
            Color ink = Theme.Hex(0x2E2640);
            float fx = s.Gx * 0.05f, fy = -s.Gy * 0.035f;
            if (rk > 0.3f) FlatFx.Eyes(g, P(-0.05f + fx, -0.68f + fy), P(0.12f + fx, -0.68f + fy), cx + (0.035f + fx) * u, u, "happy", ink, 0.9f);
            else FaceEyes(g, s, P(-0.05f + fx, -0.68f + fy), P(0.12f + fx, -0.68f + fy), u, ink, 0.9f, false);
            Blush(g, P(-0.11f + fx, -0.59f + fy), P(0.19f + fx, -0.59f + fy), u, Theme.Hex(0xF2A6C4), s.Sleep ? 30 : (int)(85 + 60 * rk));
            if (rk > 0.3f) {
                FlatFx.Mouth(g, P(0.035f + fx * 0.8f, -0.585f + fy * 0.8f), u * (0.9f + 0.6f * rk), "o", ink);
                // Звуковые дуги: расходятся от рта.
                if (u >= 20) for (int i = 0; i < 3; i++) {
                    float k = (float)((roar * 3 + i / 3.0) % 1.0);
                    PointF m = P(0.24f + 0.16f * k, -0.60f);
                    float rr = u * (0.05f + 0.08f * k);
                    using (Pen rp = new Pen(Color.FromArgb((int)(200 * rk * (1 - k)), 0xEE, 0xEA, 0xF8), Math.Max(1.2f, u * 0.028f))) {
                        rp.StartCap = rp.EndCap = LineCap.Round;
                        g.DrawArc(rp, m.X - rr, m.Y - rr, rr * 2, rr * 2, -40, 80);
                    }
                }
            }
            else FlatFx.Mouth(g, P(0.035f + fx * 0.8f, -0.585f + fy * 0.8f), u * 0.8f, s.Mouth("smile"), ink);
            float q = s.Aha > 0.05f || rk > 0.05f ? 0f : s.Perm ? s.Spark : s.Waiting ? 0.9f : 0f;
            Question(g, P(0.30f, -1.0f), u, Theme.Hex(0xEEEAF8), q);
            Exclaim(g, P(0.32f, -1.08f), u, Theme.Hex(0xFFB340), s.Aha);
            g.Restore(st);
            // Пыль из-под лапки, когда она опускается.
            if (s.Working && animate && u >= 22) {
                float ph = (float)(((t * 5.2 + s.Ph) / (2 * Math.PI)) % 1.0);
                for (int side = 0; side < 2; side++) {
                    float k = (float)((ph + side * 0.5 + 1.0) % 1.0);   // 0 — лапка опустилась
                    if (k > 0.45f) continue;
                    float fx2 = side == 0 ? -0.12f : 0.16f;
                    for (int i = -1; i <= 1; i += 2)
                        SmokePuff(g, new PointF(cx + (fx2 + i * (0.06f + 0.12f * k)) * u, by - (0.02f + 0.04f * k) * u), u * (0.025f + 0.03f * k), (int)(120 * (1 - k / 0.45f)), Theme.Hex(0xD8D0EC));
                }
            }
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
            // Фирменное: «Глоток» — кружка ко рту, глаза зажмурены, пар пропадает; после — сердечко над головой.
            float sip = MascotSig.At(t, seed, 7f, 2.4f, 1.1f, animate, state);
            float mk = MascotSig.Plateau(sip < 0 ? -1f : Math.Min(1f, sip / 0.75f), 0.3f);   // кружка у рта первые 3/4 хода
            SmoothingMode sm = Begin(g, s, P(0, -0.40f), Theme.Hex(0xBDE8B0), 0.44f);
            GraphicsState st = Rigid(g, cx, by, Tilt(s, 2.5f), Hop(s) * u);
            FillOval(g, P(-0.21f, -0.58f), 0.13f * u, 0.12f * u, skin, Draw.Mix(skin, skinBot, 0.3f));
            FillOval(g, P(0.21f, -0.58f), 0.13f * u, 0.12f * u, skin, Draw.Mix(skin, skinBot, 0.3f));
            FillOval(g, P(0, -0.31f), 0.44f * u, 0.31f * u, skin, skinBot);
            Color ink = Theme.Hex(0x23301F);
            float fx = s.Gx * 0.035f, fy = -s.Gy * 0.025f;
            if (mk > 0.4f) FlatFx.Eyes(g, P(-0.21f + fx, -0.59f + fy), P(0.21f + fx, -0.59f + fy), cx + fx * u, u, "closed", ink, 0.85f);
            else FaceEyes(g, s, P(-0.21f + fx, -0.59f + fy), P(0.21f + fx, -0.59f + fy), u, ink, 0.85f, false);
            Blush(g, P(-0.29f, -0.45f), P(0.29f, -0.45f), u, Theme.Hex(0xF29AA8), s.Sleep ? 40 : (int)(110 + 80 * MascotSig.Span(sip, 0.6f, 0.8f) * (1 - MascotSig.Span(sip, 0.85f, 1f))));
            // Ждёт — квакает: под ртом дважды раздувается горловой мешок.
            float croak = s.Waiting && animate && mk <= 0.05f ? (float)(((t + s.Ph) % 4.0) / 4.0) : -1f;
            if (croak >= 0 && croak < 0.35f && u >= 18) {
                float ck = (float)Math.Abs(Math.Sin(croak / 0.35f * Math.PI * 2));
                using (SolidBrush sb = new SolidBrush(Color.FromArgb(220, Draw.Mix(skin, Color.White, 0.55f)))) {
                    PointF c0 = P(0, -0.40f); float rx = (0.06f + 0.07f * ck) * u, ry = (0.04f + 0.05f * ck) * u;
                    g.FillEllipse(sb, c0.X - rx, c0.Y - ry * 0.6f, rx * 2, ry * 2);
                }
            }
            FlatFx.Mouth(g, P(fx * 0.6f, -0.47f), u * 0.75f, s.Mouth("smile"), ink);
            Color mug = s.Tint(Theme.Hex(0xFAF8F4), 0.3f), mugBot = s.Tint(Theme.Hex(0xDFDAD2), 0.3f);
            float my = -0.11f * mk;   // кружка поднимается ко рту
            PointF m0 = P(-0.15f, -0.40f + my), m1 = P(0.15f, -0.08f + my);
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
            FillOval(g, P(-0.15f, -0.22f + my), 0.065f * u, 0.075f * u, skin, skinBot);
            FillOval(g, P(0.13f, -0.22f + my), 0.065f * u, 0.075f * u, skin, skinBot);
            Exclaim(g, P(0.42f, -0.98f), u, Theme.Hex(0xFFB340), s.Spark);
            g.Restore(st);
            Steam(g, new PointF(cx, by - 0.76f * u - Hop(s) * u), u, t, s.A, (s.Sleep || s.Err || s.Stalled ? 0f : s.Working ? 1f : 0.65f) * (1f - mk));
            // Работает — охотится: муха кружит рядом, раз в 2,6 с язык выстреливает и ловит её, потом прилетает новая.
            if (s.Working && animate && u >= 18 && mk <= 0.05f) {
                float hc = (float)(((t + s.Ph) % 2.6) / 2.6);
                PointF mouthW = new PointF(cx + 0.0f * u, by - 0.47f * u - Hop(s) * u);
                float fa = (float)(t * 5.5 + s.Ph);
                PointF fly = new PointF(cx + (0.42f + 0.10f * (float)Math.Cos(fa)) * u, by - (0.78f + 0.08f * (float)Math.Sin(fa * 1.7)) * u);
                bool caught = hc > 0.80f;
                float tongue = hc < 0.72f || hc > 0.92f ? 0f : (float)Math.Sin((hc - 0.72f) / 0.20f * Math.PI);
                if (tongue > 0.01f) {
                    PointF tip = new PointF(mouthW.X + (fly.X - mouthW.X) * tongue, mouthW.Y + (fly.Y - mouthW.Y) * tongue);
                    using (Pen tp = new Pen(Theme.Hex(0xEE8FA2), Math.Max(1.4f, u * 0.035f))) { tp.StartCap = tp.EndCap = LineCap.Round; g.DrawLine(tp, mouthW, tip); }
                    using (SolidBrush tb = new SolidBrush(Theme.Hex(0xEE8FA2))) g.FillEllipse(tb, tip.X - u * 0.025f, tip.Y - u * 0.025f, u * 0.05f, u * 0.05f);
                }
                if (!caught && hc < 0.78f) {
                    float appear = MascotSig.Smooth(hc / 0.12f);
                    using (SolidBrush fb = new SolidBrush(Color.FromArgb((int)(230 * appear), 0x3A, 0x36, 0x40)))
                        g.FillEllipse(fb, fly.X - u * 0.022f, fly.Y - u * 0.018f, u * 0.044f, u * 0.036f);
                    float wf = (float)Math.Abs(Math.Sin(t * 40)) * u * 0.03f;
                    using (SolidBrush wb = new SolidBrush(Color.FromArgb((int)(160 * appear), 230, 236, 246))) {
                        g.FillEllipse(wb, fly.X - u * 0.03f, fly.Y - u * 0.02f - wf, u * 0.03f, u * 0.025f);
                        g.FillEllipse(wb, fly.X, fly.Y - u * 0.02f - wf, u * 0.03f, u * 0.025f);
                    }
                }
            }
            // После глотка — сердечко всплывает и тает.
            if (sip > 0.62f && u >= 18) {
                float k = (sip - 0.62f) / 0.38f;
                MascotSig.Heart(g, new PointF(cx + 0.30f * u, by - (0.80f + 0.25f * k) * u), u * (0.05f + 0.02f * k), Color.FromArgb((int)(230 * (1 - k * k)), 0xF4, 0x8F, 0xA8));
            }
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
            // Фирменное: «Взмах» — коса описывает дугу вокруг лапки, за лезвием светится след.
            float swing = MascotSig.At(t, seed, 9f, 1.5f, 2.0f, animate, state);
            float swDeg = swing < 0 ? 0f : -75f * (float)Math.Sin(Math.PI * MascotSig.Smooth(swing));
            // Ждёт — коса мерно покачивается, как маятник.
            if (s.Waiting && animate && swing < 0) swDeg = 4f * (float)Math.Sin(t * 1.1 + s.Ph);
            GraphicsState st = Rigid(g, cx, by, Tilt(s, 2f), lift);
            float drop = s.Err ? 0.10f : 0f;   // ошибка — коса чуть опущена
            PointF hand = P(0.31f, -0.40f);
            GraphicsState ss = g.Save();
            g.TranslateTransform(hand.X, hand.Y); g.RotateTransform(swDeg); g.TranslateTransform(-hand.X, -hand.Y);
            PointF top = P(0.40f, -1.00f + drop), bottom = P(0.27f, -0.02f);
            if (swing >= 0 && u >= 20) {
                // След лезвия: дуги от прежних положений кончика.
                PointF tipLocal = P(0.78f, -0.70f + drop);
                for (int i = 1; i <= 4; i++) {
                    float back = 14f * i * (swing < 0.5f ? -1f : 1f);
                    GraphicsState ts = g.Save();
                    g.TranslateTransform(hand.X, hand.Y); g.RotateTransform(back); g.TranslateTransform(-hand.X, -hand.Y);
                    using (SolidBrush tb = new SolidBrush(Color.FromArgb((int)(120 * MascotSig.Bell(swing) / i), 0xC8, 0xC2, 0xF2)))
                        g.FillEllipse(tb, tipLocal.X - u * 0.05f, tipLocal.Y - u * 0.05f, u * 0.10f, u * 0.10f);
                    g.Restore(ts);
                }
            }
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
            g.Restore(ss);
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
            FillOval(g, hand, 0.055f * u, 0.05f * u, bone, Draw.Mix(bone, cloakBot, 0.1f));   // лапка на древке
            Marks(g, P(-0.34f, -0.98f), u, Theme.Hex(0xFFC93D), s.Spark, 0.5f);
            g.Restore(st);
            // Души: работает — три голубых огонька кружат вокруг; ждёт — одна неспешно плавает рядом.
            int souls = s.Working ? 3 : s.Waiting ? 1 : 0;
            if (animate && u >= 16) for (int i = 0; i < souls; i++) {
                float a = (float)(t * (s.Working ? 1.6 : 0.6) + s.Ph + i * 2 * Math.PI / Math.Max(1, souls));
                float bob = 0.04f * (float)Math.Sin(t * 2.2 + i);
                PointF sc = new PointF(cx + (float)Math.Cos(a) * 0.52f * u, by - (0.55f + 0.20f * (float)Math.Sin(a) + bob) * u);
                bool behind = Math.Sin(a) < -0.2 && s.Working;
                int al = behind ? 90 : 200;
                // Хвостик — вдоль движения.
                float tx = (float)Math.Sin(a) * 0.08f * u, ty = -(float)Math.Cos(a) * 0.04f * u;
                using (SolidBrush tb = new SolidBrush(Color.FromArgb(al / 2, 0x9E, 0xD8, 0xFF))) { g.FillEllipse(tb, sc.X + tx - u * 0.03f, sc.Y + ty - u * 0.03f, u * 0.06f, u * 0.06f); g.FillEllipse(tb, sc.X + tx * 2 - u * 0.018f, sc.Y + ty * 2 - u * 0.018f, u * 0.036f, u * 0.036f); }
                FlatFx.Glow(g, sc, u * 0.12f, Theme.Hex(0x9ED8FF), al * 3 / 4);
                using (SolidBrush sb = new SolidBrush(Color.FromArgb(al, 0xD6, 0xF0, 0xFF))) g.FillEllipse(sb, sc.X - u * 0.045f, sc.Y - u * 0.05f, u * 0.09f, u * 0.10f);
                if (u >= 30) using (SolidBrush eb = new SolidBrush(Color.FromArgb(al, 0x2A, 0x3A, 0x55))) {
                    g.FillEllipse(eb, sc.X - u * 0.022f, sc.Y - u * 0.014f, u * 0.013f, u * 0.018f);
                    g.FillEllipse(eb, sc.X + u * 0.009f, sc.Y - u * 0.014f, u * 0.013f, u * 0.018f);
                }
            }
            Finish(g, s, mood, new PointF(cx - 0.62f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }

        // ---------------------------------------------------------------- Онигири
        // Рисовый треугольник со скруглёнными углами, снизу полоска нори; жмурится «^ ^», румянец, «ω».
        public static void Onigiri(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            // Фирменное: «Прыжок» — присел, взлетел вытянувшись, приземлился сплющившись; рисинки разлетаются.
            float jump = MascotSig.At(t, seed, 7f, 1.3f, 0.7f, animate, state);
            float air = jump < 0 ? 0f : MascotSig.Bell(FlatFx.Clamp((jump - 0.2f) / 0.5f, 0, 1));
            float squat = jump < 0 ? 0f : jump < 0.2f ? MascotSig.Bell(jump / 0.2f) : jump > 0.7f && jump < 0.9f ? MascotSig.Bell((jump - 0.7f) / 0.2f) : 0f;
            // Работает — пружинит в ритм; ждёт — качается, как метроном.
            float beat = s.Working && animate ? (float)Math.Abs(Math.Sin(t * 4.0 + s.Ph)) : 0f;
            float sq = 1f + (s.Working ? 0.05f * beat - 0.02f : 0.018f * s.Sin(1.5, 1)) * s.A - 0.10f * squat + 0.08f * air;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x / sq * u, by + y * sq * u); };
            Color rice = s.Tint(Theme.Hex(0xFBF9F5), 0.5f), riceBot = s.Tint(Theme.Hex(0xE6E1D8), 0.5f);
            SmoothingMode sm = Begin(g, s, P(0, -0.40f), Theme.Hex(0xEDE9DF), 0.40f);
            float metro = s.Waiting && animate && jump < 0 ? 6f * (float)Math.Sin(t * 1.4 + s.Ph) : 0f;
            GraphicsState st = Rigid(g, cx, by, Tilt(s, 0f) + metro, (Hop(s) + 0.22f * air + 0.015f * beat) * u);
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
            if (air > 0.2f) FlatFx.Eyes(g, P(-0.13f + fx, -0.48f + fy), P(0.13f + fx, -0.48f + fy), cx + fx * u, u, "happy", ink, 0.95f);
            else if (s.Waiting && animate && ((t + s.Ph) % 5.0) < 0.45) {
                // Подмигивает: левый глаз «^», правый открыт.
                HappyArcs(g, P(-0.13f + fx, -0.48f + fy), P(-0.13f + fx, -0.48f + fy), u, ink, 0.95f);
                FlatFx.Eyes(g, P(0.13f + fx, -0.48f + fy), P(0.13f + fx, -0.48f + fy), cx - u, u, "open", ink, 0.95f);
            }
            else FaceEyes(g, s, P(-0.13f + fx, -0.48f + fy), P(0.13f + fx, -0.48f + fy), u, ink, 0.95f, true);
            Blush(g, P(-0.24f + fx, -0.40f + fy), P(0.24f + fx, -0.40f + fy), u, Theme.Hex(0xF4A3AE), s.Sleep ? 40 : (int)(110 + 70 * air));
            FlatFx.Mouth(g, P(fx * 0.8f, -0.415f + fy * 0.8f), u * 0.85f, air > 0.2f ? "o" : s.Mouth("cat"), ink);
            // Работает — по рису вспыхивают искорки.
            if (s.Working && animate && u >= 22) for (int i = 0; i < 3; i++) {
                float k = (float)(((t * 0.9 + i * 0.37 + s.Ph) % 1.0));
                float[] xs = { -0.22f, 0.18f, -0.02f }, ys = { -0.45f, -0.52f, -0.70f };
                Sparkle(g, P(xs[i], ys[i]), u * 0.07f * MascotSig.Bell(k), Color.FromArgb(240, 0xFF, 0xD7, 0x5E));
            }
            Marks(g, P(0.30f, -0.98f), u, Theme.Hex(0xFFC93D), Math.Max(s.Spark, s.Waiting && jump < 0 ? 0.75f : 0f), -0.55f);
            g.Restore(st);
            // Рисинки разлетаются в прыжке и падают.
            if (jump > 0.2f && u >= 20) {
                float k = (jump - 0.2f) / 0.8f;
                for (int i = 0; i < 5; i++) {
                    float dir = (i - 2) * 0.16f;
                    float x = cx + (dir + dir * 1.6f * k) * u;
                    float y = by - (0.80f + 0.30f * k - 0.9f * k * k) * u - (i % 2) * 0.05f * u;
                    using (SolidBrush rb = new SolidBrush(Color.FromArgb((int)(230 * (1 - k)), 0xFB, 0xF9, 0xF5)))
                        g.FillEllipse(rb, x - u * 0.018f, y - u * 0.011f, u * 0.036f, u * 0.022f);
                }
            }
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
            // Фирменное: «Зевок» — потягивается вверх, ушки назад, глаза зажмурены, ротик широко открыт.
            float yawn = MascotSig.At(t, seed, 8f, 2.0f, 1.7f, animate, state);
            float yk = MascotSig.Plateau(yawn, 0.3f);
            // Ждёт — клюёт носом: голова медленно опускается и вздрагивает обратно.
            float doze = 0f;
            if (s.Waiting && animate && yawn < 0) {
                float dc = (float)(((t * 0.5 + s.Ph) % 1.0));
                doze = dc < 0.85f ? 0.045f * MascotSig.Smooth(dc / 0.85f) : 0.045f * (1 - MascotSig.Smooth((dc - 0.85f) / 0.15f));
            }
            // Голова только чуть приподнимается: её низ всегда спрятан в чашке.
            float rise = s.Sleep ? 0f : s.Perm ? 0.04f + 0.02f * Math.Abs(s.Sin(4.2, 1)) * s.A : 0.02f * s.Aha + 0.008f * s.Sin(1.5, 1) * s.A;
            rise += 0.035f * yk - doze;
            float hcy = rim - 0.13f - rise;
            // Кончик хвоста выглядывает из-за чашки справа и покачивается (основание спрятано за чашкой).
            if (!s.Sleep) {
                float tsw = 0.06f * (float)Math.Sin(t * (s.Working ? 2.4 : 1.2) + s.Ph) * s.A;
                using (Pen tp = new Pen(fur, Math.Max(2f, u * 0.06f))) {
                    tp.StartCap = tp.EndCap = LineCap.Round;
                    g.DrawBezier(tp, P(0.30f, rim + 0.10f), P(0.44f, rim - 0.02f), P(0.48f + tsw, rim - 0.16f), P(0.40f + tsw * 1.5f, rim - 0.26f));
                }
            }
            float earBack = 0.07f * yk;
            GraphicsState hs = Rigid(g, cx, by + rim * u, Tilt(s, 3f), 0f);   // голова с ушками наклоняется вокруг края
            for (int side = -1; side <= 1; side += 2) {
                Spike(g, P(side * 0.05f, hcy - 0.10f), P(side * (0.22f + earBack), hcy - 0.33f + earBack), P(side * 0.26f, hcy - 0.02f), fur, u);
                if (u >= 22) Spike(g, P(side * 0.11f, hcy - 0.12f), P(side * (0.205f + earBack), hcy - 0.27f + earBack), P(side * 0.22f, hcy - 0.08f), furIn, u);
            }
            FillOval(g, P(0, hcy), 0.27f * u, 0.21f * u, fur, furBot);
            Color eyeInk = Theme.Hex(0xDAD2EC);
            float fx = s.Gx * 0.04f, fy = -s.Gy * 0.025f;
            string eyes = s.Eyes == "open" && !s.Working ? "closed" : s.Eyes;   // сонный котик: глаза прикрыты
            if (yk > 0.3f) eyes = "squint";
            FlatFx.Eyes(g, P(-0.10f + fx, hcy + 0.01f + fy), P(0.10f + fx, hcy + 0.01f + fy), cx + fx * u, u, eyes, eyeInk, 0.95f);
            if (yk > 0.3f) {
                using (SolidBrush mb = new SolidBrush(Theme.Hex(0xE58FA8))) { PointF m = P(fx, hcy + 0.10f); float mw = u * 0.06f * yk, mh = u * 0.075f * yk; g.FillEllipse(mb, m.X - mw / 2, m.Y - mh / 2, mw, mh); }
            }
            else FlatFx.Mouth(g, P(fx, hcy + 0.09f + fy), u * 0.7f, s.Mouth("cat"), eyeInk);
            g.Restore(hs);
            if (!s.Sleep && !s.Err && !s.Stalled) Steam(g, P(0, hcy - 0.22f), u, t, s.A, (s.Working ? 0.85f : 0.5f) * (1 - yk));
            // Работает — мешает чай: ложечка ходит по кругу у края.
            if (s.Working && animate) {
                float sa = (float)(t * 3.2 + s.Ph);
                PointF sTop = P(0.37f + 0.05f * (float)Math.Cos(sa), rim - 0.20f + 0.02f * (float)Math.Sin(sa));
                PointF sIn = P(0.27f + 0.04f * (float)Math.Cos(sa), rim + 0.06f);
                using (Pen spn = new Pen(Theme.Hex(0xC9CCD6), Math.Max(1.4f, u * 0.035f))) { spn.StartCap = spn.EndCap = LineCap.Round; g.DrawLine(spn, sIn, sTop); }
            }
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
            // Фирменное: «Мышкование» — присел, прыгнул вверх и нырнул носом вниз, приземлился.
            float pounce = MascotSig.At(t, seed, 7f, 1.4f, 0.9f, animate, state);
            float crouch = pounce < 0 ? 0f : pounce < 0.25f ? MascotSig.Bell(pounce / 0.25f) : 0f;
            float leap = pounce < 0 ? 0f : MascotSig.Bell(FlatFx.Clamp((pounce - 0.2f) / 0.6f, 0, 1));
            float dive = pounce < 0 ? 0f : MascotSig.Span(pounce, 0.35f, 0.7f) * (1 - MascotSig.Span(pounce, 0.75f, 0.95f));
            // Работает — следит за бабочкой (глаза и голова за ней).
            PointF bfly = PointF.Empty; bool hasFly = s.Working && animate && pounce < 0;
            if (hasFly) {
                float ba = (float)(t * 0.9 + s.Ph);
                bfly = new PointF(cx + 0.55f * (float)Math.Sin(ba) * u, by - (0.95f + 0.12f * (float)Math.Sin(ba * 2.3)) * u);
            }
            float look = hasFly ? FlatFx.Clamp((bfly.X - cx) / (0.55f * u), -1, 1) : 0f;
            SmoothingMode sm = Begin(g, s, P(0, -0.42f), Theme.Hex(0xF6B98E), 0.40f);
            GraphicsState st = Rigid(g, cx, by, Tilt(s, 0f) + 5f * look + 22f * dive, (Hop(s) + 0.20f * leap - 0.02f * crouch) * u);
            FillOval(g, P(0.02f, -0.27f + 0.03f * crouch), 0.30f * u * (1 + 0.06f * crouch), 0.25f * u * (1 - 0.1f * crouch), fur, furBot);
            // Ушки: основание внутри головы; при ошибке — чуть разведены; в ожидании правое изредка дёргается.
            float spread = s.Err ? 0.04f : 0f;
            float flick = s.Waiting && animate && ((t + s.Ph) % 4.6) < 0.18 ? 0.05f : 0f;
            for (int side = -1; side <= 1; side += 2) {
                PointF tip = P(side * (0.25f + spread + (side > 0 ? flick : 0f)), -1.00f + spread + (side > 0 ? flick * 0.6f : 0f));
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
            float fx = s.Gx * 0.04f + 0.05f * look, fy = -s.Gy * 0.03f - (hasFly ? 0.03f : 0f);
            if (leap > 0.2f) FlatFx.Eyes(g, P(-0.12f + fx, -0.62f + fy), P(0.12f + fx, -0.62f + fy), cx + fx * u, u, "happy", ink, 1.0f);
            else if (hasFly) FlatFx.Eyes(g, P(-0.12f + fx, -0.62f + fy), P(0.12f + fx, -0.62f + fy), cx + fx * u, u, s.Eyes, ink, 1.0f);
            else FaceEyes(g, s, P(-0.12f + fx, -0.62f + fy), P(0.12f + fx, -0.62f + fy), u, ink, 1.0f, true);
            if (u >= 18) { PointF n = P(fx * 0.7f, -0.525f); using (SolidBrush nb = new SolidBrush(ink)) g.FillEllipse(nb, n.X - u * 0.03f, n.Y - u * 0.02f, u * 0.06f, u * 0.042f); }
            FlatFx.Mouth(g, P(fx * 0.7f, -0.48f), u * 0.75f, leap > 0.2f ? "o" : s.Mouth("cat"), ink);
            // Хвост спереди: толстая дуга от бока к другому, белый кончик; виляет кончиком.
            // Ждёт — хвост мерно метёт: поворачивается вокруг основания у бока.
            float sw = (s.Working ? 0.03f : 0.015f) * s.Sin(2.0, 1) * s.A + 0.03f * s.Aha;
            float sweep = s.Waiting && animate ? 9f * (float)Math.Sin(t * 1.3 + s.Ph) : 0f;
            PointF troot = P(0.30f, -0.30f);
            GraphicsState tsx = g.Save();
            g.TranslateTransform(troot.X, troot.Y); g.RotateTransform(sweep + 10f * leap); g.TranslateTransform(-troot.X, -troot.Y);
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
            g.Restore(tsx);
            Marks(g, P(0.30f, -1.02f), u, Theme.Hex(0xFFC93D), Math.Max(s.Spark, s.Waiting && pounce < 0 ? 0.7f : 0f), -0.55f);
            g.Restore(st);
            // Бабочка: два крыла хлопают, сердцевина тёмная.
            if (hasFly && u >= 18) {
                float fl = 0.35f + 0.65f * (float)Math.Abs(Math.Sin(t * 14));
                using (SolidBrush wb = new SolidBrush(Color.FromArgb(235, 0xF5, 0xA6, 0xC4)))
                using (SolidBrush wb2 = new SolidBrush(Color.FromArgb(235, 0xF9, 0xC9, 0x8A))) {
                    float ww = u * 0.075f * fl, wh = u * 0.09f;
                    g.FillEllipse(wb, bfly.X - ww, bfly.Y - wh, ww, wh);
                    g.FillEllipse(wb, bfly.X, bfly.Y - wh, ww, wh);
                    g.FillEllipse(wb2, bfly.X - ww * 0.8f, bfly.Y - wh * 0.1f, ww * 0.8f, wh * 0.6f);
                    g.FillEllipse(wb2, bfly.X, bfly.Y - wh * 0.1f, ww * 0.8f, wh * 0.6f);
                }
                using (SolidBrush bb = new SolidBrush(Theme.Hex(0x4A3530))) g.FillEllipse(bb, bfly.X - u * 0.008f, bfly.Y - u * 0.06f, u * 0.022f, u * 0.09f);
            }
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
            // «Тык» — затяжка с начала, прямо сейчас.
            if (smoking && animate && mood != null && mood.PokeAge > 0 && mood.PokeAge < 3.4f) c = mood.PokeAge;
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
            if (s.Aha > 0.05f && u >= 22) using (Pen dp = new Pen(Color.FromArgb(190, 245, 240, 232), Math.Max(1.2f, u * 0.024f))) {
                dp.DashStyle = DashStyle.Dash; dp.DashOffset = animate ? -t * 4f : 0f;
                using (GraphicsPath hp = new GraphicsPath()) {
                    hp.AddBezier(P(0.40f, -0.44f - lift / u), P(0.54f, -0.44f - lift / u), P(0.56f, -0.62f), P(0.66f, -0.70f));
                    hp.AddBezier(P(0.66f, -0.70f), P(0.58f, -0.86f), P(0.45f, -0.80f), P(0.50f, -0.67f));
                    hp.AddBezier(P(0.50f, -0.67f), P(0.56f, -0.80f), P(0.74f, -0.80f), P(0.66f, -0.70f));
                    g.DrawPath(dp, hp);
                }
            }
            // Фирменное: «Мёртвая петля» — облетает круг с полным оборотом, в конце — сердечко.
            float loop = MascotSig.At(t, seed, 7f, 1.4f, 0.5f, animate, state);
            float lp = loop < 0 ? 0f : MascotSig.Smooth(loop);
            float ox = 0f, oy = 0f, spin = 0f, bank = 0f;
            if (loop >= 0) {
                double a = 2 * Math.PI * lp;
                ox = (float)Math.Sin(a) * 0.20f * u; oy = -(float)(1 - Math.Cos(a)) * 0.20f * u;
                spin = -360f * lp;
            }
            else if (s.Working && animate) {
                // Работает — восьмёрка: вбок и чуть вверх-вниз, наклон по ходу полёта.
                double a = t * 1.4 + s.Ph;
                ox = (float)Math.Sin(a) * 0.16f * u; oy = -(float)Math.Sin(2 * a) * 0.05f * u;
                bank = 10f * (float)Math.Cos(a);
            }
            GraphicsState st = Rigid(g, cx + ox, by, Tilt(s, 0f) - 4f + bank, lift - oy);
            if (spin != 0f) { g.TranslateTransform(cx + ox, by - 0.40f * u); g.RotateTransform(spin); g.TranslateTransform(-(cx + ox), -(by - 0.40f * u)); }
            Func<float, float, PointF> P0 = P;
            P = delegate (float x, float y) { PointF q = P0(x, y); return new PointF(q.X + ox, q.Y); };
            float flap = s.Sleep ? 0.15f : (float)Math.Abs(Math.Sin(t * (s.Working || loop >= 0 ? 16 : 8) + s.Ph)) * s.A;
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
            if (animate && u >= 20) {
                // Работает — за ней сыплется пыльца (по прошлым точкам восьмёрки).
                if (s.Working && loop < 0) for (int i = 1; i <= 5; i++) {
                    double a = (t - i * 0.12) * 1.4 + s.Ph;
                    float px = cx + (float)Math.Sin(a) * 0.16f * u + 0.30f * u, py = by - 0.42f * u - lift - (float)Math.Sin(2 * a) * 0.05f * u + i * 0.025f * u;
                    using (SolidBrush pb = new SolidBrush(Color.FromArgb(200 - i * 35, 0xFF, 0xD8, 0x6A))) g.FillEllipse(pb, px - u * 0.013f, py - u * 0.013f, u * 0.026f, u * 0.026f);
                }
                // Ждёт — напевает: ноты всплывают и тают.
                if (s.Waiting && loop < 0) using (Font nf = new Font("Segoe UI Symbol", Math.Max(6f, u * 0.16f), FontStyle.Bold, GraphicsUnit.Pixel)) {
                    for (int i = 0; i < 2; i++) {
                        float k = (float)(((t * 0.45 + i * 0.5 + s.Ph) % 1.0));
                        PointF np = new PointF(cx - (0.42f + 0.10f * k) * u + (float)Math.Sin(k * 6 + i) * 0.04f * u, by - (0.70f + 0.35f * k) * u);
                        using (SolidBrush nb = new SolidBrush(Color.FromArgb((int)(220 * MascotSig.Bell(k)), 0xF8, 0xD2, 0x74)))
                            g.DrawString(i == 0 ? "♪" : "♫", nf, nb, np);
                    }
                }
                // После петли — сердечко.
                if (loop > 0.75f) {
                    float k = (loop - 0.75f) / 0.25f;
                    MascotSig.Heart(g, new PointF(cx + 0.05f * u, by - (0.95f + 0.15f * k) * u), u * 0.06f, Color.FromArgb((int)(240 * (1 - k)), 0xF4, 0x8F, 0xA8));
                }
            }
            Finish(g, s, mood, new PointF(cx - 0.64f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }
    }
}
