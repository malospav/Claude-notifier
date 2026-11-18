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
        // Заменить шрифт в поле, освободив прежний. Только для шрифтов, которые элемент создал сам (Fonts.*,
        // IconButton.IconFont — каждый вызов даёт новый объект): иначе ApplyTheme копит GDI-шрифты.
        public static Font Replace(Font old, Font next) {
            if (old != null && !ReferenceEquals(old, next)) { try { old.Dispose(); } catch { } }
            return next;
        }
        public static void Free(params Font[] fonts) {
            foreach (Font f in fonts) if (f != null) { try { f.Dispose(); } catch { } }
        }
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
        [DllImport("user32.dll")] static extern bool ValidateRect(IntPtr h, IntPtr rect);
        public static void ValidateAll(IntPtr h) { ValidateRect(h, IntPtr.Zero); }
        [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
        // Сколько секунд не было ввода (мышь, клавиатура) во всей системе.
        public static double InputIdleSeconds() {
            try {
                LASTINPUTINFO li = new LASTINPUTINFO(); li.cbSize = (uint)Marshal.SizeOf(li);
                if (!GetLastInputInfo(ref li)) return 0;
                return unchecked((uint)Environment.TickCount - li.dwTime) / 1000.0;
            } catch { return 0; }
        }
        [DllImport("user32.dll", EntryPoint = "SetWindowPos")] static extern bool SetWindowPosZ(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int value, int size);
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        static readonly uint ownPid = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;

        // Поднять окно на самый верх среди «поверх всех» (без фокуса). Возвращает true, если пришлось поднимать:
        // над окном было видимое окно, перекрывающее area (координаты экрана). Свои окна приложения (выпадающие
        // списки, меню, подсказки, диалоги) перекрытием не считаются: они должны оставаться над шторкой.
        public static bool KeepOnTop(IntPtr h, Rectangle area) {
            try {
                bool covered = false;
                for (IntPtr w = GetWindow(h, 3 /* GW_HWNDPREV */); w != IntPtr.Zero; w = GetWindow(w, 3)) {
                    if (!IsWindowVisible(w) || IsIconic(w)) continue;
                    uint pid; GetWindowThreadProcessId(w, out pid);
                    if (pid == ownPid) continue;
                    int cloaked;
                    if (DwmGetWindowAttribute(w, 14 /* DWMWA_CLOAKED */, out cloaked, 4) == 0 && cloaked != 0) continue;
                    RECT r;
                    if (!GetWindowRect(w, out r)) continue;
                    if (Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom).IntersectsWith(area)) { covered = true; break; }
                }
                if (!covered) return false;
                // HWND_TOPMOST; SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOOWNERZORDER
                SetWindowPosZ(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0200);
                return true;
            } catch { return false; }
        }

        // Поставить окно (выпадающий список, меню) на самый верх «поверх всех» без фокуса — выше шторки.
        public static void BringToTop(IntPtr h) {
            try { if (h != IntPtr.Zero) SetWindowPosZ(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0200); } catch { }
        }

        [DllImport("dwmapi.dll")] static extern int DwmFlush();
        // Ждать следующего кадра экрана (композиция Windows). 0 — дождались.
        public static int WaitVBlank() { try { return DwmFlush(); } catch { return -1; } }
        [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
        [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);
        // Точный таймер (1 мс) только на время анимации: иначе таймер WinForms тикает по 15,6 мс и кадры неровные.
        static int precise;
        public static void TimerPrecise(bool on) {
            try {
                if (on) { if (System.Threading.Interlocked.Increment(ref precise) == 1) timeBeginPeriod(1); }
                else if (precise > 0 && System.Threading.Interlocked.Decrement(ref precise) == 0) timeEndPeriod(1);
            } catch { }
        }
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
}
