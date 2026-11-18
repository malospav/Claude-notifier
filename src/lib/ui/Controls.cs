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
    // Точка статуса для трея — системные цвета Apple; «нет сеансов» — серое кольцо.
    public static class TrayDot {
        public static Color ColorFor(string state) {
            switch (state) {
                case "permission": case "alert": return Theme.Hex(0xFF9F0A);
                case "error": case "stalled": return Theme.Hex(0xFF453A);
                case "working": return Theme.Hex(0x0A84FF);
                case "waiting": return Theme.Hex(0x30D158);
                default: return Theme.Hex(0x8E8E93);
            }
        }

        public static Bitmap Render(string state, int size) {
            Bitmap bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.Clear(Color.Transparent);
                float d = size * 0.625f;
                float c = size / 2f;
                Color col = ColorFor(state);
                if (state == "alert") {
                    // Второй кадр мигания «запрос давно ждёт»: точка во всю иконку с ореолом.
                    float big = size * 0.94f, core = size * 0.72f;
                    using (SolidBrush halo = new SolidBrush(Color.FromArgb(110, col))) g.FillEllipse(halo, c - big / 2, c - big / 2, big, big);
                    using (SolidBrush b = new SolidBrush(col)) g.FillEllipse(b, c - core / 2, c - core / 2, core, core);
                    return bmp;
                }
                bool hollow = !(state == "permission" || state == "error" || state == "working" || state == "waiting");
                if (hollow) {
                    using (Pen p = new Pen(col, Math.Max(1.5f, size / 9f))) g.DrawEllipse(p, c - d / 2, c - d / 2, d, d);
                } else {
                    using (SolidBrush b = new SolidBrush(col)) g.FillEllipse(b, c - d / 2, c - d / 2, d, d);
                    using (Pen p = new Pen(Color.FromArgb(70, 0, 0, 0), Math.Max(1f, size / 20f))) g.DrawEllipse(p, c - d / 2, c - d / 2, d, d);
                }
            }
            return bmp;
        }

        public static Icon Create(string state, int size) {
            using (Bitmap bmp = Render(state, size)) return Native.ToIcon(bmp);
        }

        // Точка с числом: сколько сеансов ждут вас (больше 9 — «9+»). Точка во всю иконку, цифра белая.
        public static Bitmap Render(string state, int size, int count) {
            if (count < 2) return Render(state, size);
            Bitmap bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                g.Clear(Color.Transparent);
                float d = size * 0.96f, c = size / 2f;
                using (SolidBrush b = new SolidBrush(ColorFor(state))) g.FillEllipse(b, c - d / 2, c - d / 2, d, d);
                string text = count > 9 ? "9+" : count.ToString();
                using (Font f = new Font("Segoe UI", size * (text.Length > 1 ? 0.5f : 0.66f), FontStyle.Bold, GraphicsUnit.Pixel))
                using (StringFormat sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString(text, f, Brushes.White, new RectangleF(0, size * 0.03f, size, size), sf);
            }
            return bmp;
        }

        public static Icon Create(string state, int size, int count) {
            using (Bitmap bmp = Render(state, size, count)) return Native.ToIcon(bmp);
        }
    }


    // ===================== Шторка вверху экрана =====================
    // Главное окно приложения: свёрнутая — полоска с персонажами сеансов, раскрытая — страницы «Главная», «Ответ»,
    // «Статистика», «Устройства», «Настройки». Работает в своём потоке (NotchHost): анимация не зависит от того,
    // чем занят трей; щелчки уходят в очередь Commands, трей забирает их в своём таймере.

    // Кнопка-капсула. Стили: primary (акцент), secondary (серая заливка), plain (только текст акцента), destructive.
    // Нажатие: сжатие до 0.97 за 100 мс сразу при нажатии, возврат за 160 мс (ease-out).
    public sealed class Button2 : Control, IButtonControl {
        Theme theme = Theme.Create(false);
        bool hot;
        readonly Tween press = new Tween(1f);
        string style = "secondary";
        public DialogResult DialogResult { get; set; }

        public Button2() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.ResizeRedraw | ControlStyles.Selectable | ControlStyles.SupportsTransparentBackColor, true);
            TabStop = true;
            Cursor = Cursors.Hand;
            Font = Fonts.Text(10f);
            press.Changed += delegate { Invalidate(); };
        }

        public bool Primary { get { return style == "primary"; } set { Style = value ? "primary" : "secondary"; } }
        public string Style { get { return style; } set { style = value ?? "secondary"; Font = (style == "primary" || style == "plain") ? Fonts.Semibold(10f) : Fonts.Text(10f); Invalidate(); } }

        public void ApplyTheme(Theme t) { theme = t; Style = style; }

        public override Size GetPreferredSize(Size proposed) {
            Size s = TextRenderer.MeasureText(Text ?? "", Font, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            int pad = style == "plain" ? theme.S(12) : theme.S(36);
            return new Size(s.Width + pad, theme.S(34));
        }

        public void FitWidth() { Size = GetPreferredSize(Size.Empty); }

        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(BackColor);
            float s = press.Value;
            g.TranslateTransform(Width / 2f, Height / 2f);
            g.ScaleTransform(s, s);
            g.TranslateTransform(-Width / 2f, -Height / 2f);
            Color fill, text;
            switch (style) {
                case "primary": fill = hot ? theme.AccentHover : theme.Accent; text = theme.AccentText; break;
                case "plain": fill = Color.Transparent; text = hot ? theme.AccentHover : theme.Accent; break;
                case "destructive": fill = hot ? Draw.Mix(theme.Fill, theme.Text, 0.04f) : theme.Fill; text = theme.Danger; break;
                default: fill = hot ? Draw.Mix(theme.Fill, theme.Text, 0.04f) : theme.Fill; text = theme.Text; break;
            }
            if (!Enabled) { text = theme.Muted; }
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1, Height - 1);
            if (fill.A > 0) Draw.Fill(g, r, Height / 2f, fill);
            if (Focused && ShowFocusCues) {
                using (GraphicsPath p = Draw.Round(new RectangleF(1.5f, 1.5f, Width - 3, Height - 3), Height / 2f - 1))
                using (Pen pen = new Pen(Color.FromArgb(140, theme.Accent), 2f)) g.DrawPath(pen, p);
            }
            TextRenderer.DrawText(g, Text ?? "", Font, ClientRectangle, text, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine |
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            g.ResetTransform();
        }

        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hot = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hot = false; press.Animate(1f, 160); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) { Focus(); press.Animate(0.97f, 100); } }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); press.Animate(1f, 160); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }

        protected override bool IsInputKey(Keys k) { return k == Keys.Space || k == Keys.Enter || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e) {
            base.OnKeyDown(e);
            // Действия с клавиатуры не анимируются.
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { PerformClick(); e.Handled = true; }
        }

        public void NotifyDefault(bool value) { }
        public void PerformClick() { if (Enabled) OnClick(EventArgs.Empty); }
        protected override void OnClick(EventArgs e) {
            base.OnClick(e);
            Form f = FindForm();
            if (f != null && DialogResult != DialogResult.None) f.DialogResult = DialogResult;
        }

        protected override void Dispose(bool disposing) { if (disposing) press.Dispose(); base.Dispose(disposing); }
    }

    // Сегментный переключатель Apple: дорожка с заливкой, «ползунок» с тенью плавно переезжает (220 мс, ease-out).
    public sealed class Tabs : Control {
        Theme theme = Theme.Create(false);
        readonly List<string> titles = new List<string>();
        readonly Tween thumb = new Tween(0);
        int selectedIndex;
        Font fNormal, fSelected;
        public event EventHandler SelectedIndexChanged;

        public Tabs() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            Cursor = Cursors.Hand;
            fNormal = Fonts.Text(9.5f); fSelected = Fonts.Semibold(9.5f);
            thumb.Changed += delegate { Invalidate(); };
        }

        public void ApplyTheme(Theme t) { theme = t; BackColor = t.Window; Height = t.S(34); Invalidate(); }
        public void SetTitles(params string[] list) { titles.Clear(); titles.AddRange(list); Invalidate(); }
        public void SetTitle(int i, string text) { if (i >= 0 && i < titles.Count) { titles[i] = text; Invalidate(); } }

        public int SelectedIndex {
            get { return selectedIndex; }
            set {
                if (value == selectedIndex || value < 0 || value >= titles.Count) return;
                selectedIndex = value;
                thumb.Animate(value, 220);
                EventHandler h = SelectedIndexChanged; if (h != null) h(this, EventArgs.Empty);
            }
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.Clear(BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (titles.Count == 0) return;
            RectangleF track = new RectangleF(0, 0, Width - 1, Height - 1);
            Draw.Fill(g, track, theme.S(9), theme.Fill);
            float pad = theme.S(2.5f);
            float segW = (track.Width - 2 * pad) / titles.Count;
            RectangleF knob = new RectangleF(pad + thumb.Value * segW, pad, segW, track.Height - 2 * pad);
            if (!theme.Dark) Draw.Shadow(g, knob, theme.S(7), 40);
            Draw.Fill(g, knob, theme.S(7), theme.Thumb);
            for (int i = 0; i < titles.Count; i++) {
                bool sel = i == selectedIndex;
                Rectangle r = new Rectangle((int)(pad + i * segW), 0, (int)segW, Height);
                TextRenderer.DrawText(g, titles[i], sel ? fSelected : fNormal, r, theme.Text,
                    TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }

        // Переключение — на нажатие, не на отпускание.
        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            if (titles.Count == 0) return;
            int i = (int)(e.X / (Width / (float)titles.Count));
            SelectedIndex = Math.Max(0, Math.Min(titles.Count - 1, i));
        }

        protected override void Dispose(bool disposing) { if (disposing) thumb.Dispose(); base.Dispose(disposing); }
    }

    // Тумблер Apple: зелёная капсула, белая ручка с тенью; переключается сразу, ручка доезжает за 200 мс.
    public sealed class Switch : Control {
        Theme theme = Theme.Create(false);
        readonly Tween knob = new Tween(0);
        bool on;
        public event EventHandler CheckedChanged;

        public Switch() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            Cursor = Cursors.Hand;
            TabStop = true;
            knob.Changed += delegate { Invalidate(); };
        }

        public void ApplyTheme(Theme t) { theme = t; Size = new Size(t.S(46), t.S(28)); Invalidate(); }

        public bool Checked {
            get { return on; }
            set { if (value == on) return; on = value; knob.Animate(on ? 1f : 0f, 200); }
        }

        // Без анимации и без события: для синхронизации с состоянием.
        public void SetChecked(bool value) { on = value; knob.Set(value ? 1f : 0f); }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.Clear(BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float k = knob.Value;
            Color off = theme.Dark ? Theme.Hex(0x39393D) : Theme.Hex(0xE9E9EA);
            Color onC = theme.State("online");
            RectangleF track = new RectangleF(0.5f, 0.5f, Width - 1, Height - 1);
            Draw.Fill(g, track, Height / 2f, Draw.Mix(off, onC, k));
            float pad = theme.S(2);
            float d = Height - 2 * pad - 1;
            float x = pad + (Width - 1 - 2 * pad - d) * k;
            RectangleF kn = new RectangleF(x, pad, d, d);
            Draw.Shadow(g, kn, d / 2, 45);
            Draw.Fill(g, kn, d / 2, Color.White);
            if (Focused && ShowFocusCues) using (GraphicsPath p = Draw.Round(new RectangleF(1, 1, Width - 3, Height - 3), Height / 2f)) using (Pen pen = new Pen(Color.FromArgb(140, theme.Accent), 2f)) g.DrawPath(pen, p);
        }

        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) { Focus(); Toggle(); } }
        protected override bool IsInputKey(Keys k) { return k == Keys.Space || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e) {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Space) { on = !on; knob.Set(on ? 1f : 0f); RaiseChanged(); e.Handled = true; }
        }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }

        public void Toggle() { Checked = !on; RaiseChanged(); }
        void RaiseChanged() { EventHandler h = CheckedChanged; if (h != null) h(this, EventArgs.Empty); }
        protected override void Dispose(bool disposing) { if (disposing) knob.Dispose(); base.Dispose(disposing); }
    }

    // Код подключения в отдельных ячейках, как одноразовый код в iOS.
    public sealed class PinView : Control {
        Theme theme = Theme.Create(false);
        Font font;
        public PinView() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            font = Fonts.Display(22f);
        }
        public void ApplyTheme(Theme t) { theme = t; Height = t.S(58); Invalidate(); }
        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.Clear(BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            string digits = (Text ?? "").Replace(" ", "");
            if (digits.Length == 0) return;
            float gap = theme.S(8), groupGap = theme.S(18);
            float cell = Math.Min(theme.S(46), (Width - gap * (digits.Length - 2) - groupGap) / digits.Length);
            float total = cell * digits.Length + gap * (digits.Length - 2) + groupGap;
            float x = (Width - total) / 2f;
            for (int i = 0; i < digits.Length; i++) {
                RectangleF r = new RectangleF(x, 0.5f, cell, Height - 1);
                Draw.Fill(g, r, theme.S(10), theme.Surface);
                TextRenderer.DrawText(g, digits[i].ToString(), font, Rectangle.Round(r), theme.Text,
                    TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                x += cell + ((i == digits.Length / 2 - 1) ? groupGap : gap);
            }
        }
    }

    // Подпись: текст с темой; необязательная точка слева; выравнивание по центру.
    public sealed class Label2 : Control {
        Theme theme = Theme.Create(false);
        public bool MutedText;
        public bool Wrap;
        public bool Center;
        public string DotState;
        public Color ForeColorOverride = Color.Empty;

        public Label2() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            Font = Fonts.Text(10f);
        }

        public void ApplyTheme(Theme t) { theme = t; Invalidate(); }
        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }

        public override Size GetPreferredSize(Size proposed) {
            int dot = string.IsNullOrEmpty(DotState) ? 0 : theme.S(18);
            TextFormatFlags fl = TextFormatFlags.NoPrefix | (Wrap ? TextFormatFlags.WordBreak : TextFormatFlags.SingleLine);
            int width = Wrap && proposed.Width > 0 ? proposed.Width - dot : int.MaxValue;
            string text = string.IsNullOrEmpty(Text) ? "Ag" : Text;   // пустая подпись всё равно занимает строку
            Size s = TextRenderer.MeasureText(text, Font, new Size(width, int.MaxValue), fl);
            return new Size((string.IsNullOrEmpty(Text) ? 0 : s.Width) + dot, s.Height);
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.Clear(BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Color color = ForeColorOverride != Color.Empty ? ForeColorOverride : (MutedText ? theme.Muted : theme.Text);
            TextFormatFlags fl = TextFormatFlags.NoPrefix | (Wrap ? TextFormatFlags.WordBreak : (TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter));
            if (Center) fl |= TextFormatFlags.HorizontalCenter;
            int x = 0;
            if (!string.IsNullOrEmpty(DotState)) {
                int tw = Draw.Width(g, Text, Font);
                int dx = Center ? Math.Max(0, (Width - tw - theme.S(18)) / 2) : 0;
                Draw.Dot(g, dx + theme.S(5), Height / 2f, theme.S(8), theme.State(DotState), DotState == "none");
                x = dx + theme.S(18);
                if (Center) fl &= ~TextFormatFlags.HorizontalCenter;
            }
            TextRenderer.DrawText(g, Text ?? "", Font, new Rectangle(x, 0, Width - x, Height), color, fl);
        }
    }

    // Окно со своим заголовком (как в macOS): системная полоса заголовка убрана, но рамка, тень, скругление,
    // изменение размера, Snap и разворачивание остаются (WM_NCCALCSIZE + WM_NCHITTEST, как в Windows Terminal).
    public class ChromeForm : Form {
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct NCCALCSIZE_PARAMS { public RECT r0, r1, r2; public IntPtr pos; }
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

        public int CaptionHeight = 44;

        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e);
            SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, 0x0027);   // SWP_FRAMECHANGED | NOMOVE | NOSIZE | NOZORDER
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0083 && m.WParam != IntPtr.Zero) {   // WM_NCCALCSIZE
                NCCALCSIZE_PARAMS p = (NCCALCSIZE_PARAMS)Marshal.PtrToStructure(m.LParam, typeof(NCCALCSIZE_PARAMS));
                int top = p.r0.Top;
                base.WndProc(ref m);
                p = (NCCALCSIZE_PARAMS)Marshal.PtrToStructure(m.LParam, typeof(NCCALCSIZE_PARAMS));
                // Убираем заголовок (и верхнюю рамку — её заменяет HTTOP ниже). Развёрнутое окно выходит за экран
                // на толщину рамки — компенсируем.
                p.r0.Top = top + (WindowState == FormWindowState.Maximized ? GetSystemMetrics(33) + GetSystemMetrics(92) : 0);
                Marshal.StructureToPtr(p, m.LParam, false);
                m.Result = IntPtr.Zero;
                return;
            }
            if (m.Msg == 0x0084) {   // WM_NCHITTEST
                base.WndProc(ref m);
                if ((int)m.Result == 1) {   // HTCLIENT
                    int x = unchecked((short)((long)m.LParam & 0xFFFF)), y = unchecked((short)(((long)m.LParam >> 16) & 0xFFFF));
                    Point pt = PointToClient(new Point(x, y));
                    if (WindowState == FormWindowState.Normal && pt.Y < 6) m.Result = (IntPtr)12;   // HTTOP
                    else if (pt.Y < CaptionHeight) m.Result = (IntPtr)2;                          // HTCAPTION: перетаскивание, двойной щелчок
                }
                return;
            }
            base.WndProc(ref m);
        }
    }

    // Полоса заголовка: прозрачна для щелчков (HTTRANSPARENT) — окно под ней перетаскивается; кнопки на ней работают.
    public sealed class CaptionPanel : Panel {
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0084) { m.Result = (IntPtr)(-1); return; }
            base.WndProc(ref m);
        }
    }

    // Кнопки окна Windows 11: «Свернуть», «Развернуть»/«Восстановить», «Закрыть» (46 px, глифы Segoe Fluent;
    // «Закрыть» при наведении — красная). Прижимаются к правому краю заголовка.
    public sealed class CaptionButtons : Control {
        Theme theme = Theme.Create(false);
        int hot = -1, down = -1;
        Font font;
        public CaptionButtons() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        }
        public void ApplyTheme(Theme t, int height) { theme = t; font = IconButton.IconFont(7.5f); Size = new Size(t.S(46) * 3, height); Invalidate(); }
        int W { get { return Width / 3; } }
        int Hit(Point p) { if (p.X < 0 || p.Y < 0 || p.Y >= Height) return -1; int i = p.X / Math.Max(1, W); return i >= 0 && i < 3 ? i : -1; }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics; g.Clear(BackColor);
            Form f = FindForm();
            bool max = f != null && f.WindowState == FormWindowState.Maximized;
            string[] glyphs = { "\uE921", max ? "\uE923" : "\uE922", "\uE8BB" };
            bool active = f == null || Form.ActiveForm == f;
            for (int i = 0; i < 3; i++) {
                Rectangle r = new Rectangle(i * W, 0, W, Height);
                Color text = active ? theme.Text : theme.Muted;
                if (i == hot || i == down) {
                    Color fill;
                    if (i == 2) { fill = i == down ? Theme.Hex(0xA92B1F) : Theme.Hex(0xC42B1C); text = Color.White; }
                    else fill = Color.FromArgb(i == down ? (theme.Dark ? 28 : 36) : (theme.Dark ? 18 : 24), theme.Dark ? Color.White : Color.Black);
                    using (SolidBrush b = new SolidBrush(fill)) g.FillRectangle(b, r);
                }
                TextRenderer.DrawText(g, glyphs[i], font, r, text, TextFormatFlags.NoPrefix | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            }
        }
        protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); int h = Hit(e.Location); if (h != hot) { hot = h; Invalidate(); } }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hot = -1; down = -1; Invalidate(); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) { down = Hit(e.Location); Invalidate(); } }
        protected override void OnMouseUp(MouseEventArgs e) {
            base.OnMouseUp(e);
            int h = Hit(e.Location), was = down; down = -1; Invalidate();
            if (h < 0 || h != was) return;
            Form f = FindForm(); if (f == null) return;
            if (h == 0) f.WindowState = FormWindowState.Minimized;
            else if (h == 1) f.WindowState = f.WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized;
            else f.Close();
        }
    }

    // Круглая кнопка-иконка (Segoe Fluent Icons): подсветка при наведении, «включена» — заливка акцентом.
    public sealed class IconButton : Control {
        Theme theme = Theme.Create(false);
        bool hot;
        readonly Tween press = new Tween(1f);
        public string Glyph = "";
        public bool Checked;
        Font font;
        public IconButton() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.Selectable | ControlStyles.SupportsTransparentBackColor, true);
            Cursor = Cursors.Hand; TabStop = true;
            press.Changed += delegate { Invalidate(); };
        }
        public static Font IconFont(float size) {
            Font f = new Font("Segoe Fluent Icons", size);
            if (f.Name == "Segoe Fluent Icons") return f;
            f.Dispose(); return new Font("Segoe MDL2 Assets", size);
        }
        public void ApplyTheme(Theme t) { theme = t; font = IconFont(11f); Size = new Size(t.S(32), t.S(32)); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics; g.Clear(BackColor); g.SmoothingMode = SmoothingMode.AntiAlias;
            float s = press.Value;
            g.TranslateTransform(Width / 2f, Height / 2f); g.ScaleTransform(s, s); g.TranslateTransform(-Width / 2f, -Height / 2f);
            if (Checked || hot) {
                Color fill = Checked ? Color.FromArgb(theme.Dark ? 60 : 36, theme.Accent) : theme.Fill;
                Draw.Fill(g, new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), theme.S(8), fill);
            }
            if (font == null) font = IconFont(11f);
            TextRenderer.DrawText(g, Glyph, font, ClientRectangle, Checked ? theme.Accent : theme.Text,
                TextFormatFlags.NoPrefix | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            g.ResetTransform();
        }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hot = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hot = false; press.Animate(1f, 160); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) press.Animate(0.92f, 100); }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); press.Animate(1f, 160); }
        protected override void Dispose(bool disposing) { if (disposing) press.Dispose(); base.Dispose(disposing); }
    }

    // Полоса расхода лимита: подпись, процент и время сброса, дорожка с заливкой (синяя → оранжевая → красная).
    public sealed class UsageBar : Control {
        Theme theme = Theme.Create(false);
        Font fLabel, fValue;
        public string Label = "";
        public double Percent = -1;      // < 0 — нет данных
        public string Detail = "";       // «сброс в 14:05» или «нет данных»
        public UsageBar() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        }
        public void ApplyTheme(Theme t) { theme = t; fLabel = Fonts.Semibold(9f); fValue = Fonts.Text(9f); Height = t.S(34); Invalidate(); }
        public void SetValue(double percent, string detail) { Percent = percent; Detail = detail ?? ""; Invalidate(); }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics; g.Clear(BackColor); g.SmoothingMode = SmoothingMode.AntiAlias;
            if (fLabel == null) ApplyTheme(theme);
            int lh = theme.S(18);
            Draw.TextLine(g, Label, fLabel, new Rectangle(0, 0, Width / 2, lh), theme.Text, TextFormatFlags.Left);
            string right = Percent < 0 ? Detail : (Math.Round(Percent).ToString() + " %" + (string.IsNullOrEmpty(Detail) ? "" : "  ·  " + Detail));
            int rw = Draw.Width(g, right, fValue);
            Draw.TextLine(g, right, fValue, new Rectangle(Width - rw - 2, 0, rw + 2, lh), theme.Muted, TextFormatFlags.Left);
            float bh = theme.S(6), by = lh + theme.S(5);
            RectangleF track = new RectangleF(0, by, Width - 1, bh);
            Draw.Fill(g, track, bh / 2, theme.Fill);
            if (Percent > 0) {
                float w = (float)(Math.Min(100, Percent) / 100.0 * track.Width);
                Color c = Percent >= 90 ? theme.State("error") : (Percent >= 75 ? theme.State("permission") : theme.State("working"));
                Draw.Fill(g, new RectangleF(0, by, Math.Max(bh, w), bh), bh / 2, c);
            }
        }
    }

    // Глобальная горячая клавиша (RegisterHotKey) на невидимом окне сообщений; Pressed — в потоке UI.
    public sealed class HotKey : NativeWindow, IDisposable {
        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        public const uint ModAlt = 1, ModControl = 2, ModShift = 4, ModWin = 8;
        const uint NoRepeat = 0x4000;
        bool registered;
        public event EventHandler Pressed;
        public HotKey() {
            CreateParams cp = new CreateParams();
            cp.Parent = new IntPtr(-3);   // HWND_MESSAGE: окно только для сообщений
            CreateHandle(cp);
        }
        public bool Registered { get { return registered; } }
        public bool Register(uint mods, Keys key) {
            Unregister();
            registered = RegisterHotKey(Handle, 1, mods | NoRepeat, (uint)key);
            return registered;
        }
        public void Unregister() { if (registered && Handle != IntPtr.Zero) UnregisterHotKey(Handle, 1); registered = false; }
        // Для тестов: как будто клавишу нажали.
        public void Raise() { EventHandler h = Pressed; if (h != null) h(this, EventArgs.Empty); }
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0312) Raise();   // WM_HOTKEY
            base.WndProc(ref m);
        }
        public void Dispose() { Unregister(); if (Handle != IntPtr.Zero) DestroyHandle(); }
    }

    // Столбцы по дням: подпись дня снизу, значение над столбцом; выделенный (сегодня) — акцентом, остальные — светлее.
    public sealed class BarChart : Control {
        Theme theme = Theme.Create(false);
        Font fLabel, fValue, fLabelBold;
        public double[] Values = new double[0];
        public string[] Labels = new string[0];
        public string[] ValueLabels = new string[0];
        public int Highlight = -1;
        public BarChart() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        }
        public void ApplyTheme(Theme t) { theme = t; fLabel = Fonts.Text(8.5f); fLabelBold = Fonts.Semibold(8.5f); fValue = Fonts.Text(8f); Invalidate(); }
        public void SetData(double[] values, string[] labels, string[] valueLabels, int highlight) {
            Values = values ?? new double[0]; Labels = labels ?? new string[0]; ValueLabels = valueLabels ?? new string[0]; Highlight = highlight;
            Invalidate();
        }
        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics; g.Clear(BackColor); g.SmoothingMode = SmoothingMode.AntiAlias;
            if (fLabel == null) ApplyTheme(theme);
            int n = Values.Length;
            if (n == 0) return;
            double max = 0; foreach (double v in Values) max = Math.Max(max, v);
            int top = theme.S(18), bottom = Height - theme.S(22);
            float slot = Width / (float)n;
            float bw = Math.Min(theme.S(30), slot * 0.56f);
            float r = Math.Min(theme.S(6), bw / 2f);
            for (int i = 0; i < n; i++) {
                float cx = slot * i + slot / 2f;
                bool hi = i == Highlight;
                Color col = hi ? theme.Accent : Draw.Mix(BackColor, theme.Accent, theme.Dark ? 0.45f : 0.35f);
                float h = max > 0 ? (float)(Values[i] / max) * (bottom - top) : 0;
                if (Values[i] > 0) h = Math.Max(h, theme.S(4));
                if (h > 0) {
                    RectangleF bar = new RectangleF(cx - bw / 2, bottom - h, bw, h);
                    Draw.Fill(g, bar, Math.Min(r, h / 2f), col);
                } else {
                    Draw.Fill(g, new RectangleF(cx - bw / 2, bottom - theme.S(3), bw, theme.S(3)), theme.S(1.5f), theme.Fill);
                }
                string vl = i < ValueLabels.Length ? ValueLabels[i] : "";
                if (!string.IsNullOrEmpty(vl) && Values[i] > 0) {
                    int vw = Draw.Width(g, vl, fValue);
                    Draw.TextLine(g, vl, fValue, new Rectangle((int)(cx - vw / 2f) - 1, (int)(bottom - h) - theme.S(17), vw + 2, theme.S(16)), hi ? theme.Text : theme.Muted, TextFormatFlags.Left);
                }
                string lb = i < Labels.Length ? Labels[i] : "";
                Font lf = hi ? fLabelBold : fLabel;
                int lw = Draw.Width(g, lb, lf);
                Draw.TextLine(g, lb, lf, new Rectangle((int)(cx - lw / 2f) - 1, bottom + theme.S(4), lw + 2, theme.S(18)), hi ? theme.Text : theme.Muted, TextFormatFlags.Left);
            }
        }
    }

    // Меню в стиле macOS: подсветка пункта — скруглённая плашка цвета акцента с белым текстом.
    public sealed class MenuRenderer : ToolStripProfessionalRenderer {
        readonly Theme theme;
        public MenuRenderer(Theme t) : base(new MenuColors(t)) { theme = t; RoundedEdges = true; }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
            if (!e.Item.Selected || !e.Item.Enabled) return;
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Draw.Fill(g, new RectangleF(theme.S(5), 0.5f, e.Item.Width - theme.S(10), e.Item.Height - 1), theme.S(5), theme.Accent);
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
            e.TextColor = !e.Item.Enabled ? theme.Muted : (e.Item.Selected ? theme.AccentText : theme.Text);
            base.OnRenderItemText(e);
        }

        protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
            e.ArrowColor = e.Item != null && e.Item.Selected ? theme.AccentText : theme.Muted;
            base.OnRenderArrow(e);
        }

        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Color c = e.Item.Selected ? theme.AccentText : theme.Text;
            Rectangle r = e.ImageRectangle;
            using (Pen p = new Pen(c, theme.S(1.6f))) {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                g.DrawLines(p, new PointF[] { new PointF(r.X + r.Width * 0.22f, r.Y + r.Height * 0.52f), new PointF(r.X + r.Width * 0.42f, r.Y + r.Height * 0.72f), new PointF(r.X + r.Width * 0.78f, r.Y + r.Height * 0.3f) });
            }
        }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
            int y = e.Item.Height / 2;
            using (Pen p = new Pen(theme.Border)) e.Graphics.DrawLine(p, theme.S(12), y, e.Item.Width - theme.S(12), y);
        }
    }

    public sealed class MenuColors : ProfessionalColorTable {
        readonly Theme t;
        public MenuColors(Theme theme) { t = theme; UseSystemColors = false; }
        Color Back { get { return t.Dark ? Theme.Hex(0x2A2A2C) : Theme.Hex(0xF6F6F6); } }
        public override Color ToolStripDropDownBackground { get { return Back; } }
        public override Color ImageMarginGradientBegin { get { return Back; } }
        public override Color ImageMarginGradientMiddle { get { return Back; } }
        public override Color ImageMarginGradientEnd { get { return Back; } }
        public override Color MenuBorder { get { return t.Dark ? Theme.Hex(0x3F3F42) : Theme.Hex(0xD5D5D8); } }
        public override Color MenuItemBorder { get { return Color.Transparent; } }
        public override Color MenuItemSelected { get { return t.Accent; } }
        public override Color SeparatorDark { get { return t.Border; } }
        public override Color SeparatorLight { get { return t.Border; } }
        public override Color CheckBackground { get { return Color.Transparent; } }
        public override Color CheckSelectedBackground { get { return Color.Transparent; } }
        public override Color CheckPressedBackground { get { return Color.Transparent; } }
    }
}
