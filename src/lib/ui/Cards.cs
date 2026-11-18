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
        public bool NeutralState;        // текст статуса серый (у строки-группы это число сеансов, а не статус)
        public string[] Chips = new string[0];     // плашки с главными числами — в раскрытой карточке
        public string[] SubLines = new string[0];  // подстроки под статусом (работающие агенты) — видны всегда
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
        // Карточки, раскрытые запросом (ForceExpand), которые пользователь свернул щелчком. Ключ — Id и запрос:
        // новый запрос раскроет карточку снова.
        readonly HashSet<string> collapsed = new HashSet<string>();
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
            springTimer.Interval = 15;
            springTimer.Tick += delegate { SpringTick(); };
            pulseTimer.Interval = 40;
            pulseTimer.Tick += delegate {
                pulse = (float)((DateTime.UtcNow.Ticks / TimeSpan.TicksPerMillisecond) % 1600) / 1600f;
                Invalidate();
            };
            ApplyTheme(theme);
        }

        public void ApplyTheme(Theme t) {
            theme = t;
            // Прежние шрифты освобождаются (каждый Fonts.* — новый объект), иначе смена темы их копит.
            fTitle = Fonts.Replace(fTitle, Fonts.Semibold(10.5f)); fBody = Fonts.Replace(fBody, Fonts.Text(9.5f)); fSmall = Fonts.Replace(fSmall, Fonts.Text(9f)); fHeader = Fonts.Replace(fHeader, Fonts.Semibold(9f));
            fEmpty = Fonts.Replace(fEmpty, Fonts.Semibold(12f)); fButton = Fonts.Replace(fButton, Fonts.Semibold(9f)); fIcon = Fonts.Replace(fIcon, IconButton.IconFont(8f));
            Font mono = new Font("Cascadia Mono", 8.5f); if (mono.Name != "Cascadia Mono") { mono.Dispose(); mono = new Font("Consolas", 9f); }
            fMono = Fonts.Replace(fMono, mono);
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

        // Щелчок по строке (как левой кнопкой мыши мимо кнопок) — для тестов.
        public void ClickRow(int index) {
            if (index < 0 || index >= items.Count) return;
            if (!ToggleCollapse(index)) selected = index;
            Relayout(); Invalidate();
        }

        public bool IsRowExpanded(int index) { return index >= 0 && index < items.Count && IsExpanded(index); }

        // Нажимает кнопку действия строки (для тестов и клавиатуры).
        public void InvokeAction(int index, string actionId) {
            if (index < 0 || index >= items.Count) return;
            selected = index;
            Raise("act:" + actionId, Point.Empty);
        }

        static string CollapseKey(CardItem it) { return it.Id + "|" + it.RequestTitle + "|" + string.Join(";", it.Actions); }

        bool IsExpanded(int i) {
            return (items[i].ForceExpand && !collapsed.Contains(CollapseKey(items[i]))) || (ExpandSelected && i == selected && !items[i].IsAction && !items[i].IsGroup);
        }

        // Повторный щелчок по раскрытой карточке (не по кнопке) сворачивает её; щелчок по свёрнутой — раскрывает.
        // Возвращает true, если щелчок свернул карточку.
        bool ToggleCollapse(int h) {
            CardItem it = items[h];
            if (it.IsAction || it.IsGroup || !IsExpanded(h)) {
                if (it.ForceExpand) collapsed.Remove(CollapseKey(it));
                return false;
            }
            bool selectedOpen = h == selected && ExpandSelected;
            if (!selectedOpen && !it.ForceExpand) return false;
            if (it.ForceExpand) collapsed.Add(CollapseKey(it));
            if (h == selected) selected = -1;
            return true;
        }

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
            if (!IsExpanded(i)) return theme.S(string.IsNullOrEmpty(it.Preview) ? 58 : 76) + SubLinesHeight(it);
            int w = TextWidth() - (it.Child ? theme.S(18) : 0);
            int h = theme.S(10) + theme.S(19) * 2 + SubLinesHeight(it);             // заголовок, статус, агенты
            if (!string.IsNullOrEmpty(it.Preview)) h += Measure(it.Preview, fSmall, w, 6) + theme.S(4);
            if (it.Chips.Length > 0) h += ChipsHeight(it, w) + theme.S(8);
            if (!string.IsNullOrEmpty(it.Details)) h += MeasureDetails(it.Details, w) + theme.S(6);
            if (!string.IsNullOrEmpty(it.RequestTitle) || it.Actions.Length > 0) {
                h += theme.S(10);
                if (!string.IsNullOrEmpty(it.RequestTitle)) h += Measure(it.RequestTitle, fTitle, w - theme.S(24), 3) + theme.S(14);
                if (!string.IsNullOrEmpty(it.RequestDetail)) h += Measure(it.RequestDetail, fMono, w - theme.S(24), 4) + theme.S(4);
                h += ButtonsHeight(it, w - theme.S(24)) + theme.S(12);
            }
            return h + theme.S(12);
        }

        int SubLinesHeight(CardItem it) { return it.SubLines.Length * theme.S(18); }

        int ChipsHeight(CardItem it, int width) {
            if (it.Chips.Length == 0) return 0;
            int x = 0, lines = 1, ch = theme.S(22), gap = theme.S(6);
            foreach (string c in it.Chips) {
                int cw = TextRenderer.MeasureText(c, fSmall).Width + theme.S(16);
                if (x > 0 && x + cw > width) { lines++; x = 0; }
                x += cw + gap;
            }
            return lines * ch + (lines - 1) * gap;
        }

        void PaintChips(Graphics g, CardItem it, int x0, int y0, int width) {
            int x = x0, y = y0, ch = theme.S(22), gap = theme.S(6);
            foreach (string c in it.Chips) {
                int cw = TextRenderer.MeasureText(c, fSmall).Width + theme.S(16);
                if (x > x0 && x + cw > x0 + width) { x = x0; y += ch + gap; }
                Draw.Fill(g, new RectangleF(x, y, cw, ch), ch / 2f, theme.Fill);
                TextRenderer.DrawText(g, c, fSmall, new Rectangle(x, y, cw, ch), theme.Text,
                    TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                x += cw + gap;
            }
        }

        // Подробности — таблица: строка «Подпись\tЗначение» → подпись серым слева, значение справа (до 3 строк).
        int DetailsLabelWidth(string details) {
            int lw = 0;
            foreach (string row in details.Split('\n')) {
                int tab = row.IndexOf('\t');
                if (tab > 0) lw = Math.Max(lw, TextRenderer.MeasureText(row.Substring(0, tab), fSmall).Width);
            }
            return Math.Min(lw, theme.S(120));
        }

        int MeasureDetails(string details, int width) {
            int lw = DetailsLabelWidth(details), line = TextRenderer.MeasureText("Ag", fSmall).Height, total = 0;
            foreach (string row in details.Split('\n')) {
                int tab = row.IndexOf('\t');
                string value = tab > 0 ? row.Substring(tab + 1) : row;
                int vw = tab > 0 ? Math.Max(theme.S(60), width - lw - theme.S(12)) : width;
                total += Math.Max(line, Measure(value, fSmall, vw, 3)) + theme.S(3);
            }
            return total;
        }

        void PaintDetails(Graphics g, string details, int x, int y, int width) {
            int lw = DetailsLabelWidth(details), line = TextRenderer.MeasureText("Ag", fSmall).Height;
            TextFormatFlags wrap = TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.EndEllipsis;
            foreach (string row in details.Split('\n')) {
                int tab = row.IndexOf('\t');
                string value = tab > 0 ? row.Substring(tab + 1) : row;
                int vx = tab > 0 ? x + lw + theme.S(12) : x;
                int vw = tab > 0 ? Math.Max(theme.S(60), width - lw - theme.S(12)) : width;
                int h = Math.Max(line, Measure(value, fSmall, vw, 3));
                if (tab > 0) TextRenderer.DrawText(g, row.Substring(0, tab), fSmall, new Rectangle(x, y, lw + theme.S(4), line), theme.Muted,
                    TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
                TextRenderer.DrawText(g, value, fSmall, new Rectangle(vx, y, vw, h), tab > 0 ? theme.Text : theme.Muted, wrap);
                y += h + theme.S(3);
            }
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

        // --- Пружинная анимация высоты строк (как react-spring, пресет «stiff»: tension 210, friction 20, mass 1) ---
        // Раскрытие и сворачивание карточки, новая строка «вырастает» из нуля. Пружина прерываемая: новый щелчок
        // посреди движения продолжает его с текущей скоростью. Анимация выключена в Windows — высоты меняются сразу.
        public const float SpringTension = 210f, SpringFriction = 20f;
        readonly Dictionary<string, float[]> springs = new Dictionary<string, float[]>();   // ключ строки → { высота, скорость }
        readonly List<int> targets = new List<int>();
        readonly Timer springTimer = new Timer();
        bool populated;
        public bool Animating { get { return springTimer.Enabled; } }

        static string RowKey(CardItem it, int i) { return string.IsNullOrEmpty(it.Id) ? "#" + i : it.Id; }

        // Один шаг пружины (полунеявный Эйлер, шаг dt секунд). Возвращает true, если пружина успокоилась.
        public static bool SpringStep(float[] s, float target, float dt) {
            float a = -SpringTension * (s[0] - target) - SpringFriction * s[1];
            s[1] += a * dt;
            s[0] += s[1] * dt;
            if (Math.Abs(s[0] - target) < 0.5f && Math.Abs(s[1]) < 8f) { s[0] = target; s[1] = 0; return true; }
            return false;
        }

        // Сколько шагов по 5 мс прошло с прошлого тика: если UI-поток занят и тики редки, анимация не растягивается.
        readonly System.Diagnostics.Stopwatch springClock = new System.Diagnostics.Stopwatch();
        public static int StepsSince(System.Diagnostics.Stopwatch clock) {
            double ms = clock.IsRunning ? clock.Elapsed.TotalMilliseconds : 15;
            clock.Restart();
            return Math.Max(1, Math.Min(80, (int)Math.Round(ms / 5.0)));
        }

        void SpringTick() {
            int steps = StepsSince(springClock);
            bool moving = false;
            for (int i = 0; i < items.Count && i < targets.Count; i++) {
                float[] s;
                if (!springs.TryGetValue(RowKey(items[i], i), out s)) continue;
                for (int k = 0; k < steps; k++) if (SpringStep(s, targets[i], 0.005f)) break;
                if (s[0] != targets[i]) moving = true;
            }
            if (!moving) { springTimer.Stop(); springClock.Reset(); }
            LayoutRows();
            Invalidate();
        }

        void Relayout() { Relayout(true); }

        void Relayout(bool allowAnimation) {
            targets.Clear();
            for (int i = 0; i < items.Count; i++) targets.Add(RowHeight(i));
            bool animate = allowAnimation && Motion.Enabled && populated && Visible && IsHandleCreated;
            HashSet<string> alive = new HashSet<string>();
            bool moving = false;
            for (int i = 0; i < items.Count; i++) {
                string key = RowKey(items[i], i);
                alive.Add(key);
                float[] s;
                if (!springs.TryGetValue(key, out s)) { s = new float[] { animate ? 0f : targets[i], 0f }; springs[key] = s; }
                if (!animate) { s[0] = targets[i]; s[1] = 0; }
                if (s[0] != targets[i]) moving = true;
            }
            foreach (string k in new List<string>(springs.Keys)) if (!alive.Contains(k)) springs.Remove(k);
            if (items.Count > 0) populated = true;
            if (moving && !springTimer.Enabled) { springClock.Restart(); springTimer.Start(); }
            LayoutRows();
        }

        int AnimatedHeight(int i) {
            float[] s;
            if (i < targets.Count && springs.TryGetValue(RowKey(items[i], i), out s)) return Math.Max(0, (int)Math.Round(s[0]));
            return i < targets.Count ? targets[i] : RowHeight(i);
        }

        void LayoutRows() {
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
                int h = AnimatedHeight(i);
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
        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); Relayout(false); }   // окно тянут — без пружины
        protected override void Dispose(bool disposing) { if (disposing) { pulseTimer.Dispose(); springTimer.Dispose(); Fonts.Free(fTitle, fBody, fSmall, fHeader, fEmpty, fButton, fIcon, fMono); } base.Dispose(disposing); }

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
                if (r.Height <= 0) continue;
                // Во время анимации строка ниже своей полной высоты — содержимое обрезается по её краю.
                g.SetClip(r);
                PaintRow(g, items[i], r, i, last);
                g.ResetClip();
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
                Color stateColor = active ? theme.AccentText : (it.NeutralState ? muted : theme.StateText(it.State));
                Draw.TextLine(g, it.StateText, fBody, new Rectangle(textX, line2, Math.Max(0, Math.Min(sw + theme.S(2), metaRight - textX)), lh), stateColor, TextFormatFlags.Left);
                if (!string.IsNullOrEmpty(it.Meta)) {
                    string meta = (sw > 0 ? "  ·  " : "") + it.Meta;
                    int mx = textX + sw;
                    Draw.TextLine(g, meta, fBody, new Rectangle(mx, line2, Math.Max(0, metaRight - mx), lh), muted, TextFormatFlags.Left);
                }
                int y = line2 + lh;
                // Подстроки (работающие агенты): маленькая точка цвета статуса и текст в одну строку.
                foreach (string sl in it.SubLines) {
                    int sh = theme.S(18);
                    float sd = theme.S(5);
                    Color sc = active ? theme.AccentText : theme.State("working");
                    if (pulseTimer.Enabled) sc = Color.FromArgb((int)(140 + 115 * Math.Abs(Math.Sin(pulse * Math.PI * 2))), sc);
                    using (SolidBrush b = new SolidBrush(sc)) g.FillEllipse(b, textX + theme.S(1), y + sh / 2f - sd / 2, sd, sd);
                    Draw.TextLine(g, sl, fSmall, new Rectangle(textX + theme.S(12), y, Math.Max(0, avail - theme.S(12)), sh), active ? theme.AccentText : theme.Text, TextFormatFlags.Left);
                    y += sh;
                }
                if (!expanded) {
                    if (!string.IsNullOrEmpty(it.Preview)) Draw.TextLine(g, it.Preview, fSmall, new Rectangle(textX, y, avail, lh), muted, TextFormatFlags.Left);
                } else {
                    TextFormatFlags wrap = TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.EndEllipsis;
                    if (!string.IsNullOrEmpty(it.Preview)) {
                        int ph = Measure(it.Preview, fSmall, avail, 6);
                        TextRenderer.DrawText(g, it.Preview, fSmall, new Rectangle(textX, y + theme.S(2), avail, ph), theme.Text, wrap);
                        y += ph + theme.S(4);
                    }
                    if (it.Chips.Length > 0) {
                        PaintChips(g, it, textX, y + theme.S(4), avail);
                        y += ChipsHeight(it, avail) + theme.S(8);
                    }
                    if (!string.IsNullOrEmpty(it.Details)) {
                        PaintDetails(g, it.Details, textX, y + theme.S(4), avail);
                        y += MeasureDetails(it.Details, avail) + theme.S(6);
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
            if (h >= 0 && e.Button == MouseButtons.Left && ToggleCollapse(h)) { pressed = -1; Relayout(); Invalidate(); return; }
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
}
