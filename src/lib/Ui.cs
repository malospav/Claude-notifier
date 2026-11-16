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

    public sealed class Theme {
        public bool Dark;
        public Color Window, Surface, SurfaceHover, SurfaceSelected, Border, Text, Muted, Tertiary, Fill, Thumb;
        public Color Accent, AccentHover, AccentText, Danger;
        public float Scale = 1f;

        public static bool SystemIsDark() {
            try {
                object v = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1);
                return v is int && (int)v == 0;
            } catch { return false; }
        }

        // Палитра Apple: systemGroupedBackground, secondarySystemGroupedBackground, label, secondaryLabel, separator, systemBlue…
        public static Theme Create(bool dark) {
            Theme t = new Theme();
            t.Dark = dark;
            if (dark) {
                t.Window = Hex(0x1C1C1E); t.Surface = Hex(0x2C2C2E); t.SurfaceHover = Hex(0x323234); t.SurfaceSelected = Hex(0x3A3A3C);
                t.Border = Hex(0x3D3D41); t.Text = Hex(0xF5F5F7); t.Muted = Hex(0x98989D); t.Tertiary = Hex(0x5A5A5F);
                t.Fill = Hex(0x323236); t.Thumb = Hex(0x636366);
                t.Accent = Hex(0x0A84FF); t.AccentHover = Hex(0x2490FF); t.AccentText = Hex(0xFFFFFF); t.Danger = Hex(0xFF453A);
            } else {
                t.Window = Hex(0xF2F2F7); t.Surface = Hex(0xFFFFFF); t.SurfaceHover = Hex(0xF7F7F9); t.SurfaceSelected = Hex(0xE5E5EA);
                t.Border = Hex(0xD8D8DC); t.Text = Hex(0x1D1D1F); t.Muted = Hex(0x86868B); t.Tertiary = Hex(0xC7C7CC);
                t.Fill = Hex(0xE3E3E8); t.Thumb = Hex(0xFFFFFF);
                t.Accent = Hex(0x007AFF); t.AccentHover = Hex(0x1A88FF); t.AccentText = Hex(0xFFFFFF); t.Danger = Hex(0xFF3B30);
            }
            return t;
        }

        public static Theme Current() { return Create(SystemIsDark()); }

        // Цвет точки статуса: working | waiting | permission | error | online | none.
        public Color State(string state) {
            switch (state) {
                case "working": return Dark ? Hex(0x0A84FF) : Hex(0x007AFF);
                case "waiting": case "online": return Dark ? Hex(0x30D158) : Hex(0x34C759);
                case "permission": return Dark ? Hex(0xFF9F0A) : Hex(0xFF9500);
                case "error": return Dark ? Hex(0xFF453A) : Hex(0xFF3B30);
                default: return Tertiary;
            }
        }

        // Цвет текста статуса: на светлом фоне — затемнённые варианты Apple для контраста.
        public Color StateText(string state) {
            if (Dark) return State(state) == Tertiary ? Muted : State(state);
            switch (state) {
                case "working": return Hex(0x0066D6);
                case "waiting": case "online": return Hex(0x248A3D);
                case "permission": return Hex(0xC93400);
                case "error": return Hex(0xD70015);
                default: return Muted;
            }
        }

        public static Color Hex(int rgb) { return Color.FromArgb(255, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF); }

        public int S(float px) { return (int)Math.Round(px * Scale); }
    }

    public static class Fonts {
        static Font Make(string family, string fallback, float size, FontStyle style) {
            Font f = new Font(family, size, style, GraphicsUnit.Point);
            if (string.Equals(f.Name, family, StringComparison.OrdinalIgnoreCase)) return f;
            f.Dispose();
            return new Font(fallback, size, style, GraphicsUnit.Point);
        }
        public static Font Text(float size) { return Make("Segoe UI Variable Text", "Segoe UI", size, FontStyle.Regular); }
        public static Font Semibold(float size) { return Make("Segoe UI Variable Text Semibold", "Segoe UI Semibold", size, FontStyle.Regular); }
        public static Font Display(float size) { return Make("Segoe UI Variable Display Semib", "Segoe UI Semibold", size, FontStyle.Regular); }
    }

    // --- Движение ---

    public static class Motion {
        [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, ref bool value, uint ini);

        // false, если в Windows выключена анимация (Параметры → Специальные возможности → Эффекты анимации).
        public static bool Enabled {
            get {
                if (forced.HasValue) return forced.Value;
                bool on = true;
                try { SystemParametersInfo(0x1042, 0, ref on, 0); } catch { }   // SPI_GETCLIENTAREAANIMATION
                return on;
            }
        }
        static bool? forced;
        public static void Force(bool? value) { forced = value; }   // для тестов

        // cubic-bezier(0.23, 1, 0.32, 1) — сильный ease-out (Emil Kowalski).
        public static float EaseOut(float t) { return Bezier(0.23f, 1f, 0.32f, 1f, t); }

        public static float Bezier(float x1, float y1, float x2, float y2, float x) {
            if (x <= 0) return 0; if (x >= 1) return 1;
            float t = x;
            for (int i = 0; i < 8; i++) {
                float cx = Curve(x1, x2, t) - x;
                if (Math.Abs(cx) < 1e-4f) break;
                float d = Deriv(x1, x2, t);
                if (Math.Abs(d) < 1e-6f) break;
                t -= cx / d;
            }
            t = Math.Max(0, Math.Min(1, t));
            return Curve(y1, y2, t);
        }
        static float Curve(float a, float b, float t) { float u = 1 - t; return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t; }
        static float Deriv(float a, float b, float t) { float u = 1 - t; return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b); }
    }

    // Анимируемое значение: Animate(to, ms) начинает с текущего значения — анимацию можно прервать новой.
    public sealed class Tween : IDisposable {
        readonly Timer timer = new Timer();
        float from, to, value;
        DateTime start;
        int duration;
        public event EventHandler Changed;

        public Tween(float initial) { value = to = from = initial; timer.Interval = 15; timer.Tick += Tick; }

        public float Value { get { return value; } }
        public float Target { get { return to; } }

        public void Animate(float target, int ms) {
            if (!Motion.Enabled || ms <= 0) { Set(target); return; }
            from = value; to = target; duration = ms; start = DateTime.UtcNow;
            timer.Start();
        }

        public void Set(float v) { timer.Stop(); from = to = value = v; Raise(); }

        void Tick(object s, EventArgs e) {
            float p = (float)((DateTime.UtcNow - start).TotalMilliseconds / duration);
            if (p >= 1) { value = to; timer.Stop(); }
            else value = from + (to - from) * Motion.EaseOut(p);
            Raise();
        }

        void Raise() { EventHandler h = Changed; if (h != null) h(this, EventArgs.Empty); }
        public void Dispose() { timer.Dispose(); }
    }

    public static class Native {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

        public static void EnableDpiAwareness() { try { SetProcessDPIAware(); } catch { } }

        // Заголовок окна в цвет фона (как в macOS — без видимой полосы), тёмный режим, скруглённые углы.
        public static void StyleWindow(IntPtr hwnd, Theme t) {
            try {
                int dark = t.Dark ? 1 : 0;
                DwmSetWindowAttribute(hwnd, 20, ref dark, 4);              // DWMWA_USE_IMMERSIVE_DARK_MODE
                int caption = ColorTranslator.ToWin32(t.Window);
                DwmSetWindowAttribute(hwnd, 35, ref caption, 4);           // DWMWA_CAPTION_COLOR
                int text = ColorTranslator.ToWin32(t.Muted);
                DwmSetWindowAttribute(hwnd, 36, ref text, 4);              // DWMWA_TEXT_COLOR
                int border = ColorTranslator.ToWin32(t.Dark ? Theme.Hex(0x3A3A3C) : Theme.Hex(0xD1D1D6));
                DwmSetWindowAttribute(hwnd, 34, ref border, 4);            // DWMWA_BORDER_COLOR
                int round = 2;
                DwmSetWindowAttribute(hwnd, 33, ref round, 4);             // DWMWA_WINDOW_CORNER_PREFERENCE = ROUND
            } catch { }
        }

        public static void RoundPopup(IntPtr hwnd) {
            try { int small = 3; DwmSetWindowAttribute(hwnd, 33, ref small, 4); } catch { }
        }

        // Плавное появление окна (редкое действие — анимация уместна): прозрачность 0 → 1 за ms, ease-out.
        public static void FadeIn(Form form, int ms) {
            if (!Motion.Enabled) return;
            form.Opacity = 0;
            Tween tw = new Tween(0);
            tw.Changed += delegate {
                if (form.IsDisposed) { tw.Dispose(); return; }
                form.Opacity = Math.Min(1.0, tw.Value);
                if (tw.Value >= 1f) tw.Dispose();
            };
            form.Shown += delegate { tw.Animate(1f, ms); };
        }

        public static Icon ToIcon(Bitmap bmp) {
            IntPtr h = bmp.GetHicon();
            try { using (Icon tmp = Icon.FromHandle(h)) { return (Icon)tmp.Clone(); } }
            finally { DestroyIcon(h); }
        }
    }

    public static class Draw {
        public static GraphicsPath Round(RectangleF r, float radius) {
            GraphicsPath p = new GraphicsPath();
            radius = Math.Min(radius, Math.Min(r.Width, r.Height) / 2);
            float d = radius * 2;
            if (d <= 0) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        public static void Fill(Graphics g, RectangleF r, float radius, Color fill) {
            using (GraphicsPath path = Round(r, radius)) using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, path);
        }

        public static void Card(Graphics g, RectangleF r, float radius, Color fill, Color border) {
            using (GraphicsPath path = Round(r, radius)) {
                using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, path);
                if (border.A > 0) using (Pen p = new Pen(border, 1f)) g.DrawPath(p, path);
            }
        }

        // Мягкая тень (несколько полупрозрачных слоёв) — для ползунка сегментов и ручки тумблера.
        public static void Shadow(Graphics g, RectangleF r, float radius, int alpha) {
            for (int i = 3; i >= 1; i--) {
                RectangleF s = new RectangleF(r.X - i * 0.5f, r.Y - i * 0.5f + 1, r.Width + i, r.Height + i);
                Fill(g, s, radius + i * 0.5f, Color.FromArgb(alpha / (i + 1), 0, 0, 0));
            }
        }

        public static void Dot(Graphics g, float cx, float cy, float d, Color c, bool hollow) {
            RectangleF r = new RectangleF(cx - d / 2, cy - d / 2, d, d);
            if (hollow) { using (Pen p = new Pen(c, Math.Max(1.5f, d / 6))) g.DrawEllipse(p, r.X + 1, r.Y + 1, r.Width - 2, r.Height - 2); }
            else { using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, r); }
        }

        public static void TextLine(Graphics g, string s, Font f, Rectangle r, Color c, TextFormatFlags extra) {
            TextRenderer.DrawText(g, s ?? "", f, r, c, TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter | extra);
        }

        public static int Width(Graphics g, string s, Font f) {
            if (string.IsNullOrEmpty(s)) return 0;
            return TextRenderer.MeasureText(g, s, f, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding).Width;
        }

        public static Color Mix(Color a, Color b, float t) {
            t = Math.Max(0, Math.Min(1, t));
            return Color.FromArgb((int)(a.A + (b.A - a.A) * t), (int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }
    }

    // Точка статуса для трея — системные цвета Apple; «нет сеансов» — серое кольцо.
    public static class TrayDot {
        public static Color ColorFor(string state) {
            switch (state) {
                case "permission": return Theme.Hex(0xFF9F0A);
                case "error": return Theme.Hex(0xFF453A);
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
    }

    public sealed class CardItem {
        public string Id = "";
        public string Section = "";      // заголовок группы (как в Настройках iOS); пусто — без заголовка
        public string Title = "";
        public string State = "";        // цвет точки и текста статуса
        public string StateText = "";
        public string Meta = "";
        public string Right = "";
        public string Preview = "";
        public bool HollowDot;
        public bool IsAction;            // строка-действие («+ Подключить устройство»): текст цвета акцента
        public object Tag;
    }

    public sealed class CardEventArgs : EventArgs {
        public CardItem Item; public Point Location; public string Action;
        public CardEventArgs(CardItem item, Point location, string action) { Item = item; Location = location; Action = action; }
    }

    // Сгруппированный список в стиле Apple: строки в скруглённых группах, тонкие разделители с отступом,
    // выделение — скруглённая плашка цвета акцента. Обновление списка не анимируется (оно частое).
    public sealed class CardList : Control {
        readonly List<CardItem> items = new List<CardItem>();
        readonly List<Rectangle> rows = new List<Rectangle>();
        readonly List<Rectangle> groups = new List<Rectangle>();
        readonly List<KeyValuePair<Point, string>> headers = new List<KeyValuePair<Point, string>>();
        Theme theme = Theme.Create(false);
        Font fTitle, fBody, fSmall, fHeader, fEmpty;
        int hover = -1, selected = -1, pressed = -1, scroll = 0, contentHeight = 0, footerY = 0;
        public string EmptyTitle = "Пусто";
        public string EmptyHint = "";
        public string Footer = "";

        public event EventHandler<CardEventArgs> ItemAction;   // Action: open | context | delete

        public CardList() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            ApplyTheme(theme);
        }

        public void ApplyTheme(Theme t) {
            theme = t;
            fTitle = Fonts.Semibold(10.5f); fBody = Fonts.Text(9.5f); fSmall = Fonts.Text(9f); fHeader = Fonts.Semibold(9f); fEmpty = Fonts.Semibold(12f);
            BackColor = t.Window;
            Relayout();
            Invalidate();
        }

        public int Count { get { return items.Count; } }
        public CardItem this[int i] { get { return items[i]; } }
        public CardItem SelectedItem { get { return selected >= 0 && selected < items.Count ? items[selected] : null; } }

        public void SetItems(IEnumerable<CardItem> list) {
            string keep = SelectedItem != null ? SelectedItem.Id : null;
            items.Clear();
            if (list != null) items.AddRange(list);
            selected = -1;
            if (keep != null) for (int i = 0; i < items.Count; i++) if (items[i].Id == keep) { selected = i; break; }
            hover = -1; pressed = -1;
            Relayout();
            Invalidate();
        }

        public void Select(int index) {
            selected = (index >= 0 && index < items.Count) ? index : -1;
            EnsureVisible(selected);
            Invalidate();
        }

        int RowHeight(CardItem it) {
            if (it.IsAction) return theme.S(46);
            return theme.S(string.IsNullOrEmpty(it.Preview) ? 58 : 76);
        }

        void Relayout() {
            rows.Clear(); groups.Clear(); headers.Clear();
            int y = 0, w = Math.Max(0, ClientSize.Width - theme.S(2));
            int gStart = -1; string section = null;
            for (int i = 0; i < items.Count; i++) {
                CardItem it = items[i];
                if (i == 0 || it.Section != section) {
                    if (gStart >= 0) { groups.Add(new Rectangle(0, gStart, w, y - gStart)); y += theme.S(22); }
                    section = it.Section;
                    if (!string.IsNullOrEmpty(section)) { headers.Add(new KeyValuePair<Point, string>(new Point(theme.S(16), y), section)); y += theme.S(26); }
                    gStart = y;
                }
                int h = RowHeight(it);
                rows.Add(new Rectangle(0, y, w, h));
                y += h;
            }
            if (gStart >= 0) groups.Add(new Rectangle(0, gStart, w, y - gStart));
            footerY = y + theme.S(10);
            int footerH = 0;
            if (!string.IsNullOrEmpty(Footer) && items.Count > 0) {
                Size fs = TextRenderer.MeasureText(Footer, fSmall, new Size(Math.Max(1, w - theme.S(32)), int.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                footerH = fs.Height + theme.S(10);
            }
            contentHeight = y + footerH;
            ClampScroll();
        }

        void ClampScroll() { scroll = Math.Max(0, Math.Min(scroll, Math.Max(0, contentHeight - ClientSize.Height))); }

        void EnsureVisible(int i) {
            if (i < 0 || i >= rows.Count) return;
            Rectangle r = rows[i];
            if (r.Top < scroll) scroll = r.Top;
            else if (r.Bottom > scroll + ClientSize.Height) scroll = r.Bottom - ClientSize.Height;
            ClampScroll();
        }

        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); Relayout(); }

        int HitTest(Point p) {
            for (int i = 0; i < rows.Count; i++) { Rectangle r = rows[i]; r.Offset(0, -scroll); if (r.Contains(p)) return i; }
            return -1;
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.Clear(theme.Window);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (items.Count == 0) { PaintEmpty(g); return; }
            float radius = theme.S(12);
            foreach (Rectangle gr in groups) {
                Rectangle r = gr; r.Offset(0, -scroll);
                Draw.Fill(g, new RectangleF(r.X, r.Y, r.Width, r.Height), radius, theme.Surface);
            }
            foreach (KeyValuePair<Point, string> h in headers) {
                Draw.TextLine(g, h.Value, fHeader, new Rectangle(h.Key.X, h.Key.Y - scroll, ClientSize.Width - theme.S(32), theme.S(22)), theme.Muted, TextFormatFlags.Left);
            }
            for (int i = 0; i < items.Count; i++) {
                Rectangle r = rows[i]; r.Offset(0, -scroll);
                if (r.Bottom < 0 || r.Top > ClientSize.Height) continue;
                bool last = (i == items.Count - 1) || items[i + 1].Section != items[i].Section;
                PaintRow(g, items[i], r, i, last);
            }
            if (!string.IsNullOrEmpty(Footer)) {
                TextRenderer.DrawText(g, Footer, fSmall, new Rectangle(theme.S(16), footerY - scroll, Math.Max(0, ClientSize.Width - theme.S(32)), theme.S(80)), theme.Muted,
                    TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak);
            }
            if (contentHeight > ClientSize.Height) {
                float ratio = (float)ClientSize.Height / contentHeight;
                int th = Math.Max(theme.S(24), (int)(ClientSize.Height * ratio));
                int ty = (int)((ClientSize.Height - th) * (scroll / (float)Math.Max(1, contentHeight - ClientSize.Height)));
                Draw.Fill(g, new RectangleF(ClientSize.Width - theme.S(4), ty, theme.S(3), th), theme.S(1.5f), Color.FromArgb(110, theme.Muted));
            }
        }

        void PaintRow(Graphics g, CardItem it, Rectangle r, int index, bool last) {
            bool sel = index == selected, hot = index == hover, down = index == pressed;
            bool active = sel && Focused;
            int inset = theme.S(5);
            if (sel || hot || down) {
                Color fill = active ? theme.Accent : (sel || down ? theme.SurfaceSelected : theme.SurfaceHover);
                Draw.Fill(g, new RectangleF(r.X + inset, r.Y + inset * 0.6f, r.Width - 2 * inset, r.Height - inset * 1.2f), theme.S(8), fill);
            }
            int pad = theme.S(16);
            int textX = r.X + pad + theme.S(22);
            Color title = active ? theme.AccentText : theme.Text;
            Color muted = active ? Color.FromArgb(215, theme.AccentText) : theme.Muted;

            if (it.IsAction) {
                Color ac = active ? theme.AccentText : theme.Accent;
                using (Pen p = new Pen(ac, theme.S(1.6f))) {
                    float cx = r.X + pad + theme.S(5), cy = r.Y + r.Height / 2f, a = theme.S(5);
                    g.DrawLine(p, cx - a, cy, cx + a, cy); g.DrawLine(p, cx, cy - a, cx, cy + a);
                }
                Draw.TextLine(g, it.Title, fTitle, new Rectangle(textX, r.Y, r.Right - pad - textX, r.Height), ac, TextFormatFlags.Left);
            } else {
                int line1 = r.Y + theme.S(10), lh = theme.S(19);
                Color dot = theme.State(it.State);
                Draw.Dot(g, r.X + pad + theme.S(5), line1 + lh / 2f, theme.S(9), dot, it.HollowDot);
                if (active && !it.HollowDot) using (Pen ring = new Pen(theme.AccentText, 1.4f)) {
                    float d = theme.S(9), cx = r.X + pad + theme.S(5), cy = line1 + lh / 2f;
                    g.DrawEllipse(ring, cx - d / 2, cy - d / 2, d, d);
                }
                int rightW = Draw.Width(g, it.Right, fSmall);
                int rightX = r.Right - pad - rightW;
                Draw.TextLine(g, it.Title, fTitle, new Rectangle(textX, line1, Math.Max(0, rightX - textX - theme.S(8)), lh), title, TextFormatFlags.Left);
                if (rightW > 0) Draw.TextLine(g, it.Right, fSmall, new Rectangle(rightX, line1, rightW + theme.S(2), lh), muted, TextFormatFlags.Left);

                int line2 = line1 + lh;
                int avail = r.Right - pad - textX;
                int sw = Draw.Width(g, it.StateText, fBody);
                Color stateColor = active ? theme.AccentText : theme.StateText(it.State);
                Draw.TextLine(g, it.StateText, fBody, new Rectangle(textX, line2, Math.Min(sw + theme.S(2), avail), lh), stateColor, TextFormatFlags.Left);
                if (!string.IsNullOrEmpty(it.Meta)) {
                    string meta = (sw > 0 ? "  ·  " : "") + it.Meta;
                    int mx = textX + sw;
                    Draw.TextLine(g, meta, fBody, new Rectangle(mx, line2, Math.Max(0, r.Right - pad - mx), lh), muted, TextFormatFlags.Left);
                }
                if (!string.IsNullOrEmpty(it.Preview)) {
                    Draw.TextLine(g, it.Preview, fSmall, new Rectangle(textX, line2 + lh, avail, lh), muted, TextFormatFlags.Left);
                }
            }
            // Разделитель с отступом до текста — как в списках iOS; у последней строки группы его нет.
            if (!last && !sel && !(index + 1 == selected)) {
                using (Pen p = new Pen(theme.Border, 1f)) g.DrawLine(p, textX, r.Bottom - 0.5f, r.Right, r.Bottom - 0.5f);
            }
        }

        void PaintEmpty(Graphics g) {
            int cx = ClientSize.Width / 2, cy = ClientSize.Height / 2 - theme.S(30);
            Draw.Dot(g, cx, cy, theme.S(34), theme.Tertiary, true);
            Draw.TextLine(g, EmptyTitle, fEmpty, new Rectangle(0, cy + theme.S(28), ClientSize.Width, theme.S(26)), theme.Text, TextFormatFlags.HorizontalCenter);
            if (!string.IsNullOrEmpty(EmptyHint))
                TextRenderer.DrawText(g, EmptyHint, fBody, new Rectangle(theme.S(48), cy + theme.S(58), Math.Max(0, ClientSize.Width - theme.S(96)), theme.S(48)), theme.Muted,
                    TextFormatFlags.NoPrefix | TextFormatFlags.HorizontalCenter | TextFormatFlags.WordBreak);
        }

        protected override void OnMouseMove(MouseEventArgs e) {
            base.OnMouseMove(e);
            int h = HitTest(e.Location);
            if (h != hover) { hover = h; Cursor = h >= 0 ? Cursors.Hand : Cursors.Default; Invalidate(); }
        }

        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (hover != -1 || pressed != -1) { hover = -1; pressed = -1; Invalidate(); } }

        // Отклик на нажатие, а не на отпускание: выделение и подсветка появляются сразу.
        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            Focus();
            int h = HitTest(e.Location);
            if (h >= 0) { selected = h; pressed = h; Invalidate(); }
            if (e.Button == MouseButtons.Right && h >= 0) Raise("context", e.Location);
        }

        protected override void OnMouseUp(MouseEventArgs e) {
            base.OnMouseUp(e);
            int h = HitTest(e.Location);
            bool action = pressed >= 0 && h == pressed && e.Button == MouseButtons.Left && items[h].IsAction;
            pressed = -1; Invalidate();
            if (action) Raise("open", e.Location);   // строка-действие срабатывает одним щелчком
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e) {
            base.OnMouseDoubleClick(e);
            int h = HitTest(e.Location);
            if (e.Button == MouseButtons.Left && h >= 0 && !items[h].IsAction) Raise("open", e.Location);
        }

        protected override void OnMouseWheel(MouseEventArgs e) {
            base.OnMouseWheel(e);
            scroll -= e.Delta / 120 * theme.S(48);
            ClampScroll();
            Invalidate();
        }

        protected override bool IsInputKey(Keys k) {
            if (k == Keys.Up || k == Keys.Down || k == Keys.Enter || k == Keys.Delete || k == Keys.Apps) return true;
            return base.IsInputKey(k);
        }

        protected override void OnKeyDown(KeyEventArgs e) {
            base.OnKeyDown(e);
            if (items.Count == 0) return;
            if (e.KeyCode == Keys.Down) { Select(Math.Min(items.Count - 1, selected + 1)); e.Handled = true; }
            else if (e.KeyCode == Keys.Up) { Select(Math.Max(0, selected < 0 ? 0 : selected - 1)); e.Handled = true; }
            else if (e.KeyCode == Keys.Enter && SelectedItem != null) { Raise("open", Point.Empty); e.Handled = true; }
            else if (e.KeyCode == Keys.Delete && SelectedItem != null && !SelectedItem.IsAction) { Raise("delete", Point.Empty); e.Handled = true; }
            else if (e.KeyCode == Keys.Apps && SelectedItem != null) {
                Rectangle r = rows[selected]; r.Offset(0, -scroll);
                Raise("context", new Point(r.X + theme.S(40), r.Bottom - theme.S(8)));
                e.Handled = true;
            }
        }

        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }

        void Raise(string action, Point p) {
            EventHandler<CardEventArgs> h = ItemAction;
            if (h != null && SelectedItem != null) h(this, new CardEventArgs(SelectedItem, p, action));
        }
    }

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
