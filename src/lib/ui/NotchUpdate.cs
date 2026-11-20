// claude-notifier: обновление приложения — сценка прямо в раскрытой шторке (страница «Обновление»).
// Главный маскот толкает «посылку» с обновлением (подарочная коробка цветов приложения) по дорожке-прогрессу
// к финишному флажку, где его ждёт и подбадривает друг-маскот. Вся дорога — весь путь обновления:
//   download — толкает, коробка покачивается, дорожка заливается; verify — над коробкой лупа сканирует;
//   extract — крышка подпрыгивает, из коробки сыплются искры; install — над коробкой крутятся шестерёнки,
//   маскот «стучит»; restart — шторка на пару секунд закроется (трей перезапускается);
//   done — новая версия сама раскрывает шторку: коробка на финише, крышка улетает, значок приложения выпрыгивает
//   на пружине, конфетти, оба маскота прыгают от радости; через несколько секунд шторка сворачивается.
//   error — коробка опрокинулась, маскот хватается за голову, дорожка красная, шаг с ошибкой отмечен красным.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ClaudeNotifier.Ui {
    public sealed partial class NotchView {
        public string UpdPhase = "";          // '' — обновления нет; download | verify | extract | install | restart | done | error
        public double UpdPct = -1;
        public string UpdDetail = "";
        public static double UpdAutoCloseSeconds = 6.5;
        DateTime updPhaseAt = DateTime.UtcNow, updBorn = DateTime.UtcNow, updClock = DateTime.UtcNow;
        string updLast = "download", updPrevText = "";
        double updPos, updVel, updPop, updPopVel, updShake, updLid, updLidVel, updTip;
        bool updClosed, updConfettiPending;
        readonly List<float[]> updConfetti = new List<float[]>();   // x, y, vx, vy, угол, вращение, жизнь, цвет
        readonly Random updRnd = new Random(11);
        static readonly string[] UpdSteps = { "Скачивание", "Установка", "Запуск" };
        static readonly Color[] UpdColors = { Color.FromArgb(10, 132, 255), Color.FromArgb(94, 92, 230), Color.FromArgb(48, 209, 88),
            Color.FromArgb(255, 214, 10), Color.FromArgb(255, 55, 95), Color.FromArgb(100, 210, 255) };

        public bool UpdateShowing { get { return UpdPhase.Length > 0; } }

        public void SetUpdateProgress(string phase, double pct, string detail) {
            phase = phase ?? "";
            if (phase != UpdPhase) {
                if (UpdPhase.Length == 0) {
                    updBorn = DateTime.UtcNow; updPos = phase == "done" ? 0.9 : 0; updVel = 0; updTip = 0; updLid = 0; updLidVel = 0; updClosed = false; updConfetti.Clear();
                }
                updPrevText = UpdText(UpdPhase, UpdDetail);
                if (phase != "error" && phase != "done" && phase.Length > 0) updLast = phase;
                updPhaseAt = DateTime.UtcNow;
                if (phase == "extract") updLidVel = -10;
                if (phase == "done") { updPopVel = -12; updLidVel = -26; updConfettiPending = true; updClosed = false; React(SelectedId, "joy"); }
                if (phase == "error") { updShake = 14; React(SelectedId, "panic"); }
            }
            UpdPhase = phase; UpdPct = pct; UpdDetail = detail ?? "";
            WakeUi(); Invalidate();
        }

        public static string UpdText(string phase, string detail) {
            switch (phase) {
                case "download": return string.IsNullOrEmpty(detail) ? "Скачиваю новую версию…" : "Скачиваю новую версию… " + detail;
                case "verify": return "Проверяю, что архив целый…";
                case "extract": return "Распаковываю…";
                case "install": return "Устанавливаю — шторка перезапустится";
                case "restart": return "Запускаю новую версию…";
                case "done": return string.IsNullOrEmpty(detail) ? "Готово — приложение обновлено" : "Готово — версия " + detail;
                case "error": return string.IsNullOrEmpty(detail) ? "Не удалось обновить" : "Не удалось: " + detail;
                default: return "";
            }
        }

        int UpdLabelW(string s) { return TextRenderer.MeasureText(s, fSmall, Size.Empty, TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Width; }

        static int UpdStep(string phase) { switch (phase) { case "download": case "verify": case "extract": return 0; case "install": return 1; default: return 2; } }

        // Где коробка на дорожке (0..1): вся дорога — весь путь обновления. Скачивание без размера — плавно к 85 %.
        double UpdJourney() {
            double since = (DateTime.UtcNow - updPhaseAt).TotalSeconds;
            switch (UpdPhase == "error" ? updLast : UpdPhase) {
                case "download": {
                    double p = UpdPct >= 0 ? UpdPct : 0.85 * (1 - Math.Exp(-(DateTime.UtcNow - updBorn).TotalSeconds / 5));
                    return 0.6 * Math.Max(0, Math.Min(1, p));
                }
                case "verify": return 0.6 + 0.05 * Math.Min(1, since / 1.5);
                case "extract": return 0.65 + 0.07 * Math.Min(1, since / 2);
                case "install": return 0.72 + 0.18 * (1 - Math.Exp(-since / 6));
                case "restart": return 0.93;
                case "done": return 1;
                default: return 0;
            }
        }

        static GraphicsPath UpdRound(RectangleF r, float rad) {
            GraphicsPath p = new GraphicsPath(); float d = Math.Max(0.1f, Math.Min(rad * 2, Math.Min(r.Width, r.Height)));
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure(); return p;
        }

        // Шаг анимации: пружины, конфетти, сглаживание пути. Скорость не зависит от частоты кадров.
        void UpdTick() {
            DateTime now = DateTime.UtcNow;
            float dt = (float)Math.Max(0.001, Math.Min(0.05, (now - updClock).TotalSeconds)); updClock = now;
            float k = dt * 60f;
            double since = (now - updPhaseAt).TotalSeconds;
            // Коробка едет за ходом обновления на критически демпфированной пружине: без ступенек от редких данных
            // и без рывка при смене шага. Ошибка — остаётся, где упала.
            if (UpdPhase != "error") {
                double w = UpdPhase == "done" ? 7 : 3.2, target = UpdJourney();
                int n = Math.Max(1, (int)Math.Ceiling(dt / 0.004)); double h = dt / n;
                for (int i = 0; i < n; i++) { double acc = w * w * (target - updPos) - 2 * w * updVel; updVel += acc * h; updPos += updVel * h; }
                if (updVel < 0 && UpdPhase != "done") updVel *= 0.5;   // назад не катится
            } else updVel = 0;
            int steps = (int)Math.Max(1, Math.Round(k));
            bool fly = UpdPhase == "done";
            for (int i = 0; i < steps; i++) {
                updPopVel += -updPop * 0.30; updPopVel *= 0.82; updPop += updPopVel * 0.096;
                if (fly) { updLidVel += 0.9; updLid += updLidVel * 0.096; }
                else { updLidVel += -updLid * 0.35; updLidVel *= 0.84; updLid += updLidVel * 0.096; }
            }
            if (UpdPhase == "extract" && since % 0.9 < dt) updLidVel = -8;   // крышка подпрыгивает
            updTip += ((UpdPhase == "error" ? 1 : 0) - updTip) * Math.Min(1, 0.12 * k);
            if (updShake != 0) { updShake = -updShake * Math.Pow(0.82, k); if (Math.Abs(updShake) < 0.4) updShake = 0; }
            for (int i = updConfetti.Count - 1; i >= 0; i--) {
                float[] c = updConfetti[i];
                c[0] += c[2] * k; c[1] += c[3] * k; c[3] += 0.16f * k; c[2] *= (float)Math.Pow(0.985, k); c[4] += c[5] * k; c[6] -= 0.0075f * k;
                if (c[6] <= 0) updConfetti.RemoveAt(i);
            }
            // Конфетти — ещё пару раз, пока празднуют.
            if (UpdPhase == "done" && ((since > 1.4 && since - dt <= 1.4) || (since > 2.8 && since - dt <= 2.8))) updConfettiPending = true;
            // Готово — через несколько секунд шторка сворачивается сама.
            if (UpdPhase == "done" && !updClosed && since > UpdAutoCloseSeconds && Expanded && Page == "update" && IsHandleCreated) {
                updClosed = true;
                BeginInvoke((MethodInvoker)delegate { ClickArea("close", Point.Empty); UpdPhase = ""; });
            }
        }

        void UpdBurst(float scale) {
            for (int i = 0; i < 46; i++) {
                double a = -Math.PI / 2 + (updRnd.NextDouble() - 0.5) * 2.2, v = (3.5 + updRnd.NextDouble() * 5.5) * scale;
                updConfetti.Add(new float[] { 0, 0, (float)(Math.Cos(a) * v), (float)(Math.Sin(a) * v), (float)(updRnd.NextDouble() * 360),
                    (float)((updRnd.NextDouble() - 0.5) * 24), 1f + (float)updRnd.NextDouble() * 0.4f, updRnd.Next(UpdColors.Length) });
            }
        }

        static double UEase(double t) { t = Math.Max(0, Math.Min(1, t)); return 1 - Math.Pow(1 - t, 3); }
        static double UEaseBack(double t) { t = Math.Max(0, Math.Min(1, t)); double c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * Math.Pow(t - 1, 3) + c1 * Math.Pow(t - 1, 2); }

        static string UpdFriendKind() {
            string main = Mascot.For(null);
            foreach (string k in new string[] { "flame", "penguin", "fox", "flatsphynx" }) if (k != main) return k;
            return "flame";
        }

        // Силуэт сфинкса — рисуется раз на размер (каждый кадр заново — лишняя работа и рывки).
        static readonly Dictionary<int, Bitmap> updGlyphs = new Dictionary<int, Bitmap>();
        static Bitmap UpdGlyph(int size) {
            size = Math.Max(4, Math.Min(256, (size + 1) / 2 * 2));   // размеры с шагом 2 px — пружина значка не плодит картинок
            Bitmap b;
            lock (updGlyphs) {
                if (!updGlyphs.TryGetValue(size, out b)) {
                    if (updGlyphs.Count > 40) { foreach (Bitmap x in updGlyphs.Values) x.Dispose(); updGlyphs.Clear(); }
                    b = TrayDot.Glyph(size, Color.White); updGlyphs[size] = b;
                }
            }
            return b;
        }
        // Плитка приложения: сине-фиолетовый градиент, белый силуэт сфинкса, бегущий блик.
        static void PaintAppTile(Graphics g, RectangleF tile, float t) {
            using (GraphicsPath p = UpdRound(tile, tile.Width * 0.26f))
            using (LinearGradientBrush lg = new LinearGradientBrush(tile, Color.FromArgb(10, 132, 255), Color.FromArgb(94, 92, 230), 90f)) {
                lg.WrapMode = WrapMode.TileFlipXY; g.FillPath(lg, p);
                float sx = tile.X + (float)(((t * 0.5) % 1.8) * tile.Width * 2.4 - tile.Width * 0.9);
                RectangleF sr = new RectangleF(sx, tile.Y, tile.Width * 0.6f, tile.Height);
                using (LinearGradientBrush shine = new LinearGradientBrush(sr, Color.Transparent, Color.Transparent, 0f)) {
                    ColorBlend cb = new ColorBlend(); cb.Colors = new Color[] { Color.FromArgb(0, 255, 255, 255), Color.FromArgb(60, 255, 255, 255), Color.FromArgb(0, 255, 255, 255) }; cb.Positions = new float[] { 0, 0.5f, 1 };
                    shine.InterpolationColors = cb;
                    Region old = g.Clip; g.SetClip(p, CombineMode.Intersect); g.FillRectangle(shine, sr); g.Clip = old; old.Dispose();
                }
            }
            int gs = Math.Max(4, (int)(tile.Width * 0.66f));
            g.DrawImage(UpdGlyph(gs), tile.X + (tile.Width - gs) / 2f, tile.Y + (tile.Height - gs) / 2f + tile.Height * 0.02f, gs, gs);
        }

        // Посылка: коробка цветов приложения с лентой и бантом; lid — крышка над коробкой (<0 — поднята).
        static void PaintGift(Graphics g, float cx, float bottom, float size, float lid, float lidAlpha) {
            RectangleF box = new RectangleF(cx - size / 2, bottom - size * 0.86f, size, size * 0.86f);
            using (GraphicsPath p = UpdRound(box, size * 0.12f))
            using (LinearGradientBrush lg = new LinearGradientBrush(box, Color.FromArgb(10, 132, 255), Color.FromArgb(94, 92, 230), 90f)) {
                lg.WrapMode = WrapMode.TileFlipXY; g.FillPath(lg, p);
                using (SolidBrush rib = new SolidBrush(Color.FromArgb(235, 255, 255, 255))) g.FillRectangle(rib, cx - size * 0.07f, box.Y, size * 0.14f, box.Height);
                using (SolidBrush shade = new SolidBrush(Color.FromArgb(40, 0, 0, 0))) g.FillRectangle(shade, box.X, box.Y, box.Width, size * 0.07f);
            }
            if (lidAlpha <= 0.01f) return;
            int a = (int)(255 * Math.Max(0, Math.Min(1, lidAlpha)));
            float tilt = Math.Max(-40f, Math.Min(0f, lid * 0.6f));
            GraphicsState st = g.Save();
            g.TranslateTransform(cx, box.Y + lid * size * 0.06f); g.RotateTransform(tilt);
            RectangleF lr = new RectangleF(-size * 0.56f, -size * 0.24f, size * 1.12f, size * 0.26f);
            using (GraphicsPath p = UpdRound(lr, size * 0.08f))
            using (LinearGradientBrush lg = new LinearGradientBrush(lr, Color.FromArgb(a, 64, 156, 255), Color.FromArgb(a, 110, 100, 240), 90f)) { lg.WrapMode = WrapMode.TileFlipXY; g.FillPath(lg, p); }
            using (SolidBrush rib = new SolidBrush(Color.FromArgb(a * 235 / 255, 255, 255, 255))) {
                g.FillRectangle(rib, -size * 0.07f, lr.Y, size * 0.14f, lr.Height);
                float bw = size * 0.22f, bh = size * 0.16f, by = lr.Y - bh * 0.8f;   // бант
                g.FillEllipse(rib, -bw - size * 0.01f, by, bw, bh);
                g.FillEllipse(rib, size * 0.01f, by, bw, bh);
                g.FillEllipse(rib, -size * 0.06f, by + bh * 0.25f, size * 0.12f, size * 0.12f);
            }
            g.Restore(st);
        }

        void PaintUpdateProgress(Graphics g, Rectangle area) {
            UpdTick();
            WakeUi();   // 60 кадров/с, пока сценка видна
            g.SmoothingMode = SmoothingMode.AntiAlias;
            string phase = UpdPhase;
            bool done = phase == "done", err = phase == "error";
            Color acc = err ? Color.FromArgb(255, 69, 58) : done ? Color.FromArgb(48, 209, 88) : theme.Accent;
            float t = (float)(DateTime.UtcNow - updBorn).TotalSeconds;
            double since = (DateTime.UtcNow - updPhaseAt).TotalSeconds;
            Color bg = Pal(0x161618);
            Draw.Fill(g, area, theme.S(18), bg);
            Region oldClip = g.Clip; g.SetClip(area, CombineMode.Intersect);
            GraphicsState all = g.Save();

            // --- Шапка: плитка приложения, заголовок, шаг (сменяется с наплывом), точки шагов справа ---
            int pad = theme.S(20);
            float tsz = theme.S(40);
            RectangleF tile = new RectangleF(area.X + pad, area.Y + pad, tsz, tsz);
            float pop = 1f + (float)updPop * 0.10f;
            GraphicsState hs = g.Save();
            g.TranslateTransform(tile.X + tsz / 2, tile.Y + tsz / 2); g.ScaleTransform(pop, pop); g.TranslateTransform(-(tile.X + tsz / 2), -(tile.Y + tsz / 2));
            PaintAppTile(g, tile, t);
            g.Restore(hs);
            int tx = (int)(tile.Right + theme.S(14));
            int stepsW = 0;
            for (int i = 0; i < UpdSteps.Length; i++) stepsW += theme.S(9) + theme.S(6) + UpdLabelW(UpdSteps[i]) + (i < UpdSteps.Length - 1 ? theme.S(16) : 0);
            int tw = area.Right - pad - stepsW - theme.S(24) - tx;
            TextRenderer.DrawText(g, done ? "Claude Notifier обновлён" : err ? "Обновление не удалось" : "Обновление Claude Notifier", fTitle,
                new Rectangle(tx, (int)tile.Y - theme.S(2), tw, theme.S(24)), Fg, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            double ch = UEase(since / 0.3);
            Color textCol = err ? Color.FromArgb(255, 120, 110) : done ? Color.FromArgb(100, 220, 130) : Pal(0xAEAEB2);
            int ty = (int)tile.Y + theme.S(22);
            if (ch < 1 && updPrevText.Length > 0)
                TextRenderer.DrawText(g, updPrevText, fBody, new Rectangle(tx, (int)(ty - theme.S(8) * ch), tw, theme.S(22)), Draw.Mix(bg, Pal(0xAEAEB2), (float)(1 - ch)), TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            TextRenderer.DrawText(g, UpdText(phase, UpdDetail), fBody, new Rectangle(tx, (int)(ty + theme.S(8) * (1 - ch)), tw, theme.S(22)), Draw.Mix(bg, textCol, (float)ch), TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            int cur = done ? 3 : UpdStep(err ? updLast : phase);
            float sx = area.Right - pad - theme.S(6) - stepsW, dd = theme.S(9), sy = tile.Y + tsz / 2 - dd / 2f;
            for (int i = 0; i < UpdSteps.Length; i++) {
                bool doneStep = i < cur, now = i == cur;
                Color dc = doneStep ? Color.FromArgb(48, 209, 88) : now ? acc : Pal(0x48484A);
                if (now && !done && !err) {
                    float pulse = (float)(0.5 + 0.5 * Math.Sin(t * 5));
                    using (SolidBrush halo = new SolidBrush(Color.FromArgb((int)(80 * pulse), acc))) g.FillEllipse(halo, sx - theme.S(4), sy - theme.S(4), dd + theme.S(8), dd + theme.S(8));
                }
                using (SolidBrush b = new SolidBrush(dc)) g.FillEllipse(b, sx, sy, dd, dd);
                int lw = UpdLabelW(UpdSteps[i]), lh = theme.S(18);
                TextRenderer.DrawText(g, UpdSteps[i], fSmall, new Rectangle((int)(sx + dd + theme.S(6)), (int)(sy + dd / 2 - lh / 2f), lw + theme.S(4), lh), doneStep || now ? Pal(0xE5E5EA) : Pal(0x6E6E73),
                    TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.NoClipping);
                sx += dd + theme.S(6) + lw + theme.S(16);
            }

            // --- Сцена: дорожка, посылка, маскоты ---
            g.TranslateTransform((float)updShake, 0);
            float groundY = area.Bottom - theme.S(44);
            float x0 = area.X + theme.S(120), x1 = area.Right - theme.S(170);
            float trackH = theme.S(10);
            RectangleF trk = new RectangleF(x0, groundY, x1 - x0, trackH);
            using (GraphicsPath tp = UpdRound(trk, trackH / 2)) using (SolidBrush tb = new SolidBrush(Pal(0x2C2C2E))) g.FillPath(tb, tp);
            float pos = (float)Math.Max(0, Math.Min(1, updPos));
            float bx = x0 + pos * (x1 - x0);
            RectangleF fill = new RectangleF(x0, groundY, Math.Max(trackH, bx - x0), trackH);
            Color c2 = done ? Color.FromArgb(52, 199, 89) : err ? Color.FromArgb(255, 69, 58) : Color.FromArgb(94, 92, 230);
            using (GraphicsPath fp = UpdRound(fill, trackH / 2))
            using (LinearGradientBrush fb = new LinearGradientBrush(new RectangleF(fill.X - 1, fill.Y, fill.Width + 2, fill.Height), acc, c2, 0f)) {
                fb.WrapMode = WrapMode.TileFlipXY; g.FillPath(fb, fp);
                float hx = fill.X + (float)(((t * 0.8) % 1.3) * fill.Width) - theme.S(30);
                RectangleF hr = new RectangleF(hx, fill.Y, theme.S(60), fill.Height);
                using (LinearGradientBrush hb = new LinearGradientBrush(hr, Color.Transparent, Color.Transparent, 0f)) {
                    ColorBlend cb = new ColorBlend(); cb.Colors = new Color[] { Color.FromArgb(0, 255, 255, 255), Color.FromArgb(110, 255, 255, 255), Color.FromArgb(0, 255, 255, 255) }; cb.Positions = new float[] { 0, 0.5f, 1 };
                    hb.InterpolationColors = cb;
                    Region o2 = g.Clip; g.SetClip(fp, CombineMode.Intersect); g.FillRectangle(hb, hr); g.Clip = o2; o2.Dispose();
                }
            }
            string under = ((int)Math.Round(pos * 100)) + " %";
            TextRenderer.DrawText(g, under, fSmall, new Rectangle((int)(bx - theme.S(40)), (int)(groundY + trackH + theme.S(6)), theme.S(80), theme.S(18)), theme.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPrefix);

            // Финишный флажок в клетку, развевается.
            float fx = x1 + theme.S(18), fTop = groundY - theme.S(84);
            using (Pen pole = new Pen(Pal(0x8E8E93), Math.Max(1.5f, theme.S(3)))) { pole.StartCap = pole.EndCap = LineCap.Round; g.DrawLine(pole, fx, groundY + trackH / 2, fx, fTop); }
            using (GraphicsPath flag = new GraphicsPath()) {
                float fw = theme.S(34), fh = theme.S(22);
                int n = 10; PointF[] topEdge = new PointF[n + 1], botEdge = new PointF[n + 1];
                for (int i = 0; i <= n; i++) {
                    float u = i / (float)n, wave = (float)Math.Sin(t * 6 - u * 4) * theme.S(3) * u;
                    topEdge[i] = new PointF(fx + u * fw, fTop + wave);
                    botEdge[n - i] = new PointF(fx + u * fw, fTop + fh + wave);
                }
                flag.AddLines(topEdge); flag.AddLines(botEdge); flag.CloseFigure();
                using (SolidBrush fbr = new SolidBrush(acc)) g.FillPath(fbr, flag);
                Region o3 = g.Clip; g.SetClip(flag, CombineMode.Intersect);
                using (SolidBrush wsq = new SolidBrush(Color.FromArgb(120, 255, 255, 255))) {
                    float q = theme.S(7.5f);
                    for (int r = 0; r < 4; r++) for (int c = 0; c < 6; c++) if ((r + c) % 2 == 0) g.FillRectangle(wsq, fx + c * q, fTop - theme.S(4) + r * q + (float)Math.Sin(t * 6 - c * 0.6) * theme.S(3) * c / 6f, q, q);
                }
                g.Clip = o3; o3.Dispose();
            }

            // Друг-маскот у финиша: машет, подбадривает; готово — прыгает от радости; ошибка — нервничает.
            float fsz = theme.S(108);
            RectangleF fr = new RectangleF(fx + theme.S(28), groundY + trackH - fsz * 0.93f, fsz, fsz);
            CatMood fm = new CatMood { Play = true, HasLook = true, LookX = -1f, LookY = 0.1f, LookW = 1f };
            if (done) { fm.React = "joy"; fm.ReactAge = (float)((since + 0.3) % 2.5); }
            else if (err) { fm.React = "nervous"; fm.ReactAge = (float)(since % 2.5); }
            else { double wp = t % 4.0; if (wp < 1.6) fm.Wave = (float)Math.Sin(Math.PI * wp / 1.6); }
            try { Mascot.PaintKind(g, fr, UpdFriendKind(), "waiting", T + 1.7f, 7, Animate, fm); } catch { }

            // Посылка — где она на дорожке.
            float gsz = theme.S(64);
            bool pushing = phase == "download" || phase == "verify" || phase == "extract" || phase == "install" || phase == "restart";
            float wobble = pushing ? (float)Math.Sin(t * 6.5) * 1.8f : 0f;   // плавное покачивание, без рывков
            float hop = phase == "download" ? (float)(1 - Math.Cos(t * 13)) * 0.5f * theme.S(2) : 0f;   // мягкий подскок (без излома внизу)
            float gcx = Math.Max(x0 + gsz * 0.5f, Math.Min(bx, x1 - gsz * 0.6f));
            float gBottom = groundY - hop;
            PaintPusher(g, area, phase, gcx, gsz, groundY, trackH, t, since);
            // Готово: значок приложения выпрыгивает из открытой коробки, вокруг сияние.
            if (done) {
                double k = UEaseBack(since / 0.7);
                float isz = theme.S(54) * (float)Math.Max(0, k) * (1f + (float)updPop * 0.08f);
                float rise = (float)(k * theme.S(64)) + (float)Math.Sin(t * 3) * theme.S(3) * (float)Math.Min(1, since);
                if (isz > 2) {
                    float glowR = isz * (1.1f + 0.08f * (float)Math.Sin(t * 4));
                    float gy = gBottom - gsz * 0.5f - rise;
                    using (GraphicsPath gp = new GraphicsPath()) {
                        gp.AddEllipse(gcx - glowR, gy - glowR, glowR * 2, glowR * 2);
                        using (PathGradientBrush pg = new PathGradientBrush(gp)) {
                            pg.CenterColor = Color.FromArgb(110, 120, 230, 160); pg.SurroundColors = new Color[] { Color.FromArgb(0, 120, 230, 160) };
                            g.FillPath(pg, gp);
                        }
                    }
                    // Лучи.
                    using (Pen ray = new Pen(Color.FromArgb((int)(90 * Math.Min(1, since)), 255, 230, 120), Math.Max(1f, theme.S(2)))) {
                        ray.StartCap = ray.EndCap = LineCap.Round;
                        for (int i = 0; i < 10; i++) {
                            double a = i * Math.PI / 5 + t * 0.6;
                            float r0 = isz * 0.75f, r1 = isz * (0.98f + 0.12f * (float)Math.Sin(t * 5 + i));
                            g.DrawLine(ray, gcx + (float)Math.Cos(a) * r0, gy + (float)Math.Sin(a) * r0, gcx + (float)Math.Cos(a) * r1, gy + (float)Math.Sin(a) * r1);
                        }
                    }
                    PaintAppTile(g, new RectangleF(gcx - isz / 2, gy - isz / 2, isz, isz), t);
                }
            }
            GraphicsState gst = g.Save();
            float tipDeg = (float)(updTip * 24) + wobble;
            g.TranslateTransform(gcx + gsz / 2, gBottom); g.RotateTransform(tipDeg); g.TranslateTransform(-(gcx + gsz / 2), -gBottom);
            float lidAlpha = done ? (float)Math.Max(0, 1 - since / 0.6) : 1f;
            PaintGift(g, gcx, gBottom, gsz, (float)updLid, lidAlpha);
            g.Restore(gst);
            if (updConfettiPending) { updConfettiPending = false; UpdBurst(since < 0.3 ? 1.2f : 0.85f); }

            // Над коробкой: лупа (проверка), искры (распаковка), шестерёнки (установка).
            float above = gBottom - gsz - theme.S(30);
            if (phase == "verify") {
                float lx = gcx + (float)Math.Sin(t * 3.2) * gsz * 0.35f, ly = above + (float)Math.Cos(t * 6.4) * theme.S(3);
                int ms = theme.S(26);
                TextRenderer.DrawText(g, "", fIconSmall, new Rectangle((int)(lx - ms / 2f), (int)(ly - ms / 2f), ms, ms), Color.FromArgb(230, 255, 255, 255), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
                float scanY = gBottom - gsz * 0.86f + (float)((Math.Sin(t * 4) + 1) / 2) * gsz * 0.8f;
                using (Pen sp = new Pen(Color.FromArgb(170, 100, 210, 255), Math.Max(1f, theme.S(2)))) g.DrawLine(sp, gcx - gsz * 0.55f, scanY, gcx + gsz * 0.55f, scanY);
            } else if (phase == "extract") {
                for (int i = 0; i < 7; i++) {
                    double ph = (t * 1.3 + i / 7.0) % 1.0;
                    float ex = gcx + (float)Math.Sin(i * 2.1 + t) * gsz * 0.5f * (float)ph, ey = gBottom - gsz * 0.9f - (float)ph * theme.S(44);
                    using (SolidBrush sb = new SolidBrush(Color.FromArgb((int)(220 * (1 - ph)), UpdColors[i % UpdColors.Length]))) PaintStar(g, ex, ey, theme.S(6) * (float)(1 - ph), sb);
                }
            } else if (phase == "install" || phase == "restart") {
                PaintGear(g, gcx - theme.S(11), above, theme.S(26), t * 140f, Color.FromArgb(225, 230, 230, 235));
                PaintGear(g, gcx + theme.S(12), above - theme.S(12), theme.S(18), -t * 200f + 15, Color.FromArgb(225, 120, 170, 255));
            }

            // Конфетти — из коробки.
            foreach (float[] c in updConfetti) {
                GraphicsState cs = g.Save();
                float px = gcx + c[0] * theme.S(1.4f), py = gBottom - gsz * 0.6f + c[1] * theme.S(1.4f);
                g.TranslateTransform(px, py); g.RotateTransform(c[4]);
                float w = theme.S(7), h = theme.S(3.5f) * (0.4f + 0.6f * Math.Abs((float)Math.Cos(c[4] * 0.05f)));
                using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(255 * Math.Max(0, Math.Min(1, c[6]))), UpdColors[(int)c[7]]))) g.FillRectangle(b, -w / 2, -h / 2, w, h);
                g.Restore(cs);
            }
            g.Restore(all);
            g.Clip = oldClip; oldClip.Dispose();
        }

        // Главный маскот толкает посылку (стоит за ней, слева, коробка — впереди него); готово — отходит на шаг
        // и прыгает от радости; ошибка — хватается за голову.
        void PaintPusher(Graphics g, Rectangle area, string phase, float gcx, float gsz, float groundY, float trackH, float t, double since) {
            bool done = phase == "done", err = phase == "error";
            float msz = theme.S(128);
            float mx0 = Math.Max(area.X + theme.S(4), gcx - gsz / 2 - msz * 0.80f);
            if (done) mx0 = gcx - gsz / 2 - msz * 0.80f - (float)(UEase(since / 0.6) * theme.S(16));
            RectangleF mr = new RectangleF(mx0, groundY + trackH - msz * 0.93f, msz, msz);
            CatMood mm = new CatMood { Play = true, HasLook = true, LookX = 1f, LookY = 0f, LookW = 1f, Friend = (float)Affection };
            string mstate = "waiting";
            if (phase == "download") {
                float step = (float)(1 - Math.Cos(t * 13)) * 0.5f;   // шаг — гладкая волна
                mm.Lean = 6f; mm.Lift = 0.03f * step; mm.SquashY = 1f - 0.04f * (1 - step); mm.Shear = 0.04f;
            } else if (phase == "verify") { mm.Brow = 0.6f; mm.Lean = 3f; mm.LookY = 0.3f; mstate = "waiting"; }
            else if (phase == "extract") { mm.Brow = (float)(0.5 + 0.5 * Math.Sin(t * 4)); mm.LookY = 0.5f; mm.AhaAge = (float)(since % 1.8); }
            else if (phase == "install" || phase == "restart") {
                float knock = (float)Math.Pow(Math.Max(0, Math.Sin(t * 8)), 2);
                mm.Lean = 6f + 6f * knock; mm.SquashY = 1f - 0.06f * knock;
            } else if (done) { mm.React = "joy"; mm.ReactAge = (float)(since % 2.5); mstate = "waiting"; mm.LookX = 0.6f; mm.LookY = 0.6f; }
            else if (err) { mm.React = "panic"; mm.ReactAge = (float)Math.Min(2.4, since % 3.2); mstate = "error"; }
            try { Mascot.PaintKind(g, mr, Mascot.For(null), mstate, T, 3, Animate, mm); } catch { }
            // Капелька пота от усердия.
            if (phase == "download" || phase == "install") {
                double dp = (t * 1.1) % 1.0;
                float dx = mr.X + msz * 0.30f - (float)dp * theme.S(12), dy = mr.Y + msz * 0.18f + (float)(dp * dp) * theme.S(26);
                using (SolidBrush drop = new SolidBrush(Color.FromArgb((int)(200 * (1 - dp)), 120, 200, 255))) g.FillEllipse(drop, dx, dy, theme.S(5), theme.S(7));
            }
        }

        static void PaintStar(Graphics g, float cx, float cy, float r, Brush b) {
            if (r <= 0.3f) return;
            PointF[] pts = new PointF[8];
            for (int i = 0; i < 8; i++) { double a = i * Math.PI / 4; float rr = i % 2 == 0 ? r : r * 0.35f; pts[i] = new PointF(cx + (float)Math.Cos(a) * rr, cy + (float)Math.Sin(a) * rr); }
            g.FillPolygon(b, pts);
        }

        static void PaintGear(Graphics g, float cx, float cy, float d, float angle, Color c) {
            int teeth = 8; float ro = d / 2, ri = ro * 0.74f;
            PointF[] pts = new PointF[teeth * 4];
            for (int i = 0; i < teeth; i++) {
                double a0 = (angle + i * 360.0 / teeth) * Math.PI / 180, w = Math.PI / teeth;
                pts[i * 4] = new PointF(cx + (float)Math.Cos(a0 - w * 0.55) * ri, cy + (float)Math.Sin(a0 - w * 0.55) * ri);
                pts[i * 4 + 1] = new PointF(cx + (float)Math.Cos(a0 - w * 0.32) * ro, cy + (float)Math.Sin(a0 - w * 0.32) * ro);
                pts[i * 4 + 2] = new PointF(cx + (float)Math.Cos(a0 + w * 0.32) * ro, cy + (float)Math.Sin(a0 + w * 0.32) * ro);
                pts[i * 4 + 3] = new PointF(cx + (float)Math.Cos(a0 + w * 0.55) * ri, cy + (float)Math.Sin(a0 + w * 0.55) * ri);
            }
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddPolygon(pts);
                float h = ro * 0.36f; p.AddEllipse(cx - h, cy - h, h * 2, h * 2);
                p.FillMode = FillMode.Alternate;
                using (SolidBrush b = new SolidBrush(c)) g.FillPath(b, p);
            }
        }
    }
}
