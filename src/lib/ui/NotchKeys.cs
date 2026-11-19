// claude-notifier: клавиатура в раскрытой шторке.
// Раскрыли шторку (щелчком или горячей клавишей) — она получает фокус клавиатуры; свернули — фокус возвращается
// окну, где вы были. Клавиши:
//   1–9 — кнопки ответа выбранного сеанса; ← → ↑ ↓ — другой сеанс; Enter — полный ответ / отправить текст;
//   Esc — очистить поле → на главную → свернуть; Ctrl+F или просто начать печатать на главной — поиск по сеансам;
//   на странице ответа — поле «Ответить текстом»: печатаете, Enter — Claude получает это как ваш ответ.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClaudeNotifier.Ui {
    public sealed partial class NotchView {
        string search = "", reply = "";
        bool searchOn, replyOn;
        DateTime replySentAt = DateTime.MinValue;

        public string SearchText { get { return search; } }
        public string ReplyText { get { return reply; } }
        public bool SearchActive { get { return searchOn || search.Length > 0; } }

        protected override bool IsInputKey(Keys keyData) {
            Keys k = keyData & Keys.KeyCode;
            if (k == Keys.Left || k == Keys.Right || k == Keys.Up || k == Keys.Down || k == Keys.Enter || k == Keys.Escape || k == Keys.Tab) return true;
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e) {
            base.OnKeyDown(e);
            if (HandleKey(e.KeyCode, e.Control, e.Shift)) { e.Handled = true; e.SuppressKeyPress = true; }
        }

        protected override void OnKeyPress(KeyPressEventArgs e) {
            base.OnKeyPress(e);
            if (HandleChar(e.KeyChar)) e.Handled = true;
        }

        bool CanTextReply(NotchItem it) {
            if (it == null) return false;
            foreach (string a in it.Actions) { string id = a.Split('|')[0]; if (id == "reply-custom" || id == "answer-custom") return true; }
            return false;
        }

        // Клавиша. true — обработана (символ тогда не вводится).
        public bool HandleKey(Keys k, bool ctrl, bool shift) {
            if (!Expanded) return false;
            if (k == Keys.Escape) {
                if (replyOn && reply.Length > 0) reply = "";
                else if (replyOn) replyOn = false;
                else if (search.Length > 0 || searchOn) { search = ""; searchOn = false; }
                else if (Page != "home") ClickArea("page:home", Point.Empty);
                else ClickArea("close", Point.Empty);
                Invalidate(); return true;
            }
            if (ctrl && k == Keys.F) {
                if (Page != "home") ClickArea("page:home", Point.Empty);
                searchOn = true; replyOn = false; Invalidate(); return true;
            }
            if (k == Keys.Back) {
                if (replyOn && reply.Length > 0) { reply = reply.Substring(0, reply.Length - 1); Invalidate(); return true; }
                if (searchOn && search.Length > 0) { search = search.Substring(0, search.Length - 1); Invalidate(); return true; }
                return false;
            }
            if (k == Keys.Enter) {
                if (replyOn) { SendReply(); return true; }
                if (Page == "home" && Selected != null) { ClickArea("answer", Point.Empty); return true; }
                if (Page == "answer" && CanTextReply(Selected)) { replyOn = true; Invalidate(); return true; }
                return false;
            }
            if (replyOn) return false;   // печатают ответ — стрелки и цифры как текст
            if (k == Keys.Left || k == Keys.Up) { SelectRelative(-1); return true; }
            if (k == Keys.Right || k == Keys.Down) { SelectRelative(1); return true; }
            if (!ctrl && !searchOn && (Page == "home" || Page == "answer") && k >= Keys.D1 && k <= Keys.D9) {
                NotchItem it = Selected;
                int n = k - Keys.D1;
                if (it != null && n < it.Actions.Length) { ClickArea("act:" + it.Actions[n].Split('|')[0], Point.Empty); return true; }
            }
            return false;
        }

        // Символ: в поле ответа, в поиск (на главной начать печатать — уже поиск).
        public bool HandleChar(char c) {
            if (!Expanded || char.IsControl(c)) return false;
            if (replyOn) { if (reply.Length < 2000) reply += c; Invalidate(); return true; }
            if (Page == "answer" && CanTextReply(Selected)) { replyOn = true; reply += c; Invalidate(); return true; }
            if (Page == "home") { searchOn = true; if (search.Length < 60) search += c; Invalidate(); return true; }
            return false;
        }

        // Свернули шторку: поиск закрыт (черновик ответа остаётся).
        public void EndTyping() { searchOn = false; search = ""; replyOn = false; }

        void SendReply() {
            NotchItem it = Selected;
            string text = reply.Trim();
            if (it == null || text.Length == 0) return;
            EventHandler<NotchEventArgs> h = Command;
            if (h != null) h(this, new NotchEventArgs("text", it.Id, text, Point.Empty));
            reply = ""; replyOn = false; replySentAt = DateTime.UtcNow;
            WakeUi(); Invalidate();
        }

        public bool Matches(NotchItem it) {
            if (search.Length == 0 || it == null) return true;
            string q = search.Trim();
            if (q.Length == 0) return true;
            foreach (string s in new string[] { it.Title, it.Meta, it.Group, it.StateText, it.Preview, it.Ask })
                if (!string.IsNullOrEmpty(s) && s.IndexOf(q, StringComparison.CurrentCultureIgnoreCase) >= 0) return true;
            return false;
        }

        // Выбрать соседний сеанс (с учётом поиска).
        void SelectRelative(int d) {
            List<NotchItem> list = new List<NotchItem>();
            foreach (NotchItem it in items) if (Matches(it)) list.Add(it);
            if (list.Count == 0) return;
            NotchItem sel = Selected;
            int i = sel != null ? list.FindIndex(delegate (NotchItem x) { return x.Id == sel.Id; }) : -1;
            i = ((i < 0 ? 0 : i + d) % list.Count + list.Count) % list.Count;
            SelectedId = list[i].Id;
            ResetScroll("answer");
            Invalidate();
        }

        // Поле поиска вверху списка сеансов. Возвращает высоту, которую оно заняло.
        int PaintSearchField(Graphics g, Rectangle r) {
            if (!SearchActive) return 0;
            int h = theme.S(30);
            Rectangle f = new Rectangle(r.X, r.Y, r.Width, h);
            Draw.Fill(g, f, h / 2f, Pal(0x232326));
            TextRenderer.DrawText(g, "", fIconSmall, new Rectangle(f.X + theme.S(8), f.Y, theme.S(20), h), Pal(0x98989D), TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPrefix);
            Rectangle tr = new Rectangle(f.X + theme.S(32), f.Y, f.Width - theme.S(40), h);
            if (search.Length == 0) TextRenderer.DrawText(g, "Поиск по сеансам", fBody, tr, theme.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            else {
                TextRenderer.DrawText(g, search, fBody, tr, Fg, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
                int cw = Math.Min(tr.Width, TextRenderer.MeasureText(search, fBody).Width - theme.S(4));
                using (Pen caret = new Pen(theme.Accent, Math.Max(1f, theme.S(1.5f)))) g.DrawLine(caret, tr.X + cw + theme.S(2), f.Y + theme.S(8), tr.X + cw + theme.S(2), f.Bottom - theme.S(8));
            }
            return h + theme.S(8);
        }

        // Поле «Ответить текстом» в нижней строке страницы ответа (правее кнопок).
        void PaintReplyField(Graphics g, Rectangle f) {
            if (f.Width < theme.S(120)) return;
            bool sent = (DateTime.UtcNow - replySentAt).TotalSeconds < 1.6;
            float hh = Hot("reply-field");
            Draw.Fill(g, f, f.Height / 2f, replyOn ? Pal(0x2C2C2E) : Draw.Mix(Pal(0x1F1F22), Pal(0x2A2A2D), hh));
            if (replyOn) using (System.Drawing.Drawing2D.GraphicsPath p = Draw.Round(new RectangleF(f.X + 0.5f, f.Y + 0.5f, f.Width - 1, f.Height - 1), f.Height / 2f))
                using (Pen ring = new Pen(Color.FromArgb(160, theme.Accent), Math.Max(1f, theme.S(1.2f)))) g.DrawPath(ring, p);
            Rectangle tr = new Rectangle(f.X + theme.S(14), f.Y, f.Width - theme.S(28), f.Height);
            if (sent) TextRenderer.DrawText(g, "✓ Отправлено", fBold, tr, Pal(0x30D158), TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            else if (reply.Length == 0) TextRenderer.DrawText(g, replyOn ? "Напишите ответ и нажмите Enter" : "Ответить текстом…", fBody, tr, theme.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            else {
                // Длинный текст — видно конец (где печатают).
                string shown = reply;
                while (shown.Length > 1 && TextRenderer.MeasureText(shown, fBody).Width > tr.Width - theme.S(6)) shown = shown.Substring(1);
                TextRenderer.DrawText(g, shown, fBody, tr, Fg, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
                int cw = Math.Min(tr.Width - theme.S(2), TextRenderer.MeasureText(shown, fBody).Width - theme.S(4));
                using (Pen caret = new Pen(theme.Accent, Math.Max(1f, theme.S(1.5f)))) g.DrawLine(caret, tr.X + cw + theme.S(2), f.Y + theme.S(8), tr.X + cw + theme.S(2), f.Bottom - theme.S(8));
            }
            Hit(f, "reply-field");
        }
    }

    public sealed partial class NotchForm {
        IntPtr prevForeground;
        public bool HasKeyboard;

        // Раскрыли — шторка принимает клавиши (и снимает «не активироваться»); свернули — фокус прежнему окну.
        void TakeKeyboard() {
            if (!IsHandleCreated || !Visible || HasKeyboard) return;
            try {
                prevForeground = KeyboardNative.GetForegroundWindow();
                KeyboardNative.SetNoActivate(Handle, false);
                KeyboardNative.SetForegroundWindow(Handle);
                View.Focus();
                HasKeyboard = true;
            } catch { }
        }

        public void EnsureKeyboard() { TakeKeyboard(); }

        void ReleaseKeyboard() {
            if (!HasKeyboard) return;
            HasKeyboard = false;
            try {
                KeyboardNative.SetNoActivate(Handle, true);
                if (KeyboardNative.GetForegroundWindow() == Handle && prevForeground != IntPtr.Zero) KeyboardNative.SetForegroundWindow(prevForeground);
            } catch { }
            prevForeground = IntPtr.Zero;
        }
    }

    static class KeyboardNative {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] static extern int GetWindowLong(IntPtr h, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLong")] static extern int SetWindowLong(IntPtr h, int index, int value);
        const int GWL_EXSTYLE = -20, WS_EX_NOACTIVATE = 0x08000000;
        public static void SetNoActivate(IntPtr h, bool on) {
            int ex = GetWindowLong(h, GWL_EXSTYLE);
            int want = on ? ex | WS_EX_NOACTIVATE : ex & ~WS_EX_NOACTIVATE;
            if (want != ex) SetWindowLong(h, GWL_EXSTYLE, want);
        }
    }
}
