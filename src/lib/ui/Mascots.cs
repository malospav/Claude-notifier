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
    public sealed class CatMood {
        public float AhaAge = -1f;
        public bool Deep;
        public int Agents;
        public bool HasLook;
        public float LookX, LookY;
        public float LookW = 1f;          // 0..1 — насколько маскот сейчас смотрит на курсор (плавно растёт и спадает)
        // Взаимодействие с главным маскотом (шторка): гладят (0..1), зевает, обиделся (подкинули слишком сильно),
        // скучает (давно не заходили).
        public bool Play;                  // это главный маскот шторки: рисовать реакции поверх (MascotPlay)
        public float Pet;
        public bool Yawn, Grumpy, Sad;
        public float PokeAge = -1f;        // секунд назад «тыкнули» — фирменное движение по требованию
        public float Startle;              // 1 → 0: проснулся от щелчка («!», подскок)
        public float Wave;                 // 0..1: машет лапкой (любит вас)
        // Реакция на событие сеанса: joy — задача готова (прыгает от радости), panic — ошибка (хватается за голову),
        // nervous — лимит почти исчерпан (нервничает); ReactAge — секунд с события (реакция длится 2,5 с).
        public string React;
        public float ReactAge = -1f;
        public bool Reacting { get { return React != null && ReactAge >= 0 && ReactAge < 2.5f; } }
        // Движение всей фигуры (шторка считает пружинами): сжатие/растяжение по вертикали (1 — как есть; объём
        // сохраняется — по горизонтали 1/√), запаздывание верха (сдвиг верха вбок в долях высоты), подъём (доли высоты),
        // наклон (градусы) — вокруг точки опоры внизу. Brow — брови вверх (0..1), Cross — глаза к носу (задумался).
        public float SquashY = 1f, Shear, Lift, Lean, Brow;
        public bool Cross;
        public string EyesOverride, MouthOverride;   // мимика сценок (потягивается, чешет ухо, дремлет)
        public float Dust = -1f;                     // секунд с приземления — облачко пыли у ног
        public string Outfit;                        // наряд по заказу (окно «Анимации»); null — по дате и времени
        public float Friend;                         // дружба 0..100: открывает украшения (MascotStyle)
        public string DayMood;                       // настроение дня: cheer — празднует; tea — сочувствует (много ошибок)
        public bool HasMotion { get { return Math.Abs(SquashY - 1f) > 0.002f || Math.Abs(Shear) > 0.002f || Math.Abs(Lift) > 0.001f || Math.Abs(Lean) > 0.05f; } }
    }

    // Выбранный маскот шторки (настройка «Маскот»): все векторные. Прежний объёмный «sphynx» — теперь плоский сфинкс.
    public static class Mascot {
        static volatile string kind = "flatsphynx";
        public static string Kind { get { return kind; } set { kind = Normalize(value); } }
        public static readonly string[] Kinds = { "flatsphynx", "flame", "boxcat", "penguin", "kitty", "ghost", "mochi",
            "dino", "frog", "reaper", "onigiri", "cupcat", "fox", "leaf", "bee" };
        public static string Normalize(string v) { return Array.IndexOf(Kinds, v) >= 0 ? v : "flatsphynx"; }
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
            kind = Normalize(kind);
            if (mood == null) { PaintBody(g, r, kind, state, t, seed, animate, null); return; }
            bool play = mood.Play || mood.Reacting;
            FlatFx.Brow = mood.Brow; FlatFx.Cross = mood.Cross;
            GraphicsState gs = null;
            float sq = mood.SquashY * (play ? MascotPlay.ReactSquash(mood) : 1f);   // прыжки радости и испуга — со сжатием
            if (FlatFx.GroundM != null) FlatFx.GroundM.Dispose();
            FlatFx.GroundM = g.Transform; FlatFx.GroundY = r.Bottom - r.Height * 0.07f;   // земля — до движения фигуры
            if (mood.HasMotion || Math.Abs(sq - 1f) > 0.002f) { gs = g.Save(); MascotMotion.Apply(g, r, sq, mood.Shear, mood.Lift, mood.Lean); }
            // Главный маскот: «тык» запускает фирменное движение, реакции — поверх фигуры.
            MascotSig.Poke = play && animate ? mood.PokeAge : -1f;
            HeadAnchor.Clear(); HeadAnchor.Wanted = play || mood.Dust >= 0;
            try { PaintBody(g, play ? MascotPlay.Body(r, kind, mood, t) : r, kind, state, t, seed, animate, mood); }
            finally {
                MascotSig.Poke = -1f; FlatFx.Brow = 0; FlatFx.Cross = false; if (gs != null) g.Restore(gs);
                if (FlatFx.GroundM != null) { FlatFx.GroundM.Dispose(); FlatFx.GroundM = null; }
            }
            try { if (play || mood.Dust >= 0) MascotPlay.Overlay(g, r, kind, mood, t); }
            finally { HeadAnchor.Clear(); HeadAnchor.Wanted = false; }
        }

        static void PaintBody(Graphics g, RectangleF r, string kind, string state, float t, int seed, bool animate, CatMood mood) {
            switch (kind) {
                case "flame": Flame.Paint(g, r, state, t, seed, animate, mood); break;
                case "boxcat": FlatPals.BoxCat(g, r, state, t, seed, animate, mood); break;
                case "penguin": FlatPals.Penguin(g, r, state, t, seed, animate, mood); break;
                case "kitty": FlatPals.Kitty(g, r, state, t, seed, animate, mood); break;
                case "ghost": FlatPals.Ghost(g, r, state, t, seed, animate, mood); break;
                case "mochi": FlatPals.Mochi(g, r, state, t, seed, animate, mood); break;
                case "dino": FlatPals.Dino(g, r, state, t, seed, animate, mood); break;
                case "frog": FlatPals.Frog(g, r, state, t, seed, animate, mood); break;
                case "reaper": FlatPals.Reaper(g, r, state, t, seed, animate, mood); break;
                case "onigiri": FlatPals.Onigiri(g, r, state, t, seed, animate, mood); break;
                case "cupcat": FlatPals.CupCat(g, r, state, t, seed, animate, mood); break;
                case "fox": FlatPals.Fox(g, r, state, t, seed, animate, mood); break;
                case "leaf": FlatPals.Leaf(g, r, state, t, seed, animate, mood); break;
                case "bee": FlatPals.Bee(g, r, state, t, seed, animate, mood); break;
                default: FlatSphynx.Paint(g, r, state, t, seed, animate, mood); break;
            }
        }
    }

    // Общее у плоских маскотов (огонёк, плоский сфинкс): тень, свечение, глаза, ротик, искры «Ага!»,
    // огоньки агентов и облачко «…» / «z» — чтобы оба выглядели и вели себя одинаково.
    // Где у маскота голова — запоминает сам маскот, рисуя её (вместе с его наклонами, прыжками и сжатием):
    // точка макушки, полуширина головы и высота глаз, а также преобразование Graphics в этот момент. Колпак,
    // гирлянда, «!», лапки на голове и прочее рисуются в этом же преобразовании — двигаются вместе с головой.
    public static class HeadAnchor {
        [ThreadStatic] static bool has;
        [ThreadStatic] static System.Drawing.Drawing2D.Matrix m;
        [ThreadStatic] static PointF top;
        [ThreadStatic] static float halfW, faceY;
        public static bool Has { get { return has; } }
        public static PointF Top { get { return top; } }
        public static float HalfW { get { return halfW; } }
        public static float FaceY { get { return faceY; } }
        public static System.Drawing.Drawing2D.Matrix Transform { get { return m; } }
        [ThreadStatic] public static bool Wanted;   // поверх этого маскота что-то рисуется — запоминать
        public static void Set(Graphics g, PointF headTop, float halfWidth, float eyesY) {
            if (!Wanted) return;
            if (m != null) m.Dispose();
            m = g.Transform; top = headTop; halfW = halfWidth; faceY = eyesY; has = true;
        }
        public static void Clear() { has = false; if (m != null) { m.Dispose(); m = null; } }
    }

    // Для тестов: живое моргание (FlatFx внутренний).
    public static class FlatFxProbe {
        public static bool Blink(float t, int seed) { return FlatFx.Blink(t, seed, true); }
        public static bool BlinkStill(float t, int seed) { return FlatFx.Blink(t, seed, false); }
        public static string BlinkEye(float t, int seed) { return FlatFx.BlinkEye(t, seed, true); }
    }

    static class FlatFx {
        public static float Clamp(float v, float a, float b) { return Math.Max(a, Math.Min(b, v)); }

        // Брови и «глаза к носу» на время рисования одной фигуры (ставит Mascot.PaintKind из настроения).
        [ThreadStatic] public static float Brow;
        [ThreadStatic] public static bool Cross;

        static float Hash(long n, int salt) {
            unchecked {
                uint x = (uint)(n * 2654435761L) ^ (uint)(salt * 40503);
                x ^= x >> 13; x *= 0x5bd1e995; x ^= x >> 15;
                return (x & 0xffff) / 65535f;
            }
        }

        // Моргание живое: промежутки 3,5–6 с, длина 0,09–0,18 с, иногда двойное. Без анимации — не моргает.
        public static bool Blink(float t, int seed, bool animate) { return BlinkPhase(t, seed, animate) >= 0; }

        // Где мы внутри моргания: 0..1 (веки опускаются — закрыты — поднимаются), -1 — не моргает.
        public static float BlinkPhase(float t, int seed, bool animate) {
            if (!animate) return -1f;
            double tt = t + seed * 1.3;
            long n = (long)Math.Floor(tt / 5.0);
            for (long c = n - 1; c <= n; c++) {
                double start = c * 5.0 + Hash(c, seed) * 2.5;
                double len = 0.09 + 0.09 * Hash(c, seed + 7);
                double local = tt - start;
                if (local >= 0 && local < len) return (float)(local / len);
                if (Hash(c, seed + 13) < 0.25f && local >= len + 0.11 && local < 2 * len + 0.11) return (float)((local - len - 0.11) / len);   // двойное
            }
            return -1f;
        }

        // Глаза на моргании: края — прищур (веки на полпути), середина — закрыты; null — не моргает.
        public static string BlinkEye(float t, int seed, bool animate) {
            float p = BlinkPhase(t, seed, animate);
            if (p < 0) return null;
            return p < 0.25f || p > 0.75f ? "squint" : "closed";
        }

        // Брови над глазами: дужки, поднимаются на k (удивился, «Ага!»).
        static void Brows(Graphics g, PointF e, float u, float size, float k, Color ink, bool left) {
            if (k < 0.05f || u < 14) return;
            float w = u * 0.085f * size, y = e.Y - u * (0.075f + 0.04f * k) * size;
            using (Pen p = new Pen(Color.FromArgb((int)(255 * Math.Min(1f, k * 1.5f)), ink), Math.Max(1f, u * 0.03f))) {
                p.StartCap = p.EndCap = LineCap.Round;
                float tilt = (left ? -1 : 1) * u * 0.012f * k;
                g.DrawBezier(p, new PointF(e.X - w / 2, y + u * 0.012f + tilt), new PointF(e.X - w / 4, y - u * 0.012f), new PointF(e.X + w / 4, y - u * 0.012f), new PointF(e.X + w / 2, y + u * 0.012f - tilt));
            }
        }

        public static void Shadow(Graphics g, float cx, float by, float u, bool sleep) {
            GroundShadow(g, cx, by, 0.42f * u, 0.035f * u, sleep ? 50 : 90);
        }

        // Земля под маскотом (ставит Mascot.PaintKind): тень остаётся на ней, когда маскот подпрыгивает, летит
        // или выпрыгивает, — и тем меньше и бледнее, чем он выше.
        [ThreadStatic] public static System.Drawing.Drawing2D.Matrix GroundM;
        [ThreadStatic] public static float GroundY;

        public static void GroundShadow(Graphics g, float cx, float by, float rx, float ry, int alpha) {
            if (GroundM == null) {
                using (SolidBrush sh = new SolidBrush(Color.FromArgb(alpha, 0, 0, 0))) g.FillEllipse(sh, cx - rx, by - ry, rx * 2, ry * 2);
                return;
            }
            PointF[] p = { new PointF(cx, by) };
            using (Matrix cur = g.Transform) cur.TransformPoints(p);
            using (Matrix inv = GroundM.Clone()) { if (!inv.IsInvertible) return; inv.Invert(); inv.TransformPoints(p); }
            float lift = Math.Max(0f, GroundY - p[0].Y);
            float k = 1f / (1f + lift / Math.Max(1f, rx) * 1.6f);
            GraphicsState st = g.Save();
            try {
                g.Transform = GroundM;
                using (SolidBrush sh = new SolidBrush(Color.FromArgb(Math.Max(0, (int)(alpha * k)), 0, 0, 0)))
                    g.FillEllipse(sh, p[0].X - rx * (0.55f + 0.45f * k), GroundY - ry * (0.6f + 0.4f * k), rx * 2 * (0.55f + 0.45f * k), ry * 2 * (0.6f + 0.4f * k));
            } finally { g.Restore(st); }
        }

        // Объём поверх заливки: мягкий блик сверху слева, затенение у нижнего края и тонкий контур чуть темнее
        // цвета (как у мягкой игрушки). Прозрачность берётся из цвета (у привидения тело полупрозрачное).
        public static void Volume(Graphics g, GraphicsPath p, Color baseColor) { Volume(g, p, baseColor, true); }
        public static void Volume(Graphics g, GraphicsPath p, Color baseColor, bool rim) {
            RectangleF b = p.GetBounds();
            if (b.Width < 6 || b.Height < 6) return;
            int a = baseColor.A;
            float m = Math.Min(b.Width, b.Height);
            GraphicsState st = g.Save();
            try {
                g.SetClip(p, CombineMode.Intersect);
                // Блик: эллипс у верхнего левого края, от полупрозрачного белого к прозрачному.
                using (GraphicsPath hp = new GraphicsPath()) {
                    RectangleF hr = new RectangleF(b.X - b.Width * 0.05f, b.Y - b.Height * 0.08f, b.Width * 0.75f, b.Height * 0.62f);
                    hp.AddEllipse(hr);
                    using (PathGradientBrush pg = new PathGradientBrush(hp)) {
                        pg.CenterPoint = new PointF(hr.X + hr.Width * 0.42f, hr.Y + hr.Height * 0.38f);
                        pg.CenterColor = Color.FromArgb(a * 70 / 255, 255, 255, 255);
                        pg.SurroundColors = new Color[] { Color.FromArgb(0, 255, 255, 255) };
                        g.FillPath(pg, hp);
                    }
                }
                // Тень снизу: прозрачно до двух третей высоты, у края — темнее.
                RectangleF sr = new RectangleF(b.X, b.Y + b.Height * 0.55f, b.Width, b.Height * 0.46f);
                using (LinearGradientBrush lb = new LinearGradientBrush(new RectangleF(sr.X, sr.Y - 1, sr.Width, sr.Height + 2), Color.FromArgb(0, 0, 0, 0), Color.FromArgb(a * 46 / 255, 20, 10, 30), LinearGradientMode.Vertical))
                    g.FillRectangle(lb, sr);
            } finally { g.Restore(st); }
            if (!rim) return;
            // Контур: тот же цвет, темнее, тонко.
            Color rc = Draw.Mix(baseColor, Color.Black, 0.35f);
            using (Pen pen = new Pen(Color.FromArgb(a * 120 / 255, rc), Math.Max(0.8f, m * 0.025f))) { pen.LineJoin = LineJoin.Round; g.DrawPath(pen, p); }
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
                foreach (PointF e0 in new PointF[] { eL, eR }) {
                    PointF e = e0;
                    bool left = e.X < midX;
                    if (Cross && (eyes == "open" || eyes == "round")) e = new PointF(e.X + (left ? 1 : -1) * u * 0.018f * size, e.Y);   // глаза к носу
                    if (eyes != "closed" && eyes != "x") Brows(g, e0, u, size, Brow, ink, left);
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
                        case "smile": {   // «^ ^» — довольные, блаженство
                            g.DrawArc(ip, e.X - es * 0.55f, e.Y - es * 0.30f, es * 1.1f, es * 0.95f, 200, 140);
                            break;
                        }
                        case "wide": {    // широко раскрыты, два блика — «Ага!», удивился
                            float w = u * 0.08f * size, h = u * 0.10f * size;
                            g.FillEllipse(ib, e.X - w / 2, e.Y - h / 2, w, h);
                            if (u >= 20) using (SolidBrush hl = new SolidBrush(Color.FromArgb(235, 255, 255, 255))) {
                                g.FillEllipse(hl, e.X - w * 0.05f, e.Y - h * 0.40f, w * 0.42f, w * 0.42f);
                                g.FillEllipse(hl, e.X - w * 0.32f, e.Y + h * 0.10f, w * 0.20f, w * 0.20f);
                            }
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
                c = new PointF(c.X, c.Y + (animate ? (float)Math.Sin(t * 1.7) * u * 0.012f : 0f));   // облачко чуть покачивается
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
                // Сон: «z Z Z» — буквы по очереди вылетают, растут, уплывают вверх-вправо и тают.
                using (StringFormat sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center }) {
                    for (int i = 0; i < 3; i++) {
                        float ph = animate ? (float)(((t * 0.42 + i / 3.0) % 1.0 + 1.0) % 1.0) : 0.15f + 0.3f * i;
                        float alpha = (float)Math.Sin(Math.PI * ph);
                        if (alpha < 0.05f) continue;
                        float size = Math.Max(5f, u * (0.13f + 0.12f * ph));
                        PointF zp = new PointF(c.X - u * 0.06f + ph * u * 0.18f + (float)Math.Sin(ph * 6 + i) * u * 0.02f, c.Y + u * 0.06f - ph * u * 0.28f);
                        using (Font f = new Font("Segoe UI", size, FontStyle.Italic | FontStyle.Bold, GraphicsUnit.Pixel))
                        using (SolidBrush fb = new SolidBrush(Color.FromArgb((int)(220 * alpha), 0xA9, 0xA9, 0xB4)))
                            g.DrawString("z", f, fb, zp, sf);
                    }
                }
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
            s.Eyes = s.Sleep || s.Stalled ? "closed" : s.Err ? "x" : s.Aha > 0.05f ? "wide" : s.Deep ? "squint" : s.Perm ? "round" : FlatFx.BlinkEye(t, seed, animate) ?? "open";
            s.Bubble = s.Working && s.Aha <= 0.05f ? "dots" : (s.Sleep || s.Stalled) ? "z" : null;
            s.Spark = Math.Max(s.Aha, s.Perm ? 0.6f + 0.4f * (float)Math.Abs(Math.Sin(t * 4.2f + s.Ph)) * s.A : 0f);
            // Взаимодействие: гладят — жмурится от удовольствия; зевает; обиделся; скучает.
            if (mood != null && (!s.Sleep || mood.Reacting || mood.EyesOverride != null)) { s.Eyes = MoodEyes(mood, s.Eyes); s.MouthOverride = MoodMouth(mood, null); }
            return s;
        }

        // Глаза и ротик от взаимодействия (общие для всех маскотов, в т.ч. со своей мордочкой): гладят — жмурится
        // и улыбается; зевает; обиделся — прищур и кривой рот; скучает — глаза закрыты, ротик ровный.
        public static string MoodEyes(CatMood m, string eyes) {
            if (m == null) return eyes;
            if (m.Reacting) return m.React == "joy" || m.React == "wave" ? "smile" : m.React == "panic" ? "x" : m.React == "notice" ? "wide" : "round";
            if (m.Pet > 0.3f) return "smile";
            if (m.EyesOverride != null) return m.EyesOverride;
            if (m.Yawn) return "squint";
            if (m.Grumpy) return "squint";
            if (m.Sad) return "closed";
            return eyes;
        }
        public static string MoodMouth(CatMood m, string mouth) {
            if (m == null) return mouth;
            if (m.Reacting) return m.React == "joy" || m.React == "wave" ? "up" : m.React == "panic" || m.React == "notice" ? "o" : "wavy";
            if (m.Pet > 0.3f) return "up";
            if (m.MouthOverride != null) return m.MouthOverride;
            if (m.Yawn) return "o";
            if (m.Grumpy) return "wavy";
            if (m.Sad) return "flat";
            return mouth;
        }

        public string MouthOverride;
        // Ротик по статусу; Idle — свой у маскота, когда он просто ждёт ответа.
        public string Mouth(string idle) { if (MouthOverride != null) return MouthOverride; return Sleep || Stalled ? "flat" : Perm ? "o" : Err ? "wavy" : Aha > 0.05f || Working ? "up" : idle; }

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
            // Фирменное: «Зевок» — потягивается вверх, уши назад, глаза зажмурены, широкий розовый ротик.
            float yawn = MascotSig.At(t, seed, 9f, 2.2f, 0.4f, animate, state);
            float yk = MascotSig.Plateau(yawn, 0.3f);
            // Ждёт — медленно моргает («кошачий поцелуй»): глаза плавно закрываются и открываются.
            float slow = waiting && animate && yawn < 0 ? (float)(((t * 0.2 + ph) % 1.0)) : -1f;
            bool slowBlink = slow >= 0 && slow < 0.14f;
            // Работает — уши-локаторы: по очереди поворачиваются, будто прислушивается.
            float radar = working && animate && yawn < 0 ? (float)Math.Sin(t * 2.6 + ph) : 0f;
            float breath = 1f + (sleep ? 0.025f * S(0.9, 1) : 0.018f * S(working ? 2.4 : 1.6, 1)) * A;
            breath *= 1f + 0.05f * aha + 0.06f * yk;

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
                float rd = side * radar;   // локатор: одно ухо вперёд-в сторону, другое прижимается
                tx += 0.07f * Math.Max(0f, rd) + 0.10f * yk; ty += 0.05f * Math.Max(0f, -rd) + 0.10f * yk;
                PointF bIn = P(side * 0.10f, -0.70f), bOut = P(side * 0.42f, -0.44f), tip = P(side * tx, ty);
                using (GraphicsPath ear = new GraphicsPath()) {
                    ear.AddBezier(bIn, P(side * 0.14f, -0.86f), P(side * (tx - 0.10f), ty + 0.02f), tip);
                    ear.AddBezier(tip, P(side * (tx + 0.10f), ty + 0.14f), P(side * 0.50f, -0.60f), bOut);
                    ear.CloseFigure();
                    RectangleF eb = ear.GetBounds();
                    using (LinearGradientBrush lb = new LinearGradientBrush(new RectangleF(eb.X, eb.Y - 1, eb.Width, eb.Height + 2), top, bot, LinearGradientMode.Vertical))
                        g.FillPath(lb, ear);
                    FlatFx.Volume(g, ear, bot);
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
                FlatFx.Volume(g, h, bot);
            }
            HeadAnchor.Set(g, P(0f, -0.74f), 0.30f * u, P(0f, -0.42f).Y);   // украшения и эффекты — к голове

            // Подушечки усов: два светлых бугорка под носиком, на них — точки-корни усов.
            if (u >= 22) {
                float mx = gx * 0.048f, my = -gy * 0.036f;
                using (SolidBrush pb = new SolidBrush(Color.FromArgb(70, Draw.Mix(top, Color.White, 0.5f)))) {
                    foreach (float sd in new float[] { -1f, 1f }) { PointF c = P(sd * 0.075f + mx, -0.26f + my); g.FillEllipse(pb, c.X - u * 0.065f, c.Y - u * 0.04f, u * 0.13f, u * 0.08f); }
                }
                if (u >= 34) using (SolidBrush db = new SolidBrush(Color.FromArgb(110, wrinkle))) {
                    foreach (float sd in new float[] { -1f, 1f }) for (int i = 0; i < 3; i++) {
                        PointF d = P(sd * (0.05f + 0.035f * i) + mx, -0.265f + 0.018f * (i % 2) + my);
                        float dr = Math.Max(0.6f, u * 0.008f); g.FillEllipse(db, d.X - dr, d.Y - dr, dr * 2, dr * 2);
                    }
                }
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
            string eyes = sleep || stalled ? "closed" : err ? "x" : aha > 0.05f ? "wide" : deep ? "squint" : perm ? "round" : FlatFx.BlinkEye(t, seed, animate) ?? "open";
            if (yk > 0.3f) eyes = yk > 0.7f ? "closed" : "squint";   // зевает — жмурится
            else if (slowBlink) eyes = slow > 0.03f && slow < 0.11f ? "closed" : "squint";
            if (!sleep) eyes = FlatState.MoodEyes(mood, eyes);
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
            if (!sleep) mouth = FlatState.MoodMouth(mood, mouth);
            if (yk > 0.3f) {
                using (SolidBrush mb = new SolidBrush(Theme.Hex(0xC9566A))) { float mw = u * 0.10f * yk, mh = u * 0.12f * yk; g.FillEllipse(mb, mo.X - mw / 2, mo.Y + u * 0.01f - mh * 0.3f, mw, mh); }
                using (SolidBrush tb = new SolidBrush(Theme.Hex(0xF2A0AE))) { float tw = u * 0.06f * yk, th = u * 0.04f * yk; g.FillEllipse(tb, mo.X - tw / 2, mo.Y + u * 0.01f + u * 0.12f * yk * 0.45f, tw, th); }
            }
            else FlatFx.Mouth(g, new PointF(mo.X, mo.Y + u * 0.012f), u, mouth, ink);
            // Медленное моргание — румянец ярче.
            if (slowBlink && u >= 26) using (SolidBrush bl = new SolidBrush(Color.FromArgb(70, blush))) {
                PointF l = P(-0.28f, -0.26f), rr = P(0.28f, -0.26f);
                g.FillEllipse(bl, l.X - u * 0.08f, l.Y - u * 0.045f, u * 0.16f, u * 0.09f);
                g.FillEllipse(bl, rr.X - u * 0.08f, rr.Y - u * 0.045f, u * 0.16f, u * 0.09f);
            }
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
            // Фирменное: «Вспышка» — пламя взмывает, разбрасывает кольцо искр.
            float flare = MascotSig.At(t, seed, 7f, 1.3f, 0.6f, animate, state);
            float fk = MascotSig.Bell(flare);
            height *= 1f + 0.28f * fk;
            // Ждёт — пламя мягко покачивается из стороны в сторону.
            if (waiting && animate) lean += 0.06f * (float)Math.Sin(t * 1.1 + ph);

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
                FlatFx.Volume(g, o, bot, false);
                HeadAnchor.Set(g, P(0.02f, -0.92f), 0.21f * u, P(0f, -0.36f).Y);
                // Тёплая кайма по краю пламени.
                if (u >= 20) using (Pen ep = new Pen(Color.FromArgb(90, 255, 214, 140), Math.Max(1f, u * 0.018f))) { ep.LineJoin = LineJoin.Round; g.DrawPath(ep, o); }
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
            string eyes = sleep || stalled ? "closed" : err ? "x" : aha > 0.05f ? "wide" : deep ? "squint" : perm ? "round" : FlatFx.BlinkEye(t, seed, animate) ?? "open";
            if (!sleep) eyes = FlatState.MoodEyes(mood, eyes);
            FlatFx.Eyes(g, eL, eR, mo.X, u, eyes, ink, 1f);
            string fmouth = sleep || stalled ? "flat" : perm ? "o" : err ? "wavy" : aha > 0.05f || working ? "up" : "smile";
            if (!sleep) fmouth = FlatState.MoodMouth(mood, fmouth);
            FlatFx.Mouth(g, mo, u, fmouth, ink);

            // Чёрточки-искры у макушки: «Ага!» и запрос разрешения.
            float spark = Math.Max(aha, perm ? 0.6f + 0.4f * (float)Math.Abs(Math.Sin(t * 4.2f + ph)) * A : 0f);
            FlatFx.Sparks(g, P(0.40f, -0.95f), P(0.50f, -1.08f), P(0.50f, -0.82f), P(0.64f, -0.90f), top, spark, u);

            // Агенты — искры кружат вокруг огонька.
            FlatFx.Agents(g, cx, by, u, mood != null ? mood.Agents : 0, t, animate, ph);

            if (animate && u >= 18) {
                // Работает — из макушки летят искры, как в кузнице: поднимаются, петляют и гаснут.
                if (working) for (int i = 0; i < 5; i++) {
                    float k = (float)(((t * 0.9 + i * 0.21 + ph) % 1.0));
                    float x = cx + u * (0.03f + 0.18f * (float)Math.Sin(i * 2.1 + k * 4) * k);
                    float y = by - u * hs * (0.95f + 0.55f * k);
                    float rr = u * 0.022f * (1 - k * 0.6f);
                    using (SolidBrush sb = new SolidBrush(Color.FromArgb((int)(230 * (1 - k)), 0xFF, (int)(0xC8 - 0x50 * k), 0x5A))) g.FillEllipse(sb, x - rr, y - rr, rr * 2, rr * 2);
                }
                // Ждёт — рядом кружит светлячок.
                if (waiting) {
                    float a = (float)(t * 0.8 + ph);
                    PointF fly = new PointF(cx + (float)Math.Cos(a) * 0.55f * u, by - (0.55f + 0.18f * (float)Math.Sin(a * 1.6)) * u);
                    float pulse = 0.6f + 0.4f * (float)Math.Abs(Math.Sin(t * 3.0));
                    FlatFx.Glow(g, fly, u * 0.10f, Theme.Hex(0xFFE27A), (int)(150 * pulse));
                    using (SolidBrush fb = new SolidBrush(Theme.Hex(0xFFF2B8))) g.FillEllipse(fb, fly.X - u * 0.018f, fly.Y - u * 0.018f, u * 0.036f, u * 0.036f);
                }
                // Вспышка — кольцо искр разлетается от середины.
                if (flare >= 0) for (int i = 0; i < 10; i++) {
                    double a = i * Math.PI / 5 + ph;
                    float k = flare;
                    float x = cx + (float)Math.Cos(a) * (0.20f + 0.45f * k) * u;
                    float y = by - 0.50f * u - (float)Math.Sin(a) * (0.20f + 0.40f * k) * u + 0.15f * k * k * u;
                    float rr = u * 0.025f * (1 - k * 0.5f);
                    using (SolidBrush sb = new SolidBrush(Color.FromArgb((int)(240 * (1 - k)), 0xFF, 0xD6, 0x6A))) g.FillEllipse(sb, x - rr, y - rr, rr * 2, rr * 2);
                }
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
            FlatFx.Bubble(g, new PointF(cx + 0.66f * u, by - 0.98f * u * (sleep ? 0.75f : 1f)), u, bubble, t, A, deep, animate);
            g.SmoothingMode = sm;
        }
    }

    // Ещё плоские маскоты в рисунке огонька: котик в коробке, пингвин, белый котик, привидение и моти.
    // Поведение у всех общее (FlatState): работает — покачивается и смотрит по сторонам, облачко «…»;
    // «Ага!» — глаза «> <» и восклицание; задумался — прищур; ждёт решения — янтарный оттенок, глаза круглые;
    // ждёт ответа — дышит и моргает; ошибка — красноватый, глаза-крестики; остановился и спит — тусклый, «z».
    public static partial class FlatPals {
        static void Fill(Graphics g, GraphicsPath p, Color top, Color bot) {
            RectangleF b = p.GetBounds();
            if (b.Width <= 0 || b.Height <= 0) return;
            using (LinearGradientBrush lb = new LinearGradientBrush(new RectangleF(b.X, b.Y - 1, b.Width, b.Height + 2), top, bot, LinearGradientMode.Vertical))
                g.FillPath(lb, p);
            FlatFx.Volume(g, p, bot);
        }

        // Заливка без объёма (мелкие и плоские детали: щёчки, узоры, полоски).
        static void FillFlat(Graphics g, GraphicsPath p, Color top, Color bot) {
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
            // Фирменное: «Прятки» — нырнул в коробку (видны только ушки), коробка качнулась, выпрыгнул повыше.
            float hide = MascotSig.At(t, seed, 8f, 2.2f, 1.3f, animate, state);
            float wob = 0f;
            if (hide >= 0) {
                float down = MascotSig.Span(hide, 0f, 0.25f), up = MascotSig.Span(hide, 0.55f, 0.72f), settle = MascotSig.Span(hide, 0.8f, 1f);
                rise = rise * (1 - down) + 0.03f * down;                                   // спрятался
                if (up > 0) rise = 0.03f + (0.30f - 0.03f) * up - (0.30f - 0.26f) * settle;   // выскочил и осел
                wob = (hide > 0.25f && hide < 0.55f) ? 3.5f * (float)Math.Sin((hide - 0.25f) * 50) * (1 - (hide - 0.25f) / 0.3f) : 0f;
            }
            // Работает — стучит лапками по краю, как по клавиатуре; ждёт — водит глазами из стороны в сторону.
            float tapL = s.Working && animate && hide < 0 ? Math.Max(0f, (float)Math.Sin(t * 9 + s.Ph)) : 0f;
            float tapR = s.Working && animate && hide < 0 ? Math.Max(0f, -(float)Math.Sin(t * 9 + s.Ph)) : 0f;
            float peek = s.Waiting && animate && hide < 0 ? (float)Math.Tanh(2.5 * Math.Sin(t * 0.9 + s.Ph)) : 0f;
            float hx = 0.05f * s.Gx + (s.Working ? 0.03f * s.Sin(0.8, 1) * s.A : 0f) + (s.Err ? 0.01f * s.Sin(38, 1) * s.A : 0f);
            float top = -0.46f, hcy = top - rise + 0.06f;
            Color fur = s.Tint(Theme.Hex(0x3E3E47), 0.6f), furBot = s.Tint(Theme.Hex(0x24242A), 0.6f);
            Color kraft = s.Tint(Theme.Hex(0xDDA468), 0.4f), kraftBot = s.Tint(Theme.Hex(0xC4874D), 0.4f), flap = s.Tint(Theme.Hex(0xC98F55), 0.4f), inside = s.Tint(Theme.Hex(0x7E5129), 0.4f);
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            FlatFx.Shadow(g, cx, by, u, s.Sleep);
            if (!s.Sleep && u >= 16) FlatFx.Glow(g, P(0, -0.45f), 0.6f * u, kraft, (int)((s.Perm ? 60 : 30) + 50 * s.Aha));
            GraphicsState bst = Rigid(g, cx, by, wob, 0f);   // коробка качается целиком (вместе с котиком)

            // Внутренность и задние клапаны коробки.
            using (GraphicsPath p = Poly(P(-0.44f, top), P(0.44f, top), P(0.38f, top - 0.08f), P(-0.38f, top - 0.08f))) using (SolidBrush b = new SolidBrush(inside)) g.FillPath(b, p);
            using (GraphicsPath p = Poly(P(-0.38f, top - 0.08f), P(-0.04f, top - 0.08f), P(-0.10f, top - 0.30f), P(-0.50f, top - 0.24f))) Fill(g, p, Draw.Mix(flap, Color.White, 0.1f), flap);
            using (GraphicsPath p = Poly(P(0.38f, top - 0.08f), P(0.04f, top - 0.08f), P(0.10f, top - 0.30f), P(0.50f, top - 0.24f))) Fill(g, p, Draw.Mix(flap, Color.White, 0.1f), flap);

            // Мордочка с ушками.
            for (int side = -1; side <= 1; side += 2) {
                float tw = s.Err ? 0.06f : 0f;   // ошибка — ушки в стороны
                using (GraphicsPath ear = Poly(P(hx + side * 0.06f, hcy - 0.18f), P(hx + side * (0.27f + tw), hcy - 0.10f), P(hx + side * (0.23f + tw * 2), hcy - 0.40f + tw)))
                    Fill(g, ear, fur, furBot);
                if (u >= 18) using (GraphicsPath ie = Poly(P(hx + side * 0.11f, hcy - 0.18f), P(hx + side * (0.23f + tw), hcy - 0.13f), P(hx + side * (0.215f + tw * 2), hcy - 0.33f + tw)))
                    using (SolidBrush ib = new SolidBrush(s.Tint(Theme.Hex(0x7A5466), 0.4f))) g.FillPath(ib, ie);
            }
            FillOval(g, P(hx, hcy), 0.30f * u, 0.25f * u, fur, furBot);
            HeadAnchor.Set(g, P(hx, hcy - 0.23f), 0.25f * u, P(hx, hcy).Y);   // украшения и эффекты — к голове
            Color eye = Theme.Hex(0xF4F4F6);
            float fx = s.Gx * 0.05f + 0.06f * peek, fy = -s.Gy * 0.04f + (tapL + tapR > 0 ? 0.03f : 0f);   // за работой смотрит вниз, на лапки
            bool popped = hide > 0.55f && hide < 0.85f;
            FlatFx.Eyes(g, P(hx - 0.11f + fx, hcy + 0.0f + fy), P(hx + 0.11f + fx, hcy + 0.0f + fy), cx + (hx + fx) * u, u, popped ? "wide" : s.Eyes, eye, 1.15f);
            FlatFx.Mouth(g, P(hx + fx * 0.8f, hcy + 0.10f + fy * 0.8f), u * 0.8f, popped ? "o" : s.Mouth("cat"), Theme.Hex(0xB9B9C2));

            // Лицевая сторона коробки и лапки на краю.
            using (GraphicsPath front = new GraphicsPath()) {
                RectangleF fr = new RectangleF(cx - 0.44f * u, by + top * u, 0.88f * u, -top * u);
                front.AddRectangle(fr);
                Fill(g, front, kraft, kraftBot);
            }
            if (u >= 20) {
                // Правая сторона коробки в тени, светлая гофрокромка сверху, полоса скотча посередине.
                using (SolidBrush side = new SolidBrush(Color.FromArgb(45, 60, 30, 10))) g.FillRectangle(side, cx + 0.24f * u, by + top * u, 0.20f * u, -top * u);
                using (Pen rim = new Pen(Color.FromArgb(150, 245, 210, 160), Math.Max(1f, u * 0.022f))) g.DrawLine(rim, P(-0.44f, top + 0.012f), P(0.44f, top + 0.012f));
                using (SolidBrush tape = new SolidBrush(Color.FromArgb(70, 250, 235, 200))) g.FillRectangle(tape, cx - 0.06f * u, by + top * u, 0.12f * u, -top * u);
                using (Pen tl = new Pen(Color.FromArgb(60, 120, 80, 40), Math.Max(1f, u * 0.012f))) {
                    g.DrawLine(tl, P(-0.06f, top), P(-0.06f, 0f)); g.DrawLine(tl, P(0.06f, top), P(0.06f, 0f));
                }
                // Значок «верх» на коробке — две стрелочки.
                if (u >= 34) using (Pen ar = new Pen(Color.FromArgb(90, 110, 70, 35), Math.Max(1f, u * 0.016f))) {
                    ar.StartCap = ar.EndCap = LineCap.Round;
                    for (int i = 0; i < 2; i++) {
                        PointF a0 = P(-0.30f + i * 0.08f, -0.10f), a1 = P(-0.30f + i * 0.08f, -0.24f);
                        g.DrawLine(ar, a0, a1);
                        g.DrawLines(ar, new PointF[] { new PointF(a1.X - u * 0.025f, a1.Y + u * 0.03f), a1, new PointF(a1.X + u * 0.025f, a1.Y + u * 0.03f) });
                    }
                }
            }
            if (rise >= 0.2f) {
                foreach (float[] pw in new float[][] { new float[] { -0.14f, tapL }, new float[] { 0.14f, tapR } }) {
                    PointF pc = P(hx + pw[0], top + 0.005f - 0.035f * pw[1]);
                    FillOval(g, pc, 0.07f * u, 0.045f * u, fur, furBot);
                    // Пальчики: две бороздки.
                    if (u >= 24) using (Pen tp = new Pen(Color.FromArgb(150, 20, 20, 24), Math.Max(1f, u * 0.012f))) {
                        g.DrawLine(tp, pc.X - u * 0.022f, pc.Y + u * 0.005f, pc.X - u * 0.022f, pc.Y + u * 0.035f);
                        g.DrawLine(tp, pc.X + u * 0.022f, pc.Y + u * 0.005f, pc.X + u * 0.022f, pc.Y + u * 0.035f);
                    }
                }
            }
            Exclaim(g, P(0.36f + hx, hcy - 0.50f), u, Theme.Hex(0xFFB340), s.Spark);
            g.Restore(bst);
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
            // Фирменное: «Танец» — прыжки из стороны в сторону, крылышки вверх и машут, глаза «> <».
            float dance = MascotSig.At(t, seed, 8f, 2.4f, 2.1f, animate, state);
            float dk = MascotSig.Plateau(dance, 0.1f);
            float hopD = dance < 0 ? 0f : (float)Math.Abs(Math.Sin(Math.PI * dance * 4)) * dk;
            by -= hopD * u * 0.08f;
            // Работает — топает на месте: лапки по очереди, тело переваливается.
            float step = s.Working && animate && dance < 0 ? (float)Math.Sin(t * 6.0 + s.Ph) : 0f;
            // Ждёт — смотрит вверх на снежинки.
            float lookUp = s.Waiting && animate ? 0.35f + 0.25f * (float)Math.Sin(t * 0.5 + s.Ph) : 0f;
            float lean = 0.05f * s.Gx + (s.Working ? 0.07f * step * s.A : 0f) + (s.Sleep ? 0.03f * s.Sin(0.9, 1) * s.A : 0f)
                + (dance >= 0 ? 0.12f * (float)Math.Sin(Math.PI * dance * 4) * dk : 0f);
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
            if (dance >= 0) wing = wing * (1 - dk) + (0.95f + 0.25f * (float)Math.Sin(t * 22)) * dk;
            for (int side = -1; side <= 1; side += 2) {
                PointF pivot = P(side * 0.30f, -0.50f);
                GraphicsState st = g.Save();
                g.TranslateTransform(pivot.X, pivot.Y);
                // За работой крылышки гребут по очереди.
                float paddle = step != 0f ? 0.25f * Math.Max(0f, side * step) : 0f;
                g.RotateTransform(-side * (15f + 55f * (wing + paddle)));
                using (GraphicsPath w = Oval(new PointF(0, u * 0.17f), 0.075f * u, 0.19f * u)) Fill(g, w, back, backBot);
                g.Restore(st);
            }
            // Хохолок: три пёрышка на макушке (за головой).
            if (u >= 18) using (Pen tuft = new Pen(back, Math.Max(1.2f, u * 0.04f))) {
                tuft.StartCap = tuft.EndCap = LineCap.Round;
                for (int i = -1; i <= 1; i++) { PointF a = P(i * 0.04f, -0.84f); g.DrawBezier(tuft, a, P(i * 0.06f, -0.92f), P(i * 0.10f + 0.03f, -0.95f), P(i * 0.12f + 0.05f, -0.92f)); }
            }
            FillOval(g, P(0, -0.44f), 0.34f * u, 0.44f * u, back, backBot);
            // Белая грудка и мордочка (без контура — это окрас, а не отдельные части).
            using (GraphicsPath bp = new GraphicsPath()) {
                PointF bc = P(0, -0.33f); bp.AddEllipse(bc.X - 0.25f * u, bc.Y - 0.31f * u, 0.5f * u, 0.62f * u);
                PointF f1 = P(-0.09f, -0.58f), f2 = P(0.09f, -0.58f);
                bp.AddEllipse(f1.X - 0.14f * u, f1.Y - 0.13f * u, 0.28f * u, 0.26f * u);
                bp.AddEllipse(f2.X - 0.14f * u, f2.Y - 0.13f * u, 0.28f * u, 0.26f * u);
                bp.FillMode = FillMode.Winding;
                FillFlat(g, bp, white, whiteBot);
            }
            HeadAnchor.Set(g, P(0, -0.86f), 0.26f * u, P(0, -0.60f).Y);   // украшения и эффекты — к голове
            // Лапки.
            using (SolidBrush ob = new SolidBrush(orange))
            using (Pen toe = new Pen(Color.FromArgb(140, Draw.Mix(orange, Color.Black, 0.35f)), Math.Max(1f, u * 0.012f))) {
                PointF l = P(-0.12f, -0.01f - 0.05f * Math.Max(0f, step)), rr = P(0.12f, -0.01f - 0.05f * Math.Max(0f, -step));
                foreach (PointF f in new PointF[] { l, rr }) {
                    g.FillEllipse(ob, f.X - 0.10f * u, f.Y - 0.04f * u, 0.2f * u, 0.08f * u);
                    if (u >= 26) { g.DrawLine(toe, f.X - 0.035f * u, f.Y, f.X - 0.035f * u, f.Y + 0.035f * u); g.DrawLine(toe, f.X + 0.035f * u, f.Y, f.X + 0.035f * u, f.Y + 0.035f * u); }
                }
            }
            Color ink = Theme.Hex(0x2A2F3A);
            float fx = s.Gx * 0.05f, fy = -s.Gy * 0.04f - 0.04f * lookUp;
            FlatFx.Eyes(g, P(-0.10f + fx, -0.60f + fy), P(0.10f + fx, -0.60f + fy), cx + fx * u, u, dk > 0.3f ? "smile" : s.Eyes, ink, 0.95f);
            Blush(g, P(-0.17f + fx, -0.52f + fy), P(0.17f + fx, -0.52f + fy), u, Theme.Hex(0xF2A0A8), s.Sleep ? 40 : 90);
            // Клюв: открыт, когда ждёт решения или «Ага!».
            bool open = s.Perm || s.Aha > 0.05f;
            using (GraphicsPath bk = Poly(P(-0.055f + fx, -0.53f + fy), P(0.055f + fx, -0.53f + fy), P(fx, open ? -0.45f + fy : -0.47f + fy))) using (SolidBrush ob = new SolidBrush(orange)) g.FillPath(ob, bk);
            if (open) using (GraphicsPath bk = Poly(P(-0.04f + fx, -0.505f + fy), P(0.04f + fx, -0.505f + fy), P(fx, -0.475f + fy))) using (SolidBrush ob = new SolidBrush(Draw.Mix(orange, Color.Black, 0.25f))) g.FillPath(ob, bk);
            Exclaim(g, P(0.36f, -1.02f), u, Theme.Hex(0xFFB340), s.Spark);
            // Ждёт — вокруг падает снежок.
            if (s.Waiting && animate && u >= 20) for (int i = 0; i < 5; i++) {
                float k = (float)(((t * 0.22 + i * 0.2 + s.Ph * 0.1) % 1.0));
                float x = cx + (-0.50f + i * 0.25f + 0.05f * (float)Math.Sin(t * 1.3 + i * 2)) * u;
                float y = by - (1.05f - 1.0f * k) * u;
                float rr = u * (0.018f + 0.006f * (i % 2));
                using (SolidBrush fb = new SolidBrush(Color.FromArgb((int)(220 * MascotSig.Bell(k)), 0xF2, 0xF6, 0xFF))) g.FillEllipse(fb, x - rr, y - rr, rr * 2, rr * 2);
            }
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
                // Кончик хвоста потемнее — хвост читается на белом теле.
                PointF tt = P(0.36f + 0.10f * sw, -0.42f - 0.06f * sw);
                float tr = Math.Max(1f, u * 0.04f);
                using (SolidBrush tb = new SolidBrush(Draw.Mix(furBot, Theme.Hex(0xC9B8B2), 0.6f))) g.FillEllipse(tb, tt.X - tr, tt.Y - tr, tr * 2, tr * 2);
            }
            // Фирменное: «Умывается» — правая лапка к щеке, трёт кругами, глаза закрыты, язычок.
            float wash = MascotSig.At(t, seed, 9f, 2.6f, 2.6f, animate, state);
            float wk = MascotSig.Plateau(wash, 0.18f);
            // Работает — играет с клубком: лапка бьёт, клубок откатывается и возвращается.
            float bat = s.Working && animate && wash < 0 ? (float)Math.Pow(Math.Max(0, Math.Sin(t * 3.0 + s.Ph)), 3) : 0f;
            float roll = s.Working && animate ? 0.05f * (float)Math.Sin(t * 3.0 + s.Ph - 0.9) : 0f;
            // Ждёт — месит лапками: левая и правая по очереди, прищур и мурлыканье.
            float knead = s.Waiting && animate && wash < 0 ? (float)Math.Sin(t * 3.4 + s.Ph) : 0f;
            if (s.Working && animate && u >= 18) {
                PointF bc = P(0.52f + roll, -0.09f);
                float br = 0.095f * u;
                using (SolidBrush yb = new SolidBrush(s.Tint(Theme.Hex(0xF4A6C0), 0.3f))) g.FillEllipse(yb, bc.X - br, bc.Y - br, br * 2, br * 2);
                if (u >= 26) using (Pen yp = new Pen(Color.FromArgb(150, 0xC9, 0x6E, 0x92), Math.Max(1f, u * 0.014f))) {
                    float rot = (float)(roll * 60);
                    for (int i = 0; i < 3; i++) g.DrawArc(yp, bc.X - br * (0.9f - i * 0.25f), bc.Y - br * 0.9f, br * 2 * (0.9f - i * 0.25f), br * 1.8f, 60 + rot * 10, 120);
                    g.DrawBezier(yp, bc.X + br * 0.7f, bc.Y + br * 0.7f, bc.X + br * 1.3f, bc.Y + br * 1.0f, bc.X + br * 1.1f, bc.Y + br * 0.3f, bc.X + br * 1.6f, bc.Y + br * 0.8f);
                }
            }
            // Тело и лапки.
            FillOval(g, P(0, -0.22f), 0.27f * u, 0.23f * u, fur, furBot);
            FillOval(g, P(-0.10f, -0.03f - 0.035f * Math.Max(0f, knead)), 0.08f * u, 0.045f * u, fur, fur);
            if (wk < 0.05f) {
                // Правая лапка: за работой тянется к клубку, в ожидании месит.
                PointF rp0 = P(0.10f + 0.24f * bat, -0.03f - 0.06f * bat - 0.035f * Math.Max(0f, -knead));
                FillOval(g, rp0, 0.08f * u, 0.045f * u, fur, fur);
            }
            // Голова с ушками.
            for (int side = -1; side <= 1; side += 2) {
                float droop = s.Err ? 0.07f : 0f;
                using (GraphicsPath ear = Poly(H(side * 0.08f, -0.80f), H(side * (0.30f + droop), -0.70f), H(side * (0.25f + droop * 1.5f), -0.98f + droop))) Fill(g, ear, fur, fur);
                using (GraphicsPath ie = Poly(H(side * 0.13f, -0.79f), H(side * (0.26f + droop), -0.72f), H(side * (0.235f + droop * 1.5f), -0.91f + droop))) using (SolidBrush b = new SolidBrush(pink)) g.FillPath(b, ie);
            }
            // Ошейник с колокольчиком (под головой); колокольчик звякает — качается в работе и при «Ага!».
            if (u >= 18) {
                Color red = s.Tint(Theme.Hex(0xE0525E), 0.3f), gold = s.Tint(Theme.Hex(0xF5C04A), 0.3f);
                using (Pen col = new Pen(red, Math.Max(1.5f, u * 0.05f))) {
                    col.StartCap = col.EndCap = LineCap.Round;
                    g.DrawBezier(col, P(-0.21f, -0.43f), P(-0.10f, -0.36f), P(0.10f, -0.36f), P(0.21f, -0.43f));
                }
                float swing = (s.Working ? 12f * s.Sin(6, 1) : 0f) * s.A + 18f * s.Aha;
                PointF bc = P(0f, -0.355f);
                GraphicsState bs = g.Save();
                g.TranslateTransform(bc.X, bc.Y); g.RotateTransform(swing);
                float br = 0.05f * u;
                using (GraphicsPath bell = Oval(new PointF(0, br * 0.9f), br, br)) Fill(g, bell, Draw.Mix(gold, Color.White, 0.3f), gold);
                if (u >= 28) using (Pen sl = new Pen(Draw.Mix(gold, Color.Black, 0.45f), Math.Max(1f, u * 0.012f))) { g.DrawLine(sl, -br * 0.5f, br * 1.1f, br * 0.5f, br * 1.1f); g.FillEllipse(Brushes.Black, -br * 0.15f, br * 1.3f, br * 0.3f, br * 0.3f); }
                g.Restore(bs);
            }
            FillOval(g, H(0, -0.62f), 0.31f * u, 0.25f * u, fur, Draw.Mix(fur, furBot, 0.6f));
            HeadAnchor.Set(g, H(0, -0.85f), 0.25f * u, H(0, -0.63f).Y);   // украшения и эффекты — к голове
            Color ink = Theme.Hex(0x3A2E2C);
            float fx = s.Gx * 0.05f + 0.04f * (s.Working && animate ? 1f : 0f), fy = -s.Gy * 0.04f + (s.Working && animate ? 0.03f : 0f);   // за работой смотрит на клубок
            string keyes = wk > 0.3f ? "closed" : knead != 0f ? "squint" : s.Eyes;
            FlatFx.Eyes(g, H(-0.12f + fx, -0.63f + fy), H(0.12f + fx, -0.63f + fy), cx + fx * u, u, keyes, ink, 0.9f);
            Blush(g, H(-0.19f + fx, -0.56f + fy), H(0.19f + fx, -0.56f + fy), u, Theme.Hex(0xF4A0AE), s.Sleep ? 40 : (int)(100 + 50 * wk));
            if (u >= 20) { PointF n = H(fx, -0.575f + fy); using (SolidBrush nb = new SolidBrush(pink)) g.FillEllipse(nb, n.X - u * 0.022f, n.Y - u * 0.015f, u * 0.044f, u * 0.03f); }
            FlatFx.Mouth(g, H(fx * 0.8f, -0.535f + fy * 0.8f), u * 0.9f, s.Mouth("cat"), ink);
            if (wk >= 0.05f) {
                // Лапка у щеки трёт кругами; язычок высовывается.
                float rub = (float)Math.Sin(t * 12);
                PointF wp = H(0.10f + (0.12f + 0.02f * rub) * wk, -0.03f + (-0.50f + 0.02f * (float)Math.Cos(t * 12)) * wk);
                // Лапка видна на белой мордочке: контур и розовые подушечки.
                using (GraphicsPath pw = Oval(wp, 0.08f * u, 0.065f * u)) {
                    Fill(g, pw, fur, furBot);
                    using (Pen op = new Pen(Theme.Hex(0xCFC3BE), Math.Max(1f, u * 0.02f))) g.DrawPath(op, pw);
                }
                if (u >= 22) using (SolidBrush pb = new SolidBrush(pink)) {
                    g.FillEllipse(pb, wp.X - u * 0.025f, wp.Y - u * 0.005f, u * 0.05f, u * 0.03f);
                    for (int i = -1; i <= 1; i++) g.FillEllipse(pb, wp.X + i * u * 0.03f - u * 0.012f, wp.Y - u * 0.04f, u * 0.024f, u * 0.02f);
                }
                if (rub > 0 && u >= 20) using (SolidBrush tb = new SolidBrush(Theme.Hex(0xEE8FA2))) { PointF m = H(fx * 0.8f, -0.515f + fy); g.FillEllipse(tb, m.X - u * 0.018f, m.Y, u * 0.036f, u * 0.03f); }
            }
            // Мурлыканье в ожидании: волнистые чёрточки сбоку.
            if (knead != 0f && u >= 22) using (Pen pp = new Pen(Color.FromArgb((int)(150 * Math.Abs(knead)), 0xF4, 0xA0, 0xAE), Math.Max(1.2f, u * 0.025f))) {
                pp.StartCap = pp.EndCap = LineCap.Round;
                for (int i = 0; i < 2; i++) { PointF a = H(-0.40f - i * 0.04f, -0.66f + i * 0.08f); g.DrawBezier(pp, a.X, a.Y, a.X - u * 0.03f, a.Y - u * 0.03f, a.X - u * 0.05f, a.Y + u * 0.03f, a.X - u * 0.08f, a.Y); }
            }
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
            // Фирменное: «Бу!» — оборот вокруг себя, потом раздувается, ручки в стороны, рот «О».
            float boo = MascotSig.At(t, seed, 8f, 1.8f, 3.3f, animate, state);
            float spinX = boo >= 0 && boo < 0.45f ? (float)Math.Cos(2 * Math.PI * MascotSig.Smooth(boo / 0.45f)) : 1f;
            float puffUp = boo >= 0.45f ? MascotSig.Plateau((boo - 0.45f) / 0.55f, 0.25f) : 0f;
            // Работает — летает по кругу и оставляет полупрозрачные следы; ждёт — играет в прятки: тает и проявляется.
            float ox = 0f, oy = 0f;
            if (s.Working && animate && boo < 0) { double a = t * 1.5 + s.Ph; ox = (float)Math.Sin(a) * 0.14f; oy = (float)Math.Sin(2 * a) * 0.05f; }
            int alpha = s.Sleep ? 170 : s.Stalled ? 210 : 255;
            if (s.Waiting && animate && boo < 0) alpha = (int)(140 + 115 * (0.5f + 0.5f * (float)Math.Cos(t * 0.9 + s.Ph)));
            Color body = Color.FromArgb(alpha, s.Tint(Theme.Hex(0xF4F1FF), 0.5f)), bodyBot = Color.FromArgb(alpha, s.Tint(Theme.Hex(0xD6CFF3), 0.5f));
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            FlatFx.GroundShadow(g, cx + ox * u, by, 0.32f * u, 0.03f * u, s.Sleep ? 40 : 70);
            // Тело — одной фигурой; рисуется и для следов (k > 0: прошлые положения, прозрачнее).
            float w = 0.03f * s.Sin(3.0, 1) * s.A;
            Func<float, float, float, GraphicsPath> Body = delegate (float dx, float dy, float sc) {
                Func<float, float, PointF> Q = delegate (float x, float y) { return new PointF(cx + (dx + (x - lean * y) * sc) * u, by + (dy + (y * sc) - hover) * u); };
                GraphicsPath p = new GraphicsPath();
                p.AddBezier(Q(-0.36f, -0.12f), Q(-0.38f, -0.40f), Q(-0.36f, -0.88f), Q(0f, -0.88f));
                p.AddBezier(Q(0f, -0.88f), Q(0.36f, -0.88f), Q(0.40f, -0.40f), Q(0.38f, -0.12f));
                p.AddBezier(Q(0.38f, -0.12f), Q(0.36f, -0.02f + w), Q(0.24f, 0.00f + w), Q(0.20f, -0.08f));
                p.AddBezier(Q(0.20f, -0.08f), Q(0.14f, -0.02f - w), Q(0.04f, 0.00f - w), Q(-0.02f, -0.08f));
                p.AddBezier(Q(-0.02f, -0.08f), Q(-0.08f, -0.02f + w), Q(-0.20f, 0.00f + w), Q(-0.24f, -0.08f));
                p.AddBezier(Q(-0.24f, -0.08f), Q(-0.28f, -0.02f - w), Q(-0.36f, -0.04f - w), Q(-0.36f, -0.12f));
                p.CloseFigure();
                return p;
            };
            if (s.Working && animate && boo < 0) for (int k = 3; k >= 1; k--) {
                double a = (t - k * 0.13) * 1.5 + s.Ph;
                using (GraphicsPath tp = Body((float)Math.Sin(a) * 0.14f, -(float)Math.Sin(2 * a) * 0.05f, 1f))
                using (SolidBrush tb = new SolidBrush(Color.FromArgb(70 - k * 15, 0xD6, 0xCF, 0xF3))) g.FillPath(tb, tp);
            }
            float sc0 = 1f + 0.14f * puffUp;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + (ox + (x - lean * y) * sc0) * u, by + (-oy + y * sc0 - hover) * u); };
            if (!s.Sleep && u >= 16) FlatFx.Glow(g, P(0, -0.45f), 0.62f * u, Theme.Hex(0xB8AEF0), (int)((s.Perm ? 70 : 40) + 60 * s.Aha + 50 * puffUp));
            // Оборот: фигура сжимается по ширине (cos), на «спине» лица нет.
            GraphicsState gs = g.Save();
            if (spinX != 1f) { PointF c0 = P(0, -0.45f); g.TranslateTransform(c0.X, c0.Y); g.ScaleTransform(Math.Max(0.04f, Math.Abs(spinX)), 1f); g.TranslateTransform(-c0.X, -c0.Y); }
            // Ручки в стороны при «Бу!» (за телом).
            for (int side = -1; side <= 1; side += 2) {
                // Ручки-лапки: всегда чуть видны; в работе машут по очереди, при «Бу!» — раскинуты.
                float flap = s.Working && animate ? 0.04f * (float)Math.Sin(t * 5 + side) : 0f;
                float ax = side * (0.35f + 0.06f * puffUp), ay = -0.42f - 0.04f * puffUp + flap;
                using (GraphicsPath arm = Oval(P(ax, ay), (0.065f + 0.04f * puffUp) * u, (0.045f + 0.025f * puffUp) * u)) Fill(g, arm, body, bodyBot);
            }
            using (GraphicsPath p = Body(ox, -oy, sc0)) Fill(g, p, body, bodyBot);
            HeadAnchor.Set(g, P(0, -0.88f), 0.30f * u, P(0, -0.52f).Y);   // украшения и эффекты — к голове
            // Внутреннее свечение: светлое ядро в верхней части тела — привидение будто светится изнутри.
            if (u >= 20) FlatFx.Glow(g, P(-0.04f, -0.62f), 0.30f * u, Color.White, (int)(alpha * 0.35f));
            Color ink = Color.FromArgb(Math.Min(255, alpha + 40), Theme.Hex(0x2B2738));
            float fx = s.Gx * 0.06f, fy = -s.Gy * 0.045f;
            if (spinX > 0f) {
                FlatFx.Eyes(g, P(-0.11f + fx, -0.52f + fy), P(0.11f + fx, -0.52f + fy), cx + fx * u, u, puffUp > 0.3f ? "round" : s.Eyes, ink, 1.1f + 0.3f * puffUp);
                Blush(g, P(-0.20f + fx, -0.44f + fy), P(0.20f + fx, -0.44f + fy), u, Theme.Hex(0xE7A6D6), s.Sleep ? 30 : 80);
                if (puffUp > 0.3f) {
                    using (SolidBrush mb = new SolidBrush(ink)) { PointF m = P(fx, -0.38f); float mw = u * 0.09f * puffUp, mh = u * 0.11f * puffUp; g.FillEllipse(mb, m.X - mw / 2, m.Y - mh / 2, mw, mh); }
                }
                else if (!s.Waiting || s.Aha > 0.05f) FlatFx.Mouth(g, P(fx * 0.8f, -0.42f + fy * 0.8f), u * 0.9f, s.Mouth("smile"), ink);
            }
            g.Restore(gs);
            float mk = Math.Max(s.Spark, s.Working ? 0.75f : puffUp);
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
            // Фирменное: «Желе-прыжок» — присел, взлетел вытянувшись, шлёпнулся, задрожал.
            float jj = MascotSig.At(t, seed, 6f, 1.6f, 0.2f, animate, state);
            float pre = jj >= 0 && jj < 0.18f ? MascotSig.Bell(jj / 0.18f) : 0f;
            float fly = jj >= 0.15f && jj < 0.6f ? MascotSig.Bell((jj - 0.15f) / 0.45f) : 0f;
            float land = jj >= 0.58f && jj < 0.72f ? MascotSig.Bell((jj - 0.58f) / 0.14f) : 0f;
            float jig = jj >= 0.7f ? (float)Math.Sin((jj - 0.7f) * 60) * (1 - (jj - 0.7f) / 0.3f) : 0f;
            // Работает — желейная волна бежит по комочку; ждёт — перекатывается из стороны в сторону.
            float wave = s.Working && animate ? (float)(t * 5 + s.Ph) : 0f;
            float rollX = s.Waiting && animate && jj < 0 ? 0.08f * (float)Math.Sin(t * 0.9 + s.Ph) : 0f;
            float squash = 1f + (s.Working ? 0.04f * s.Sin(2.6, 1) : 0.025f * s.Sin(1.5, 1)) * s.A - 0.18f * pre - 0.22f * land + 0.16f * fly + 0.06f * jig;
            float rx = 0.42f * (1f - 0.05f * hop) / squash, ry = 0.33f * (1f + 0.08f * hop) * squash;
            if (s.Sleep) { rx *= 1.06f; ry *= 0.9f; }
            float lift = hop * 0.06f + 0.30f * fly;
            Func<float, float, PointF> P = delegate (float x, float y) { return new PointF(cx + (x + rollX) * u, by + (y - lift) * u); };
            Color body = s.Tint(Theme.Hex(0xFDF3F5), 0.5f), bodyBot = s.Tint(Theme.Hex(0xF2D3DB), 0.5f);
            Color leafC = s.Tint(Theme.Hex(0x8DBA6E), 0.4f), leafBot = s.Tint(Theme.Hex(0x6A9A52), 0.4f);
            SmoothingMode sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            FlatFx.Shadow(g, cx, by, u, s.Sleep);
            if (!s.Sleep && u >= 16) FlatFx.Glow(g, P(0, -0.34f), 0.58f * u, Theme.Hex(0xF2C9D4), (int)((s.Perm ? 60 : 30) + 50 * s.Aha));
            float cyy = -ry + 0.0f;   // низ комочка — на земле
            // Волна по макушке: левый и правый «бугорок» поднимаются по очереди.
            float wl = s.Working && animate ? 0.05f * (float)Math.Sin(wave) : 0f, wr = s.Working && animate ? 0.05f * (float)Math.Sin(wave - 1.6) : 0f;
            using (GraphicsPath p = new GraphicsPath()) {
                // Сверху круглый, снизу чуть приплюснутый.
                p.AddBezier(P(-rx, cyy), P(-rx, cyy - ry * 0.75f - wl), P(-rx * 0.55f, cyy - ry - wl), P(0, cyy - ry));
                p.AddBezier(P(0, cyy - ry), P(rx * 0.55f, cyy - ry - wr), P(rx, cyy - ry * 0.75f - wr), P(rx, cyy));
                p.AddBezier(P(rx, cyy), P(rx, cyy + ry * 0.7f), P(rx * 0.6f, cyy + ry), P(0, cyy + ry));
                p.AddBezier(P(0, cyy + ry), P(-rx * 0.6f, cyy + ry), P(-rx, cyy + ry * 0.7f), P(-rx, cyy));
                p.CloseFigure();
                // Лист сакуры за комочком: выглядывает справа и снизу.
                if (u >= 14) using (GraphicsPath lf = new GraphicsPath()) {
                    lf.AddBezier(P(-rx * 0.35f, cyy + ry * 1.0f), P(rx * 0.5f, cyy + ry * 1.5f), P(rx * 1.55f, cyy + ry * 0.7f), P(rx * 1.28f, cyy - ry * 0.75f));
                    lf.AddBezier(P(rx * 1.28f, cyy - ry * 0.75f), P(rx * 0.75f, cyy - ry * 0.35f), P(rx * 0.2f, cyy + ry * 0.35f), P(-rx * 0.35f, cyy + ry * 1.0f));
                    lf.CloseFigure();
                    Fill(g, lf, leafC, leafBot);
                    if (u >= 26) using (Pen vp = new Pen(Color.FromArgb(150, Draw.Mix(leafC, Color.White, 0.4f)), Math.Max(1f, u * 0.012f)))
                        g.DrawBezier(vp, P(-rx * 0.2f, cyy + ry * 0.95f), P(rx * 0.6f, cyy + ry * 0.95f), P(rx * 1.1f, cyy + ry * 0.3f), P(rx * 1.22f, cyy - ry * 0.6f));
                }
                Fill(g, p, body, bodyBot);
                HeadAnchor.Set(g, P(0, cyy - ry * 0.97f), rx * 0.75f * u, P(0, cyy + 0.02f).Y);
                // Крупинки пудры.
                if (u >= 26) using (SolidBrush pw = new SolidBrush(Color.FromArgb(160, 255, 255, 255))) {
                    float[][] dots = { new float[] { -0.25f, -0.55f }, new float[] { 0.18f, -0.62f }, new float[] { -0.05f, -0.80f }, new float[] { 0.30f, -0.35f }, new float[] { -0.32f, -0.25f } };
                    foreach (float[] d in dots) { PointF c0 = P(rx * d[0] / 0.42f, cyy + ry * d[1] / 0.33f * 0.5f); float dr = Math.Max(0.6f, u * 0.009f); g.FillEllipse(pw, c0.X - dr, c0.Y - dr, dr * 2, dr * 2); }
                }
                // Цветок сакуры на макушке: пять лепестков и жёлтая серединка.
                if (u >= 16) {
                    PointF fc = P(-rx * 0.35f, cyy - ry * 0.92f - wl);
                    float pr = 0.055f * u;
                    using (SolidBrush pb = new SolidBrush(s.Tint(Theme.Hex(0xF7A8C0), 0.3f)))
                        for (int i = 0; i < 5; i++) { double a = i * Math.PI * 2 / 5 - Math.PI / 2 + 0.2 * s.Sin(1.3, 1) * s.A; float px = fc.X + (float)Math.Cos(a) * pr * 0.75f, py = fc.Y + (float)Math.Sin(a) * pr * 0.75f; g.FillEllipse(pb, px - pr * 0.55f, py - pr * 0.55f, pr * 1.1f, pr * 1.1f); }
                    using (SolidBrush cb = new SolidBrush(Theme.Hex(0xF6D25C))) g.FillEllipse(cb, fc.X - pr * 0.3f, fc.Y - pr * 0.3f, pr * 0.6f, pr * 0.6f);
                }
            }
            Color ink = Theme.Hex(0x26262C);
            float fx = s.Gx * 0.06f, fy = -s.Gy * 0.04f;
            FlatFx.Eyes(g, P(-0.12f + fx, cyy + 0.02f + fy), P(0.12f + fx, cyy + 0.02f + fy), cx + fx * u, u, fly > 0.2f ? "smile" : pre + land > 0.3f ? "squint" : s.Eyes, ink, 1.0f);
            Blush(g, P(-0.22f + fx, cyy + 0.10f + fy), P(0.22f + fx, cyy + 0.10f + fy), u, Theme.Hex(0xF2B0BC), s.Sleep ? 30 : (int)(70 + 80 * fly));
            if (!s.Waiting || s.Aha > 0.05f || fly > 0.2f) FlatFx.Mouth(g, P(fx * 0.8f, cyy + 0.10f + fy * 0.8f), u * 0.85f, fly > 0.2f ? "o" : s.Mouth("smile"), ink);
            // «Антенны» над головой: серые, при «Ага!» и запросе — янтарные и торчком, при ошибке — красные.
            // «Антенны» — только как сигнал: запрос, «Ага!», прыжок, ошибка, работа (в покое не торчат).
            float mk = Math.Max(s.Spark, s.Err || s.Working ? 0.8f : fly > 0.2f ? 1f : 0f);
            Color mc = s.Perm || s.Aha > 0.05f || fly > 0.2f ? Theme.Hex(0xFFB340) : s.Err ? Theme.Hex(0xEF5A48) : Theme.Hex(0x8E8E9A);
            float wavek = rollX != 0f ? 0.25f * (float)Math.Sin(t * 3.0) : 0f;   // в ожидании «антенны» машут
            Marks(g, P(-0.20f, cyy - ry - 0.06f), u, mc, mk, 0.45f + (s.Aha > 0.05f ? -0.2f : 0f) + 0.06f * s.Sin(2.2, 1) * s.A + wavek - 0.25f * fly);
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
