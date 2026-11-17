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

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
        [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int pid);

        public static void EnableDpiAwareness() { try { SetProcessDPIAware(); } catch { } }

        // AppUserModelID процесса: окна трея группируются на панели задач под ярлыком «Claude Notifier»
        // (его иконка и имя), а не под powershell.exe. Вызывать до создания окон.
        public static bool SetAppId(string appId) { try { return SetCurrentProcessExplicitAppUserModelID(appId) == 0; } catch { return false; } }

        // Разрешает любому процессу (трею) вывести своё окно на передний план — после щелчка по ярлыку.
        public static bool AllowForeground() { try { return AllowSetForegroundWindow(-1); } catch { return false; } }

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

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);

        // Тёмные системные полосы прокрутки у прокручиваемой панели (как в Проводнике в тёмной теме).
        public static void DarkScrollbars(IntPtr hwnd, bool dark) {
            try { SetWindowTheme(hwnd, dark ? "DarkMode_Explorer" : "Explorer", null); } catch { }
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
                case "permission": case "alert": return Theme.Hex(0xFF9F0A);
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
        public string Details = "";      // подробности (строки через \n) — видны, когда строка раскрыта
        public string RequestTitle = ""; // запрос к пользователю (разрешение, вопрос, быстрый ответ)
        public string RequestDetail = "";
        public string[] Actions = new string[0];   // кнопки: "id|текст|primary|secondary|destructive"
        public bool ForceExpand;         // раскрыта всегда (есть запрос, ждущий ответа)
        public int ContextPercent = -1;  // заполненность контекста сеанса; < 0 — не показывать
        public int ContextWarn = 85;     // с этого процента индикатор оранжевый
        public bool Pinned;              // закреплён сверху — значок булавки
        public bool Muted;               // без уведомлений — значок «без звука»
        public bool Urgent;              // запрос давно ждёт ответа — точка пульсирует сильнее
        public bool IsGroup;             // строка-группа (сеансы одного проекта): стрелка справа, щелчок раскрывает или сворачивает
        public bool GroupOpen;           // группа раскрыта — стрелка вниз
        public bool Child;               // сеанс внутри раскрытой группы — с отступом
        public object Tag;
    }

    public sealed class CardEventArgs : EventArgs {
        public CardItem Item; public Point Location; public string Action;
        public CardEventArgs(CardItem item, Point location, string action) { Item = item; Location = location; Action = action; }
    }

    // Сгруппированный список в стиле Apple: строки в скруглённых группах, тонкие разделители с отступом,
    // выделение — скруглённая плашка цвета акцента. Выбранная строка (и строка с запросом) раскрывается:
    // полный ответ, подробности, блок запроса с кнопками. Обновление списка не анимируется (оно частое);
    // у статуса «Работает» точка мягко пульсирует (постоянное движение — линейно, только когда движение разрешено).
    public sealed class CardList : Control {
        readonly List<CardItem> items = new List<CardItem>();
        readonly List<Rectangle> rows = new List<Rectangle>();
        readonly List<Rectangle> groups = new List<Rectangle>();
        readonly List<KeyValuePair<Point, string>> headers = new List<KeyValuePair<Point, string>>();
        readonly Dictionary<int, List<KeyValuePair<Rectangle, string>>> buttons = new Dictionary<int, List<KeyValuePair<Rectangle, string>>>();
        readonly Timer pulseTimer = new Timer();
        Theme theme = Theme.Create(false);
        Font fTitle, fBody, fSmall, fHeader, fEmpty, fButton, fMono, fIcon;
        int hover = -1, selected = -1, pressed = -1, scroll = 0, contentHeight = 0, footerY = 0;
        string hoverButton = null;
        float pulse;
        public string EmptyTitle = "Пусто";
        public string EmptyHint = "";
        public string Footer = "";
        public bool ExpandSelected = true;

        public event EventHandler<CardEventArgs> ItemAction;   // Action: open | context | delete | act:<id>

        public CardList() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            pulseTimer.Interval = 40;
            pulseTimer.Tick += delegate {
                pulse = (float)((DateTime.UtcNow.Ticks / TimeSpan.TicksPerMillisecond) % 1600) / 1600f;
                Invalidate();
            };
            ApplyTheme(theme);
        }

        public void ApplyTheme(Theme t) {
            theme = t;
            fTitle = Fonts.Semibold(10.5f); fBody = Fonts.Text(9.5f); fSmall = Fonts.Text(9f); fHeader = Fonts.Semibold(9f);
            fEmpty = Fonts.Semibold(12f); fButton = Fonts.Semibold(9f); fIcon = IconButton.IconFont(8f);
            fMono = new Font("Cascadia Mono", 8.5f); if (fMono.Name != "Cascadia Mono") { fMono.Dispose(); fMono = new Font("Consolas", 9f); }
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
            UpdatePulse();
            Invalidate();
        }

        public void Select(int index) {
            selected = (index >= 0 && index < items.Count) ? index : -1;
            Relayout();
            EnsureVisible(selected);
            Invalidate();
        }

        // Нажимает кнопку действия строки (для тестов и клавиатуры).
        public void InvokeAction(int index, string actionId) {
            if (index < 0 || index >= items.Count) return;
            selected = index;
            Raise("act:" + actionId, Point.Empty);
        }

        bool IsExpanded(int i) { return items[i].ForceExpand || (ExpandSelected && i == selected && !items[i].IsAction && !items[i].IsGroup); }

        int TextWidth() { return Math.Max(theme.S(120), ClientSize.Width - theme.S(2) - theme.S(16) * 2 - theme.S(22)); }

        int Measure(string text, Font f, int width, int maxLines) {
            if (string.IsNullOrEmpty(text)) return 0;
            int h = TextRenderer.MeasureText(text, f, new Size(width, int.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl).Height;
            int line = TextRenderer.MeasureText("Ag", f).Height;
            return Math.Min(h, line * maxLines);
        }

        static string[] ParseAction(string a) {
            string[] p = (a ?? "").Split('|');
            return new string[] { p[0], p.Length > 1 ? p[1] : p[0], p.Length > 2 ? p[2] : "secondary" };
        }

        int RowHeight(int i) {
            CardItem it = items[i];
            if (it.IsAction) return theme.S(46);
            if (!IsExpanded(i)) return theme.S(string.IsNullOrEmpty(it.Preview) ? 58 : 76);
            int w = TextWidth();
            int h = theme.S(10) + theme.S(19) * 2;                                  // заголовок и статус
            if (!string.IsNullOrEmpty(it.Preview)) h += Measure(it.Preview, fSmall, w, 6) + theme.S(4);
            if (!string.IsNullOrEmpty(it.Details)) h += Measure(it.Details, fSmall, w, 11) + theme.S(6);
            if (!string.IsNullOrEmpty(it.RequestTitle) || it.Actions.Length > 0) {
                h += theme.S(10);
                if (!string.IsNullOrEmpty(it.RequestTitle)) h += Measure(it.RequestTitle, fTitle, w - theme.S(24), 3) + theme.S(14);
                if (!string.IsNullOrEmpty(it.RequestDetail)) h += Measure(it.RequestDetail, fMono, w - theme.S(24), 4) + theme.S(4);
                h += ButtonsHeight(it, w - theme.S(24)) + theme.S(12);
            }
            return h + theme.S(12);
        }

        int ButtonsHeight(CardItem it, int width) {
            if (it.Actions.Length == 0) return 0;
            int x = 0, lines = 1, bh = theme.S(28), gap = theme.S(8);
            foreach (string a in it.Actions) {
                int bw = TextRenderer.MeasureText(ParseAction(a)[1], fButton).Width + theme.S(24);
                if (x > 0 && x + bw > width) { lines++; x = 0; }
                x += bw + gap;
            }
            return lines * bh + (lines - 1) * gap;
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
                int h = RowHeight(i);
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
            else if (r.Bottom > scroll + ClientSize.Height) scroll = Math.Min(r.Top, r.Bottom - ClientSize.Height);
            ClampScroll();
        }

        void UpdatePulse() {
            bool need = Motion.Enabled && Visible;
            if (need) { need = false; foreach (CardItem it in items) if ((it.State == "working" || it.Urgent) && !it.IsAction) { need = true; break; } }
            if (need && !pulseTimer.Enabled) pulseTimer.Start();
            if (!need && pulseTimer.Enabled) { pulseTimer.Stop(); pulse = 0; }
        }

        protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); UpdatePulse(); }
        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); Relayout(); }
        protected override void Dispose(bool disposing) { if (disposing) pulseTimer.Dispose(); base.Dispose(disposing); }

        int HitTest(Point p) {
            for (int i = 0; i < rows.Count; i++) { Rectangle r = rows[i]; r.Offset(0, -scroll); if (r.Contains(p)) return i; }
            return -1;
        }

        string HitButton(Point p) {
            foreach (KeyValuePair<int, List<KeyValuePair<Rectangle, string>>> kv in buttons)
                foreach (KeyValuePair<Rectangle, string> b in kv.Value) if (b.Key.Contains(p)) return kv.Key + ":" + b.Value;
            return null;
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.Clear(theme.Window);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            buttons.Clear();
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
            bool expanded = IsExpanded(index);
            // Раскрытая строка выделяется мягко (без синей плашки): на ней кнопки и длинный текст.
            bool active = sel && Focused && !expanded;
            int inset = theme.S(5);
            if (sel || hot || down) {
                Color fill = active ? theme.Accent : (sel || down ? theme.SurfaceSelected : theme.SurfaceHover);
                if (expanded && !down) fill = hot && !sel ? theme.SurfaceHover : theme.SurfaceHover;
                Draw.Fill(g, new RectangleF(r.X + inset, r.Y + inset * 0.6f, r.Width - 2 * inset, r.Height - inset * 1.2f), theme.S(8), fill);
            }
            int pad = theme.S(16);
            int indent = it.Child ? theme.S(18) : 0;
            int textX = r.X + pad + indent + theme.S(22);
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
                float dcx = r.X + pad + indent + theme.S(5), dcy = line1 + lh / 2f, dd = theme.S(9);
                if ((it.State == "working" || it.Urgent) && pulseTimer.Enabled) {
                    // Мягкий «пульс»: кольцо расходится и тает за 1,6 с. Давно ждущий запрос — вдвое чаще и шире.
                    float ph = it.Urgent ? (pulse * 2f) % 1f : pulse;
                    float pr = dd * (1f + ph * (it.Urgent ? 1.8f : 1.1f));
                    using (SolidBrush halo = new SolidBrush(Color.FromArgb((int)((it.Urgent ? 150 : 110) * (1f - ph)), dot)))
                        g.FillEllipse(halo, dcx - pr / 2, dcy - pr / 2, pr, pr);
                }
                Draw.Dot(g, dcx, dcy, dd, dot, it.HollowDot);
                if (active && !it.HollowDot) using (Pen ring = new Pen(theme.AccentText, 1.4f)) g.DrawEllipse(ring, dcx - dd / 2, dcy - dd / 2, dd, dd);
                int rightW = Draw.Width(g, it.Right, fSmall);
                int rightX = r.Right - pad - rightW;
                if (it.IsGroup) {
                    // Стрелка группы: вправо — свёрнута, вниз — раскрыта (Segoe Fluent Icons: ChevronRight / ChevronDown).
                    int cw = theme.S(16);
                    rightX -= cw + (rightW > 0 ? theme.S(6) : 0);
                    TextRenderer.DrawText(g, it.GroupOpen ? "\uE70D" : "\uE76C", fIcon, new Rectangle(r.Right - pad - cw, line1, cw, lh), muted,
                        TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                    if (rightW > 0) rightX = r.Right - pad - cw - theme.S(6) - rightW;
                }
                // Значки «закреплён» и «без уведомлений» — перед временем.
                string icons = (it.Pinned ? "" : "") + (it.Muted ? "" : "");
                int iconsX = rightX;
                if (icons.Length > 0) {
                    int iw = theme.S(14) * icons.Length;
                    iconsX = rightX - (rightW > 0 ? theme.S(6) : 0) - iw;
                    for (int k = 0; k < icons.Length; k++)
                        TextRenderer.DrawText(g, icons[k].ToString(), fIcon, new Rectangle(iconsX + k * theme.S(14), line1, theme.S(14), lh), muted,
                            TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                }
                Draw.TextLine(g, it.Title, fTitle, new Rectangle(textX, line1, Math.Max(0, iconsX - textX - theme.S(8)), lh), title, TextFormatFlags.Left);
                if (rightW > 0) Draw.TextLine(g, it.Right, fSmall, new Rectangle(rightX, line1, rightW + theme.S(2), lh), muted, TextFormatFlags.Left);

                int line2 = line1 + lh;
                int avail = r.Right - pad - textX;
                // Заполненность контекста — справа во второй строке: «контекст 72 %» и короткая полоска.
                int metaRight = r.Right - pad;
                if (it.ContextPercent >= 0) {
                    int bw = theme.S(36), bh = theme.S(4);
                    string ct = (avail > theme.S(300) ? "контекст " : "") + it.ContextPercent + " %";
                    int ctw = Draw.Width(g, ct, fSmall);
                    int bx = r.Right - pad - bw;
                    Color cc = it.ContextPercent >= 95 ? theme.State("error") : (it.ContextPercent >= it.ContextWarn ? theme.State("permission") : theme.State("working"));
                    if (active) cc = theme.AccentText;
                    float by = line2 + lh / 2f - bh / 2f;
                    Draw.Fill(g, new RectangleF(bx, by, bw, bh), bh / 2f, active ? Color.FromArgb(90, theme.AccentText) : theme.Fill);
                    float fw = Math.Max(bh, bw * Math.Min(100, it.ContextPercent) / 100f);
                    Draw.Fill(g, new RectangleF(bx, by, fw, bh), bh / 2f, cc);
                    Color ctc = active ? theme.AccentText : (it.ContextPercent >= it.ContextWarn ? theme.StateText("permission") : muted);
                    Draw.TextLine(g, ct, fSmall, new Rectangle(bx - theme.S(6) - ctw, line2, ctw + theme.S(2), lh), ctc, TextFormatFlags.Left);
                    metaRight = bx - theme.S(6) - ctw - theme.S(10);
                }
                int sw = Draw.Width(g, it.StateText, fBody);
                Color stateColor = active ? theme.AccentText : theme.StateText(it.State);
                Draw.TextLine(g, it.StateText, fBody, new Rectangle(textX, line2, Math.Max(0, Math.Min(sw + theme.S(2), metaRight - textX)), lh), stateColor, TextFormatFlags.Left);
                if (!string.IsNullOrEmpty(it.Meta)) {
                    string meta = (sw > 0 ? "  ·  " : "") + it.Meta;
                    int mx = textX + sw;
                    Draw.TextLine(g, meta, fBody, new Rectangle(mx, line2, Math.Max(0, metaRight - mx), lh), muted, TextFormatFlags.Left);
                }
                int y = line2 + lh;
                if (!expanded) {
                    if (!string.IsNullOrEmpty(it.Preview)) Draw.TextLine(g, it.Preview, fSmall, new Rectangle(textX, y, avail, lh), muted, TextFormatFlags.Left);
                } else {
                    TextFormatFlags wrap = TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.EndEllipsis;
                    if (!string.IsNullOrEmpty(it.Preview)) {
                        int ph = Measure(it.Preview, fSmall, avail, 6);
                        TextRenderer.DrawText(g, it.Preview, fSmall, new Rectangle(textX, y + theme.S(2), avail, ph), theme.Text, wrap);
                        y += ph + theme.S(4);
                    }
                    if (!string.IsNullOrEmpty(it.Details)) {
                        int dh = Measure(it.Details, fSmall, avail, 11);
                        TextRenderer.DrawText(g, it.Details, fSmall, new Rectangle(textX, y + theme.S(4), avail, dh), theme.Muted, wrap);
                        y += dh + theme.S(6);
                    }
                    if (!string.IsNullOrEmpty(it.RequestTitle) || it.Actions.Length > 0) PaintRequest(g, it, index, textX, y + theme.S(10), avail);
                }
            }
            // Разделитель с отступом до текста — как в списках iOS; у последней строки группы его нет.
            if (!last && !sel && !(index + 1 == selected)) {
                using (Pen p = new Pen(theme.Border, 1f)) g.DrawLine(p, textX, r.Bottom - 0.5f, r.Right, r.Bottom - 0.5f);
            }
        }

        void PaintRequest(Graphics g, CardItem it, int index, int x, int y, int width) {
            int innerW = width - theme.S(24);
            int th = string.IsNullOrEmpty(it.RequestTitle) ? 0 : Measure(it.RequestTitle, fTitle, innerW, 3);
            int dh = string.IsNullOrEmpty(it.RequestDetail) ? 0 : Measure(it.RequestDetail, fMono, innerW, 4);
            int bh = ButtonsHeight(it, innerW);
            int boxH = theme.S(12) + th + (th > 0 ? theme.S(6) : 0) + dh + (dh > 0 ? theme.S(8) : 0) + bh + theme.S(12);
            Color box = theme.Dark ? Theme.Hex(0x232325) : Theme.Hex(0xF2F2F7);
            Draw.Fill(g, new RectangleF(x, y, width, boxH), theme.S(10), box);
            int cx = x + theme.S(12), cy = y + theme.S(12);
            TextFormatFlags wrap = TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.EndEllipsis;
            if (th > 0) { TextRenderer.DrawText(g, it.RequestTitle, fTitle, new Rectangle(cx, cy, innerW, th), theme.Text, wrap); cy += th + theme.S(6); }
            if (dh > 0) { TextRenderer.DrawText(g, it.RequestDetail, fMono, new Rectangle(cx, cy, innerW, dh), theme.Muted, wrap); cy += dh + theme.S(8); }
            List<KeyValuePair<Rectangle, string>> list = new List<KeyValuePair<Rectangle, string>>();
            int bx = cx, bhh = theme.S(28), gap = theme.S(8);
            foreach (string a in it.Actions) {
                string[] p = ParseAction(a);
                int bw = TextRenderer.MeasureText(p[1], fButton).Width + theme.S(24);
                if (bx > cx && bx + bw > cx + innerW) { bx = cx; cy += bhh + gap; }
                Rectangle br = new Rectangle(bx, cy, bw, bhh);
                bool hot = hoverButton == index + ":" + p[0];
                Color fill, text;
                switch (p[2]) {
                    case "primary": fill = hot ? theme.AccentHover : theme.Accent; text = theme.AccentText; break;
                    case "destructive": fill = hot ? Draw.Mix(theme.Fill, theme.Text, 0.06f) : theme.Fill; text = theme.Danger; break;
                    default: fill = hot ? Draw.Mix(theme.Fill, theme.Text, 0.06f) : theme.Fill; text = theme.Text; break;
                }
                Draw.Fill(g, br, bhh / 2f, fill);
                TextRenderer.DrawText(g, p[1], fButton, br, text, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                list.Add(new KeyValuePair<Rectangle, string>(br, p[0]));
                bx += bw + gap;
            }
            buttons[index] = list;
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
            string hb = HitButton(e.Location);
            if (h != hover || hb != hoverButton) { hover = h; hoverButton = hb; Cursor = h >= 0 ? Cursors.Hand : Cursors.Default; Invalidate(); }
        }

        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (hover != -1 || pressed != -1 || hoverButton != null) { hover = -1; pressed = -1; hoverButton = null; Invalidate(); } }

        // Отклик на нажатие, а не на отпускание: выделение и подсветка появляются сразу.
        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            Focus();
            if (HitButton(e.Location) != null) return;   // кнопка сработает на отпускание
            int h = HitTest(e.Location);
            if (h >= 0) { bool changed = h != selected; selected = h; pressed = h; if (changed) Relayout(); Invalidate(); }
            if (e.Button == MouseButtons.Right && h >= 0) Raise("context", e.Location);
        }

        protected override void OnMouseUp(MouseEventArgs e) {
            base.OnMouseUp(e);
            string hb = HitButton(e.Location);
            if (hb != null && e.Button == MouseButtons.Left) {
                int colon = hb.IndexOf(':');
                selected = int.Parse(hb.Substring(0, colon));
                pressed = -1; Invalidate();
                Raise("act:" + hb.Substring(colon + 1), e.Location);
                return;
            }
            int h = HitTest(e.Location);
            bool action = pressed >= 0 && h == pressed && e.Button == MouseButtons.Left && (items[h].IsAction || items[h].IsGroup);
            pressed = -1; Invalidate();
            if (action) Raise("open", e.Location);   // строка-действие срабатывает одним щелчком
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e) {
            base.OnMouseDoubleClick(e);
            if (HitButton(e.Location) != null) return;
            int h = HitTest(e.Location);
            if (e.Button == MouseButtons.Left && h >= 0 && !items[h].IsAction && !items[h].IsGroup) Raise("open", e.Location);
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
                Raise("context", new Point(r.X + theme.S(40), r.Top + theme.S(40)));
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
