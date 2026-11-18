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
    // Выбранный маскот шторки (настройка «Маскот»): сфинкс (3D), плоский сфинкс или огонёк (оба векторные).
    public static class Mascot {
        static volatile string kind = "sphynx";
        public static string Kind { get { return kind; } set { kind = Normalize(value); } }
        public static readonly string[] Kinds = { "sphynx", "flatsphynx", "flame", "boxcat", "penguin", "kitty", "ghost", "mochi" };
        public static string Normalize(string v) { return Array.IndexOf(Kinds, v) >= 0 ? v : "sphynx"; }
        public static void Paint(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            Paint(g, r, state, t, seed, animate, mood, null);
        }

        // Свой маскот у сеансов с другого устройства (Mac, телефон): id устройства → sphynx | flame.
        static readonly Dictionary<string, string> byDevice = new Dictionary<string, string>();
        public static void ClearDevices() { lock (byDevice) byDevice.Clear(); }
        public static void SetDevice(string device, string mascot) {
            if (string.IsNullOrEmpty(device)) return;
            lock (byDevice) byDevice[device] = Normalize(mascot);
        }
        public static string For(string device) {
            if (!string.IsNullOrEmpty(device)) { string k; lock (byDevice) { if (byDevice.TryGetValue(device, out k)) return k; } }
            return kind;
        }

        public static void Paint(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood, string device) {
            PaintKind(g, r, For(device), state, t, seed, animate, mood);
        }

        // Картинка маскота для списка выбора в настройках: ждёт ответа, без анимации, на прозрачном фоне.
        public static Bitmap Preview(string mascot, int size) {
            Bitmap b = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(b)) {
                g.Clear(Color.Transparent);
                try { PaintKind(g, new RectangleF(size * 0.06f, size * 0.04f, size * 0.88f, size * 0.88f), Normalize(mascot), "waiting", 0f, 1, false, null); } catch { }
            }
            return b;
        }

        public static void PaintKind(Graphics g, RectangleF r, string kind, string state, float t, int seed, bool animate, CatMood mood) {
            switch (Normalize(kind)) {
                case "flame": Flame.Paint(g, r, state, t, seed, animate, mood); break;
                case "flatsphynx": FlatSphynx.Paint(g, r, state, t, seed, animate, mood); break;
                case "boxcat": FlatPals.BoxCat(g, r, state, t, seed, animate, mood); break;
                case "penguin": FlatPals.Penguin(g, r, state, t, seed, animate, mood); break;
                case "kitty": FlatPals.Kitty(g, r, state, t, seed, animate, mood); break;
                case "ghost": FlatPals.Ghost(g, r, state, t, seed, animate, mood); break;
                case "mochi": FlatPals.Mochi(g, r, state, t, seed, animate, mood); break;
                default: Cat.Paint(g, r, state, t, seed, animate, mood); break;
            }
        }
    }

    // Общее у плоских маскотов (огонёк, плоский сфинкс): тень, свечение, глаза, ротик, искры «Ага!»,
    // огоньки агентов и облачко «…» / «z» — чтобы оба выглядели и вели себя одинаково.
    static class FlatFx {
        public static float Clamp(float v, float a, float b) { return Math.Max(a, Math.Min(b, v)); }

        public static void Shadow(Graphics g, float cx, float by, float u, bool sleep) {
            using (SolidBrush sh = new SolidBrush(Color.FromArgb(sleep ? 50 : 90, 0, 0, 0)))
                g.FillEllipse(sh, cx - 0.42f * u, by - 0.035f * u, 0.84f * u, 0.07f * u);
        }

        public static void Glow(Graphics g, PointF c, float radius, Color color, int alpha) {
            using (GraphicsPath gp = new GraphicsPath()) {
                gp.AddEllipse(c.X - radius, c.Y - radius, radius * 2, radius * 2);
                using (PathGradientBrush pg = new PathGradientBrush(gp)) {
                    pg.CenterColor = Color.FromArgb(Math.Max(0, Math.Min(255, alpha)), color);
                    pg.SurroundColors = new Color[] { Color.FromArgb(0, color) };
                    g.FillPath(pg, gp);
                }
            }
        }

        // Глаза: open | round | happy («> <») | squint | x | closed. Size — множитель размера (1 — как у огонька).
        public static void Eyes(Graphics g, PointF eL, PointF eR, float midX, float u, string eyes, Color ink, float size) {
            float ew = Math.Max(1.2f, u * 0.042f);
            float es = u * 0.07f * size;
            using (Pen ip = new Pen(ink, ew))
            using (SolidBrush ib = new SolidBrush(ink)) {
                ip.StartCap = ip.EndCap = LineCap.Round; ip.LineJoin = LineJoin.Round;
                foreach (PointF e in new PointF[] { eL, eR }) {
                    bool left = e.X < midX;
                    switch (eyes) {
                        case "open": {
                            float w = u * 0.06f * size, h = u * 0.085f * size;
                            g.FillEllipse(ib, e.X - w / 2, e.Y - h / 2, w, h);
                            if (u >= 30) using (SolidBrush hl = new SolidBrush(Color.FromArgb(200, 255, 255, 255))) g.FillEllipse(hl, e.X - w * 0.05f, e.Y - h * 0.38f, w * 0.38f, w * 0.38f);
                            break;
                        }
                        case "round": {
                            float w = u * 0.085f * size;
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
            }
        }

        // Ротик: flat (спит) | o (ждёт решения) | wavy (ошибка) | up («^» — работает, «Ага!») | smile | cat («ω»).
        public static void Mouth(Graphics g, PointF mo, float u, string kind, Color ink) {
            float ew = Math.Max(1.2f, u * 0.042f);
            float m = u * 0.045f;
            using (Pen ip = new Pen(ink, ew))
            using (SolidBrush ib = new SolidBrush(ink)) {
                ip.StartCap = ip.EndCap = LineCap.Round; ip.LineJoin = LineJoin.Round;
                switch (kind) {
                    case "flat": g.DrawLine(ip, mo.X - m * 0.5f, mo.Y + m * 0.2f, mo.X + m * 0.5f, mo.Y + m * 0.2f); break;
                    case "o": { float w = u * 0.05f; g.FillEllipse(ib, mo.X - w / 2, mo.Y - w * 0.3f, w, w * 1.1f); break; }
                    case "wavy": g.DrawBezier(ip, mo.X - m, mo.Y + m * 0.2f, mo.X - m * 0.3f, mo.Y - m * 0.5f, mo.X + m * 0.3f, mo.Y + m * 0.7f, mo.X + m, mo.Y); break;
                    case "up": g.DrawLines(ip, new PointF[] { new PointF(mo.X - m * 0.6f, mo.Y + m * 0.35f), new PointF(mo.X, mo.Y - m * 0.3f), new PointF(mo.X + m * 0.6f, mo.Y + m * 0.35f) }); break;
                    case "cat":   // «ω» — кошачий ротик
                        g.DrawArc(ip, mo.X - m * 1.0f, mo.Y - m * 0.55f, m * 1.0f, m * 0.9f, 10, 160);
                        g.DrawArc(ip, mo.X, mo.Y - m * 0.55f, m * 1.0f, m * 0.9f, 10, 160);
                        break;
                    default: g.DrawArc(ip, mo.X - m * 0.7f, mo.Y - m * 0.6f, m * 1.4f, m * 1.0f, 30, 120); break;   // улыбка
                }
            }
        }

        // Две чёрточки-искры у макушки («Ага!», запрос разрешения).
        public static void Sparks(Graphics g, PointF a1, PointF a2, PointF b1, PointF b2, Color c, float spark, float u) {
            if (spark <= 0.05f || u < 18) return;
            using (Pen sp = new Pen(Color.FromArgb((int)(255 * Clamp(spark, 0, 1)), c), Math.Max(1.2f, u * 0.045f))) {
                sp.StartCap = sp.EndCap = LineCap.Round;
                g.DrawLine(sp, a1, a2); g.DrawLine(sp, b1, b2);
            }
        }

        // Агенты — огоньки кружат вокруг маскота, по одному на агента (до 5).
        public static void Agents(Graphics g, float cx, float by, float u, int count, float t, bool animate, float ph) {
            int ag = Math.Min(5, count);
            if (ag <= 0 || u < 14) return;
            for (int i = 0; i < ag; i++) {
                float ang = (animate ? t * 1.3f : 0f) + i * (float)(2 * Math.PI / ag) + ph;
                PointF c = new PointF(cx + (float)Math.Cos(ang) * 0.6f * u, by - 0.5f * u + (float)Math.Sin(ang) * 0.22f * u);
                float gr = u * 0.07f, cr = u * 0.03f;
                using (SolidBrush gb = new SolidBrush(Color.FromArgb(80, 255, 196, 60))) g.FillEllipse(gb, c.X - gr, c.Y - gr, gr * 2, gr * 2);
                using (SolidBrush cb = new SolidBrush(Theme.Hex(0xFFE27A))) g.FillEllipse(cb, c.X - cr, c.Y - cr, cr * 2, cr * 2);
            }
        }

        // Облачко: dots — бегущие точки (работает), z — спит или остановился.
        public static void Bubble(Graphics g, PointF c, float u, string kind, float t, float A, bool deep, bool animate) {
            if (kind == null || u < 22) return;
            Color bg = Color.FromArgb(235, 248, 246, 244);
            if (kind == "dots") {
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
    }

    // Общее состояние плоского маскота на кадр: статус, «Ага!», задумчивость, взгляд, глаза, ротик, облачко.
    // Каждый маскот рисует только своё тело, а мордочка и поведение у всех одинаковые.
    sealed class FlatState {
        public bool Sleep, Working, Perm, Err, Waiting, Stalled, Deep, Animate;
        public float T, Ph, A, Aha, Gx, Gy, U, Cx, By, Spark;
        public string Eyes, Bubble;

        public static FlatState Of(RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            FlatState s = new FlatState();
            s.Sleep = string.IsNullOrEmpty(state) || state == "none";
            s.Working = state == "working"; s.Perm = state == "permission"; s.Err = state == "error";
            s.Waiting = state == "waiting"; s.Stalled = state == "stalled";
            s.T = t; s.Ph = seed * 1.7f; s.Animate = animate; s.A = animate ? 1f : 0f;
            s.Aha = (mood != null && mood.AhaAge >= 0 && mood.AhaAge < 0.8f) ? (float)Math.Sin(mood.AhaAge / 0.8 * Math.PI) : 0f;
            s.Deep = s.Working && mood != null && mood.Deep && s.Aha <= 0;
            if (s.Working && animate) { s.Gx = 0.7f * (float)Math.Tanh(3.0 * Math.Sin(t * 0.45f + s.Ph)); s.Gy = s.Deep ? 0.1f : 0.45f; }
            if (mood != null && mood.HasLook && !s.Sleep) {
                float lw = FlatFx.Clamp(mood.LookW, 0, 1);
                s.Gx = s.Gx * (1 - lw) + mood.LookX * lw; s.Gy = s.Gy * (1 - lw) + mood.LookY * lw;
            }
            s.U = r.Height * 0.86f; s.Cx = r.X + r.Width / 2f; s.By = r.Bottom - r.Height * 0.07f;
            bool blink = animate && ((t + seed * 1.3f) % 4.2f) < 0.14f;
            s.Eyes = s.Sleep || s.Stalled ? "closed" : s.Err ? "x" : s.Aha > 0.05f ? "happy" : s.Deep ? "squint" : s.Perm ? "round" : blink ? "closed" : "open";
            s.Bubble = s.Working && s.Aha <= 0.05f ? "dots" : (s.Sleep || s.Stalled) ? "z" : null;
            s.Spark = Math.Max(s.Aha, s.Perm ? 0.6f + 0.4f * (float)Math.Abs(Math.Sin(t * 4.2f + s.Ph)) * s.A : 0f);
            return s;
        }

        // Ротик по статусу; Idle — свой у маскота, когда он просто ждёт ответа.
        public string Mouth(string idle) { return Sleep || Stalled ? "flat" : Perm ? "o" : Err ? "wavy" : Aha > 0.05f || Working ? "up" : idle; }

        // Лёгкая подкраска по статусу, как у огонька: янтарный — ждёт решения, красноватый — ошибка, тусклый — спит.
        public Color Tint(Color c, float amount) {
            if (Perm) return Draw.Mix(c, Theme.Hex(0xFFB547), 0.35f * amount);
            if (Err) return Draw.Mix(c, Theme.Hex(0xEF5A48), 0.35f * amount);
            if (Sleep) return Draw.Mix(c, Theme.Hex(0x7A6E6A), 0.5f * amount);
            if (Stalled) return Draw.Mix(c, Theme.Hex(0x7A6E6A), 0.35f * amount);
            return c;
        }

        public float Sin(double speed, double k) { return (float)Math.Sin(T * speed + Ph * k); }
    }

    // Плоский сфинкс — в том же рисунке, что огонёк: лысая персиковая мордочка с большими ушами-раковинами,
    // складками на лбу, крупными глазами, розовым носиком и «ω»-ротиком; мягкая тень и свечение.
    // Поведение — как у огонька: работает — покачивается, взгляд гуляет, облачко «…»; «Ага!» — уши торчком,
    // глаза «> <», искры; задумался — уши чуть в стороны, прищур; ждёт решения — янтарный, наклоняет голову и
    // подпрыгивает, глаза круглые; ждёт ответа — спокойно дышит и моргает; ошибка — красноватый, уши обвисли,
    // глаза-крестики, капелька пота; остановился — тусклый и сонный, «z»; сеансов нет — спит и медленно кивает.
    // Агенты — огоньки вокруг; в раскрытой шторке смотрит на курсор; изредка дёргает ухом.
    public static class FlatSphynx {
        public static void Paint(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            bool sleep = string.IsNullOrEmpty(state) || state == "none";
            bool working = state == "working", perm = state == "permission", err = state == "error", waiting = state == "waiting", stalled = state == "stalled";
            float ph = seed * 1.7f, A = animate ? 1f : 0f;
            float aha = (mood != null && mood.AhaAge >= 0 && mood.AhaAge < 0.8f) ? (float)Math.Sin(mood.AhaAge / 0.8 * Math.PI) : 0f;
            bool deep = working && mood != null && mood.Deep && aha <= 0;

            // Кожа (верх светлее), уши изнутри, складки, румянец; подкраска по статусу — как у огонька.
            Color top = Theme.Hex(0xF7CDBA), bot = Theme.Hex(0xE89A82), inner = Theme.Hex(0xE5848C), innerTop = Theme.Hex(0xF2A9A7);
            Color nose = Theme.Hex(0xD9727A), blush = Theme.Hex(0xF08C8C);
            if (perm) {
                Color amber = Theme.Hex(0xFFB547);
                top = Draw.Mix(top, amber, 0.35f); bot = Draw.Mix(bot, amber, 0.45f); inner = Draw.Mix(inner, amber, 0.3f); innerTop = Draw.Mix(innerTop, amber, 0.3f);
            } else if (err) {
                Color red = Theme.Hex(0xEF5A48);
                top = Draw.Mix(top, red, 0.3f); bot = Draw.Mix(bot, red, 0.45f); inner = Draw.Mix(inner, red, 0.3f); blush = Draw.Mix(blush, red, 0.4f);
            } else if (sleep || stalled) {
                Color grey = Theme.Hex(0x7A6E6A);
                float k = sleep ? 0.55f : 0.4f;
                top = Draw.Mix(top, grey, k); bot = Draw.Mix(bot, grey, k); inner = Draw.Mix(inner, grey, k); innerTop = Draw.Mix(innerTop, grey, k);
                nose = Draw.Mix(nose, grey, k); blush = Draw.Mix(blush, grey, k);
            }
            Color wrinkle = Draw.Mix(bot, Theme.Hex(0x7A3E30), 0.35f);

            // Движение: покачивание и дыхание, наклон головы, дрожь при ошибке, кивание во сне.
            Func<double, double, float> S = delegate (double speed, double k) { return (float)Math.Sin(t * speed + ph * k); };
            float bob = (working ? 0.014f * S(2.2, 1) : waiting ? 0.008f * S(1.4, 1) : 0f) * A;
            float nod = (sleep ? 0.03f * S(0.9, 1) : stalled ? 0.02f * S(0.7, 1) : 0f) * A;
            float shiver = err ? 0.010f * S(38, 1) * A : 0f;
            float tilt = perm ? 0.06f + 0.06f * S(1.6, 1) * A : 0f;
            float breath = 1f + (sleep ? 0.025f * S(0.9, 1) : 0.018f * S(working ? 2.4 : 1.6, 1)) * A;
            breath *= 1f + 0.05f * aha;

            // Взгляд: у работающего гуляет вверх-в сторону, в раскрытой шторке — на курсор.
            float gx = 0, gy = 0;
            if (working && animate) { gx = 0.7f * (float)Math.Tanh(3.0 * Math.Sin(t * 0.45f + ph)); gy = deep ? 0.1f : 0.45f; }
            if (mood != null && mood.HasLook && !sleep) {
                float lw = FlatFx.Clamp(mood.LookW, 0, 1);
                gx = gx * (1 - lw) + mood.LookX * lw; gy = gy * (1 - lw) + mood.LookY * lw;
            }
            float lean = 0.06f * gx + tilt + 0.03f * S(0.8, 1) * (working ? 1 : 0) * A;

            float u = r.Height * 0.86f;
            float cx = r.X + r.Width / 2f, by = r.Bottom - r.Height * 0.07f;
            if (perm) by -= Math.Abs((float)Math.Sin(t * 4.2f + ph)) * u * 0.04f * A;
            float lift = bob + nod;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + (x - lean * y + shiver) * u, by + (y * breath + lift) * u); };

            SmoothingMode sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            FlatFx.Shadow(g, cx, by, u, sleep);
            if (!sleep && u >= 16) FlatFx.Glow(g, P(0, -0.46f), 0.62f * u * (1f + 0.25f * aha), bot, (int)((perm ? 70 : 40) + 60 * aha));

            // Уши: кончики по настроению — торчком («Ага!»), в стороны (задумался), обвисли (ошибка), опущены (сон).
            float tipX = 0.36f, tipY = -1.00f;
            if (aha > 0.05f) { tipX = 0.36f - 0.04f * aha; tipY = -1.00f - 0.10f * aha; }
            else if (err) { tipX = 0.54f; tipY = -0.82f; }
            else if (sleep) { tipX = 0.52f; tipY = -0.86f; }
            else if (stalled) { tipX = 0.48f; tipY = -0.90f; }
            else if (deep) { tipX = 0.42f; tipY = -0.95f; }
            else if (perm) { tipY = -1.04f; }
            // Изредка дёргает правым ухом.
            float twitch = animate && !sleep && ((t + seed * 0.9f) % 5.3f) < 0.22f ? 0.05f : 0f;
            for (int side = -1; side <= 1; side += 2) {
                float tx = tipX + (side > 0 ? twitch : 0f), ty = tipY + (side > 0 ? twitch * 0.6f : 0f);
                PointF bIn = P(side * 0.10f, -0.70f), bOut = P(side * 0.42f, -0.44f), tip = P(side * tx, ty);
                using (GraphicsPath ear = new GraphicsPath()) {
                    ear.AddBezier(bIn, P(side * 0.14f, -0.86f), P(side * (tx - 0.10f), ty + 0.02f), tip);
                    ear.AddBezier(tip, P(side * (tx + 0.10f), ty + 0.14f), P(side * 0.50f, -0.60f), bOut);
                    ear.CloseFigure();
                    RectangleF eb = ear.GetBounds();
                    using (LinearGradientBrush lb = new LinearGradientBrush(new RectangleF(eb.X, eb.Y - 1, eb.Width, eb.Height + 2), top, bot, LinearGradientMode.Vertical))
                        g.FillPath(lb, ear);
                }
                // Внутренняя часть уха — розовая, к кончику светлее.
                PointF iIn = P(side * 0.16f, -0.66f), iOut = P(side * 0.37f, -0.50f), iTip = P(side * (tx - 0.01f), ty + 0.10f);
                using (GraphicsPath ie = new GraphicsPath()) {
                    ie.AddBezier(iIn, P(side * 0.19f, -0.80f), P(side * (tx - 0.08f), ty + 0.12f), iTip);
                    ie.AddBezier(iTip, P(side * (tx + 0.05f), ty + 0.22f), P(side * 0.42f, -0.60f), iOut);
                    ie.CloseFigure();
                    RectangleF ib = ie.GetBounds();
                    using (LinearGradientBrush lb = new LinearGradientBrush(new RectangleF(ib.X, ib.Y - 1, ib.Width, ib.Height + 2), innerTop, inner, LinearGradientMode.Vertical))
                        g.FillPath(lb, ie);
                }
            }

            // Голова: широкие скулы, узкий подбородок.
            using (GraphicsPath h = new GraphicsPath()) {
                h.AddBezier(P(0f, -0.05f), P(0.20f, -0.05f), P(0.40f, -0.17f), P(0.43f, -0.37f));
                h.AddBezier(P(0.43f, -0.37f), P(0.46f, -0.58f), P(0.32f, -0.75f), P(0f, -0.76f));
                h.AddBezier(P(0f, -0.76f), P(-0.32f, -0.75f), P(-0.46f, -0.58f), P(-0.43f, -0.37f));
                h.AddBezier(P(-0.43f, -0.37f), P(-0.40f, -0.17f), P(-0.20f, -0.05f), P(0f, -0.05f));
                h.CloseFigure();
                RectangleF hb = h.GetBounds();
                using (LinearGradientBrush lb = new LinearGradientBrush(new RectangleF(hb.X, hb.Y - 1, hb.Width, hb.Height + 2), top, bot, LinearGradientMode.Vertical))
                    g.FillPath(lb, h);
            }

            // Складки на лбу и румянец — только когда мордочка достаточно крупная.
            if (u >= 26) {
                using (Pen wp = new Pen(Color.FromArgb(150, wrinkle), Math.Max(1f, u * 0.022f))) {
                    wp.StartCap = wp.EndCap = LineCap.Round;
                    float wy = deep ? 0.012f : 0f;   // задумался — складки глубже и ниже
                    foreach (float[] w in new float[][] { new float[] { -0.10f, -0.63f, 0.10f }, new float[] { -0.07f, -0.58f, 0.07f } }) {
                        PointF a = P(w[0], w[1] + wy), m = P(0f, w[1] - 0.025f + wy), b = P(w[2], w[1] + wy);
                        g.DrawBezier(wp, a, new PointF((a.X + m.X) / 2, m.Y), new PointF((m.X + b.X) / 2, m.Y), b);
                    }
                    PointF c1 = P(-0.20f, -0.60f), c2 = P(0.20f, -0.60f);
                    g.DrawArc(wp, c1.X - u * 0.04f, c1.Y - u * 0.02f, u * 0.08f, u * 0.05f, 200, 110);
                    g.DrawArc(wp, c2.X - u * 0.04f, c2.Y - u * 0.02f, u * 0.08f, u * 0.05f, 230, 110);
                }
                using (SolidBrush bl = new SolidBrush(Color.FromArgb(sleep ? 30 : 60, blush))) {
                    PointF l = P(-0.28f, -0.26f), rr = P(0.28f, -0.26f);
                    g.FillEllipse(bl, l.X - u * 0.07f, l.Y - u * 0.04f, u * 0.14f, u * 0.08f);
                    g.FillEllipse(bl, rr.X - u * 0.07f, rr.Y - u * 0.04f, u * 0.14f, u * 0.08f);
                }
            }

            // Мордочка: глаза, носик, ротик, усики.
            Color ink = Theme.Hex(0x3A2420);
            float fx = gx * 0.06f, fy = -gy * 0.045f;
            PointF eL = P(-0.16f + fx, -0.42f + fy), eR = P(0.16f + fx, -0.42f + fy);
            PointF ns = P(0f + fx * 0.8f, -0.31f + fy * 0.8f), mo = P(0f + fx * 0.8f, -0.24f + fy * 0.8f);
            bool blink = animate && ((t + seed * 1.3f) % 4.2f) < 0.14f;
            string eyes = sleep || stalled ? "closed" : err ? "x" : aha > 0.05f ? "happy" : deep ? "squint" : perm ? "round" : blink ? "closed" : "open";
            FlatFx.Eyes(g, eL, eR, mo.X, u, eyes, ink, 1.3f);   // у сфинксов глаза крупные
            float nw = u * 0.075f, nh = u * 0.05f;
            using (GraphicsPath np = new GraphicsPath()) {
                np.AddBezier(new PointF(ns.X - nw / 2, ns.Y - nh / 2), new PointF(ns.X - nw / 4, ns.Y - nh * 0.6f), new PointF(ns.X + nw / 4, ns.Y - nh * 0.6f), new PointF(ns.X + nw / 2, ns.Y - nh / 2));
                np.AddBezier(new PointF(ns.X + nw / 2, ns.Y - nh / 2), new PointF(ns.X + nw * 0.3f, ns.Y + nh * 0.2f), new PointF(ns.X + nw * 0.1f, ns.Y + nh / 2), new PointF(ns.X, ns.Y + nh / 2));
                np.AddBezier(new PointF(ns.X, ns.Y + nh / 2), new PointF(ns.X - nw * 0.1f, ns.Y + nh / 2), new PointF(ns.X - nw * 0.3f, ns.Y + nh * 0.2f), new PointF(ns.X - nw / 2, ns.Y - nh / 2));
                np.CloseFigure();
                using (SolidBrush nb = new SolidBrush(nose)) g.FillPath(nb, np);
            }
            string mouth = sleep || stalled ? "flat" : perm ? "o" : err ? "wavy" : aha > 0.05f || working ? "up" : "cat";
            FlatFx.Mouth(g, new PointF(mo.X, mo.Y + u * 0.012f), u, mouth, ink);
            if (u >= 34)
                using (Pen wh = new Pen(Color.FromArgb(sleep ? 60 : 110, ink), Math.Max(1f, u * 0.016f))) {
                    wh.StartCap = wh.EndCap = LineCap.Round;
                    for (int side = -1; side <= 1; side += 2)
                        for (int i = 0; i < 2; i++) {
                            PointF a = P(side * 0.27f + fx, -0.29f + i * 0.04f + fy), b = P(side * 0.44f + fx, -0.32f + i * 0.07f + fy);
                            g.DrawLine(wh, a, b);
                        }
                }

            // Искры у уха: «Ага!» и запрос разрешения.
            float spark = Math.Max(aha, perm ? 0.6f + 0.4f * (float)Math.Abs(Math.Sin(t * 4.2f + ph)) * A : 0f);
            FlatFx.Sparks(g, P(0.50f, -1.00f), P(0.60f, -1.12f), P(0.58f, -0.86f), P(0.72f, -0.92f), Theme.Hex(perm ? 0xFF9F0A : 0xF59A4E), spark, u);

            FlatFx.Agents(g, cx, by, u, mood != null ? mood.Agents : 0, t, animate, ph);

            // Ошибка — капелька пота у виска.
            if (err && u >= 18) {
                float k = (float)(((animate ? t * 0.5f : 0.3f) + seed * 0.13f) % 1.0);
                PointF d = P(0.40f, -0.70f + 0.18f * k);
                float dw = u * 0.06f, dh = u * 0.09f;
                using (GraphicsPath dp = new GraphicsPath()) {
                    dp.AddBezier(new PointF(d.X, d.Y - dh / 2), new PointF(d.X + dw * 0.2f, d.Y - dh * 0.1f), new PointF(d.X + dw / 2, d.Y + dh * 0.1f), new PointF(d.X + dw / 2, d.Y + dh * 0.22f));
                    dp.AddArc(d.X - dw / 2, d.Y - dh * 0.06f, dw, dw * 1.0f, 0, 180);
                    dp.AddBezier(new PointF(d.X - dw / 2, d.Y + dh * 0.22f), new PointF(d.X - dw / 2, d.Y + dh * 0.1f), new PointF(d.X - dw * 0.2f, d.Y - dh * 0.1f), new PointF(d.X, d.Y - dh / 2));
                    dp.CloseFigure();
                    using (SolidBrush db = new SolidBrush(Color.FromArgb((int)(220 * (1 - k * 0.6f)), 120, 190, 245))) g.FillPath(db, dp);
                }
            }

            string bubble = working && aha <= 0.05f ? "dots" : (sleep || stalled) ? "z" : null;
            FlatFx.Bubble(g, new PointF(cx + 0.66f * u, by - 1.0f * u * (sleep ? 0.78f : 1f)), u, bubble, t, A, deep, animate);
            g.SmoothingMode = sm;
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
            FlatFx.Shadow(g, cx, by, u, sleep);
            if (!sleep && u >= 16) FlatFx.Glow(g, P(0, -0.42f), 0.62f * u * (1f + 0.25f * aha), bot, (int)((perm ? 70 : 45) + 60 * aha));

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
            float fx = gx * 0.06f, fy = -gy * 0.045f;
            PointF eL = P(-0.135f + fx, -0.36f + fy), eR = P(0.135f + fx, -0.36f + fy), mo = P(0f + fx * 0.8f, -0.25f + fy * 0.8f);
            bool blink = animate && ((t + seed * 1.3f) % 4.2f) < 0.14f;
            string eyes = sleep || stalled ? "closed" : err ? "x" : aha > 0.05f ? "happy" : deep ? "squint" : perm ? "round" : blink ? "closed" : "open";
            FlatFx.Eyes(g, eL, eR, mo.X, u, eyes, ink, 1f);
            FlatFx.Mouth(g, mo, u, sleep || stalled ? "flat" : perm ? "o" : err ? "wavy" : aha > 0.05f || working ? "up" : "smile", ink);

            // Чёрточки-искры у макушки: «Ага!» и запрос разрешения.
            float spark = Math.Max(aha, perm ? 0.6f + 0.4f * (float)Math.Abs(Math.Sin(t * 4.2f + ph)) * A : 0f);
            FlatFx.Sparks(g, P(0.40f, -0.95f), P(0.50f, -1.08f), P(0.50f, -0.82f), P(0.64f, -0.90f), top, spark, u);

            // Агенты — искры кружат вокруг огонька.
            FlatFx.Agents(g, cx, by, u, mood != null ? mood.Agents : 0, t, animate, ph);

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
            FlatFx.Bubble(g, new PointF(cx + 0.66f * u, by - 0.98f * u * (sleep ? 0.75f : 1f)), u, bubble, t, A, deep, animate);
            g.SmoothingMode = sm;
        }
    }

    // Ещё плоские маскоты в рисунке огонька: котик в коробке, пингвин, белый котик, привидение и моти.
    // Поведение у всех общее (FlatState): работает — покачивается и смотрит по сторонам, облачко «…»;
    // «Ага!» — глаза «> <» и восклицание; задумался — прищур; ждёт решения — янтарный оттенок, глаза круглые;
    // ждёт ответа — дышит и моргает; ошибка — красноватый, глаза-крестики; остановился и спит — тусклый, «z».
    public static class FlatPals {
        static void Fill(Graphics g, GraphicsPath p, Color top, Color bot) {
            RectangleF b = p.GetBounds();
            if (b.Width <= 0 || b.Height <= 0) return;
            using (LinearGradientBrush lb = new LinearGradientBrush(new RectangleF(b.X, b.Y - 1, b.Width, b.Height + 2), top, bot, LinearGradientMode.Vertical))
                g.FillPath(lb, p);
        }

        static GraphicsPath Oval(PointF c, float rx, float ry) {
            GraphicsPath p = new GraphicsPath();
            p.AddEllipse(c.X - rx, c.Y - ry, rx * 2, ry * 2);
            return p;
        }

        static void FillOval(Graphics g, PointF c, float rx, float ry, Color top, Color bot) { using (GraphicsPath p = Oval(c, rx, ry)) Fill(g, p, top, bot); }

        static GraphicsPath Poly(params PointF[] pts) { GraphicsPath p = new GraphicsPath(); p.AddPolygon(pts); return p; }

        // Восклицание «!» — «Ага!» и запрос разрешения.
        static void Exclaim(Graphics g, PointF p, float u, Color c, float k) {
            if (k <= 0.05f || u < 16) return;
            using (Pen pen = new Pen(Color.FromArgb((int)(255 * FlatFx.Clamp(k, 0, 1)), c), Math.Max(1.6f, u * 0.06f))) {
                pen.StartCap = pen.EndCap = LineCap.Round;
                g.DrawLine(pen, p.X, p.Y, p.X - u * 0.02f, p.Y + u * 0.16f);
            }
            float d = Math.Max(1.6f, u * 0.06f);
            using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(255 * FlatFx.Clamp(k, 0, 1)), c))) g.FillEllipse(b, p.X - u * 0.03f - d / 2, p.Y + u * 0.23f - d / 2, d, d);
        }

        // Чёрточки движения («сюда смотрю», как на картинке привидения и моти).
        static void Marks(Graphics g, PointF a, float u, Color c, float k, float ang) {
            if (k <= 0.05f || u < 16) return;
            using (Pen pen = new Pen(Color.FromArgb((int)(255 * FlatFx.Clamp(k, 0, 1)), c), Math.Max(1.4f, u * 0.05f))) {
                pen.StartCap = pen.EndCap = LineCap.Round;
                for (int i = 0; i < 2; i++) {
                    float ox = a.X + i * u * 0.10f, oy = a.Y + i * u * 0.02f;
                    float dx = (float)Math.Sin(ang) * u * 0.13f, dy = (float)Math.Cos(ang) * u * 0.13f;
                    g.DrawLine(pen, ox, oy, ox - dx, oy - dy);
                }
            }
        }

        static void Blush(Graphics g, PointF l, PointF r, float u, Color c, int alpha) {
            if (u < 22) return;
            using (SolidBrush b = new SolidBrush(Color.FromArgb(alpha, c))) {
                g.FillEllipse(b, l.X - u * 0.06f, l.Y - u * 0.03f, u * 0.12f, u * 0.06f);
                g.FillEllipse(b, r.X - u * 0.06f, r.Y - u * 0.03f, u * 0.12f, u * 0.06f);
            }
        }

        static void Finish(Graphics g, FlatState s, CatMood mood, PointF bubble) {
            FlatFx.Agents(g, s.Cx, s.By, s.U, mood != null ? mood.Agents : 0, s.T, s.Animate, s.Ph);
            FlatFx.Bubble(g, bubble, s.U, s.Bubble, s.T, s.A, s.Deep, s.Animate);
        }

        // Котик в коробке: чёрная мордочка с ушками выглядывает из открытой картонной коробки, лапки на краю.
        // Ждёт решения — высовывается выше и над ним «!»; спит — прячется, видны ушки и закрытые глаза.
        public static void BoxCat(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + y * u); };
            float rise = s.Sleep ? 0.06f : s.Stalled ? 0.12f : s.Perm ? 0.36f + 0.03f * Math.Abs(s.Sin(4.2, 1)) * s.A : 0.26f + 0.08f * s.Aha;
            if (s.Working) rise += 0.02f * s.Sin(2.2, 1) * s.A;
            float hx = 0.05f * s.Gx + (s.Working ? 0.03f * s.Sin(0.8, 1) * s.A : 0f) + (s.Err ? 0.01f * s.Sin(38, 1) * s.A : 0f);
            float top = -0.46f, hcy = top - rise + 0.06f;
            Color fur = s.Tint(Theme.Hex(0x3E3E47), 0.6f), furBot = s.Tint(Theme.Hex(0x24242A), 0.6f);
            Color kraft = s.Tint(Theme.Hex(0xDDA468), 0.4f), kraftBot = s.Tint(Theme.Hex(0xC4874D), 0.4f), flap = s.Tint(Theme.Hex(0xC98F55), 0.4f), inside = s.Tint(Theme.Hex(0x7E5129), 0.4f);
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            FlatFx.Shadow(g, cx, by, u, s.Sleep);
            if (!s.Sleep && u >= 16) FlatFx.Glow(g, P(0, -0.45f), 0.6f * u, kraft, (int)((s.Perm ? 60 : 30) + 50 * s.Aha));

            // Внутренность и задние клапаны коробки.
            using (GraphicsPath p = Poly(P(-0.44f, top), P(0.44f, top), P(0.38f, top - 0.08f), P(-0.38f, top - 0.08f))) using (SolidBrush b = new SolidBrush(inside)) g.FillPath(b, p);
            using (GraphicsPath p = Poly(P(-0.38f, top - 0.08f), P(-0.04f, top - 0.08f), P(-0.10f, top - 0.30f), P(-0.50f, top - 0.24f))) Fill(g, p, Draw.Mix(flap, Color.White, 0.1f), flap);
            using (GraphicsPath p = Poly(P(0.38f, top - 0.08f), P(0.04f, top - 0.08f), P(0.10f, top - 0.30f), P(0.50f, top - 0.24f))) Fill(g, p, Draw.Mix(flap, Color.White, 0.1f), flap);

            // Мордочка с ушками.
            for (int side = -1; side <= 1; side += 2) {
                float tw = s.Err ? 0.06f : 0f;   // ошибка — ушки в стороны
                using (GraphicsPath ear = Poly(P(hx + side * 0.06f, hcy - 0.18f), P(hx + side * (0.27f + tw), hcy - 0.10f), P(hx + side * (0.23f + tw * 2), hcy - 0.40f + tw)))
                    Fill(g, ear, fur, furBot);
            }
            FillOval(g, P(hx, hcy), 0.30f * u, 0.25f * u, fur, furBot);
            Color eye = Theme.Hex(0xF4F4F6);
            float fx = s.Gx * 0.05f, fy = -s.Gy * 0.04f;
            FlatFx.Eyes(g, P(hx - 0.11f + fx, hcy + 0.0f + fy), P(hx + 0.11f + fx, hcy + 0.0f + fy), cx + (hx + fx) * u, u, s.Eyes, eye, 1.15f);
            FlatFx.Mouth(g, P(hx + fx * 0.8f, hcy + 0.10f + fy * 0.8f), u * 0.8f, s.Mouth("cat"), Theme.Hex(0xB9B9C2));

            // Лицевая сторона коробки и лапки на краю.
            using (GraphicsPath front = new GraphicsPath()) {
                RectangleF fr = new RectangleF(cx - 0.44f * u, by + top * u, 0.88f * u, -top * u);
                front.AddRectangle(fr);
                Fill(g, front, kraft, kraftBot);
            }
            if (u >= 20) using (Pen tape = new Pen(Color.FromArgb(70, 90, 55, 25), Math.Max(1f, u * 0.02f))) g.DrawLine(tape, P(-0.44f, top + 0.06f), P(0.44f, top + 0.06f));
            if (rise >= 0.2f) {
                FillOval(g, P(hx - 0.14f, top + 0.005f), 0.07f * u, 0.045f * u, fur, furBot);
                FillOval(g, P(hx + 0.14f, top + 0.005f), 0.07f * u, 0.045f * u, fur, furBot);
            }
            Exclaim(g, P(0.36f + hx, hcy - 0.50f), u, Theme.Hex(0xFFB340), s.Spark);
            Finish(g, s, mood, new PointF(cx + 0.64f * u, by - 1.0f * u));
            g.SmoothingMode = sm;
        }

        // Пингвин: тёмная спинка, белая грудка и мордочка, оранжевые клюв и лапки, крылышки. Работает —
        // переваливается; «Ага!» и запрос — крылышки вверх; ошибка — крылышки повисли; спит — глаза-дужки и «z».
        public static void Penguin(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            if (s.Perm) by -= Math.Abs(s.Sin(4.2, 1)) * u * 0.04f * s.A;
            float lean = 0.05f * s.Gx + (s.Working ? 0.07f * s.Sin(3.0, 1) * s.A : 0f) + (s.Sleep ? 0.03f * s.Sin(0.9, 1) * s.A : 0f);
            float breath = 1f + 0.018f * s.Sin(s.Working ? 2.4 : 1.6, 1) * s.A;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + (x - lean * y) * u, by + y * breath * u); };
            Color back = s.Tint(Theme.Hex(0x343B4A), 0.5f), backBot = s.Tint(Theme.Hex(0x1F2430), 0.5f);
            Color white = s.Tint(Theme.Hex(0xF8F8FA), 0.4f), whiteBot = s.Tint(Theme.Hex(0xE2E2E8), 0.4f);
            Color orange = s.Tint(Theme.Hex(0xF7A93B), 0.3f);
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            FlatFx.Shadow(g, cx, by, u, s.Sleep);
            if (!s.Sleep && u >= 16) FlatFx.Glow(g, P(0, -0.45f), 0.6f * u, Theme.Hex(0x8FA8D8), (int)((s.Perm ? 60 : 30) + 50 * s.Aha));

            // Крылышки (за телом): поднимаются при «Ага!» и запросе, повисают при ошибке, слегка машут в работе.
            float wing = s.Err ? -0.35f : s.Perm || s.Aha > 0.05f ? 0.9f + 0.2f * s.Aha : s.Working ? 0.15f + 0.1f * s.Sin(5, 1) * s.A : 0.05f;
            for (int side = -1; side <= 1; side += 2) {
                PointF pivot = P(side * 0.30f, -0.50f);
                GraphicsState st = g.Save();
                g.TranslateTransform(pivot.X, pivot.Y);
                g.RotateTransform(-side * (15f + 55f * wing));
                using (GraphicsPath w = Oval(new PointF(0, u * 0.17f), 0.075f * u, 0.19f * u)) Fill(g, w, back, backBot);
                g.Restore(st);
            }
            FillOval(g, P(0, -0.44f), 0.34f * u, 0.44f * u, back, backBot);
            // Белая грудка и мордочка.
            FillOval(g, P(0, -0.33f), 0.25f * u, 0.31f * u, white, whiteBot);
            FillOval(g, P(-0.09f, -0.58f), 0.14f * u, 0.13f * u, white, white);
            FillOval(g, P(0.09f, -0.58f), 0.14f * u, 0.13f * u, white, white);
            // Лапки.
            using (SolidBrush ob = new SolidBrush(orange)) {
                PointF l = P(-0.12f, -0.01f), rr = P(0.12f, -0.01f);
                g.FillEllipse(ob, l.X - 0.10f * u, l.Y - 0.04f * u, 0.2f * u, 0.08f * u);
                g.FillEllipse(ob, rr.X - 0.10f * u, rr.Y - 0.04f * u, 0.2f * u, 0.08f * u);
            }
            Color ink = Theme.Hex(0x2A2F3A);
            float fx = s.Gx * 0.05f, fy = -s.Gy * 0.04f;
            FlatFx.Eyes(g, P(-0.10f + fx, -0.60f + fy), P(0.10f + fx, -0.60f + fy), cx + fx * u, u, s.Eyes, ink, 0.95f);
            Blush(g, P(-0.17f + fx, -0.52f + fy), P(0.17f + fx, -0.52f + fy), u, Theme.Hex(0xF2A0A8), s.Sleep ? 40 : 90);
            // Клюв: открыт, когда ждёт решения или «Ага!».
            bool open = s.Perm || s.Aha > 0.05f;
            using (GraphicsPath bk = Poly(P(-0.055f + fx, -0.53f + fy), P(0.055f + fx, -0.53f + fy), P(fx, open ? -0.45f + fy : -0.47f + fy))) using (SolidBrush ob = new SolidBrush(orange)) g.FillPath(ob, bk);
            if (open) using (GraphicsPath bk = Poly(P(-0.04f + fx, -0.505f + fy), P(0.04f + fx, -0.505f + fy), P(fx, -0.475f + fy))) using (SolidBrush ob = new SolidBrush(Draw.Mix(orange, Color.Black, 0.25f))) g.FillPath(ob, bk);
            Exclaim(g, P(0.36f, -1.02f), u, Theme.Hex(0xFFB340), s.Spark);
            Finish(g, s, mood, new PointF(cx + 0.60f * u, by - 0.98f * u * (s.Sleep ? 0.85f : 1f)));
            g.SmoothingMode = sm;
        }

        // Белый котик: сидит, розовые ушки, «ω»-ротик, хвост виляет; задумался — голова набок.
        public static void Kitty(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            if (s.Perm) by -= Math.Abs(s.Sin(4.2, 1)) * u * 0.035f * s.A;
            float tilt = 0.05f * s.Gx + (s.Deep ? 0.08f : 0f) + (s.Perm ? 0.06f : 0f) + (s.Sleep ? 0.03f * s.Sin(0.9, 1) * s.A : 0f);
            float breath = 1f + 0.02f * s.Sin(s.Working ? 2.4 : 1.6, 1) * s.A;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + y * breath * u); };
            Func<float, float, PointF> H = delegate (float x, float y) { float hy = y + 0.60f; return new PointF(cx + (x + tilt * (hy) * -1.2f + tilt * 0.3f) * u, by + y * breath * u); };
            Color fur = s.Tint(Theme.Hex(0xFCFAF8), 0.5f), furBot = s.Tint(Theme.Hex(0xE8E0DC), 0.5f), pink = s.Tint(Theme.Hex(0xF5B5C2), 0.3f);
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            FlatFx.Shadow(g, cx, by, u, s.Sleep);
            if (!s.Sleep && u >= 16) FlatFx.Glow(g, P(0, -0.45f), 0.6f * u, Theme.Hex(0xF5C9C9), (int)((s.Perm ? 60 : 30) + 50 * s.Aha));

            // Хвост: виляет, сильнее при «Ага!», висит при ошибке.
            float sw = s.Err ? -0.6f : (s.Working ? 0.5f : 0.25f) * s.Sin(s.Aha > 0.05f ? 9 : 2.0, 1) * s.A + 0.6f * s.Aha;
            using (Pen tail = new Pen(furBot, Math.Max(2f, u * 0.075f))) {
                tail.StartCap = tail.EndCap = LineCap.Round;
                g.DrawBezier(tail, P(0.20f, -0.06f), P(0.42f, -0.06f), P(0.46f + 0.05f * sw, -0.26f), P(0.36f + 0.10f * sw, -0.42f - 0.06f * sw));
            }
            // Тело и лапки.
            FillOval(g, P(0, -0.22f), 0.27f * u, 0.23f * u, fur, furBot);
            FillOval(g, P(-0.10f, -0.03f), 0.08f * u, 0.045f * u, fur, fur);
            FillOval(g, P(0.10f, -0.03f), 0.08f * u, 0.045f * u, fur, fur);
            // Голова с ушками.
            for (int side = -1; side <= 1; side += 2) {
                float droop = s.Err ? 0.07f : 0f;
                using (GraphicsPath ear = Poly(H(side * 0.08f, -0.80f), H(side * (0.30f + droop), -0.70f), H(side * (0.25f + droop * 1.5f), -0.98f + droop))) Fill(g, ear, fur, fur);
                using (GraphicsPath ie = Poly(H(side * 0.13f, -0.79f), H(side * (0.26f + droop), -0.72f), H(side * (0.235f + droop * 1.5f), -0.91f + droop))) using (SolidBrush b = new SolidBrush(pink)) g.FillPath(b, ie);
            }
            FillOval(g, H(0, -0.62f), 0.31f * u, 0.25f * u, fur, Draw.Mix(fur, furBot, 0.6f));
            Color ink = Theme.Hex(0x3A2E2C);
            float fx = s.Gx * 0.05f, fy = -s.Gy * 0.04f;
            FlatFx.Eyes(g, H(-0.12f + fx, -0.63f + fy), H(0.12f + fx, -0.63f + fy), cx + fx * u, u, s.Eyes, ink, 0.9f);
            Blush(g, H(-0.19f + fx, -0.56f + fy), H(0.19f + fx, -0.56f + fy), u, Theme.Hex(0xF4A0AE), s.Sleep ? 40 : 100);
            if (u >= 20) { PointF n = H(fx, -0.575f + fy); using (SolidBrush nb = new SolidBrush(pink)) g.FillEllipse(nb, n.X - u * 0.022f, n.Y - u * 0.015f, u * 0.044f, u * 0.03f); }
            FlatFx.Mouth(g, H(fx * 0.8f, -0.535f + fy * 0.8f), u * 0.9f, s.Mouth("cat"), ink);
            Exclaim(g, H(0.36f, -1.04f), u, Theme.Hex(0xFFB340), s.Spark);
            Finish(g, s, mood, new PointF(cx + 0.62f * u, by - 1.0f * u * (s.Sleep ? 0.85f : 1f)));
            g.SmoothingMode = sm;
        }

        // Привидение: парит, волнистый край колышется, чёрточки движения слева; спит — полупрозрачное.
        public static void Ghost(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            float hover = (s.Sleep ? 0.01f : s.Working || s.Perm ? 0.045f : 0.03f) * s.Sin(s.Perm ? 4.2 : 1.8, 1) * s.A + 0.04f;
            float lean = 0.06f * s.Gx + (s.Working ? 0.04f * s.Sin(1.1, 1) * s.A : 0f);
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + (x - lean * y) * u, by + (y - hover) * u); };
            int alpha = s.Sleep ? 170 : s.Stalled ? 210 : 255;
            Color body = Color.FromArgb(alpha, s.Tint(Theme.Hex(0xF4F1FF), 0.5f)), bodyBot = Color.FromArgb(alpha, s.Tint(Theme.Hex(0xD6CFF3), 0.5f));
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush sh = new SolidBrush(Color.FromArgb(s.Sleep ? 40 : 70, 0, 0, 0)))
                g.FillEllipse(sh, cx - 0.32f * u, by - 0.03f * u, 0.64f * u, 0.06f * u);
            if (!s.Sleep && u >= 16) FlatFx.Glow(g, P(0, -0.45f), 0.62f * u, Theme.Hex(0xB8AEF0), (int)((s.Perm ? 70 : 40) + 60 * s.Aha));
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddBezier(P(-0.36f, -0.12f), P(-0.38f, -0.40f), P(-0.36f, -0.88f), P(0f, -0.88f));
                p.AddBezier(P(0f, -0.88f), P(0.36f, -0.88f), P(0.40f, -0.40f), P(0.38f, -0.12f));
                // Волнистый край: три «язычка», колышутся.
                float w = 0.03f * s.Sin(3.0, 1) * s.A;
                p.AddBezier(P(0.38f, -0.12f), P(0.36f, -0.02f + w), P(0.24f, 0.00f + w), P(0.20f, -0.08f));
                p.AddBezier(P(0.20f, -0.08f), P(0.14f, -0.02f - w), P(0.04f, 0.00f - w), P(-0.02f, -0.08f));
                p.AddBezier(P(-0.02f, -0.08f), P(-0.08f, -0.02f + w), P(-0.20f, 0.00f + w), P(-0.24f, -0.08f));
                p.AddBezier(P(-0.24f, -0.08f), P(-0.28f, -0.02f - w), P(-0.36f, -0.04f - w), P(-0.36f, -0.12f));
                p.CloseFigure();
                Fill(g, p, body, bodyBot);
            }
            Color ink = Theme.Hex(0x2B2738);
            float fx = s.Gx * 0.06f, fy = -s.Gy * 0.045f;
            FlatFx.Eyes(g, P(-0.11f + fx, -0.52f + fy), P(0.11f + fx, -0.52f + fy), cx + fx * u, u, s.Eyes, ink, 1.1f);
            Blush(g, P(-0.20f + fx, -0.44f + fy), P(0.20f + fx, -0.44f + fy), u, Theme.Hex(0xE7A6D6), s.Sleep ? 30 : 80);
            if (!s.Waiting || s.Aha > 0.05f) FlatFx.Mouth(g, P(fx * 0.8f, -0.42f + fy * 0.8f), u * 0.9f, s.Mouth("smile"), ink);
            float mk = Math.Max(s.Spark, s.Working ? 0.75f : 0f);
            Marks(g, P(-0.46f, -0.98f), u, Theme.Hex(s.Perm ? 0xFFB340 : 0x7D74D0), mk, 0.5f + 0.08f * s.Sin(3, 1) * s.A);
            Finish(g, s, mood, new PointF(cx + 0.62f * u, by - 1.04f * u));
            g.SmoothingMode = sm;
        }

        // Моти: круглый белый комочек, сплющивается и подпрыгивает; две чёрточки над ним — «антенны» настроения.
        public static void Mochi(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            FlatState s = FlatState.Of(r, state, t, seed, animate, mood);
            float u = s.U, cx = s.Cx, by = s.By;
            float hop = s.Perm ? Math.Abs(s.Sin(4.2, 1)) * s.A : s.Aha;
            float squash = 1f + (s.Working ? 0.04f * s.Sin(2.6, 1) : 0.025f * s.Sin(1.5, 1)) * s.A;
            float rx = 0.42f * (1f - 0.05f * hop) / squash, ry = 0.33f * (1f + 0.08f * hop) * squash;
            if (s.Sleep) { rx *= 1.06f; ry *= 0.9f; }
            float lift = hop * 0.06f;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + x * u, by + (y - lift) * u); };
            Color body = s.Tint(Theme.Hex(0xFCFCFD), 0.5f), bodyBot = s.Tint(Theme.Hex(0xE2E2E8), 0.5f);
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            FlatFx.Shadow(g, cx, by, u, s.Sleep);
            if (!s.Sleep && u >= 16) FlatFx.Glow(g, P(0, -0.34f), 0.58f * u, Theme.Hex(0xD9DDF0), (int)((s.Perm ? 60 : 30) + 50 * s.Aha));
            float cyy = -ry + 0.0f;   // низ комочка — на земле
            using (GraphicsPath p = new GraphicsPath()) {
                // Сверху круглый, снизу чуть приплюснутый.
                p.AddBezier(P(-rx, cyy), P(-rx, cyy - ry * 0.75f), P(-rx * 0.55f, cyy - ry), P(0, cyy - ry));
                p.AddBezier(P(0, cyy - ry), P(rx * 0.55f, cyy - ry), P(rx, cyy - ry * 0.75f), P(rx, cyy));
                p.AddBezier(P(rx, cyy), P(rx, cyy + ry * 0.7f), P(rx * 0.6f, cyy + ry), P(0, cyy + ry));
                p.AddBezier(P(0, cyy + ry), P(-rx * 0.6f, cyy + ry), P(-rx, cyy + ry * 0.7f), P(-rx, cyy));
                p.CloseFigure();
                Fill(g, p, body, bodyBot);
            }
            Color ink = Theme.Hex(0x26262C);
            float fx = s.Gx * 0.06f, fy = -s.Gy * 0.04f;
            FlatFx.Eyes(g, P(-0.12f + fx, cyy + 0.02f + fy), P(0.12f + fx, cyy + 0.02f + fy), cx + fx * u, u, s.Eyes, ink, 1.0f);
            Blush(g, P(-0.22f + fx, cyy + 0.10f + fy), P(0.22f + fx, cyy + 0.10f + fy), u, Theme.Hex(0xF2B0BC), s.Sleep ? 30 : 70);
            if (!s.Waiting || s.Aha > 0.05f) FlatFx.Mouth(g, P(fx * 0.8f, cyy + 0.10f + fy * 0.8f), u * 0.85f, s.Mouth("smile"), ink);
            // «Антенны» над головой: серые, при «Ага!» и запросе — янтарные и торчком, при ошибке — красные.
            float mk = Math.Max(s.Spark, s.Sleep || s.Stalled ? 0.35f : 0.8f);
            Color mc = s.Perm || s.Aha > 0.05f ? Theme.Hex(0xFFB340) : s.Err ? Theme.Hex(0xEF5A48) : Theme.Hex(0x8E8E9A);
            Marks(g, P(-0.20f, cyy - ry - 0.06f), u, mc, mk, 0.45f + (s.Aha > 0.05f ? -0.2f : 0f) + 0.06f * s.Sin(2.2, 1) * s.A);
            Finish(g, s, mood, new PointF(cx + 0.62f * u, by - 0.92f * u));
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
