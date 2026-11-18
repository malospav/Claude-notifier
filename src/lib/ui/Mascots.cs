// claude-notifier: элементы интерфейса в стиле Apple (WinForms + GDI+, C# 5 для csc из .NET Framework).
// Сгруппированные списки, сегментный переключатель, тумблер, кнопки-капсулы, ячейки кода, точка статуса для трея.
// Движение — по принципам Apple / Emil Kowalski: отклик на нажатие сразу, ease-out, прерываемые анимации
// с текущего значения, частые действия (обновление списка, клавиатура) не анимируются, «меньше движения» в Windows уважается.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ClaudeNotifier.Ui {
    // Настроение сфинкса от шторки: «Ага!» (сколько секунд назад Claude сделал действие), глубокая задумчивость
    // (долго без действий), сколько агентов работает, куда смотреть (курсор рядом в раскрытой шторке).
    // Выбранный маскот шторки (настройка «Маскот»): сфинкс (3D) или огонёк (плоский, векторный).
    public static class Mascot {
        static volatile string kind = "sphynx";
        public static string Kind { get { return kind; } set { kind = value == "flame" ? "flame" : "sphynx"; } }
        public static void Paint(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            Paint(g, r, state, t, seed, animate, mood, null);
        }

        // Свой маскот у сеансов с другого устройства (Mac, телефон): id устройства → sphynx | flame.
        static readonly Dictionary<string, string> byDevice = new Dictionary<string, string>();
        public static void ClearDevices() { lock (byDevice) byDevice.Clear(); }
        public static void SetDevice(string device, string mascot) {
            if (string.IsNullOrEmpty(device)) return;
            lock (byDevice) byDevice[device] = mascot == "flame" ? "flame" : "sphynx";
        }
        public static string For(string device) {
            if (!string.IsNullOrEmpty(device)) { string k; lock (byDevice) { if (byDevice.TryGetValue(device, out k)) return k; } }
            return kind;
        }

        public static void Paint(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood, string device) {
            if (For(device) == "flame") Flame.Paint(g, r, state, t, seed, animate, mood);
            else Cat.Paint(g, r, state, t, seed, animate, mood);
        }
    }

    // Огонёк: плоское пламя с тремя языками, жёлтой серединкой и мордочкой (глаза, ротик), мягкая тень снизу.
    // Поведение — как у сфинкса: работает — пламя пляшет, взгляд гуляет, облачко «…»; «Ага!» — вспыхивает,
    // глаза «> <», чёрточки-искры; задумался — пламя ниже и спокойнее, прищур; ждёт решения — янтарный, подпрыгивает,
    // глаза круглые; ждёт ответа — тихо горит и моргает; ошибка — красный, глаза-крестики, дымок; остановился —
    // тусклый, сонный, «z»; сеансов нет — уголёк спит. Агенты — искры вокруг; в раскрытой шторке смотрит на курсор.
    public static class Flame {
        static float Clamp(float v, float a, float b) { return Math.Max(a, Math.Min(b, v)); }

        public static void Paint(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            bool sleep = string.IsNullOrEmpty(state) || state == "none";
            bool working = state == "working", perm = state == "permission", err = state == "error", waiting = state == "waiting", stalled = state == "stalled";
            float ph = seed * 1.7f, A = animate ? 1f : 0f;
            float aha = (mood != null && mood.AhaAge >= 0 && mood.AhaAge < 0.8f) ? (float)Math.Sin(mood.AhaAge / 0.8 * Math.PI) : 0f;
            bool deep = working && mood != null && mood.Deep && aha <= 0;

            // Цвета: верх и низ внешнего пламени, серединка.
            Color top = Theme.Hex(0xEE5F45), bot = Theme.Hex(0xF59A4E), core = Theme.Hex(0xFFCF6B), coreTop = Theme.Hex(0xFFE59A);
            if (perm) { top = Theme.Hex(0xF58A1F); bot = Theme.Hex(0xFFB340); core = Theme.Hex(0xFFE07A); coreTop = Theme.Hex(0xFFF0B8); }
            else if (err) { top = Theme.Hex(0xD9372E); bot = Theme.Hex(0xEF6448); core = Theme.Hex(0xFF9E70); coreTop = Theme.Hex(0xFFC09A); }
            else if (sleep || stalled) {
                Color grey = Theme.Hex(0x7A6E6A);
                float k = sleep ? 0.55f : 0.4f;
                top = Draw.Mix(top, grey, k); bot = Draw.Mix(bot, grey, k); core = Draw.Mix(core, grey, k); coreTop = Draw.Mix(coreTop, grey, k);
            }

            // Движение.
            float flick = (working ? 1f : perm ? 1.2f : waiting ? 0.5f : err ? 0.9f : stalled ? 0.3f : 0.2f) * A;
            float speed = working ? 5.5f : perm ? 7f : waiting ? 3f : err ? 10f : 2f;
            if (deep) { flick *= 0.45f; speed *= 0.6f; }
            float height = sleep ? 0.6f : stalled ? 0.78f : deep ? 0.9f : 1f;
            height *= 1f + 0.16f * aha;
            float squash = 1f + 0.035f * (float)Math.Sin(t * speed * 0.45f + ph) * Math.Max(flick, 0.3f * A);
            Func<double, float> S = delegate (double k) { return (float)Math.Sin(t * speed * k + ph * k); };

            // Взгляд: у работающего гуляет вверх-в сторону, в раскрытой шторке — на курсор.
            float gx = 0, gy = 0;
            if (working && animate) { gx = 0.7f * (float)Math.Tanh(3.0 * Math.Sin(t * 0.45f + ph)); gy = deep ? 0.1f : 0.45f; }
            if (mood != null && mood.HasLook && !sleep) {
                float lw = Clamp(mood.LookW, 0, 1);
                gx = gx * (1 - lw) + mood.LookX * lw; gy = gy * (1 - lw) + mood.LookY * lw;
            }
            float lean = 0.07f * gx;

            float u = r.Height * 0.86f;
            float cx = r.X + r.Width / 2f, by = r.Bottom - r.Height * 0.07f;
            if (perm) by -= Math.Abs((float)Math.Sin(t * 4.2f + ph)) * u * 0.05f * A;
            float hs = height * squash;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + (x - lean * y) * u, by + y * u * hs); };

            SmoothingMode sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            // Тень и мягкое свечение.
            using (SolidBrush sh = new SolidBrush(Color.FromArgb(sleep ? 50 : 90, 0, 0, 0)))
                g.FillEllipse(sh, cx - 0.42f * u, by - 0.035f * u, 0.84f * u, 0.07f * u);
            if (!sleep && u >= 16) {
                float gr = 0.62f * u * (1f + 0.25f * aha);
                PointF gc = P(0, -0.42f);
                using (GraphicsPath gp = new GraphicsPath()) {
                    gp.AddEllipse(gc.X - gr, gc.Y - gr, gr * 2, gr * 2);
                    using (PathGradientBrush pg = new PathGradientBrush(gp)) {
                        pg.CenterColor = Color.FromArgb((int)((perm ? 70 : 45) + 60 * aha), bot);
                        pg.SurroundColors = new Color[] { Color.FromArgb(0, bot) };
                        g.FillPath(pg, gp);
                    }
                }
            }

            // Внешнее пламя: круглый низ, справа — язычок, посередине — высокий, слева — средний.
            float sR = 0.05f * S(1.0) * flick, sM = 0.07f * S(1.3) * flick, sL = 0.05f * S(0.8) * flick;
            float hR = 1f + 0.07f * S(1.7) * flick, hM = 1f + 0.08f * S(1.1) * flick + 0.1f * aha, hL = 1f + 0.07f * S(1.5) * flick;
            using (GraphicsPath o = new GraphicsPath()) {
                o.AddBezier(P(-0.44f, -0.42f), P(-0.44f, -0.17f), P(-0.25f, 0f), P(0f, 0f));
                o.AddBezier(P(0f, 0f), P(0.25f, 0f), P(0.44f, -0.17f), P(0.44f, -0.42f));
                o.AddBezier(P(0.44f, -0.42f), P(0.45f, -0.56f), P(0.40f + sR, -0.68f * hR), P(0.34f + sR, -0.80f * hR));
                o.AddBezier(P(0.34f + sR, -0.80f * hR), P(0.26f, -0.70f), P(0.18f, -0.68f), P(0.15f, -0.66f));
                o.AddBezier(P(0.15f, -0.66f), P(0.22f, -0.82f), P(0.12f + sM, -0.95f * hM), P(0.02f + sM, -1.04f * hM));
                o.AddBezier(P(0.02f + sM, -1.04f * hM), P(-0.05f, -0.88f), P(-0.13f, -0.78f), P(-0.19f, -0.72f));
                o.AddBezier(P(-0.19f, -0.72f), P(-0.24f, -0.78f), P(-0.30f + sL, -0.84f * hL), P(-0.35f + sL, -0.88f * hL));
                o.AddBezier(P(-0.35f + sL, -0.88f * hL), P(-0.47f, -0.72f), P(-0.47f, -0.56f), P(-0.44f, -0.42f));
                o.CloseFigure();
                RectangleF ob = o.GetBounds();
                using (LinearGradientBrush lb = new LinearGradientBrush(new RectangleF(ob.X, ob.Y - 1, ob.Width, ob.Height + 2), top, bot, LinearGradientMode.Vertical))
                    g.FillPath(lb, o);
            }

            // Серединка: круглая, с одним мягким язычком сверху.
            float sI = 0.04f * S(1.6) * flick, hI = 1f + 0.06f * S(1.25) * flick;
            using (GraphicsPath c = new GraphicsPath()) {
                c.AddBezier(P(-0.35f, -0.34f), P(-0.35f, -0.13f), P(-0.19f, -0.02f), P(0f, -0.02f));
                c.AddBezier(P(0f, -0.02f), P(0.19f, -0.02f), P(0.35f, -0.13f), P(0.35f, -0.34f));
                c.AddBezier(P(0.35f, -0.34f), P(0.35f, -0.50f), P(0.24f, -0.58f), P(0.13f, -0.62f));
                c.AddBezier(P(0.13f, -0.62f), P(0.10f + sI, -0.70f * hI), P(0.04f + sI, -0.76f * hI), P(-0.03f + sI, -0.80f * hI));
                c.AddBezier(P(-0.03f + sI, -0.80f * hI), P(-0.04f, -0.70f), P(-0.10f, -0.64f), P(-0.20f, -0.60f));
                c.AddBezier(P(-0.20f, -0.60f), P(-0.32f, -0.55f), P(-0.35f, -0.46f), P(-0.35f, -0.34f));
                c.CloseFigure();
                RectangleF cb = c.GetBounds();
                using (LinearGradientBrush lb = new LinearGradientBrush(new RectangleF(cb.X, cb.Y - 1, cb.Width, cb.Height + 2), coreTop, core, LinearGradientMode.Vertical))
                    g.FillPath(lb, c);
            }

            // Мордочка.
            Color ink = Theme.Hex(0x3A2420);
            float ew = Math.Max(1.2f, u * 0.042f);
            float fx = gx * 0.06f, fy = -gy * 0.045f;
            PointF eL = P(-0.135f + fx, -0.36f + fy), eR = P(0.135f + fx, -0.36f + fy), mo = P(0f + fx * 0.8f, -0.25f + fy * 0.8f);
            bool blink = animate && ((t + seed * 1.3f) % 4.2f) < 0.14f;
            string eyes = sleep || stalled ? "closed" : err ? "x" : aha > 0.05f ? "happy" : deep ? "squint" : perm ? "round" : blink ? "closed" : "open";
            using (Pen ip = new Pen(ink, ew))
            using (SolidBrush ib = new SolidBrush(ink)) {
                ip.StartCap = ip.EndCap = LineCap.Round; ip.LineJoin = LineJoin.Round;
                float es = u * 0.07f;
                foreach (PointF e in new PointF[] { eL, eR }) {
                    bool left = e.X < mo.X;
                    switch (eyes) {
                        case "open": {
                            float w = u * 0.06f, h = u * 0.085f;
                            g.FillEllipse(ib, e.X - w / 2, e.Y - h / 2, w, h);
                            if (u >= 30) using (SolidBrush hl = new SolidBrush(Color.FromArgb(200, 255, 255, 255))) g.FillEllipse(hl, e.X - w * 0.05f, e.Y - h * 0.38f, w * 0.38f, w * 0.38f);
                            break;
                        }
                        case "round": {
                            float w = u * 0.085f;
                            g.FillEllipse(ib, e.X - w / 2, e.Y - w / 2, w, w);
                            if (u >= 24) using (SolidBrush hl = new SolidBrush(Color.FromArgb(220, 255, 255, 255))) g.FillEllipse(hl, e.X - w * 0.1f, e.Y - w * 0.36f, w * 0.4f, w * 0.4f);
                            break;
                        }
                        case "happy": {   // «> <»
                            float d = left ? 1 : -1;
                            g.DrawLines(ip, new PointF[] { new PointF(e.X - d * es * 0.55f, e.Y - es * 0.5f), new PointF(e.X + d * es * 0.45f, e.Y), new PointF(e.X - d * es * 0.55f, e.Y + es * 0.5f) });
                            break;
                        }
                        case "squint":
                            g.DrawLine(ip, e.X - es * 0.5f, e.Y + es * 0.1f, e.X + es * 0.5f, e.Y + es * 0.1f);
                            break;
                        case "x":
                            g.DrawLine(ip, e.X - es * 0.42f, e.Y - es * 0.42f, e.X + es * 0.42f, e.Y + es * 0.42f);
                            g.DrawLine(ip, e.X - es * 0.42f, e.Y + es * 0.42f, e.X + es * 0.42f, e.Y - es * 0.42f);
                            break;
                        default:   // закрыты — дужки вниз
                            g.DrawArc(ip, e.X - es * 0.5f, e.Y - es * 0.45f, es, es * 0.8f, 20, 140);
                            break;
                    }
                }
                // Ротик.
                float m = u * 0.045f;
                if (sleep || stalled) g.DrawLine(ip, mo.X - m * 0.5f, mo.Y + m * 0.2f, mo.X + m * 0.5f, mo.Y + m * 0.2f);
                else if (perm) { float w = u * 0.05f; g.FillEllipse(ib, mo.X - w / 2, mo.Y - w * 0.3f, w, w * 1.1f); }
                else if (err) g.DrawBezier(ip, mo.X - m, mo.Y + m * 0.2f, mo.X - m * 0.3f, mo.Y - m * 0.5f, mo.X + m * 0.3f, mo.Y + m * 0.7f, mo.X + m, mo.Y);
                else if (aha > 0.05f || working) g.DrawLines(ip, new PointF[] { new PointF(mo.X - m * 0.6f, mo.Y + m * 0.35f), new PointF(mo.X, mo.Y - m * 0.3f), new PointF(mo.X + m * 0.6f, mo.Y + m * 0.35f) });
                else g.DrawArc(ip, mo.X - m * 0.7f, mo.Y - m * 0.6f, m * 1.4f, m * 1.0f, 30, 120);   // ждёт — улыбка
            }

            // Чёрточки-искры у макушки: «Ага!» и запрос разрешения.
            float spark = Math.Max(aha, perm ? 0.6f + 0.4f * (float)Math.Abs(Math.Sin(t * 4.2f + ph)) * A : 0f);
            if (spark > 0.05f && u >= 18)
                using (Pen sp = new Pen(Color.FromArgb((int)(255 * Clamp(spark, 0, 1)), top), Math.Max(1.2f, u * 0.045f))) {
                    sp.StartCap = sp.EndCap = LineCap.Round;
                    PointF a1 = P(0.40f, -0.95f), a2 = P(0.50f, -1.08f), b1 = P(0.50f, -0.82f), b2 = P(0.64f, -0.90f);
                    g.DrawLine(sp, a1, a2); g.DrawLine(sp, b1, b2);
                }

            // Агенты — искры кружат вокруг огонька.
            int ag = mood != null ? Math.Min(5, mood.Agents) : 0;
            if (ag > 0 && u >= 14)
                for (int i = 0; i < ag; i++) {
                    float ang = (animate ? t * 1.3f : 0f) + i * (float)(2 * Math.PI / ag) + ph;
                    PointF c = new PointF(cx + (float)Math.Cos(ang) * 0.6f * u, by - 0.5f * u + (float)Math.Sin(ang) * 0.22f * u);
                    float gr = u * 0.07f, cr = u * 0.03f;
                    using (SolidBrush gb = new SolidBrush(Color.FromArgb(80, 255, 196, 60))) g.FillEllipse(gb, c.X - gr, c.Y - gr, gr * 2, gr * 2);
                    using (SolidBrush cb = new SolidBrush(Theme.Hex(0xFFE27A))) g.FillEllipse(cb, c.X - cr, c.Y - cr, cr * 2, cr * 2);
                }

            // Ошибка — дымок над пламенем.
            if (err && u >= 18)
                for (int i = 0; i < 3; i++) {
                    float k = (float)(((animate ? t * 0.6f : 0.3f) + i / 3f) % 1.0);
                    PointF c = P(0.02f + 0.08f * (float)Math.Sin(k * 6 + i), -1.08f - k * 0.35f);
                    float rr = u * (0.04f + 0.05f * k);
                    using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(140 * (1 - k)), 140, 140, 146))) g.FillEllipse(b, c.X - rr, c.Y - rr, rr * 2, rr * 2);
                }

            // Облачко: работает — бегущие точки, спит или остановился — «z».
            string bubble = working && aha <= 0.05f ? "dots" : (sleep || stalled) ? "z" : null;
            if (bubble != null && u >= 22) {
                PointF c = new PointF(cx + 0.66f * u, by - 0.98f * u * (sleep ? 0.75f : 1f));
                Color bg = Color.FromArgb(235, 248, 246, 244);
                if (bubble == "dots") {
                    float bw = u * 0.42f, bh = u * 0.24f;
                    using (SolidBrush bb = new SolidBrush(bg)) {
                        g.FillEllipse(bb, c.X - bw * 0.62f - u * 0.03f, c.Y + bh * 0.62f, u * 0.06f, u * 0.06f);
                        Draw.Fill(g, new RectangleF(c.X - bw / 2, c.Y - bh / 2, bw, bh), bh / 2f, bg);
                    }
                    float sp2 = deep ? 1.3f : 3f;
                    for (int i = 0; i < 3; i++) {
                        float a = (float)Math.Max(0, Math.Sin(t * sp2 - i * 0.7f)) * A;
                        float dr = u * 0.032f;
                        using (SolidBrush db = new SolidBrush(Color.FromArgb((int)(70 + 185 * a), 60, 60, 66)))
                            g.FillEllipse(db, c.X + (i - 1) * u * 0.1f - dr, c.Y - dr - a * u * 0.02f, dr * 2, dr * 2);
                    }
                } else {
                    float zy = -(float)(((animate ? t : 0) * 0.5) % 1.0) * u * 0.12f;
                    using (Font f = new Font("Segoe UI", Math.Max(6f, u * 0.2f), FontStyle.Italic | FontStyle.Bold, GraphicsUnit.Pixel))
                    using (StringFormat sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    using (SolidBrush fb = new SolidBrush(Theme.Hex(0x8E8E93)))
                        g.DrawString("z", f, fb, new PointF(c.X, c.Y + zy), sf);
                }
            }
            g.SmoothingMode = sm;
        }
    }

    // Персонаж сеанса: скруглённый «камешек» с двумя глазами. Работает — оглядывается и покачивается;
    // нужно разрешение — глаза шире, мягко пульсирует; ждёт — моргает; ошибка — глаза-крестики; сеансов нет — спит.
    public static class Face {
        public static Color BodyColor(string state) {
            switch (state) {
                case "working": return Theme.Hex(0xD97757);
                case "permission": return Theme.Hex(0xFF9F0A);
                case "error": return Theme.Hex(0xFF453A);
                case "waiting": return Theme.Hex(0xF2F2F2);
                default: return Theme.Hex(0x6E6E73);
            }
        }

        // Персонаж — объёмная мордочка котика (Cat); окраска и поведение — по статусу.
        public static void Paint(Graphics g, RectangleF r, string state, float t, int seed, bool animate) {
            Mascot.Paint(g, r, state, t, seed, animate, null);
        }
    }
}
