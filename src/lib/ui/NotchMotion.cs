// claude-notifier: движение маскотов в шторке — у каждого свои пружины (сжатие, запаздывание верха, подъём).
//  • Смена статуса — плавный переход 0,35 с (старый вид тает, новый проявляется) и мягкий «шлепок» пружиной.
//  • Новый сеанс — маскот выпрыгивает снизу с перелётом, остальные удивлённо смотрят; закрытый — машет и уходит
//    вниз, соседи машут ему вслед.
//  • «Ага!» — подскакивает и поднимает брови; задумался — иногда косит глаза к носу.
//  • Долго ждёт ответа — сценки: потягивается, чешет ухо, дремлет и съезжает набок, подпрыгивает к соседу;
//    без курсора иногда поглядывает на соседей. Курсор рядом со свёрнутой шторкой — смотрит на него.
//  • Раскрытие шторки — главный маскот перелетает со своего места в свёрнутой на место в раскрытой.
// Пока что-то движется, шторка рисуется 60 кадров в секунду (AnimTick), шаги пружин — по реальному времени.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace ClaudeNotifier.Ui {
    public sealed partial class NotchView {
        sealed class FaceMotion {
            public readonly Spring Squash = new Spring(1f), Shear = new Spring(0f), Lift = new Spring(0f);
            public string State, OldState;
            public DateTime Born = DateTime.MinValue, StateAt = DateTime.MinValue, LeftAt = DateTime.MinValue, AhaKick = DateTime.MinValue;
            public RectangleF Rect;
            public float LastX = float.NaN;
            public string Device, Project;
            public int Seed;
        }

        public static double EnterSeconds = 0.7, LeaveSeconds = 0.6, BlendSeconds = 0.35, IdleSceneAfter = 40, FlySeconds = 0.45;
        readonly Dictionary<string, FaceMotion> motions = new Dictionary<string, FaceMotion>();
        readonly List<FaceMotion> leaving = new List<FaceMotion>();
        DateTime motionClock = DateTime.UtcNow;
        bool motionsPrimed, motionBusy;
        // Перелёт главного маскота при раскрытии.
        RectangleF lastMainWin;
        DateTime flyAt = DateTime.MinValue;

        public int MotionCount { get { return motions.Count; } }
        public int LeavingCount { get { return leaving.Count; } }
        public bool MotionBusy { get { return motionBusy; } }

        static float Hash01(long n, int salt) {
            unchecked {
                uint x = (uint)(n * 2654435761L) ^ (uint)(salt * 40503 + 17);
                x ^= x >> 13; x *= 0x5bd1e995; x ^= x >> 15;
                return (x & 0xffff) / 65535f;
            }
        }

        // Из SetItems: новые, ушедшие и сменившие статус маскоты.
        void TrackMotions() {
            DateTime now = DateTime.UtcNow;
            HashSet<string> alive = new HashSet<string>();
            List<string> fresh = new List<string>();
            foreach (NotchItem it in items) {
                alive.Add(it.Id);
                FaceMotion fm;
                if (!motions.TryGetValue(it.Id, out fm)) {
                    fm = new FaceMotion();
                    fm.State = it.State;
                    fm.Born = motionsPrimed ? now : DateTime.MinValue;   // при запуске — без выпрыгивания
                    fm.Seed = (it.Id.GetHashCode() & 0x7fff) % 97;
                    motions[it.Id] = fm;
                    if (motionsPrimed) fresh.Add(it.Id);
                } else if (fm.State != it.State) {
                    fm.OldState = fm.State; fm.State = it.State; fm.StateAt = now;
                    fm.Squash.Kick(-2.4f);   // шлепок: присел и отпружинил
                }
                fm.Device = it.Device; fm.Project = it.Project;
            }
            bool gone = false;
            foreach (string k in new List<string>(motions.Keys)) {
                if (alive.Contains(k) || k == "") continue;
                FaceMotion fm = motions[k];
                motions.Remove(k);
                if (motionsPrimed && fm.Rect.Width > 0 && !Expanded && Animate) { fm.LeftAt = now; leaving.Add(fm); }
                gone = true;
            }
            if (motionsPrimed && Animate) {
                // Соседи замечают друг друга: ушедшему машут, на новенького удивлённо смотрят.
                foreach (string id in alive) {
                    if (fresh.Contains(id)) continue;
                    if (gone) reactions[id] = new KeyValuePair<string, DateTime>("wave", now);
                    else if (fresh.Count > 0) reactions[id] = new KeyValuePair<string, DateTime>("notice", now);
                }
            }
            motionsPrimed = true;
        }

        FaceMotion MotionFor(NotchItem it) {
            string id = it != null ? it.Id : "";
            FaceMotion fm;
            if (!motions.TryGetValue(id, out fm)) {
                fm = new FaceMotion(); fm.State = it != null ? it.State : "none";
                fm.Seed = it != null ? (it.Id.GetHashCode() & 0x7fff) % 97 : 0;
                motions[id] = fm;
            }
            return fm;
        }

        // Кадр: шаги пружин, ушедшие доигрывают. true — что-то движется (рисовать 60 кадров/с).
        bool StepMotions() {
            DateTime now = DateTime.UtcNow;
            float dt = (float)Math.Max(0, Math.Min(0.1, (now - motionClock).TotalSeconds));
            motionClock = now;
            bool busy = false;
            foreach (FaceMotion fm in motions.Values) busy |= StepOne(fm, dt);
            foreach (FaceMotion fm in leaving) StepOne(fm, dt);
            leaving.RemoveAll(delegate (FaceMotion f) { return (now - f.LeftAt).TotalSeconds > LeaveSeconds; });
            if (leaving.Count > 0 || Since(flyAt) < FlySeconds || OpenGreeting) busy = true;
            motionBusy = busy && Animate;
            return motionBusy;
        }

        static bool StepOne(FaceMotion fm, float dt) {
            fm.Squash.Step(dt, 1f, 220f, 0.30f);
            fm.Shear.Step(dt, 0f, 150f, 0.28f);
            fm.Lift.Step(dt, 0f, 260f, 0.50f);
            bool busy = !fm.Squash.Settled(1f) || !fm.Shear.Settled(0f) || !fm.Lift.Settled(0f);
            if (Since(fm.Born) < EnterSeconds) busy = true;
            if (fm.OldState != null && Since(fm.StateAt) < BlendSeconds) busy = true;
            return busy;
        }

        // Настроение от движения: пружины, выпрыгивание, брови, глаза к носу, сценки, взгляды на соседей.
        void MotionMood(FaceMotion fm, NotchItem it, CatMood md, RectangleF r, int seed) {
            if (!Animate) return;
            // Сдвинулся вбок (перестроился ряд) — верх догоняет низ. Но не когда шторку раскрывают или сворачивают
            // и не при скачке на другое место раскладки: там маскот просто стоит на новом месте (иначе — качка и растяжка).
            bool jump = !float.IsNaN(fm.LastX) && Math.Abs(r.X - fm.LastX) > r.Width * 0.8f;
            if (!float.IsNaN(fm.LastX) && Math.Abs(r.X - fm.LastX) > 0.5f && r.Height > 0 && !jump && !Morphing && !FlyActive && Since(openedAt) > 0.8)
                fm.Shear.Kick(-(r.X - fm.LastX) / r.Height * 3f);
            fm.LastX = r.X; fm.Rect = r;
            double born = Since(fm.Born);
            if (born < EnterSeconds) {
                float e = (float)(born / EnterSeconds);
                md.Lift -= (1f - MascotMotion.EaseOutBack(e)) * 0.9f;                    // выпрыгивает снизу
                md.SquashY *= 1f + 0.22f * (float)Math.Sin(e * Math.PI) * (1f - e);      // вытянут в прыжке
            }
            md.SquashY *= fm.Squash.X; md.Shear += fm.Shear.X; md.Lift += fm.Lift.X;
            // Дыхание: во сне глубже и медленнее, в ожидании — едва заметно.
            string st = it != null ? it.State : "none";
            if (st == "none" || st == "stalled") md.SquashY *= 1f + 0.025f * (float)Math.Sin(T * 1.3 + seed);
            else if (st == "waiting") md.SquashY *= 1f + 0.012f * (float)Math.Sin(T * 2.1 + seed);
            if (md.AhaAge >= 0) {
                md.Brow = Math.Max(md.Brow, (float)Math.Sin(Math.PI * Math.Min(1f, md.AhaAge / 0.8f)));
                if (md.AhaAge < 0.08f && Since(fm.AhaKick) > 0.5) { fm.AhaKick = DateTime.UtcNow; fm.Squash.Kick(2.6f); }   // «Ага!» — подскок
            }
            if (md.Deep && ((T + seed * 0.7f) % 9f) < 2.2f) md.Cross = true;
            IdleScene(fm, it, md, r, seed);
            OpenGreetMood(it, md);   // раскрыли шторку — заметили вас и улыбнулись (NotchReact.cs)
            // Без курсора иногда поглядывает на соседей (к середине шторки).
            if (!md.HasLook && items.Count > 1) {
                float ph = (T + seed * 1.9f) % 13f;
                if (ph < 1.3f) {
                    md.HasLook = true;
                    md.LookX = (r.X + r.Width / 2 < lay.Width / 2f ? 0.8f : -0.8f);
                    md.LookY = 0.1f; md.LookW = (float)Math.Sin(Math.PI * ph / 1.3f);
                }
            }
        }

        // Сценки, пока сеанс давно спокойно ждёт ответа (каждые ~26 с одна, по очереди «случайно»).
        void IdleScene(FaceMotion fm, NotchItem it, CatMood md, RectangleF r, int seed) {
            if (it == null || it.State != "waiting" || NeedsYou(it) || md.Reacting) return;
            double idle = Math.Min(Since(fm.StateAt), Since(fm.Born));
            if (fm.StateAt == DateTime.MinValue && fm.Born == DateTime.MinValue) idle = double.MaxValue;
            if (idle < IdleSceneAfter) return;
            const float per = 26f;
            double clock = T + seed * 3.7;
            float ph = (float)(clock % per);
            int which = (int)(Hash01((long)Math.Floor(clock / per), seed) * 4);
            if (which == 2 && idle < 180) which = 0;   // дремать — только после трёх минут ожидания
            float dur = which == 2 ? 5f : which == 0 ? 2.4f : 1.8f;
            if (ph >= dur) return;
            float b = (float)Math.Sin(Math.PI * ph / dur);
            switch (which) {
                case 0:   // потягивается: вытягивается вверх, глаза закрыты, ротик «о»
                    md.SquashY *= 1f + 0.16f * b;
                    if (b > 0.3f) { md.EyesOverride = "closed"; md.MouthOverride = "o"; }
                    break;
                case 1:   // чешет ухо: мелко качается, щурится
                    md.Lean += 7f * (float)Math.Sin(T * 16) * b;
                    if (b > 0.2f) md.EyesOverride = "squint";
                    break;
                case 2: { // дремлет: медленно съезжает набок и вздрагивает в конце
                    float slide = MascotMotion.Smooth(Math.Min(1f, ph / 3.5f)) * (ph < 4.4f ? 1f : 1f - (ph - 4.4f) / 0.6f);
                    md.Lean += 16f * slide; md.Lift -= 0.02f * slide;
                    if (slide > 0.2f) { md.EyesOverride = "closed"; md.MouthOverride = "flat"; }
                    break;
                }
                default:  // подпрыгивает к соседу и смотрит на него
                    md.Lift += 0.10f * (float)Math.Abs(Math.Sin(ph * Math.PI * 2 / dur));
                    md.HasLook = true; md.LookW = b;
                    md.LookX = r.X + r.Width / 2 < lay.Width / 2f ? 1f : -1f; md.LookY = 0f;
                    break;
            }
        }

        // Рисует маскота; сразу после смены статуса — плавный переход: старый вид тает, новый проявляется.
        bool tinting;

        void DrawMascot(Graphics g, RectangleF r, NotchItem it, string state, int seed, CatMood md, FaceMotion fm) {
            string dev = it != null ? it.Device : null, proj = it != null ? it.Project : null;
            // Свой цвет маскота этого ПК: рисуем в картинку и переносим через матрицу цвета.
            if (!tinting && MascotColor.Active && string.IsNullOrEmpty(dev) && r.Width >= 4) {
                RectangleF tb = RectangleF.Inflate(r, r.Width * 0.6f, r.Height * 0.8f);
                int tx0 = (int)Math.Floor(tb.X), ty0 = (int)Math.Floor(tb.Y), tw0 = (int)Math.Ceiling(tb.Width) + 2, th0 = (int)Math.Ceiling(tb.Height) + 2;
                using (Bitmap tbmp = new Bitmap(tw0, th0, PixelFormat.Format32bppPArgb)) {
                    using (Graphics tg = Graphics.FromImage(tbmp)) {
                        tg.SmoothingMode = SmoothingMode.AntiAlias;
                        tg.TranslateTransform(-tx0, -ty0);
                        tinting = true;
                        try { DrawMascot(tg, r, it, state, seed, md, fm); } finally { tinting = false; }
                    }
                    MascotColor.Blit(g, tbmp, tx0, ty0);
                }
                return;
            }
            double since = fm != null && fm.OldState != null ? Since(fm.StateAt) : double.MaxValue;
            if (!Animate || since >= BlendSeconds || fm.OldState == state || r.Width < 4) { Mascot.PaintItem(g, r, state, T, seed, Animate, md, dev, proj); return; }
            float k = MascotMotion.Smooth((float)(since / BlendSeconds));
            RectangleF big = RectangleF.Inflate(r, r.Width * 0.45f, r.Height * 0.6f);
            int bx = (int)Math.Floor(big.X), byy = (int)Math.Floor(big.Y), w = (int)Math.Ceiling(big.Width) + 2, h = (int)Math.Ceiling(big.Height) + 2;
            using (Bitmap a = new Bitmap(w, h, PixelFormat.Format32bppPArgb))
            using (Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppPArgb)) {
                foreach (KeyValuePair<Bitmap, string> p in new KeyValuePair<Bitmap, string>[] { new KeyValuePair<Bitmap, string>(a, fm.OldState), new KeyValuePair<Bitmap, string>(b, state) }) {
                    using (Graphics gg = Graphics.FromImage(p.Key)) {
                        gg.SmoothingMode = SmoothingMode.AntiAlias;
                        gg.TranslateTransform(-bx, -byy);
                        Mascot.PaintItem(gg, r, p.Value, T, seed, Animate, md, dev, proj);
                    }
                }
                Blit(g, a, bx, byy, 1f - k);
                Blit(g, b, bx, byy, k);
            }
        }

        static void Blit(Graphics g, Bitmap img, int x, int y, float alpha) {
            if (alpha <= 0.01f) return;
            using (ImageAttributes ia = new ImageAttributes()) {
                ColorMatrix cm = new ColorMatrix(); cm.Matrix33 = Math.Min(1f, alpha);
                ia.SetColorMatrix(cm);
                g.DrawImage(img, new Rectangle(x, y, img.Width, img.Height), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, ia);
            }
        }

        // Ушедшие сеансы: машут и уходят вниз за край шторки.
        void PaintLeaving(Graphics g) {
            foreach (FaceMotion fm in leaving) {
                float k = (float)Math.Min(1, Since(fm.LeftAt) / LeaveSeconds);
                CatMood md = new CatMood();
                md.React = "wave"; md.ReactAge = 0.6f + k; md.Wave = 1f - k;
                md.Lift = -0.9f * MascotMotion.Smooth(k); md.SquashY = 1f + 0.15f * (float)Math.Sin(Math.PI * k);
                Mascot.PaintItem(g, fm.Rect, fm.State, T, fm.Seed, Animate, md, fm.Device, fm.Project);
            }
        }

        // Свёрнутая запоминает, где стоял главный маскот (в координатах окна).
        void NoteCollapsedMain(RectangleF r, NotchItem it) {
            lastMainWin = r; lastMainWin.Offset(origin.X, origin.Y);
        }

        // Раскрыли или свернули шторку — пружины всех маскотов успокоить: ни раскачки, ни сжатия-растяжения.
        void SettleMotions() {
            foreach (FaceMotion fm in motions.Values) {
                fm.Squash.X = 1f; fm.Squash.V = 0; fm.Shear.X = 0; fm.Shear.V = 0; fm.Lift.X = 0; fm.Lift.V = 0;
                fm.LastX = float.NaN;
            }
        }

        // Раскрытая: главный маскот сразу стоит на своём месте на карточке — без перелёта (по диагонали через
        // шторку смотрелось плохо). Шторка проявляется кругом от того места, где он стоял в свёрнутой.
        RectangleF FlyRect(NotchItem it, RectangleF target) {
            return target;
        }

        public bool FlyActive { get { return Since(flyAt) < FlySeconds; } }
    }
}
