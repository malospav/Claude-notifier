// claude-notifier: сеансы в раскрытой шторке — мелочи, которые помогают каждый день.
//   * Лента сеанса под полным ответом: ваши сообщения, ответы Claude и его действия (последние 5).
//   * Закреплённые сеансы — со звёздочкой, всегда первыми.
//   * Сколько сеанс ждёт вас: «12 мин» на плашке; со временем плашка мягко краснеет.
//   * «Разрешить все»: несколько запросов разрешения в одном проекте — одной кнопкой (второе нажатие подтверждает).
//   * Перетащите файл из Проводника на плашку или карточку сеанса — путь уйдёт Claude ответом.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ClaudeNotifier.Ui {
    static class FsNative {
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; }
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
        // Окно закрывает весь монитор (с панелью задач). Рабочий стол и панель задач не считаются.
        public static bool CoversMonitor(IntPtr h) {
            System.Text.StringBuilder cls = new System.Text.StringBuilder(64); GetClassName(h, cls, 64);
            string c = cls.ToString();
            if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return false;
            RECT r; if (!GetWindowRect(h, out r)) return false;
            MONITORINFO mi = new MONITORINFO(); mi.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(MONITORINFO));
            if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) return false;
            return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
        }
    }

    public sealed partial class NotchView {
        string allowArmed;                       // проект, для которого «Разрешить все» ждёт подтверждения
        DateTime allowArmedAt = DateTime.MinValue;
        string dropHover;                        // над какой плашкой держат файлы
        public bool UpdateAvailable;             // есть обновление приложения — значок в верхней панели
        public string DropHover { get { return dropHover; } }

        // --- Сколько ждёт ---

        public static int WaitMinutes(NotchItem it, DateTime nowUtc) {
            if (it == null || it.WaitSince <= 0) return -1;
            double m = (nowUtc - new DateTime(it.WaitSince, DateTimeKind.Utc)).TotalMinutes;
            return m < 0 ? 0 : (int)m;
        }

        public static string WaitText(int minutes) {
            if (minutes < 1) return "";
            if (minutes < 60) return minutes + " мин";
            if (minutes < 60 * 24) return (minutes / 60) + " ч " + (minutes % 60).ToString("00") + " мин";
            return (minutes / (60 * 24)) + " дн";
        }

        // 0 — только что, 1 — ждёт полчаса и дольше.
        public static float WaitUrgency(int minutes) { return minutes < 2 ? 0f : Math.Min(1f, (minutes - 2) / 28f); }

        void PaintWaitTint(Graphics g, RectangleF r, NotchItem it) {
            float u = WaitUrgency(WaitMinutes(it, DateTime.UtcNow));
            if (u <= 0) return;
            Draw.Fill(g, r, r.Height / 2f, Color.FromArgb((int)(u * 70), 255, 69, 58));
        }

        // Время ожидания справа на плашке. Возвращает, сколько места оно заняло.
        int PaintWaitLabel(Graphics g, NotchItem it, int right, int y, int h) {
            int m = WaitMinutes(it, DateTime.UtcNow);
            string t = WaitText(m);
            if (t.Length == 0) return 0;
            int w = TextRenderer.MeasureText(t, fSmall).Width;
            Color c = Draw.Mix(theme.Muted, Color.FromArgb(255, 105, 97), WaitUrgency(m));
            TextRenderer.DrawText(g, t, fSmall, new Rectangle(right - w, y, w, h), c, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            return w + theme.S(6);
        }

        // Звёздочка закреплённого сеанса перед именем. Возвращает ширину.
        int PaintPinStar(Graphics g, NotchItem it, int x, int y, int h) {
            if (!it.Pinned) return 0;
            int w = theme.S(16);
            TextRenderer.DrawText(g, "", fIconSmall, new Rectangle(x, y, w, h), Color.FromArgb(255, 214, 10),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            return w + theme.S(2);
        }

        // Значок «ждёт N мин» на карточке выбранного сеанса (левее стрелки «перейти»).
        // Плашка «ждёт 9 мин» у правого края строки заголовка. Возвращает её ширину (0 — не ждёт), чтобы заголовок
        // и «Терминал / Приложение» не заезжали под неё.
        int PaintMainWait(Graphics g, NotchItem it, int right, int y) {
            int m = WaitMinutes(it, DateTime.UtcNow);
            string t = WaitText(m);
            if (t.Length == 0) return 0;
            t = "ждёт " + t;
            float u = WaitUrgency(m);
            int w = TextRenderer.MeasureText(t, fSmall, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix).Width + theme.S(22), h = theme.S(24);
            Rectangle r = new Rectangle(right - w, y, w, h);
            Draw.Fill(g, r, h / 2f, Color.FromArgb(40 + (int)(u * 80), 255, 69, 58));
            TextRenderer.DrawText(g, t, fSmall, r, Draw.Mix(Pal(0xE5E5EA), Color.FromArgb(255, 160, 150), u),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            return w;
        }

        // --- «Разрешить все» ---

        // Сколько сеансов этого проекта ждут разрешения (вместе с выбранным); меньше двух — кнопки нет.
        public int AllowAllCount(NotchItem it) {
            if (it == null || it.State != "permission" || string.IsNullOrEmpty(it.Project)) return 0;
            bool hasAllow = false;
            foreach (string a in it.Actions) if (a.Split('|')[0] == "allow") hasAllow = true;
            if (!hasAllow) return 0;
            int n = 0;
            foreach (NotchItem x in items) if (x.State == "permission" && x.Project == it.Project) n++;
            return n >= 2 ? n : 0;
        }

        public bool AllowAllArmed(NotchItem it) {
            return it != null && allowArmed == it.Project && (DateTime.UtcNow - allowArmedAt).TotalSeconds < 4;
        }

        // Кнопка после кнопок ответа. Возвращает её ширину с отступом (0 — не нарисована).
        int PaintAllowAll(Graphics g, NotchItem it, int x, int y, int h, int maxRight) {
            int n = AllowAllCount(it);
            if (n == 0) return 0;
            string text = AllowAllArmed(it) ? "Точно? Разрешить " + n : "Разрешить все · " + n;
            int w = TextRenderer.MeasureText(text, fBold).Width + theme.S(22);
            if (x + w > maxRight) return 0;
            Rectangle r = new Rectangle(x, y, w, h);
            PaintPill(g, r, text, AllowAllArmed(it) ? "primary" : "secondary", "allowall");
            Hit(r, "allowall");
            return w + theme.S(6);
        }

        // Дополнительные щелчки (из ClickArea). true — обработан.
        bool ExtraClick(string hit, Point p) {
            if (hit != "allowall") return false;
            NotchItem it = Selected;
            if (it == null || AllowAllCount(it) == 0) return true;
            if (!AllowAllArmed(it)) { allowArmed = it.Project; allowArmedAt = DateTime.UtcNow; WakeUi(); Invalidate(); return true; }
            allowArmed = null;
            MarkSent("allow");
            EventHandler<NotchEventArgs> h = Command;
            if (h != null) h(this, new NotchEventArgs("allowall", it.Id, it.Project, p));
            Invalidate();
            return true;
        }

        // --- Лента сеанса ---

        struct FeedLine { public string Kind, Time, Text; }

        static List<FeedLine> ParseFeed(NotchItem it) {
            List<FeedLine> l = new List<FeedLine>();
            if (it == null || it.Feed == null) return l;
            foreach (string s in it.Feed) {
                if (string.IsNullOrEmpty(s)) continue;
                string[] p = s.Split(new char[] { '|' }, 3);
                if (p.Length < 3 || p[2].Trim().Length == 0) continue;
                FeedLine f; f.Kind = p[0]; f.Time = p[1]; f.Text = p[2];
                l.Add(f);
            }
            return l;
        }

        // Высота ленты под ответом (или 0). При g != null — рисует, начиная с y.
        int PaintFeed(Graphics g, NotchItem it, int x, int y, int width) {
            List<FeedLine> feed = ParseFeed(it);
            if (feed.Count == 0) return 0;
            int y0 = y;
            y += theme.S(14);
            if (g != null) {
                using (Pen sep = new Pen(Pal(0x2C2C2E))) g.DrawLine(sep, x, y, x + width, y);
                TextRenderer.DrawText(g, "ЛЕНТА СЕАНСА", fHeader, new Rectangle(x, y + theme.S(6), width, theme.S(18)), theme.Muted, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            }
            y += theme.S(28);
            int timeW = theme.S(40), bubbleMax = (int)((width - timeW) * 0.86f);
            TextFormatFlags wrap = TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl;
            foreach (FeedLine f in feed) {
                bool tool = f.Kind == "tool";
                int inner = tool ? width - timeW - theme.S(20) : bubbleMax - theme.S(20);
                int tw = Math.Min(inner, TextRenderer.MeasureText(f.Text, fSmall, new Size(inner, int.MaxValue), wrap).Width + theme.S(2));
                int th = TextRenderer.MeasureText(f.Text, fSmall, new Size(Math.Max(theme.S(20), tw), int.MaxValue), wrap).Height;
                int bh = tool ? th + theme.S(4) : th + theme.S(12), bw = tw + theme.S(20);
                if (g != null) {
                    TextRenderer.DrawText(g, f.Time, fSmall, new Rectangle(x, y, timeW, tool ? theme.S(18) : bh), theme.Muted, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter);
                    if (tool) {
                        TextRenderer.DrawText(g, "", fIconSmall, new Rectangle(x + timeW, y, theme.S(16), theme.S(18)), theme.Muted, TextFormatFlags.NoPrefix | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                        TextRenderer.DrawText(g, f.Text, fSmall, new Rectangle(x + timeW + theme.S(20), y + theme.S(1), inner, th + theme.S(2)), theme.Muted, wrap);
                    } else {
                        bool you = f.Kind == "you";
                        int bx = you ? x + width - bw : x + timeW;
                        Rectangle b = new Rectangle(bx, y, bw, bh);
                        Draw.Fill(g, b, theme.S(12), you ? Color.FromArgb(70, theme.Accent) : Pal(0x232326));
                        TextRenderer.DrawText(g, f.Text, fSmall, new Rectangle(bx + theme.S(10), y + theme.S(6), tw, th + theme.S(2)), Pal(0xE5E5EA), wrap);
                    }
                }
                y += bh + theme.S(8);
            }
            return y - y0;
        }

        // --- Файлы из Проводника ---

        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e);
            // Регистрация приёма перетаскивания — только в потоке STA (поток шторки такой; в тестах может не быть).
            if (System.Threading.Thread.CurrentThread.GetApartmentState() == System.Threading.ApartmentState.STA) {
                try { AllowDrop = true; } catch { }
            }
        }

        string DropTargetId(Point p) {
            string hit = HitAt(p);
            if (hit != null && hit.StartsWith("item:")) return hit.Substring(5);
            NotchItem sel = Selected;
            return sel != null ? sel.Id : null;
        }

        static string[] DroppedFiles(IDataObject data) {
            if (data == null || !data.GetDataPresent(DataFormats.FileDrop)) return null;
            string[] f = data.GetData(DataFormats.FileDrop) as string[];
            return f != null && f.Length > 0 ? f : null;
        }

        protected override void OnDragEnter(DragEventArgs e) {
            base.OnDragEnter(e);
            if (DroppedFiles(e.Data) == null || items.Count == 0) { e.Effect = DragDropEffects.None; return; }
            e.Effect = DragDropEffects.Copy;
            if (!Expanded) ClickArea("expand", PointToClient(new Point(e.X, e.Y)));   // свёрнута — раскрыть, чтобы выбрать сеанс
        }

        protected override void OnDragOver(DragEventArgs e) {
            base.OnDragOver(e);
            if (DroppedFiles(e.Data) == null) { e.Effect = DragDropEffects.None; return; }
            e.Effect = DragDropEffects.Copy;
            string id = DropTargetId(PointToClient(new Point(e.X, e.Y)));
            if (id != dropHover) { dropHover = id; Invalidate(); }
        }

        protected override void OnDragLeave(EventArgs e) {
            base.OnDragLeave(e);
            if (dropHover != null) { dropHover = null; Invalidate(); }
        }

        protected override void OnDragDrop(DragEventArgs e) {
            base.OnDragDrop(e);
            string[] files = DroppedFiles(e.Data);
            string id = DropTargetId(PointToClient(new Point(e.X, e.Y)));
            dropHover = null;
            if (files == null || id == null) { Invalidate(); return; }
            DropFiles(id, files, new Point(e.X, e.Y));
        }

        // Файлы → сеансу (трей отправит пути ответом или скопирует их, если Claude сейчас не ждёт).
        public void DropFiles(string id, string[] files, Point screen) {
            List<string> q = new List<string>();
            foreach (string f in files) if (!string.IsNullOrEmpty(f)) q.Add(f.IndexOf(' ') >= 0 ? "\"" + f + "\"" : f);
            if (q.Count == 0) return;
            EventHandler<NotchEventArgs> h = Command;
            if (h != null) h(this, new NotchEventArgs("files", id, string.Join(" ", q.ToArray()), screen));
            WakeUi(); Invalidate();
        }

        // --- Приложение на весь экран (игра, видео): анимация шторки на его мониторе не нужна ---
        bool fullscreenPaused, fullscreenLast;
        DateTime fullscreenAt = DateTime.MinValue;
        public static bool PauseOnFullscreen;   // включает трей при запуске (в тестах выключено)

        bool FullscreenOver() {
            if (!PauseOnFullscreen || !IsHandleCreated) return false;
            DateTime now = DateTime.UtcNow;
            if ((now - fullscreenAt).TotalMilliseconds < 1000) return fullscreenLast;   // проверка — раз в секунду
            fullscreenAt = now;
            fullscreenLast = false;
            try {
                Form f = FindForm();
                IntPtr fg = FsNative.GetForegroundWindow();
                if (fg == IntPtr.Zero || f == null || fg == f.Handle) return false;
                fullscreenLast = FsNative.CoversMonitor(fg) && FsNative.MonitorFromWindow(fg, 2) == FsNative.MonitorFromWindow(f.Handle, 2);
            } catch { fullscreenLast = false; }
            return fullscreenLast;
        }

        // --- Сообщение внизу раскрытой шторки («Отправлено», «Скопировано») ---
        string notice;
        DateTime noticeUntil = DateTime.MinValue;
        public string NoticeText { get { return DateTime.UtcNow < noticeUntil ? notice : null; } }

        public void Notice(string text, int ms) {
            notice = text; noticeUntil = DateTime.UtcNow.AddMilliseconds(Math.Max(500, ms));
            WakeUi(); Invalidate();
        }

        void PaintNotice(Graphics g, int W, int H) {
            string t = NoticeText;
            if (t == null) return;
            double left = (noticeUntil - DateTime.UtcNow).TotalMilliseconds;
            float a = (float)Math.Min(1.0, left / 300.0);
            int w = Math.Min(W - theme.S(40), TextRenderer.MeasureText(t, fBody).Width + theme.S(32)), h = theme.S(32);
            Rectangle r = new Rectangle((W - w) / 2, H - h - theme.S(14), w, h);
            Draw.Fill(g, r, h / 2f, Color.FromArgb((int)(235 * a), Pal(0x2C2C2E)));
            TextRenderer.DrawText(g, t, fBody, r, Draw.Mix(Bg, Fg, a), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            WakeUi();
        }

        // Рамка вокруг плашки, над которой держат файлы.
        void PaintDropRing(Graphics g, RectangleF r, string id) {
            if (dropHover == null || dropHover != id) return;
            using (GraphicsPath p = Draw.Round(new RectangleF(r.X + 0.5f, r.Y + 0.5f, r.Width - 1, r.Height - 1), r.Height / 2f))
            using (Pen ring = new Pen(theme.Accent, Math.Max(1.5f, theme.S(2f)))) g.DrawPath(ring, p);
        }
    }
}
