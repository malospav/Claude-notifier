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
    public sealed class NotchItem {
        public string Id = "";
        public string Title = "";
        public string Meta = "";          // «Терминал» / «Приложение» / устройство
        public string State = "";         // working | waiting | permission | error
        public string StateText = "";
        public string Preview = "";
        public string RequestTitle = "";
        public string[] Actions = new string[0];   // "id|текст|primary|secondary|destructive"
        public int Tools;                // действий Claude в сеансе: прибавилось — у сфинкса «Ага!»
        public int Agents;               // работающих агентов — огоньки вокруг головы
        public string Device = "";       // id устройства ('' — этот ПК): свой маскот
        public string Group = "";        // подпись группы в списке «Другие» («Этот ПК», «MacBook Air»)
        public long WaitSince;           // ждёт вас (запрос, ошибка, вопрос в ответе) с этого момента, UTC ticks; 0 — не ждёт
        public string Ask = "";          // что спрашивают — для бегущей строки («Закоммитить и отправить?»)
        public string Hint = "";         // подсказка над главным маскотом: что делает сейчас (действие, сколько работает, контекст)
        public bool Pinned;              // закреплён — звёздочка, всегда первым
        public string Project = "";      // проект (папка) — «Разрешить все» для запросов одного проекта
        public string[] Feed = new string[0];   // лента сеанса: "you|claude|tool" + "|HH:mm|текст"
        public object Tag;
    }

    // Строка страницы: header | switch | choice | button | info | device | chart | note.
    public sealed class NotchRow {
        public string Kind = "info";
        public string Key = "";
        public string Title = "";
        public string Subtitle = "";
        public string Value = "";          // текст справа (кнопка, выбор, число)
        public bool On;                    // switch
        public string Dot = "";            // цвет точки слева (статус): online | working | ... ; '' — без точки
        public string[] Actions = new string[0];   // device: "id|текст|style"
        public double[] Values = new double[0];    // chart
        public string[] Labels = new string[0];
        public string[] ValueLabels = new string[0];
        public int Highlight = -1;
    }

    public sealed class NotchEventArgs : EventArgs {
        public string Kind;      // expand | collapse | page | plus | term | open | sound | close | action | set | row
        public string Id;        // сеанс (или ключ строки)
        public string Action;    // кнопка ответа, страница, действие строки
        public Point Location;   // экранные координаты щелчка
        public NotchEventArgs(string kind, string id, string action, Point location) { Kind = kind; Id = id; Action = action; Location = location; }
    }

    public sealed partial class NotchView : Control {
        // Текст шторки рисуется со сдвигом и обрезкой Graphics (содержимое смещено внутри окна и обрезается
        // растущей фигурой). Обычный TextRenderer то и другое игнорирует — текст «отставал» от фонов.
        static class TextRenderer {
            const TextFormatFlags P = TextFormatFlags.PreserveGraphicsTranslateTransform | TextFormatFlags.PreserveGraphicsClipping;
            public static void DrawText(IDeviceContext g, string t, Font f, Rectangle r, Color c) { System.Windows.Forms.TextRenderer.DrawText(g, t, f, r, c, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | P); }
            public static void DrawText(IDeviceContext g, string t, Font f, Rectangle r, Color c, TextFormatFlags fl) { System.Windows.Forms.TextRenderer.DrawText(g, t, f, r, c, fl | P); }
            public static void DrawText(IDeviceContext g, string t, Font f, Rectangle r, Color c, Color back, TextFormatFlags fl) { System.Windows.Forms.TextRenderer.DrawText(g, t, f, r, c, back, fl | P); }
            public static void DrawText(IDeviceContext g, string t, Font f, Point pt, Color c) { System.Windows.Forms.TextRenderer.DrawText(g, t, f, pt, c, P); }
            public static void DrawText(IDeviceContext g, string t, Font f, Point pt, Color c, TextFormatFlags fl) { System.Windows.Forms.TextRenderer.DrawText(g, t, f, pt, c, fl | P); }
            public static Size MeasureText(string t, Font f) { return System.Windows.Forms.TextRenderer.MeasureText(t, f); }
            public static Size MeasureText(string t, Font f, Size s) { return System.Windows.Forms.TextRenderer.MeasureText(t, f, s); }
            public static Size MeasureText(string t, Font f, Size s, TextFormatFlags fl) { return System.Windows.Forms.TextRenderer.MeasureText(t, f, s, fl); }
            public static Size MeasureText(IDeviceContext g, string t, Font f) { return System.Windows.Forms.TextRenderer.MeasureText(g, t, f); }
            public static Size MeasureText(IDeviceContext g, string t, Font f, Size s) { return System.Windows.Forms.TextRenderer.MeasureText(g, t, f, s); }
            public static Size MeasureText(IDeviceContext g, string t, Font f, Size s, TextFormatFlags fl) { return System.Windows.Forms.TextRenderer.MeasureText(g, t, f, s, fl); }
        }

        readonly List<NotchItem> items = new List<NotchItem>();
        readonly Dictionary<string, NotchRow[]> pages = new Dictionary<string, NotchRow[]>();
        readonly Dictionary<string, int> scrolls = new Dictionary<string, int>();
        readonly List<KeyValuePair<Rectangle, string>> hits = new List<KeyValuePair<Rectangle, string>>();
        readonly Timer anim = new Timer();
        readonly DateTime born = DateTime.UtcNow;
        int busyInterval = 100;
        Theme theme = Theme.Create(true);
        Font fTitle, fBody, fSmall, fBold, fHeader, fIcon, fIconSmall;
        string hover;
        int contentHeight, viewHeight;
        public bool Expanded;
        public string Page = "home";           // home | chat | stats | devices | settings
        public string SelectedId = "";
        // Полоски вверху: сколько осталось от лимитов Claude (5 часов и неделя), %; < 0 — нет данных.
        public bool ShowStats;            // загрузка ПК (ЦП, ГП, память) посередине свёрнутой шторки
        Rectangle statsRect;              // где нарисованы показатели — перерисовать только их при новом замере
        int statsShown = -1;              // номер замера SysStats, который сейчас на экране
        public float Left5 = -1, LeftWeek = -1;
        public string Detail5 = "", DetailWeek = "";
        public bool LimitsStale;               // данные старые (сервер давно не отвечал) — полоски серые
        public bool SoundOff;
        public event EventHandler<NotchEventArgs> Command;
        public event EventHandler PageChanged;
        public event EventHandler<NotchEventArgs> Local;   // раскрыть / свернуть — обрабатывает окно шторки сразу
        readonly Dictionary<string, string> answers = new Dictionary<string, string>();   // id сеанса → полный последний ответ

        public void SetAnswer(string id, string text) { answers[id ?? ""] = text ?? ""; Invalidate(); }
        public string Answer(string id) { string a; return answers.TryGetValue(id ?? "", out a) ? a : null; }

        // Cursor.Position бросает Win32Exception, когда ввод на чужом рабочем столе (окно UAC, экран блокировки):
        // в таймере это убило бы поток шторки. Последняя известная позиция — безопасная замена.
        static Point lastSafeCursor;
        internal static Point SafeCursor() {
            try { lastSafeCursor = Cursor.Position; } catch { }
            return lastSafeCursor;
        }

        public NotchView() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            BackColor = Bg;
            anim.Interval = 33;
            anim.Tick += delegate { try { AnimTick(); } catch (Exception e) { NotchHost.Report(e); } };
            peekTimer.Tick += delegate { try { EndPeek(); } catch (Exception e) { peekTimer.Stop(); NotchHost.Report(e); } };
            ApplyTheme(Theme.Create(true));
        }

        // Шаг таймера анимации. Исключение здесь ловит обработчик Tick: один сбойный кадр не должен
        // останавливать поток шторки.
        void AnimTick() {
            {
                Point c = SafeCursor();
                if (c != lastCursor) { lastCursor = c; lastMove = DateTime.UtcNow; }
                // Частота кадров по тому, что сейчас видно: сфинкс следит за курсором — 40 кадров/с; кто-то работает —
                // 30 (раскрыта) или 20 (свёрнута); все ждут — 10. Экран заблокирован, компьютер засыпает или вас нет
                // за компьютером (2 мин без ввода, шторка свёрнута) — анимация стоит, таймер лишь раз в секунду
                // проверяет, не вернулись ли вы.
                bool away = Away;
                int want = Paused || away ? 1000 : Expanded && (DateTime.UtcNow - lastMove).TotalSeconds < 3 ? 25 : busyInterval;
                if (anim.Interval != want) anim.Interval = want;
                SetAbsent(Paused || away);   // ушли — копим события; вернулись — сводка
                if (Paused || away) { wasAway = true; return; }
                if (wasAway) { wasAway = false; Invalidate(); return; }
                // Игра или видео на весь экран на этом мониторе — свёрнутая шторка не анимируется (кадр раз в секунду).
                if (!Expanded && FullscreenOver()) { if (anim.Interval != 1000) anim.Interval = 1000; fullscreenPaused = true; return; }
                if (fullscreenPaused) { fullscreenPaused = false; Invalidate(); return; }
                // Двигаются только персонажи: перерисовываем их места, а не всю шторку (текст, кнопки, списки).
                // Загрузка ПК: замер нужен, пока показатели видны (раньше всех выходов ниже — иначе при свечении
                // замер не запрашивался и вместо цифр висели «—»); новый замер — перерисовать только их.
                bool statsNew = false;
                if (ShowStats && !Expanded) {
                    SysStats.Want();
                    int v = System.Threading.Thread.VolatileRead(ref SysStats.Version);
                    if (v != statsShown) { statsShown = v; statsNew = true; }
                }
                if (!painted) { Invalidate(); return; }
                // Главный маскот летит, его гладят, тыкнули, разбудили — перерисовать целиком.
                bool playing = PlayTick(), moving = StepMotions(), ui = UiTick();
            if (playing || moving || ui) {
                if (anim.Interval != 16 && Animate) anim.Interval = 16;   // что-то движется — 60 кадров/с
                Invalidate(); return;
            }
                // Внимание: свечение и бегущая строка меняются каждый кадр — свёрнутую (она маленькая) целиком;
                // главный маскот вырос — свёрнутой нужна другая высота.
                if (!Expanded && Attention) {
                    bool grown = Grown;
                    if (grown != grownShown) { grownShown = grown; RaiseCollapsedResize(); }
                    if (GlowItem() != null || PeekActive) { Invalidate(); return; }
                }
                if (statsNew) Invalidate(statsRect.Width > 0 ? Rectangle.Inflate(statsRect, 2, 2) : ClientRectangle);
                foreach (RectangleF fr in faceRects) {
                    RectangleF big = RectangleF.Inflate(fr, fr.Width * 0.35f + 2, fr.Height * 0.25f + 2);
                    Invalidate(Rectangle.Intersect(ClientRectangle, Rectangle.Round(big)));
                }
            }
        }

        public Theme Theme { get { return theme; } }

        public void ApplyTheme(Theme t) {
            theme = t;
            // Шрифты свои (каждый Fonts.* — новый объект): прежние освобождаем, иначе каждая смена темы их копит.
            fTitle = Fonts.Replace(fTitle, Fonts.Semibold(12f)); fBody = Fonts.Replace(fBody, Fonts.Text(10f)); fSmall = Fonts.Replace(fSmall, Fonts.Text(9f));
            fBold = Fonts.Replace(fBold, Fonts.Semibold(10f)); fHeader = Fonts.Replace(fHeader, Fonts.Semibold(9f));
            fIcon = Fonts.Replace(fIcon, IconButton.IconFont(11f)); fIconSmall = Fonts.Replace(fIconSmall, IconButton.IconFont(9f));
            Invalidate();
        }

        public int Count { get { return items.Count; } }
        public NotchItem this[int i] { get { return items[i]; } }
        public NotchRow[] Rows(string page) { NotchRow[] r; return pages.TryGetValue(page, out r) ? r : new NotchRow[0]; }

        public NotchItem Selected {
            get {
                foreach (NotchItem it in items) if (it.Id == SelectedId) return it;
                return items.Count > 0 ? items[0] : null;
            }
        }

        public void SetItems(IEnumerable<NotchItem> list) {
            items.Clear();
            if (list != null) items.AddRange(list);
            if (Selected != null && Selected.Id != SelectedId) SelectedId = Selected.Id;
            TrackMoods();
            TrackMotions();
            TrackAttention();
            TryPendingQuick();
            UpdateTimer();
            Invalidate();
        }

        // --- Настроение сфинксов: «Ага!» на каждое новое действие Claude, задумчивость после долгой паузы ---
        sealed class MoodState { public int Tools = -1; public DateTime LastChange = DateTime.UtcNow; public readonly List<DateTime> Ahas = new List<DateTime>(); }
        sealed class LookState { public float X, Y, W; public DateTime At = DateTime.UtcNow; }
        readonly Dictionary<string, LookState> looks = new Dictionary<string, LookState>();
        readonly Dictionary<string, MoodState> moods = new Dictionary<string, MoodState>();
        Point lastCursor;
        DateTime lastMove = DateTime.MinValue;
        public static double DeepAfterSeconds = 25;   // столько секунд без действий — «задумался» (тесты уменьшают)

        void TrackMoods() {
            DateTime now = DateTime.UtcNow;
            HashSet<string> alive = new HashSet<string>();
            foreach (NotchItem it in items) {
                alive.Add(it.Id);
                MoodState m;
                if (!moods.TryGetValue(it.Id, out m)) { m = new MoodState(); m.Tools = it.Tools; moods[it.Id] = m; continue; }
                if (it.Tools > m.Tools && m.Tools >= 0) {
                    // Новые действия — до трёх «озарений» подряд, с паузой 0,9 с.
                    int n = Math.Min(3, it.Tools - m.Tools);
                    DateTime at = now;
                    if (m.Ahas.Count > 0 && m.Ahas[m.Ahas.Count - 1].AddMilliseconds(900) > at) at = m.Ahas[m.Ahas.Count - 1].AddMilliseconds(900);
                    for (int i = 0; i < n; i++) { m.Ahas.Add(at); at = at.AddMilliseconds(900); }
                    m.LastChange = now;
                }
                if (it.State != "working") m.LastChange = now;
                m.Tools = it.Tools;
            }
            foreach (string k in new List<string>(moods.Keys)) if (!alive.Contains(k)) moods.Remove(k);
        }

        public void PulseAha(string id) { MoodState m; if (moods.TryGetValue(id, out m)) { m.Ahas.Add(DateTime.UtcNow); m.LastChange = DateTime.UtcNow; } }

        public CatMood MoodFor(NotchItem it, RectangleF face, bool look) {
            CatMood md = new CatMood();
            md.Agents = it.Agents;
            DateTime now = DateTime.UtcNow;
            MoodState m;
            if (moods.TryGetValue(it.Id, out m)) {
                m.Ahas.RemoveAll(delegate (DateTime a) { return (now - a).TotalSeconds > 2; });
                DateTime latest = DateTime.MinValue;
                foreach (DateTime a in m.Ahas) if (a <= now && a > latest) latest = a;
                if (latest != DateTime.MinValue && (now - latest).TotalSeconds < 0.8) md.AhaAge = (float)(now - latest).TotalSeconds;   // «Ага!» длится 0,8 с
                md.Deep = it.State == "working" && md.AhaAge < 0 && (now - m.LastChange).TotalSeconds > DeepAfterSeconds;
            }
            // Курсор недавно двигался рядом — сфинкс смотрит на него (только крупные в раскрытой шторке).
            // Без рывков: взгляд догоняет курсор с затуханием (~0,15 с), а «вес» взгляда плавно растёт и спадает.
            if (look || !Expanded) {
                bool has = false; float tx = 0, ty = 0;
                if ((now - lastMove).TotalSeconds < 2.0 && IsHandleCreated && Animate) {
                    Point c = PointToScreen(new Point((int)(face.X + face.Width / 2) + origin.X, (int)(face.Y + face.Height / 2) + origin.Y));
                    Point cur = SafeCursor();
                    float dx = cur.X - c.X, dy = cur.Y - c.Y;
                    float nx = Expanded ? theme.S(700) : theme.S(320), ny = Expanded ? theme.S(500) : theme.S(200);
                    if (Math.Abs(dx) < nx && Math.Abs(dy) < ny) {
                        has = true;
                        tx = Math.Max(-1f, Math.Min(1f, dx / theme.S(240)));
                        ty = Math.Max(-1f, Math.Min(1f, -dy / theme.S(200)));
                    }
                }
                LookState ls;
                if (!looks.TryGetValue(it.Id, out ls)) { ls = new LookState(); looks[it.Id] = ls; if (has) { ls.X = tx; ls.Y = ty; } }
                float dt = (float)Math.Max(0, Math.Min(0.1, (now - ls.At).TotalSeconds));
                ls.At = now;
                float follow = 1f - (float)Math.Exp(-dt * 7.0), fade = 1f - (float)Math.Exp(-dt * 4.0);
                if (has) { ls.X += (tx - ls.X) * follow; ls.Y += (ty - ls.Y) * follow; }
                ls.W += ((has ? 1f : 0f) - ls.W) * fade;
                if (ls.W > 0.01f) { md.HasLook = true; md.LookX = ls.X; md.LookY = ls.Y; md.LookW = ls.W; }
            }
            return md;
        }

        readonly List<RectangleF> faceRects = new List<RectangleF>();
        bool painted, wasAway;
        public static int AwaySeconds = 120;
        // Вас нет за компьютером: давно не было ввода, а шторка свёрнута (раскрытую не замораживаем).
        public bool Away { get { return !Expanded && AwaySeconds > 0 && Native.InputIdleSeconds() >= AwaySeconds; } }
        // Пауза анимации (экран заблокирован, компьютер засыпает) — ставит NotchHost.
        public static volatile bool Paused;
        void PaintFace(Graphics g, RectangleF r, NotchItem it, bool look) { PaintFace(g, r, it, look, false); }
        void PaintFace(Graphics g, RectangleF r, NotchItem it, bool look, bool main) {
            RectangleF fr = r; fr.Offset(origin.X, origin.Y);
            faceRects.Add(fr);
            if (it == null) {
                if (main) { CatMood m0 = new CatMood(); ApplyReaction(null, m0, true); MotionMood(MotionFor(null), null, m0, r, 0); PaintPlayFace(g, r, null, m0, 0); }
                else Mascot.Paint(g, r, "none", T, 0, Animate, null);
                return;
            }
            int seed = (it.Id.GetHashCode() & 0x7fff) % 97;
            CatMood md = MoodFor(it, r, look);
            // Маскот зовёт: раз в CallEverySeconds сеанс, который ждёт вас, подпрыгивает и «стучит» по шторке
            // (дрожь в стороны), с выражением «Ага!». Только в свёрнутой и только если анимации включены.
            if (!Expanded && Attention && Animate && NeedsYou(it)) {
                double age = WaitAge(it), ph = (age + seed * 0.37) % CallEverySeconds;
                if (age > 3 && ph < 1.4) {
                    float k = (float)(ph / 1.4);
                    float shake = (float)Math.Sin(ph * Math.PI * 12) * theme.S(2.5f) * (1 - k);
                    float hop = (float)Math.Abs(Math.Sin(ph * Math.PI * 2.2)) * r.Height * 0.10f;
                    r.Offset(shake, -hop);
                    md.AhaAge = (float)(ph % 0.8);
                }
            }
            ApplyReaction(it, md, main);
            FaceMotion fm = MotionFor(it);
            MotionMood(fm, it, md, r, seed);
            if (main) { PaintPlayFace(g, r, it, md, seed); return; }
            DrawMascot(g, r, it, it.State, seed, md, fm);
        }

        public void SetRows(string page, NotchRow[] rows) { pages[page] = rows ?? new NotchRow[0]; Invalidate(); }

        public void SetPage(string page) {
            if (Page == page) return;
            SnapPage();   // снимок старой страницы — он растает поверх новой
            Page = page;
            EventHandler h = PageChanged; if (h != null) h(this, EventArgs.Empty);
            Invalidate();
        }

        // Анимация персонажей: 30 кадров/с, пока кто-то работает или ждёт решения; иначе — только моргание.
        internal void UpdateTimer() {
            bool busy = false;
            foreach (NotchItem it in items) if (it.State == "working" || it.State == "permission" || it.State == "stalled") busy = true;
            // Загрузка ПК обновляется и без сеансов, и при выключенных эффектах анимации — таймер нужен и тогда.
            bool need = Visible && ((Motion.Enabled && items.Count > 0) || (ShowStats && !Expanded));
            busyInterval = busy ? (Expanded ? 33 : 50) : 100;   // свёрнутая — 20 кадров/с хватает
            int interval = Expanded && (DateTime.UtcNow - lastMove).TotalSeconds < 3 ? 25 : busyInterval;
            if (anim.Interval != interval) anim.Interval = interval;
            if (need && !anim.Enabled) anim.Start();
            if (!need && anim.Enabled) anim.Stop();
        }

        protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); UpdateTimer(); }
        protected override void Dispose(bool disposing) {
            if (disposing) { anim.Dispose(); peekTimer.Dispose(); if (tipBox != null) tipBox.Dispose(); Fonts.Free(fTitle, fBody, fSmall, fBold, fHeader, fIcon, fIconSmall); }
            base.Dispose(disposing);
        }

        float T { get { return (float)(DateTime.UtcNow - born).TotalSeconds; } }
        bool Animate { get { return Motion.Enabled; } }
        bool SessionPage { get { return Page == "home"; } }

        NotchItem Main() {
            foreach (NotchItem it in items) if (it.State == "permission" || it.State == "error") return it;
            foreach (NotchItem it in items) if (NeedsYou(it)) return it;   // Claude что-то спросил
            return Selected;
        }

        // --- Внимание к шторке: «выдох» с текстом, свечение по краю, маскот зовёт, растёт, бегущая строка
        // с вопросом, сводка, когда вы вернулись. Всё — только в свёрнутой шторке; выключается настройкой. ---
        public bool Attention = true;
        public event EventHandler CollapsedResize;   // свёрнутой нужен другой размер (выдох, рост, место под вопрос)
        public static double GrowAfterSeconds = 120, GlowFullSeconds = 300, CallEverySeconds = 24;   // тесты уменьшают
        readonly Timer peekTimer = new Timer();
        string peekText = "";
        NotchItem peekItem;
        int peekWidth;
        readonly Dictionary<string, long> prevWait = new Dictionary<string, long>();
        readonly Dictionary<string, string> prevState = new Dictionary<string, string>();
        readonly HashSet<string> awayChanged = new HashSet<string>();
        bool attentionPrimed, absent, grownShown, askShown;

        static bool NeedsYou(NotchItem it) { return it != null && it.WaitSince > 0; }
        static double WaitAge(NotchItem it) { return it == null || it.WaitSince <= 0 ? 0 : Math.Max(0, (DateTime.UtcNow.Ticks - it.WaitSince) / 1e7); }

        public bool PeekActive { get { return peekText.Length > 0; } }
        public string PeekText { get { return peekText; } }
        public int PeekWidth { get { return peekWidth; } }
        // Главный сеанс ждёт дольше GrowAfterSeconds — его маскот крупнее, шторка выше.
        public bool Grown { get { NotchItem m = Main(); return Attention && NeedsYou(m) && WaitAge(m) >= GrowAfterSeconds; } }
        float GrowK(NotchItem m) { return Attention && NeedsYou(m) ? (float)Math.Max(0, Math.Min(1, (WaitAge(m) - GrowAfterSeconds) / GrowAfterSeconds)) : 0f; }
        // Есть вопрос для бегущей строки — посередине свёрнутой нужно место.
        public bool HasAsk { get { if (!Attention) return false; foreach (NotchItem it in items) if (NeedsYou(it) && !string.IsNullOrEmpty(it.Ask)) return true; return false; } }
        NotchItem GlowItem() {
            NotchItem best = null; int rank = 0;
            foreach (NotchItem it in items) {
                if (!NeedsYou(it)) continue;
                int r = it.State == "error" ? 3 : it.State == "permission" ? 2 : 1;
                if (r > rank) { rank = r; best = it; }
            }
            return best;
        }

        void RaiseCollapsedResize() { EventHandler h = CollapsedResize; if (h != null) h(this, EventArgs.Empty); }

        static string Lower(string s) { return string.IsNullOrEmpty(s) ? s : char.ToLower(s[0]) + s.Substring(1); }
        static string Plural(int n, string one, string few, string many) {
            int m10 = n % 10, m100 = n % 100;
            if (m10 == 1 && m100 != 11) return one;
            if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
            return many;
        }

        string PeekLine(NotchItem it) {
            string what = it.State == "permission" ? "нужно разрешение" : it.State == "error" ? "ошибка" : "ждёт ответа";
            string who = string.IsNullOrEmpty(it.Device) ? it.Title : it.Meta + " · " + it.Title;
            return who + " — " + what;
        }

        // Новые «ждёт вас» → «выдох»; пока вас нет — запомнить для сводки. Первый вызов только запоминает.
        void TrackAttention() {
            NotchItem fresh = null;
            HashSet<string> alive = new HashSet<string>();
            foreach (NotchItem it in items) {
                alive.Add(it.Id);
                long pw; bool known = prevWait.TryGetValue(it.Id, out pw);
                string ps; prevState.TryGetValue(it.Id, out ps);
                bool isNew = NeedsYou(it) && (!known || pw != it.WaitSince);
                bool done = ps == "working" && it.State == "waiting";
                if (attentionPrimed && (isNew || done) && absent) awayChanged.Add(it.Id);
                if (attentionPrimed && isNew && !absent && fresh == null) fresh = it;
                prevWait[it.Id] = it.WaitSince; prevState[it.Id] = it.State;
            }
            foreach (string k in new List<string>(prevWait.Keys)) if (!alive.Contains(k)) { prevWait.Remove(k); prevState.Remove(k); }
            attentionPrimed = true;
            if (fresh != null && Attention && !Expanded) StartPeek(PeekLine(fresh), fresh, 2200);
            bool ask = HasAsk;
            if (ask != askShown) { askShown = ask; RaiseCollapsedResize(); }
        }

        public void StartPeek(string text, NotchItem item, int ms) {
            if (string.IsNullOrEmpty(text)) return;
            peekText = text; peekItem = item;
            if (item != null && !Expanded) SelectedId = item.Id;   // щелчок по шторке — сразу этот сеанс
            int fw = (int)Math.Round(Math.Min(theme.S(38) * 0.8f, theme.S(30)) * 1.3f);
            peekWidth = theme.S(16) + fw + theme.S(14) + TextRenderer.MeasureText(text, fBold).Width + theme.S(22);
            if (peekTimer.Enabled) peekTimer.Stop();
            peekTimer.Interval = Math.Max(300, ms);
            peekTimer.Start();
            RaiseCollapsedResize();
            Invalidate();
        }

        void EndPeek() {
            peekTimer.Stop();
            if (!PeekActive) return;
            peekText = ""; peekItem = null;
            RaiseCollapsedResize();
            Invalidate();
        }

        // Вы вернулись — что произошло, пока вас не было: «2 готово, 1 ждёт разрешения».
        void ShowAwaySummary() {
            int done = 0, perm = 0, err = 0, ask = 0;
            NotchItem first = null;
            foreach (NotchItem it in items) {
                if (!awayChanged.Contains(it.Id)) continue;
                if (it.State == "permission") perm++;
                else if (it.State == "error") err++;
                else if (it.State == "waiting" && NeedsYou(it)) ask++;
                else if (it.State == "waiting") done++;
                else continue;
                if (first == null && NeedsYou(it)) first = it;
            }
            awayChanged.Clear();
            List<string> parts = new List<string>();
            if (done > 0) parts.Add(done + " готово");
            if (ask > 0) parts.Add(ask + " " + Plural(ask, "ждёт ответа", "ждут ответа", "ждут ответа"));
            if (perm > 0) parts.Add(perm + " " + Plural(perm, "ждёт разрешения", "ждут разрешения", "ждут разрешения"));
            if (err > 0) parts.Add(err + " " + Plural(err, "ошибка", "ошибки", "ошибок"));
            if (parts.Count == 0 || !Attention || Expanded) return;
            StartPeek("Пока вас не было: " + string.Join(", ", parts.ToArray()), first, 6000);
        }

        // Для тестов и трея: отметить уход / возвращение (обычно это делает таймер по простою и блокировке).
        public void SetAbsent(bool value) {
            if (value == absent) return;
            absent = value;
            if (value) awayChanged.Clear(); else ShowAwaySummary();
        }

        void Hit(Rectangle r, string id) { r.Offset(origin); hits.Add(new KeyValuePair<Rectangle, string>(r, id)); }
        // Кнопки-селекты (строки choice): где нарисованы — список вариантов открывается ровно под кнопкой.
        readonly Dictionary<string, Rectangle> selectAnchors = new Dictionary<string, Rectangle>();
        // Обрезанные многоточием подписи строк настроек: где и полный текст — подсказка при наведении.
        readonly List<KeyValuePair<Rectangle, string>> tips = new List<KeyValuePair<Rectangle, string>>();
        ToolTip tipBox;
        string tipShown;
        void Tip(Rectangle r, string text, Font f) {
            if (string.IsNullOrEmpty(text) || TextRenderer.MeasureText(text, f).Width <= r.Width) return;
            r.Offset(origin);
            tips.Add(new KeyValuePair<Rectangle, string>(r, text));
        }
        void UpdateTip(Point p) {
            string text = null;
            foreach (KeyValuePair<Rectangle, string> t in tips) if (t.Key.Contains(p)) { text = t.Value; break; }
            if (text == tipShown) return;
            tipShown = text;
            if (tipBox == null) { tipBox = new ToolTip(); tipBox.InitialDelay = 350; tipBox.ReshowDelay = 100; }
            tipBox.SetToolTip(this, text ?? "");
        }

        // --- Раскрытие без рывков: окно на время анимации не меняет размер и форму (это дорого и дёргается),
        // а внутри прозрачного окна плавно растёт нарисованная фигура шторки. Содержимое не перекладывается:
        // раскрытая раскладка проявляется из чёрного, свёрнутая — гаснет (и наоборот при сворачивании).
        public static readonly Color Key = Color.FromArgb(255, 1, 0, 1);   // прозрачный цвет окна (щелчки проходят насквозь)
        public RectangleF Shape;          // фигура шторки в координатах окна; пусто — всё окно
        public float Corner = -1;         // радиус нижних углов; < 0 — по размеру
        public bool Morphing;             // идёт переход свёрнута ↔ раскрыта
        // Шторка меняет размер (пружина ещё не дошла до цели): полосу прокрутки не показываем — иначе она мелькает.
        bool Resizing { get { return Shape.Width > 0 && Expanded && LayoutExpanded.Height > 0 && Math.Abs(Shape.Height - LayoutExpanded.Height) > 1.5f; } }
        public float Progress;            // 0 — свёрнута, 1 — раскрыта (по высоте фигуры)
        public Size LayoutExpanded, LayoutCollapsed;
        Point origin;                     // где начинается раскладка содержимого
        Size lay;                         // размер раскладки содержимого

        public RectangleF ShapeRect { get { return Shape.Width > 0 && Shape.Height > 0 ? Shape : new RectangleF(0, 0, ClientSize.Width, ClientSize.Height); } }

        public static GraphicsPath ShapePath(RectangleF s, float r) {
            GraphicsPath p = new GraphicsPath();
            r = Math.Max(0.5f, Math.Min(r, Math.Min(s.Width, s.Height) / 2f));
            p.AddLine(s.Left, s.Top, s.Right, s.Top);
            p.AddLine(s.Right, s.Top, s.Right, s.Bottom - r);
            p.AddArc(s.Right - 2 * r, s.Bottom - 2 * r, 2 * r, 2 * r, 0, 90);
            p.AddLine(s.Right - r, s.Bottom, s.Left + r, s.Bottom);
            p.AddArc(s.Left, s.Bottom - 2 * r, 2 * r, 2 * r, 90, 90);
            p.CloseFigure();
            return p;
        }

        public double PaintMaxMs, PaintSumMs; public int PaintCount;   // замер отрисовки в переходе
        protected override void OnPaint(PaintEventArgs e) {
            System.Diagnostics.Stopwatch pw = System.Diagnostics.Stopwatch.StartNew();
            try { PaintNotch(e); }
            finally {
                if (Morphing) { double ms = pw.Elapsed.TotalMilliseconds; PaintSumMs += ms; PaintCount++; if (ms > PaintMaxMs) PaintMaxMs = ms; }
            }
        }

        // Шторка в layered-окне: рисуется не сама (WM_PAINT), а в буфер окна (PaintInto); вне фигуры — прозрачно.
        public bool External;
        public Color Outside = Key;
        public void PaintInto(Graphics g, Rectangle clip) { PaintNotch(new PaintEventArgs(g, clip)); }
        public float CornerRadius {
            get { RectangleF s = ShapeRect; return Corner >= 0 ? Corner : (Expanded ? Math.Min(s.Height * 0.12f + 6, 28) : s.Height * 0.45f); }
        }
        protected override void WndProc(ref Message m) {
            // В layered-окне дочерние окна на экран не выводятся: свой WM_PAINT только подтверждаем (без работы).
            if (External && m.Msg == 0x000F) { Native.ValidateAll(Handle); return; }
            base.WndProc(ref m);
        }
        protected override void OnPaintBackground(PaintEventArgs e) { if (!External) base.OnPaintBackground(e); }

        void PaintNotch(PaintEventArgs e) {
            Graphics g = e.Graphics;
            RectangleF s = ShapeRect;
            float r = CornerRadius;
            hits.Clear();
            tips.Clear();
            faceRects.Clear();
            // Что рисуем: в переходе до 40 % высоты — свёрнутую раскладку, дальше — раскрытую.
            bool showExpanded = Morphing ? Progress > 0.4f : Expanded;
            // Пока фигура в движении — раскладка итогового размера (содержимое не «плывёт»), в покое — по окну.
            Size want = showExpanded ? LayoutExpanded : LayoutCollapsed;
            // Раскладка. Раскрытие и сворачивание — по итоговому размеру (содержимое проявляется уже на своих местах).
            // Остальные изменения размера (другая страница, кнопки решения у маскота, «выдох») — раскладка
            // перестраивается вслед за фигурой: кнопки у края плавно едут вместе с ним и не уходят за шторку.
            // Ширина раскрытой шторки у всех страниц одна, так что там меняется только высота: переносы текста и
            // многоточия не пересчитываются — ничего не мерцает. Края округляются одинаково (левый и правый
            // отдельно) — иначе содержимое дрожало бы на пиксель туда-обратно, пока фигура движется.
            if (Shape.Width > 0 && want.Width > 0 && Morphing) {
                lay = want;
                origin = new Point((int)Math.Round(s.X + (s.Width - lay.Width) / 2f), (int)Math.Round(s.Y));
            } else {
                int l = (int)Math.Round(s.X), rt = (int)Math.Round(s.Right), tp = (int)Math.Round(s.Y), bt = (int)Math.Round(s.Bottom);
                lay = new Size(Math.Max(1, rt - l), Math.Max(1, bt - tp));
                origin = new Point(l, tp);
            }
            using (GraphicsPath path = ShapePath(s, r)) {
                // Углы шторки — рисованные (у окна нет Region); вне фигуры — прозрачное.
                g.Clear(Outside);
                g.SmoothingMode = SmoothingMode.None;   // край без сглаживания — иначе цветная кайма у прозрачного цвета
                using (SolidBrush b = new SolidBrush(Bg)) g.FillPath(b, path);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                GraphicsState st = g.Save();
                g.SetClip(path, CombineMode.Intersect);
                if (Morphing && showExpanded && lastMainWin.Width > 0 && Animate) {
                    // Раскрытие «из маскота»: содержимое проявляется кругом от главного маскота (и сворачивается в него).
                    PointF c0 = new PointF(lastMainWin.X + lastMainWin.Width / 2f, lastMainWin.Y + lastMainWin.Height / 2f);
                    float far = 0;
                    foreach (PointF corner in new PointF[] { new PointF(s.Left, s.Top), new PointF(s.Right, s.Top), new PointF(s.Left, s.Bottom), new PointF(s.Right, s.Bottom) })
                        far = Math.Max(far, (float)Math.Sqrt((corner.X - c0.X) * (corner.X - c0.X) + (corner.Y - c0.Y) * (corner.Y - c0.Y)));
                    float k = MascotMotion.Smooth(Math.Max(0f, Math.Min(1f, (Progress - 0.3f) / 0.6f)));
                    float rad = Math.Max(1f, far * k);
                    using (GraphicsPath circle = new GraphicsPath()) {
                        circle.AddEllipse(c0.X - rad, c0.Y - rad, rad * 2, rad * 2);
                        g.SetClip(circle, CombineMode.Intersect);
                    }
                }
                g.TranslateTransform(origin.X, origin.Y);
                if (showExpanded) { PaintExpanded(g); PaintPageShot(g); } else PaintCollapsed(g);
                g.Restore(st);
                // Проявление: поверх содержимого — чёрный с прозрачностью (дёшево, без отрисовки в отдельный кадр).
                if (Morphing) {
                    float veil = showExpanded ? 1f - Math.Min(1f, (Progress - 0.4f) / 0.45f) : Math.Min(1f, Progress / 0.4f);
                    int a = (int)Math.Round(255 * Math.Max(0f, Math.Min(1f, veil)));
                    if (a > 0) {
                        g.SmoothingMode = SmoothingMode.None;
                        using (SolidBrush b = new SolidBrush(Color.FromArgb(a, 0, 0, 0))) g.FillPath(b, path);
                    }
                }
            }
            painted = true;
        }

        void PaintCollapsed(Graphics g) {
            Hit(new Rectangle(0, 0, lay.Width, lay.Height), "expand");
            int h = lay.Height, pad = theme.S(16);
            // «Выдох»: на пару секунд — маскот и строка «MacBook · проект — нужно разрешение» (или сводка), без остального.
            if (PeekActive) {
                NotchItem pm = peekItem ?? Main();
                float ph = Math.Min(h * 0.8f, theme.S(30)), pw = ph * 1.3f;
                PaintFace(g, new RectangleF(pad, (h - ph) / 2, pw, ph), pm, false);
                int tx = pad + (int)pw + theme.S(12);
                TextRenderer.DrawText(g, peekText, fBold, new Rectangle(tx, 0, Math.Max(0, lay.Width - tx - theme.S(14)), h), Fg,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
                PaintGlow(g, h);
                return;
            }
            NotchItem main = Main();
            // Маскот растёт, пока сеанс ждёт вас дольше GrowAfterSeconds: «выходит вперёд» (шторка при этом выше).
            float grow = GrowK(main);
            float fh = Math.Min(h * 0.86f, theme.S(30) * (1f + 0.35f * grow)), fw = fh * 1.3f;
            NoteCollapsedMain(new RectangleF(pad, (h - fh) / 2, fw, fh), main);
            PaintFace(g, new RectangleF(pad, (h - fh) / 2, fw, fh), main, false, true);
            float sh = Math.Min(h * 0.6f, theme.S(23)), sw = sh * 1.3f, gap = theme.S(2);
            // Посередине — загрузка ПК или бегущая строка с вопросом; маленькие персонажи справа на них не заходят (лишние — «+N»).
            float statsRight = 0;
            statsRect = Rectangle.Empty;
            NotchItem asker = TickerItem();
            Rectangle sr = PaintQuick(g, h, pad + (int)fw + theme.S(12));   // кнопки решения у маскота — вместо всего посередине
            if (sr.Width == 0) {
                if (asker != null) sr = PaintTicker(g, h, pad + (int)fw + theme.S(12), asker);
                else if (ShowStats) sr = PaintStats(g, h);
            }
            if (sr.Width > 0) {
                statsRight = sr.Right + theme.S(10);
                statsRect = new Rectangle(sr.X + origin.X, sr.Y + origin.Y, sr.Width, sr.Height);
            }
            bool middle = sr.Width > 0;
            float x = lay.Width - pad;
            int shown = 0, rest = 0;
            for (int i = items.Count - 1; i >= 0; i--) {
                NotchItem it = items[i];
                if (main != null && it.Id == main.Id) continue;
                if (shown >= 5 || (middle && x - sw < statsRight + theme.S(22))) { rest++; continue; }
                x -= sw;
                PaintFace(g, new RectangleF(x, (h - sh) / 2, sw, sh), it, false);
                x -= gap; shown++;
            }
            PaintLeaving(g);   // закрытые сеансы машут и уходят вниз
            if (rest > 0) {
                string more = "+" + rest;
                int mw = TextRenderer.MeasureText(more, fSmall).Width;
                TextRenderer.DrawText(g, more, fSmall, new Rectangle((int)x - mw, 0, mw, h), theme.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            }
            PaintGlow(g, h);
        }

        // Бегущая строка: вместо загрузки ПК на 5 с из каждых 15 — вопрос Claude («Закоммитить и отправить?»).
        // Без загрузки ПК — вопрос виден всё время.
        NotchItem TickerItem() {
            if (!Attention) return null;
            NotchItem best = null;
            foreach (NotchItem it in items) if (NeedsYou(it) && !string.IsNullOrEmpty(it.Ask)) { best = it; break; }
            if (best == null) return null;
            if (ShowStats && Animate && (T % 15f) >= 5f) return null;
            return best;
        }

        Rectangle PaintTicker(Graphics g, int h, int left, NotchItem it) {
            int right = lay.Width - theme.S(16) - theme.S(70);
            int avail = Math.Max(theme.S(60), right - left);
            int tw = Math.Min(avail, TextRenderer.MeasureText(it.Ask, fBold).Width);
            int x = Math.Max(left, (lay.Width - tw) / 2);
            if (x + tw > right) x = Math.Max(left, right - tw);
            // Плавно проявляется и гаснет в начале и в конце показа.
            float ph = T % 15f, fade = 1f;
            if (ShowStats && Animate) fade = Math.Min(1f, Math.Min(ph / 0.35f, (5f - ph) / 0.35f));
            Color c = Draw.Mix(Pal(0x1A1A1C), Fg, Math.Max(0, Math.Min(1, fade)));
            Rectangle r = new Rectangle(x, 0, tw, h);
            TextRenderer.DrawText(g, it.Ask, fBold, r, c, TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            return r;
        }

        // Свечение по краю свёрнутой шторки цвета статуса того, кто ждёт: янтарное — разрешение, красное — ошибка,
        // голубое — вопрос. Пульсирует; первые минуты едва заметно, к GlowFullSeconds — в полную силу.
        void PaintGlow(Graphics g, int h) {
            if (!Attention) return;
            NotchItem gi = GlowItem();
            if (gi == null) return;
            float amp = 0.3f + 0.7f * (float)Math.Max(0, Math.Min(1, WaitAge(gi) / GlowFullSeconds));
            float pulse = Animate ? 0.5f + 0.5f * (float)Math.Sin(T * Math.PI * 2 / 1.8) : 0.6f;
            Color c = gi.State == "error" ? Pal(0xFF453A) : gi.State == "permission" ? Pal(0xFF9F0A) : Pal(0x64D2FF);
            int a = (int)(255 * amp * (0.25f + 0.75f * pulse));
            float R = Math.Max(4, CornerRadius);
            SmoothingMode sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            // Верх прямоугольника — над шторкой (у края экрана): видны только бока и низ со скруглениями.
            using (GraphicsPath p = Draw.Round(new RectangleF(1.5f, -R - 2, lay.Width - 3, h + R + 0.5f), R)) {
                using (Pen soft = new Pen(Color.FromArgb(Math.Max(0, Math.Min(255, a / 4)), c), theme.S(6))) g.DrawPath(soft, p);
                using (Pen line = new Pen(Color.FromArgb(Math.Max(0, Math.Min(255, a)), c), Math.Max(1.5f, theme.S(2)))) g.DrawPath(line, p);
            }
            g.SmoothingMode = sm;
        }

        // Загрузка ПК по центру свёрнутой шторки: три колонки «значение / подпись» — ЦП, ГП, ОЗУ. Высокая загрузка —
        // янтарным (от 70 %) или красным (от 90 %); нет данных — «—». В подписи ЦП и ГП — температура, если известна
        // (горячо — подпись янтарная или красная). Возвращает занятый прямоугольник.
        Rectangle PaintStats(Graphics g, int h) {
            float cpu = SysStats.Cpu, gpu = SysStats.Gpu, mem = SysStats.MemUsedGb, memTotal = SysStats.MemTotalGb;
            string[] vals = {
                cpu < 0 ? "—" : ((int)Math.Round(cpu)) + " %",
                gpu < 0 ? "—" : ((int)Math.Round(gpu)) + " %",
                mem < 0 ? "—" : mem.ToString(mem < 100 ? "0.0" : "0", System.Globalization.CultureInfo.GetCultureInfo("ru-RU")) + " ГБ"
            };
            // Температура — в подписи: «ЦП 52°», «ГП 64°» (если её удаётся узнать).
            float cpuT = SysStats.CpuTemp, gpuT = SysStats.GpuTemp;
            string[] labels = { cpuT > 0 ? "ЦП " + (int)Math.Round(cpuT) + "°" : "ЦП", gpuT > 0 ? "ГП " + (int)Math.Round(gpuT) + "°" : "ГП", "ОЗУ" };
            float[] temp = { cpuT, gpuT, -1 };
            float memPct = mem >= 0 && memTotal > 0 ? mem / memTotal * 100f : -1;
            float[] load = { cpu, gpu, memPct };
            int colGap = theme.S(14);
            int[] w = new int[3];
            int total = 0;
            for (int i = 0; i < 3; i++) {
                w[i] = Math.Max(TextRenderer.MeasureText(vals[i], fBold).Width, TextRenderer.MeasureText(labels[i], fSmall).Width);
                total += w[i] + (i > 0 ? colGap : 0);
            }
            int x = (lay.Width - total) / 2;
            int vh = theme.S(16), lh = theme.S(13);
            int y = (h - vh - lh) / 2;
            int x0 = x;
            for (int i = 0; i < 3; i++) {
                Color vc = load[i] >= 90 ? Pal(0xFF6961) : load[i] >= 70 ? Pal(0xFFB340) : Pal(0xE5E5EA);
                if (load[i] < 0) vc = theme.Muted;
                TextRenderer.DrawText(g, vals[i], fBold, new Rectangle(x, y, w[i], vh), vc, TextFormatFlags.HorizontalCenter | TextFormatFlags.Bottom | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
                // Горячо — подпись янтарная (от 80°) или красная (от 90°).
                Color lc = temp[i] >= 90 ? Pal(0xFF6961) : temp[i] >= 80 ? Pal(0xFFB340) : theme.Muted;
                TextRenderer.DrawText(g, labels[i], fSmall, new Rectangle(x, y + vh, w[i], lh), lc, TextFormatFlags.HorizontalCenter | TextFormatFlags.Top | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
                x += w[i] + colGap;
            }
            return new Rectangle(x0, y, total, vh + lh);
        }

        // Полоска лимита: «5 часов · сброс в 14:05» слева, «осталось 62 %» справа, под ними — полоса остатка.
        void PaintLimit(Graphics g, Rectangle r, string name, float left, string detail) {
            bool hot = hover == "page:stats-limits";
            bool none = left < 0;
            float v = none ? 0 : Anim("lim:" + name, Math.Max(0, Math.Min(100, left)), 6f);
            Color c = none || LimitsStale ? Pal(0x636366) : v <= 10 ? Pal(0xFF453A) : v <= 25 ? Pal(0xFFB340) : Pal(0x30D158);
            int lineH = theme.S(16), barH = theme.S(6);
            int ty = r.Y + theme.S(4), by = ty + lineH + theme.S(4);
            string pct = none ? "нет данных" : "осталось " + ((int)Math.Round(v)) + " %";
            int pw = TextRenderer.MeasureText(pct, fBold).Width;
            TextRenderer.DrawText(g, pct, fBold, new Rectangle(r.Right - pw, ty, pw, lineH), none ? theme.Muted : (hot ? Fg : Pal(0xE5E5EA)),
                TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            string label = string.IsNullOrEmpty(detail) ? name : name + " · " + detail;
            TextRenderer.DrawText(g, label, fSmall, new Rectangle(r.X, ty, Math.Max(0, r.Width - pw - theme.S(6)), lineH), hot ? Pal(0xC7C7CC) : theme.Muted,
                TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            RectangleF bar = new RectangleF(r.X, by, r.Width, barH);
            Draw.Fill(g, bar, barH / 2f, Pal(0x2C2C2E));
            if (v > 0) Draw.Fill(g, new RectangleF(bar.X, bar.Y, Math.Max(barH, bar.Width * v / 100f), barH), barH / 2f, c);
            Hit(r, "page:stats-limits");
        }

        void IconButtonAt(Graphics g, Rectangle r, string glyph, string id, bool active, string tip) {
            float h = Hot(id), p = Press(id), a = Anim("tab:" + id, active ? 1f : 0f, 18f);
            float inset = p * theme.S(1.5f);
            RectangleF rr = new RectangleF(r.X + inset, r.Y + inset, r.Width - inset * 2, r.Height - inset * 2);
            Color bg = Draw.Mix(Draw.Mix(Bg, Pal(0x1C1C1E), h), Pal(0x2C2C2E), a);
            if (h > 0.01f || a > 0.01f) Draw.Fill(g, rr, rr.Height / 2f, bg);
            TextRenderer.DrawText(g, glyph, fIcon, r, Draw.Mix(Pal(0xB0B0B5), Fg, Math.Max(a, h * 0.6f)),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            Hit(r, id);
        }

        void PaintExpanded(Graphics g) {
            int W = lay.Width, H = lay.Height, pad = theme.S(14), bs = theme.S(34), gap = theme.S(4);
            int y0 = theme.S(10), x = pad;
            // Страницы — слева; справа — звук и «закрыть»; между ними — полоски оставшихся лимитов.
            string[,] tabs = { { "home", "\uE80F" }, { "history", "\uE81C" }, { "stats", "\uE9D2" }, { "devices", "\uE772" }, { "settings", "\uE713" } };
            for (int i = 0; i < tabs.GetLength(0); i++) { IconButtonAt(g, new Rectangle(x, y0, bs, bs), tabs[i, 1], "page:" + tabs[i, 0], Page == tabs[i, 0] || (Page == "answer" && tabs[i, 0] == "home"), null); x += bs + gap; }
            int rx = W - pad;
            rx -= bs; IconButtonAt(g, new Rectangle(rx, y0, bs, bs), "\uE711", "close", false, null);
            rx -= bs + gap; IconButtonAt(g, new Rectangle(rx, y0, bs, bs), SoundOff ? "\uE74F" : "\uE767", "sound", false, null);
            // Есть обновление — значок «скачать» с точкой: страница «Что нового» и кнопка «Обновить сейчас».
            if (UpdateAvailable) {
                rx -= bs + gap;
                Rectangle ur = new Rectangle(rx, y0, bs, bs);
                IconButtonAt(g, ur, "\uE896", "page:update", Page == "update", null);
                float dd = theme.S(8);
                using (SolidBrush dot = new SolidBrush(theme.Accent)) g.FillEllipse(dot, ur.Right - dd - theme.S(5), ur.Y + theme.S(5), dd, dd);
            }
            // Две полоски остатка лимитов; щелчок — статистика.
            int lx = x + theme.S(14), lr = rx - theme.S(16), lgap = theme.S(18);
            if (lr - lx > theme.S(160)) {
                int bw = (lr - lx - lgap) / 2;
                PaintLimit(g, new Rectangle(lx, y0, bw, bs), "5 ч", Left5, Detail5);
                PaintLimit(g, new Rectangle(lx + bw + lgap, y0, bw, bs), "Неделя", LeftWeek, DetailWeek);
            }
            int top = y0 + bs + theme.S(12);
            if (SessionPage) {
                int ch = H - top - pad;
                int lw = (int)((W - pad * 3) * 0.54f);
                Rectangle left = new Rectangle(pad, top, lw, ch), right = new Rectangle(pad * 2 + lw, top, W - pad * 3 - lw, ch);
                Draw.Fill(g, left, theme.S(18), Pal(0x161618));
                Draw.Fill(g, right, theme.S(18), Pal(0x161618));
                PaintMain(g, left);
                PaintOthers(g, right);
                PaintDraggedChip(g);
            } else if (Page == "answer") {
                PaintAnswer(g, new Rectangle(pad, top, W - pad * 2, H - top - pad));
            } else if (Page == "settings") {
                PaintSettings(g, new Rectangle(pad, top, W - pad * 2, H - top - pad));
            } else {
                PaintRows(g, new Rectangle(pad, top, W - pad * 2, H - top - pad));
            }
            PaintNotice(g, W, H);
        }

        // --- «Настройки»: слева — разделы (заголовки строк), справа — строки выбранного раздела в две колонки ---
        public int SettingsSection;
        sealed class Section { public string Title; public readonly List<NotchRow> Rows = new List<NotchRow>(); }

        List<Section> Sections() {
            List<Section> list = new List<Section>();
            Section cur = null;
            foreach (NotchRow row in Rows("settings")) {
                if (row.Kind == "header") { cur = new Section { Title = row.Title }; list.Add(cur); continue; }
                if (cur == null) { cur = new Section { Title = "Общие" }; list.Add(cur); }
                cur.Rows.Add(row);
            }
            return list;
        }

        static string SectionIcon(string title) {
            switch (title) {
                case "Уведомления": return "\uEA8F";
                case "Ответы": return "\uE8BD";
                case "Сеансы": return "\uE9D9";
                case "Шторка": return "\uE7F4";
                case "Маскоты": return "\uE76E";
                case "Система": return "\uE713";
                default: return "\uE712";
            }
        }

        int SidebarWidth { get { return theme.S(176); } }
        static bool FullWidth(NotchRow r) { return r.Kind == "note" || r.Kind == "device" || r.Kind == "chart"; }

        // Высота раздела в две колонки (полноширинные строки — на всю ширину).
        int GridHeight(List<NotchRow> rows, int width) {
            int colW = (width - theme.S(8)) / 2, h = 0, i = 0;
            while (i < rows.Count) {
                if (FullWidth(rows[i])) { h += RowHeight(rows[i], width) + theme.S(8); i++; continue; }
                int rh = RowHeight(rows[i], colW);
                if (i + 1 < rows.Count && !FullWidth(rows[i + 1])) { rh = Math.Max(rh, RowHeight(rows[i + 1], colW)); i += 2; } else i++;
                h += rh + theme.S(8);
            }
            return Math.Max(0, h - theme.S(8));
        }

        // Высота страницы настроек — по самому большому разделу (и по боковому меню): при переключении разделов
        // шторка не прыгает.
        int SettingsHeight(int width) {
            List<Section> secs = Sections();
            int gw = width - SidebarWidth - theme.S(14), h = secs.Count * theme.S(40);
            foreach (Section s in secs) h = Math.Max(h, theme.S(30) + GridHeight(s.Rows, gw));
            return h;
        }

        void PaintSettings(Graphics g, Rectangle area) {
            List<Section> secs = Sections();
            if (secs.Count == 0) { TextRenderer.DrawText(g, "Загружаю…", fBody, area, theme.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix); return; }
            if (SettingsSection >= secs.Count || SettingsSection < 0) SettingsSection = 0;
            // Боковое меню.
            Rectangle side = new Rectangle(area.X, area.Y, SidebarWidth, area.Height);
            Draw.Fill(g, side, theme.S(16), Pal(0x111113));
            int iy = side.Y + theme.S(6), ih = theme.S(36);
            float selY = Anim("sidebar", side.Y + theme.S(6) + SettingsSection * (ih + theme.S(4)), 18f);
            Draw.Fill(g, new RectangleF(side.X + theme.S(6), selY, side.Width - theme.S(12), ih), theme.S(10), Pal(0x2C2C2E));
            for (int i = 0; i < secs.Count; i++) {
                Rectangle it = new Rectangle(side.X + theme.S(6), iy, side.Width - theme.S(12), ih);
                string id = "section:" + i;
                bool sel = i == SettingsSection;
                float hh = Hot(id);
                if (!sel && hh > 0.01f) Draw.Fill(g, it, theme.S(10), Color.FromArgb((int)(255 * hh), Pal(0x1C1C1E)));
                TextRenderer.DrawText(g, SectionIcon(secs[i].Title), fIconSmall, new Rectangle(it.X + theme.S(8), it.Y, theme.S(22), ih), sel ? Pal(0x0A84FF) : Pal(0x98989D),
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
                TextRenderer.DrawText(g, secs[i].Title, sel ? fBold : fBody, new Rectangle(it.X + theme.S(36), it.Y, it.Width - theme.S(40), ih), sel ? Fg : Pal(0xC7C7CC),
                    TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
                Hit(it, id);
                iy += ih + theme.S(4);
            }
            // Раздел: заголовок и строки в две колонки.
            Section s = secs[SettingsSection];
            Rectangle body = new Rectangle(side.Right + theme.S(14), area.Y, area.Right - side.Right - theme.S(14), area.Height);
            TextRenderer.DrawText(g, s.Title, fTitle, new Rectangle(body.X + theme.S(4), body.Y, body.Width, theme.S(24)), Fg, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter);
            Rectangle grid = new Rectangle(body.X, body.Y + theme.S(30), body.Width, body.Height - theme.S(30));
            viewHeight = grid.Height;
            contentHeight = GridHeight(s.Rows, grid.Width);
            int scroll = Scroll;
            Region old = g.Clip;
            g.SetClip(grid, CombineMode.Intersect);
            int colW = (grid.Width - theme.S(8)) / 2, y = grid.Y - scroll, idx = 0;
            while (idx < s.Rows.Count) {
                NotchRow a = s.Rows[idx];
                if (FullWidth(a)) {
                    int fh = RowHeight(a, grid.Width);
                    PaintRow(g, a, new Rectangle(grid.X, y, grid.Width, fh), grid);
                    y += fh + theme.S(8); idx++; continue;
                }
                NotchRow b = idx + 1 < s.Rows.Count && !FullWidth(s.Rows[idx + 1]) ? s.Rows[idx + 1] : null;
                int rh = RowHeight(a, colW);
                if (b != null) rh = Math.Max(rh, RowHeight(b, colW));
                PaintRow(g, a, new Rectangle(grid.X, y, colW, rh), grid);
                if (b != null) PaintRow(g, b, new Rectangle(grid.X + colW + theme.S(8), y, colW, rh), grid);
                y += rh + theme.S(8); idx += b != null ? 2 : 1;
            }
            g.Clip = old; old.Dispose();   // g.Clip отдаёт копию — без Dispose регион GDI+ копится на каждом кадре
            if (contentHeight > grid.Height + theme.S(3) && !Resizing) {   // запас: округление в 1–2 px не включает полосу
                int th = Math.Max(theme.S(24), grid.Height * grid.Height / contentHeight);
                int ty = grid.Y + (int)((grid.Height - th) * (scroll / (float)Math.Max(1, contentHeight - grid.Height)));
                Draw.Fill(g, new RectangleF(grid.Right + theme.S(4), ty, theme.S(3), th), theme.S(1.5f), Color.FromArgb(120, 142, 142, 147));
            }
        }

        // --- Полный ответ: щелчок по карточке сеанса на главной ---

        int AnswerTextWidth(int width) { return width - theme.S(32); }

        string AnswerText(NotchItem it) {
            string full = Answer(it.Id);
            string text = !string.IsNullOrEmpty(full) ? full : it.Preview;
            if (!string.IsNullOrEmpty(it.RequestTitle)) text = it.RequestTitle + (string.IsNullOrEmpty(text) ? "" : "\n\n" + text);
            return string.IsNullOrEmpty(text) ? "Ответа пока нет." : text;
        }

        // Высота содержимого страницы ответа: заголовок, текст целиком, кнопки.
        public int AnswerContentHeight(int width) {
            NotchItem it = Selected;
            if (it == null) return theme.S(120);
            int text = TextRenderer.MeasureText(AnswerText(it), fBody, new Size(AnswerTextWidth(width), int.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl).Height;
            text += PaintFeed(null, it, 0, 0, AnswerTextWidth(width));
            return theme.S(56) + text + theme.S(16) + theme.S(52);
        }

        void PaintAnswer(Graphics g, Rectangle area) {
            NotchItem it = Selected;
            Draw.Fill(g, area, theme.S(18), Pal(0x161618));
            if (it == null) { TextRenderer.DrawText(g, "Сеансов нет", fBody, area, theme.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter); return; }
            int pad = theme.S(16);
            // Заголовок: «назад», персонаж, название, статус.
            Rectangle back = new Rectangle(area.X + theme.S(10), area.Y + theme.S(10), theme.S(30), theme.S(30));
            Draw.Fill(g, back, back.Height / 2f, Draw.Mix(Pal(0x2C2C2E), Pal(0x3A3A3C), Hot("page:home")));
            TextRenderer.DrawText(g, "\uE72B", fIconSmall, back, Pal(0xC7C7CC), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            Hit(back, "page:home");
            float fh = theme.S(26), fw = fh * 1.3f;
            PaintFace(g, new RectangleF(back.Right + theme.S(10), area.Y + theme.S(12), fw, fh), it, true);
            int tx = back.Right + theme.S(10) + (int)fw + theme.S(10);
            TextRenderer.DrawText(g, it.Title, fTitle, new Rectangle(tx, area.Y + theme.S(8), area.Right - tx - pad, theme.S(20)), Fg, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            TextRenderer.DrawText(g, it.StateText, fSmall, new Rectangle(tx, area.Y + theme.S(28), area.Right - tx - pad, theme.S(18)), theme.Muted, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            Rectangle arrow = new Rectangle(area.Right - theme.S(40), area.Y + theme.S(12), theme.S(26), theme.S(26));
            Draw.Fill(g, arrow, arrow.Height / 2f, Draw.Mix(Pal(0x2C2C2E), Pal(0x3A3A3C), Hot("open")));
            TextRenderer.DrawText(g, "\uE8A7", fIconSmall, arrow, Pal(0xC7C7CC), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            Hit(arrow, "open");
            // Кнопки ответа — внизу, всегда видны.
            int barH = theme.S(52);
            Rectangle bar = new Rectangle(area.X, area.Bottom - barH, area.Width, barH);
            int bx = area.X + pad, by = bar.Y + theme.S(10), bhh = theme.S(30);
            if (it.Actions.Length == 0) {
                TextRenderer.DrawText(g, it.State == "working" ? "Claude работает — ответить можно, когда он закончит." : "Сейчас Claude не ждёт ответа.", fSmall,
                    new Rectangle(bx, bar.Y, area.Width - pad * 2, barH), theme.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            }
            foreach (string a in it.Actions) {
                string[] p = a.Split('|');
                string id = p[0], text = p.Length > 1 ? p[1] : p[0], style = p.Length > 2 ? p[2] : "secondary";
                int bw = TextRenderer.MeasureText(text, fBold).Width + theme.S(24);
                if (bx + bw > area.Right - pad) break;
                Rectangle br = new Rectangle(bx, by, bw, bhh);
                PaintPill(g, br, text, style, "act:" + id);
                Hit(br, "act:" + id);
                bx += bw + theme.S(8);
            }
            if (CanTextReply(it)) PaintReplyField(g, new Rectangle(bx + theme.S(4), by, area.Right - pad - bx - theme.S(4), bhh));
            // Текст ответа целиком — с прокруткой колесом.
            Rectangle textArea = new Rectangle(area.X + pad, area.Y + theme.S(56), AnswerTextWidth(area.Width), bar.Y - area.Y - theme.S(60));
            string body = AnswerText(it);
            int ath = TextRenderer.MeasureText(body, fBody, new Size(textArea.Width, int.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl).Height;
            int th = ath + PaintFeed(null, it, textArea.X, 0, textArea.Width);
            viewHeight = textArea.Height; contentHeight = th;
            int scroll = Scroll;
            Region old = g.Clip;
            g.SetClip(textArea, CombineMode.Intersect);   // сужаем, а не заменяем: при сворачивании текст режется формой шторки
            TextRenderer.DrawText(g, body, fBody, new Rectangle(textArea.X, textArea.Y - scroll, textArea.Width, ath + theme.S(4)), Pal(0xE5E5EA), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl);
            PaintFeed(g, it, textArea.X, textArea.Y - scroll + ath, textArea.Width);
            g.Clip = old; old.Dispose();   // g.Clip отдаёт копию — без Dispose регион GDI+ копится на каждом кадре
            if (th > textArea.Height + theme.S(3) && !Resizing) {
                int sh = Math.Max(theme.S(24), textArea.Height * textArea.Height / th);
                int sy = textArea.Y + (int)((textArea.Height - sh) * (scroll / (float)Math.Max(1, th - textArea.Height)));
                Draw.Fill(g, new RectangleF(area.Right - theme.S(8), sy, theme.S(3), sh), theme.S(1.5f), Color.FromArgb(120, 142, 142, 147));
            }
        }

        void PaintMain(Graphics g, Rectangle r) {
            NotchItem it = Selected;
            if (it != null) {
                if (hover == "answer") Draw.Fill(g, r, theme.S(18), Pal(0x1C1C1F));
                Hit(r, "answer");   // щелчок по карточке — полный ответ и варианты ответа
            }
            if (it == null) {
                PaintFace(g, new RectangleF(r.X + theme.S(18), r.Y + (r.Height - theme.S(64)) / 2f, theme.S(84), theme.S(64)), null, false, true);
                TextRenderer.DrawText(g, "Сеансов нет", fTitle, new Rectangle(r.X + theme.S(120), r.Y, r.Width - theme.S(130), r.Height / 2), Fg, TextFormatFlags.Bottom | TextFormatFlags.NoPrefix);
                TextRenderer.DrawText(g, "Начните работу в Claude Code — сеанс появится здесь.", fSmall, new Rectangle(r.X + theme.S(120), r.Y + r.Height / 2 + theme.S(4), r.Width - theme.S(130), r.Height / 2), theme.Muted, TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                return;
            }
            PaintDropRing(g, new RectangleF(r.X, r.Y, r.Width, r.Height), it.Id);
            PaintMainWait(g, it, r.Right - theme.S(44), r.Y + theme.S(12));
            int fw = theme.S(96), fh = theme.S(74);
            if (it.Actions.Length > 0 && r.Height < theme.S(150)) { fw = theme.S(66); fh = theme.S(50); }
            PaintFace(g, FlyRect(it, new RectangleF(r.X + theme.S(16), r.Y + theme.S(16), fw, fh)), it, true, true);
            int tx = r.X + theme.S(16) + fw + theme.S(16), tw = r.Right - tx - theme.S(44);
            int y = r.Y + theme.S(14);
            int titleW = Math.Min(tw, TextRenderer.MeasureText(it.Title, fTitle).Width);
            TextRenderer.DrawText(g, it.Title, fTitle, new Rectangle(tx, y, titleW + 2, theme.S(22)), Fg, TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
            if (!string.IsNullOrEmpty(it.Meta) && titleW + theme.S(8) + TextRenderer.MeasureText(it.Meta, fBody).Width <= tw)
                TextRenderer.DrawText(g, it.Meta, fBody, new Rectangle(tx + titleW + theme.S(8), y + theme.S(2), tw - titleW - theme.S(8), theme.S(22)), theme.Muted, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            y += theme.S(24);
            float d = theme.S(7);
            using (SolidBrush b = new SolidBrush(TrayDot.ColorFor(it.State))) g.FillEllipse(b, tx, y + theme.S(10) - d / 2, d, d);
            TextRenderer.DrawText(g, it.StateText, fBody, new Rectangle(tx + theme.S(13), y, tw - theme.S(13), theme.S(20)), Pal(0xAEAEB2), TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
            y += theme.S(24);
            string body = !string.IsNullOrEmpty(it.RequestTitle) ? it.RequestTitle : it.Preview;
            int lines = 2;
            int bottomReserve = it.Actions.Length > 0 ? theme.S(40) : theme.S(28);
            int bh = Math.Max(0, Math.Min(r.Bottom - bottomReserve - y, TextRenderer.MeasureText("Ag", fSmall).Height * lines));
            if (!string.IsNullOrEmpty(body) && bh > 0)
                TextRenderer.DrawText(g, body, fSmall, new Rectangle(tx, y, tw + theme.S(30), bh), Pal(0x98989D), TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.TextBoxControl);
            if (it.Actions.Length > 0) {
                int bx = r.X + theme.S(16), by = r.Bottom - theme.S(38), bhh = theme.S(28);
                foreach (string a in it.Actions) {
                    string[] p = a.Split('|');
                    string id = p[0], text = p.Length > 1 ? p[1] : p[0], style = p.Length > 2 ? p[2] : "secondary";
                    int bw = TextRenderer.MeasureText(text, fBold).Width + theme.S(22);
                    if (bx + bw > r.Right - theme.S(12)) break;
                    Rectangle br = new Rectangle(bx, by, bw, bhh);
                    PaintPill(g, br, text, style, "act:" + id);
                    Hit(br, "act:" + id);
                    bx += bw + theme.S(6);
                }
                bx += PaintAllowAll(g, it, bx, by, bhh, r.Right - theme.S(12));
            } else {
                string open = "Полный ответ  \u203A";
                Rectangle or = new Rectangle(tx, r.Bottom - theme.S(32), TextRenderer.MeasureText(open, fBold).Width, theme.S(22));
                TextRenderer.DrawText(g, open, fBold, or, hover == "answer" ? Fg : Pal(0xD1D1D6), TextFormatFlags.NoPrefix | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            }
            Rectangle arrow = new Rectangle(r.Right - theme.S(36), r.Y + theme.S(10), theme.S(26), theme.S(26));
            Draw.Fill(g, arrow, arrow.Height / 2f, Draw.Mix(Pal(0x2C2C2E), Pal(0x3A3A3C), Hot("open")));
            TextRenderer.DrawText(g, "", fIconSmall, arrow, Pal(0xC7C7CC), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            Hit(arrow, "open");
        }

        void PaintSelect(Graphics g, Rectangle br, string text, string id) {
            float rad = theme.S(8), h = Hot(id), pr = Press(id);
            Draw.Fill(g, br, rad, Draw.Mix(Draw.Mix(Pal(0x2C2C2E), Pal(0x3A3A3C), h), Bg, 0.15f * pr));
            using (GraphicsPath path = Draw.Round(new RectangleF(br.X + 0.5f, br.Y + 0.5f, br.Width - 1, br.Height - 1), rad))
            using (Pen border = new Pen(Draw.Mix(Pal(0x48484A), Pal(0x6A6A6E), h)))
                g.DrawPath(border, path);
            int chev = theme.S(26);
            TextRenderer.DrawText(g, text, fBody, new Rectangle(br.X + theme.S(12), br.Y, br.Width - theme.S(12) - chev, br.Height), Fg,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            // Стрелка вниз — как у системного выпадающего списка.
            float cx = br.Right - chev / 2f - theme.S(2), cy = br.Y + br.Height / 2f, w = theme.S(4.5f);
            using (Pen p = new Pen(Pal(0xAEAEB2), theme.S(1.6f))) {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                g.DrawLines(p, new PointF[] { new PointF(cx - w, cy - w / 2), new PointF(cx, cy + w / 2), new PointF(cx + w, cy - w / 2) });
            }
        }

        void PaintOthers(Graphics g, Rectangle r) {
            NotchItem sel = Selected;
            int pad = theme.S(12), chH = theme.S(40), gap = theme.S(8);
            int x = r.X + pad, y = r.Y + pad, colW = Math.Max(theme.S(120), (r.Width - pad * 2 - gap) / 2);
            y += PaintSearchField(g, new Rectangle(r.X + pad, r.Y + pad, r.Width - pad * 2, 0));   // поиск (печатают на главной)
            int shown = 0, total = 0;
            // Сеансы нескольких устройств — группами с подписью («Этот ПК», «MacBook Air»): одинаковые проекты не путаются.
            bool grouped = false;
            foreach (NotchItem it in items) if (it.Device != items[0].Device) { grouped = true; break; }
            string group = null;
            int labelH = theme.S(20);
            List<NotchItem> order = new List<NotchItem>(items);
            if (chipDragging && chipDrag != null) {
                int from = order.FindIndex(delegate (NotchItem q) { return q.Id == chipDrag; });
                if (from >= 0) {
                    NotchItem d = order[from]; order.RemoveAt(from);
                    string before = DropTarget(chipDragPos, chipDrag);
                    int to = before == null ? order.Count : order.FindIndex(delegate (NotchItem q) { return q.Id == before; });
                    order.Insert(to < 0 ? order.Count : to, d);
                }
            }
            chipSlots.Clear();
            foreach (NotchItem it in order) {
                if (sel != null && it.Id == sel.Id) continue;
                if (!Matches(it)) continue;
                total++;
                if (grouped && it.Device != group) {
                    group = it.Device;
                    if (x != r.X + pad) { x = r.X + pad; y += chH + gap; }   // группа — с новой строки
                    if (y + labelH + chH <= r.Bottom - pad + 1) {
                        TextRenderer.DrawText(g, string.IsNullOrEmpty(it.Group) ? "Этот ПК" : it.Group, fSmall,
                            new Rectangle(x + theme.S(6), y, r.Width - pad * 2, labelH), theme.Muted,
                            TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
                    }
                    y += labelH;
                }
                if (y + chH > r.Bottom - pad + 1) continue;
                Rectangle target = new Rectangle(x, y, colW, chH);
                Rectangle chip = new Rectangle((int)Math.Round(Anim("cx:" + it.Id, x, 18f)), (int)Math.Round(Anim("cy:" + it.Id, y, 18f)), colW, chH);
                Rectangle slotW = target; slotW.Offset(origin);
                chipSlots.Add(new KeyValuePair<string, Rectangle>(it.Id, slotW));
                if (chipDragging && chipDrag == it.Id) {
                    using (Pen ph = new Pen(Pal(0x3A3A3C), Math.Max(1f, theme.S(1.2f)))) {
                        ph.DashStyle = DashStyle.Dash;
                        using (GraphicsPath pp = Draw.Round(new RectangleF(target.X + 0.5f, target.Y + 0.5f, target.Width - 1, target.Height - 1), chH / 2f)) g.DrawPath(ph, pp);
                    }
                    shown++;
                    if (x == r.X + pad) x += colW + gap; else { x = r.X + pad; y += chH + gap; }
                    continue;
                }
                bool hot = hover == "item:" + it.Id || hover == "remove:" + it.Id;
                float chipH = Math.Max(Hot("item:" + it.Id), Hot("remove:" + it.Id)), chipP = Press("item:" + it.Id);
                RectangleF chipR = RectangleF.Inflate(chip, -chipP * theme.S(1.5f), -chipP * theme.S(1.5f));
                Draw.Fill(g, chipR, chipR.Height / 2f, Draw.Mix(Pal(0x1F1F21), Pal(0x2C2C2E), chipH));
                PaintWaitTint(g, chipR, it);
                PaintDropRing(g, chipR, it.Id);
                float fh = chH * 0.62f, fw = fh * 1.3f;
                PaintFace(g, new RectangleF(chip.X + theme.S(8), chip.Y + (chH - fh) / 2, fw, fh), it, false);
                // Крестик справа — убрать сеанс из списка (вернётся, если в нём что-то произойдёт).
                int xs = theme.S(22);
                Rectangle xr = new Rectangle(chip.Right - theme.S(8) - xs, chip.Y + (chH - xs) / 2, xs, xs);
                bool xhot = hover == "remove:" + it.Id;
                // Крестик — только при наведении на плашку: в покое имени и статусу больше места.
                if (hot) {
                    if (xhot) Draw.Fill(g, xr, xs / 2f, Pal(0x3A3A3C));
                    TextRenderer.DrawText(g, "\uE711", fIconSmall, xr, xhot ? Fg : Pal(0x98989D),
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
                }
                int tx = chip.X + theme.S(8) + (int)fw + theme.S(8), tright = hot ? xr.X : chip.Right - theme.S(14);
                // Имя и под ним — статус («Работает · 12 мин»); справа — сколько ждёт вас; закреплённый — со звёздочкой.
                bool sub = !string.IsNullOrEmpty(it.StateText) && chH >= theme.S(36);
                int nameY = sub ? chip.Y + theme.S(3) : chip.Y, nameH = sub ? theme.S(19) : chH;
                if (!hot) tright -= PaintWaitLabel(g, it, tright, nameY, nameH);
                int nameX = tx + PaintPinStar(g, it, tx, nameY, nameH);
                int tr = tright - tx;
                TextRenderer.DrawText(g, it.Title, fBold, new Rectangle(nameX, nameY, tright - nameX, nameH), Pal(0xE5E5EA),
                    (sub ? TextFormatFlags.Bottom : TextFormatFlags.VerticalCenter) | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
                if (sub) TextRenderer.DrawText(g, it.StateText, fSmall, new Rectangle(tx, chip.Y + theme.S(21), tr, theme.S(15)),
                    it.State == "permission" || it.State == "error" ? TrayDot.ColorFor(it.State) : theme.Muted,
                    TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
                Hit(chip, "item:" + it.Id);
                Hit(xr, "remove:" + it.Id);   // добавлен позже — важнее плашки
                shown++;
                if (x == r.X + pad) x += colW + gap; else { x = r.X + pad; y += chH + gap; }
            }
            if (total == 0) TextRenderer.DrawText(g, SearchActive && search.Length > 0 ? "Ничего не найдено" : "Других сеансов нет", fBody, r, theme.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            else if (shown < total) TextRenderer.DrawText(g, "ещё " + (total - shown), fSmall, new Rectangle(r.X, r.Bottom - theme.S(22), r.Width - pad, theme.S(18)), theme.Muted, TextFormatFlags.Right | TextFormatFlags.NoPrefix);
        }

        // --- Страницы-списки: «Статистика», «Устройства», «Настройки» ---

        int RowHeight(NotchRow row, int width) {
            switch (row.Kind) {
                case "header": return theme.S(30);
                case "chart": return theme.S(156);
                case "note": return Math.Min(theme.S(60), TextRenderer.MeasureText(row.Title, fSmall, new Size(width - theme.S(8), int.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix).Height + theme.S(10));
                default:
                    if (string.IsNullOrEmpty(row.Subtitle)) return theme.S(44);
                    return SubtitleLines(row, width) > 1 ? theme.S(70) : theme.S(56);
            }
        }

        // Ширина правой части строки (тумблер, выбор, кнопка, значение, действия) — для раскладки текста.
        int RightWidth(NotchRow row, int width) {
            switch (row.Kind) {
                case "switch": return theme.S(52);
                case "choice": return Math.Min(width / 2, Math.Max(theme.S(100), TextRenderer.MeasureText(row.Value, fBody).Width + theme.S(56))) + theme.S(10);
                case "button": return Math.Min(width / 2, TextRenderer.MeasureText(row.Value, fBold).Width + theme.S(24)) + theme.S(10);
                case "device": {
                    int w = 0;
                    foreach (string a in row.Actions) { string[] p = a.Split('|'); w += TextRenderer.MeasureText(p.Length > 1 ? p[1] : p[0], fBold).Width + theme.S(26); }
                    return w;
                }
                default: return string.IsNullOrEmpty(row.Value) ? 0 : Math.Min(width / 2, TextRenderer.MeasureText(row.Value, fBody).Width + theme.S(4)) + theme.S(10);
            }
        }

        int TextWidth(NotchRow row, int width) {
            int w = width - theme.S(14) * 2 - RightWidth(row, width) - (string.IsNullOrEmpty(row.Dot) ? 0 : theme.S(16));
            return Math.Max(theme.S(40), w);
        }

        int SubtitleLines(NotchRow row, int width) {
            if (string.IsNullOrEmpty(row.Subtitle) || fSmall == null) return 0;
            return TextRenderer.MeasureText(row.Subtitle, fSmall).Width <= TextWidth(row, width) ? 1 : 2;
        }

        public int ContentHeight(string page, int width) {
            if (page == "settings") return SettingsHeight(width);
            int h = 0;
            foreach (NotchRow row in Rows(page)) h += RowHeight(row, width) + (row.Kind == "header" ? 0 : theme.S(6));
            return h;
        }

        void PaintRows(Graphics g, Rectangle area) {
            NotchRow[] rows = Rows(Page);
            viewHeight = area.Height;
            contentHeight = ContentHeight(Page, area.Width);
            int scroll = Scroll;
            Region old = g.Clip;
            g.SetClip(area, CombineMode.Intersect);   // сужаем, а не заменяем: при сворачивании строки режутся формой шторки
            int y = area.Y - scroll;
            if (rows.Length == 0) TextRenderer.DrawText(g, "Загружаю…", fBody, area, theme.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            foreach (NotchRow row in rows) {
                int h = RowHeight(row, area.Width);
                Rectangle r = new Rectangle(area.X, y, area.Width, h);
                if (r.Bottom >= area.Y && r.Top <= area.Bottom) PaintRow(g, row, r, area);
                y += h + (row.Kind == "header" ? 0 : theme.S(6));
            }
            g.Clip = old; old.Dispose();   // g.Clip отдаёт копию — без Dispose регион GDI+ копится на каждом кадре
            // Полоса прокрутки.
            if (contentHeight > area.Height + theme.S(3) && !Resizing) {
                int th = Math.Max(theme.S(24), area.Height * area.Height / contentHeight);
                int ty = area.Y + (int)((area.Height - th) * (scroll / (float)Math.Max(1, contentHeight - area.Height)));
                Draw.Fill(g, new RectangleF(area.Right + theme.S(4), ty, theme.S(3), th), theme.S(1.5f), Color.FromArgb(120, 142, 142, 147));
            }
        }

        int Scroll {
            get { int s; scrolls.TryGetValue(Page, out s); return ShownScroll(Math.Max(0, Math.Min(s, Math.Max(0, contentHeight - viewHeight)))); }
            set { scrolls[Page] = value; }
        }

        void PaintRow(Graphics g, NotchRow row, Rectangle r, Rectangle area) {
            if (row.Kind == "header") {
                TextRenderer.DrawText(g, row.Title.ToUpperInvariant(), fHeader, new Rectangle(r.X + theme.S(6), r.Y + theme.S(8), r.Width, r.Height - theme.S(8)), theme.Muted, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
                return;
            }
            if (row.Kind == "note") {
                TextRenderer.DrawText(g, row.Title, fSmall, new Rectangle(r.X + theme.S(6), r.Y, r.Width - theme.S(8), r.Height), theme.Muted, TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis);
                return;
            }
            string hitId = row.Kind == "switch" || row.Kind == "choice" ? "set:" + row.Key : (row.Kind == "button" || row.Kind == "link" ? "row:" + row.Key : null);
            bool hot = hitId != null && hover == hitId;
            Draw.Fill(g, r, theme.S(14), Draw.Mix(Draw.Mix(Pal(0x161618), Pal(0x222225), Hot(hitId)), Pal(0x111113), Press(hitId)));
            if (row.Kind == "chart") { PaintChart(g, row, r); return; }
            int pad = theme.S(14), rightW = 0;
            // Правая часть: тумблер, выбор, кнопка, значение или действия устройства.
            if (row.Kind == "switch") {
                int sw = theme.S(42), sh = theme.S(24);
                Rectangle t = new Rectangle(r.Right - pad - sw, r.Y + (r.Height - sh) / 2, sw, sh);
                PaintSwitch(g, t, row.Key, row.On, hitId);
                rightW = sw + theme.S(10);
            } else if (row.Kind == "choice") {
                // Селект: значение слева, стрелка вниз справа; щелчок — выпадающий список под кнопкой.
                int bw = Math.Min(r.Width / 2, Math.Max(theme.S(100), TextRenderer.MeasureText(row.Value, fBody).Width + theme.S(56)));
                Rectangle b = new Rectangle(r.Right - pad - bw, r.Y + (r.Height - theme.S(30)) / 2, bw, theme.S(30));
                PaintSelect(g, b, row.Value, hitId);
                Rectangle a = b; a.Offset(origin);
                selectAnchors[hitId] = a;
                rightW = bw + theme.S(10);
            } else if (row.Kind == "button") {
                string text = row.Value;
                int bw = Math.Min(r.Width / 2, TextRenderer.MeasureText(text, fBold).Width + theme.S(24));
                Rectangle b = new Rectangle(r.Right - pad - bw, r.Y + (r.Height - theme.S(28)) / 2, bw, theme.S(28));
                PaintPill(g, b, text, "secondary", hitId);
                rightW = bw + theme.S(10);
            } else if (row.Kind == "device") {
                int bx = r.Right - pad;
                for (int i = row.Actions.Length - 1; i >= 0; i--) {
                    string[] p = row.Actions[i].Split('|');
                    string text = p.Length > 1 ? p[1] : p[0], style = p.Length > 2 ? p[2] : "secondary";
                    int bw = TextRenderer.MeasureText(text, fBold).Width + theme.S(20);
                    bx -= bw;
                    Rectangle b = new Rectangle(bx, r.Y + (r.Height - theme.S(26)) / 2, bw, theme.S(26));
                    string id = "row:" + row.Key + ":" + p[0];
                    PaintPill(g, b, text, style, id);
                    Hit(Rectangle.Intersect(b, area), id);
                    bx -= theme.S(6);
                }
                rightW = r.Right - pad - bx;
            } else if (row.Kind == "link") {
                int cw = theme.S(14);
                TextRenderer.DrawText(g, "\u203A", fTitle, new Rectangle(r.Right - pad - cw, r.Y, cw, r.Height), Draw.Mix(Pal(0x6E6E73), Fg, Hot(hitId) * 0.6f),
                    TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPrefix);
                int vw = string.IsNullOrEmpty(row.Value) ? 0 : TextRenderer.MeasureText(row.Value, fSmall).Width + theme.S(4);
                if (vw > 0) TextRenderer.DrawText(g, row.Value, fSmall, new Rectangle(r.Right - pad - cw - theme.S(6) - vw, r.Y, vw, r.Height), theme.Muted,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Right | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
                rightW = cw + theme.S(10) + vw;
            } else if (!string.IsNullOrEmpty(row.Value)) {
                int vw = Math.Min(r.Width / 2, TextRenderer.MeasureText(row.Value, fBody).Width + theme.S(4));
                TextRenderer.DrawText(g, row.Value, fBody, new Rectangle(r.Right - pad - vw, r.Y, vw, r.Height), Pal(0xAEAEB2), TextFormatFlags.VerticalCenter | TextFormatFlags.Right | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
                rightW = vw + theme.S(10);
            }
            int tx = r.X + pad;
            if (!string.IsNullOrEmpty(row.Dot)) {
                float d = theme.S(8);
                Color dc = row.Dot == "online" ? Pal(0x30D158) : TrayDot.ColorFor(row.Dot);
                using (SolidBrush b = new SolidBrush(dc)) g.FillEllipse(b, tx, r.Y + r.Height / 2f - d / 2, d, d);
                tx += theme.S(16);
            }
            int tw = Math.Max(theme.S(40), r.Right - pad - rightW - tx);
            if (string.IsNullOrEmpty(row.Subtitle)) {
                Rectangle tr = new Rectangle(tx, r.Y, tw, r.Height);
                TextRenderer.DrawText(g, row.Title, fBold, tr, Fg, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
                Tip(Rectangle.Intersect(tr, area), row.Title, fBold);
            } else {
                // Подпись в одну строку, а если не помещается — в две (строка выше); текст — по середине строки.
                bool two = SubtitleLines(row, r.Width) > 1;
                int subH = two ? theme.S(34) : theme.S(18), blockH = theme.S(20) + subH;
                int ty0 = r.Y + (r.Height - blockH) / 2;
                Rectangle tr = new Rectangle(tx, ty0, tw, theme.S(20)), sr = new Rectangle(tx, ty0 + theme.S(20), tw, subH);
                TextRenderer.DrawText(g, row.Title, fBold, tr, Fg, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
                TextRenderer.DrawText(g, row.Subtitle, fSmall, sr, theme.Muted, TextFormatFlags.NoPrefix | (two ? TextFormatFlags.WordBreak : TextFormatFlags.SingleLine) | TextFormatFlags.EndEllipsis);
                Tip(Rectangle.Intersect(tr, area), row.Title, fBold);
                Tip(Rectangle.Intersect(sr, area), row.Subtitle, fSmall);
            }
            if (hitId != null) Hit(Rectangle.Intersect(r, area), hitId);
        }

        void PaintChart(Graphics g, NotchRow row, Rectangle r) {
            int n = row.Values.Length;
            if (n == 0) return;
            double max = 0; foreach (double v in row.Values) max = Math.Max(max, v);
            int pad = theme.S(16), labelH = theme.S(20), valueH = theme.S(16);
            int top = r.Y + pad + valueH, bottom = r.Bottom - pad - labelH;
            float slot = (r.Width - pad * 2) / (float)n, bw = Math.Min(theme.S(34), slot * 0.56f);
            for (int i = 0; i < n; i++) {
                float cx = r.X + pad + slot * i + slot / 2;
                float h = max > 0 ? (float)((bottom - top) * row.Values[i] / max) : 0;
                h = Math.Max(row.Values[i] > 0 ? theme.S(4) : theme.S(2), h);
                bool hi = i == row.Highlight;
                Draw.Fill(g, new RectangleF(cx - bw / 2, bottom - h, bw, h), theme.S(5), hi ? theme.Accent : Pal(0x3A3A3C));
                if (i < row.ValueLabels.Length && row.Values[i] > 0)
                    TextRenderer.DrawText(g, row.ValueLabels[i], fSmall, new Rectangle((int)(cx - slot / 2), (int)(bottom - h) - valueH, (int)slot, valueH), hi ? Fg : theme.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
                if (i < row.Labels.Length)
                    TextRenderer.DrawText(g, row.Labels[i], hi ? fBold : fSmall, new Rectangle((int)(cx - slot / 2), bottom + theme.S(4), (int)slot, labelH), hi ? Fg : theme.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            }
        }

        string HitAt(Point p) {
            for (int i = hits.Count - 1; i >= 0; i--) if (hits[i].Key.Contains(p)) return hits[i].Value;
            return null;
        }

        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            string h0 = HitAt(e.Location);
            if (e.Button == MouseButtons.Left && h0 != "mascot") { pressed = h0; WakeUi(); Invalidate(); }
            ChipMouseDown(e, h0);
            PlayMouseDown(e, h0);
        }

        protected override void OnMouseMove(MouseEventArgs e) {
            base.OnMouseMove(e);
            string h = HitAt(e.Location);
            if (ChipMouseMove(e)) return;      // тянут плашку сеанса
            if (PlayMouseMove(e, h)) return;   // тянут маскота
            if (h != hover) { hover = h; Cursor = h != null ? Cursors.Hand : Cursors.Default; Invalidate(); }
            UpdateTip(e.Location);
        }

        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); UpdateTip(new Point(-1, -1)); if (hover != null) { hover = null; Invalidate(); } }

        protected override void OnMouseWheel(MouseEventArgs e) {
            base.OnMouseWheel(e);
            if (!Expanded || SessionPage) return;
            int target; scrolls.TryGetValue(Page, out target);
            scrolls[Page] = Math.Max(0, Math.Min(target - e.Delta / 120 * theme.S(64), Math.Max(0, contentHeight - viewHeight)));
            WakeUi();
            Invalidate();
        }

        protected override void OnMouseUp(MouseEventArgs e) {
            base.OnMouseUp(e);
            if (pressed != null) { pressed = null; WakeUi(); Invalidate(); }
            if (ChipMouseUp(e)) return;   // перенесли плашку сеанса
            if (PlayMouseUp(e)) return;   // бросили маскота или щёлкнули по нему
            string hit = HitAt(e.Location);
            if (e.Button == MouseButtons.Right) {
                // Правый щелчок по сеансу (плашка или большая карточка) — меню сеанса в трее.
                string id = null;
                if (hit != null && hit.StartsWith("item:")) id = hit.Substring(5);
                else if (hit != null && hit.StartsWith("remove:")) id = hit.Substring(7);
                else if (hit == "answer" || hit == "open") { NotchItem s = Selected; if (s != null) id = s.Id; }
                EventHandler<NotchEventArgs> h = Command;
                if (id != null && h != null) h(this, new NotchEventArgs("menu", id, null, PointToScreen(e.Location)));
                return;
            }
            if (e.Button != MouseButtons.Left) return;
            ClickArea(hit, PointToScreen(e.Location));
        }

        // Щелчок по области: вкладки, выбор сеанса и раскрытие — здесь; остальное — событием Command (в очередь трея).
        public void ClickArea(string hit, Point p) {
            if (hit == null) return;
            NotchItem sel = Selected;
            string id = sel != null ? sel.Id : "";
            EventHandler<NotchEventArgs> h = Command;
            if (hit.StartsWith("section:")) {
                int si; if (int.TryParse(hit.Substring(8), out si)) { if (si != SettingsSection) SnapPage(); SettingsSection = si; ResetScroll("settings"); Invalidate(); }
                return;
            }
            if (hit.StartsWith("page:")) {
                string page = hit.Substring(5);
                if (page == "stats-limits") page = "stats";
                SetPage(page);
                if (h != null) h(this, new NotchEventArgs("page", id, page, p));
                return;
            }
            if (hit == "mascot") { MascotClick(); return; }
            if (ExtraClick(hit, p)) return;
            if (hit == "reply-field") {
                replyOn = true; searchOn = false;
                NotchForm nf = FindForm() as NotchForm; if (nf != null) nf.EnsureKeyboard();
                Invalidate(); return;
            }
            if (hit.StartsWith("qact:")) { QuickAnswer(hit.Substring(5), p); return; }
            if (hit.StartsWith("item:")) { SelectedId = hit.Substring(5); Invalidate(); return; }
            if (hit.StartsWith("remove:")) { if (h != null) h(this, new NotchEventArgs("remove", hit.Substring(7), null, p)); return; }
            if (hit == "expand" || hit == "close") {
                EventHandler<NotchEventArgs> l = Local;
                if (l != null) l(this, new NotchEventArgs(hit, id, null, p));
                if (h != null) h(this, new NotchEventArgs(hit, id, null, p));
                return;
            }
            if (hit == "answer") {
                ResetScroll("answer");
                SetPage("answer");
                if (h != null) h(this, new NotchEventArgs("page", id, "answer", p));
                return;
            }
            string kind = hit, action = null;
            if (hit.StartsWith("act:")) { kind = "action"; action = hit.Substring(4); MarkSent(action); }
            else if (hit.StartsWith("set:")) {
                kind = "set"; id = hit.Substring(4);
                // Селект: список — под левым краем кнопки и не уже её (ширина — в action).
                Rectangle a;
                if (selectAnchors.TryGetValue(hit, out a)) { p = PointToScreen(new Point(a.X, a.Bottom + theme.S(4))); action = a.Width.ToString(); }
            }
            else if (hit.StartsWith("row:")) {
                kind = "row";
                string rest = hit.Substring(4);
                int c = rest.IndexOf(':');
                if (c >= 0) { id = rest.Substring(0, c); action = rest.Substring(c + 1); } else { id = rest; }
            }
            else if (hit == "open-text") kind = "open";
            // Тумблер переключается сразу (трей запишет настройку и пришлёт строки заново).
            if (kind == "set") foreach (NotchRow row in Rows(Page)) if (row.Key == id && row.Kind == "switch") { row.On = !row.On; Invalidate(); }
            if (h != null) h(this, new NotchEventArgs(kind, id, action, p));
        }

        public string[] HitIds() { string[] r = new string[hits.Count]; for (int i = 0; i < hits.Count; i++) r[i] = hits[i].Value; return r; }
    }

    // Окно шторки: без рамки, поверх всех окон, без кнопки на панели задач и без перехвата фокуса.
    // Прижато к верхнему краю выбранного монитора; нижние углы скруглены; размер меняется пружиной.
    public sealed partial class NotchForm : Form {
        public readonly NotchView View = new NotchView();
        readonly Timer spring = new Timer();
        readonly Timer outside = new Timer();
        readonly System.Diagnostics.Stopwatch clock = new System.Diagnostics.Stopwatch();
        readonly float[] sw = new float[2], sh = new float[2];
        DateTime expandedAt = DateTime.MinValue;
        Size target;
        public Rectangle ScreenBounds = Screen.PrimaryScreen.Bounds;
        public string Position = "center";   // left | center | right
        public int Margin2 = 0;
        public bool Hold;                     // открыт диалог трея — щелчок мимо не сворачивает
        public bool Animating { get { return running; } }
        volatile bool running;
        System.Threading.Thread vsync;
        int vsyncGen;
        int VsyncGen { get { return System.Threading.Thread.VolatileRead(ref vsyncGen); } }

        public NotchForm() {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.Black;
            Text = "Claude Notifier — шторка";
            View.Dock = DockStyle.Fill;
            // Layered-окно с попиксельной прозрачностью: края шторки сглажены, вне фигуры окно прозрачно и
            // пропускает щелчки. Картинку окну отдаём сами (Present) — по каждой перерисовке панели.
            View.External = true;
            View.Outside = Color.Transparent;
            View.Invalidated += delegate (object s, InvalidateEventArgs e) {
                dirty = dirty.IsEmpty ? e.InvalidRect : Rectangle.Union(dirty, e.InvalidRect);
                if (!presentPending && IsHandleCreated) { presentPending = true; try { BeginInvoke((MethodInvoker)Present); } catch { presentPending = false; } }
            };
            VisibleChanged += delegate { if (Visible) { dirty = ClientRectangle; Present(); } };
            Controls.Add(View);
            spring.Interval = 8;
            spring.Tick += delegate {   // запасной путь, если синхронизация с экраном недоступна
                try { Step(); } catch (Exception e) { NotchHost.Report(e); try { StopSpring(); } catch { running = false; } }
            };
            View.PageChanged += delegate { if (View.Expanded) SetTargetSize(SizeFor(), true); };
            // Свёрнутой нужен другой размер (выдох, рост): пружиной, если окно видно; невидимому — сразу.
            View.CollapsedResize += delegate {
                if (View.Expanded) return;
                View.LayoutCollapsed = CollapsedSize();
                SetTargetSize(SizeFor(), Visible && Motion.Enabled);
            };
            View.Local += delegate (object s, NotchEventArgs e) { SetExpanded(e.Kind == "expand", e.Kind == "expand" ? "home" : null); };
            // Щелчок мимо раскрытой шторки сворачивает её (окно шторки фокус не берёт — проверяем кнопки мыши).
            outside.Interval = 80;
            outside.Tick += delegate { try { OutsideTick(); } catch (Exception e) { NotchHost.Report(e); } };
            outside.Start();
        }

        void OutsideTick() {
            {
                // Щелчок мимо нужно ловить только у раскрытой (каждые 80 мс); свёрнутой хватает раза в 0,8 с —
                // проверить, не перекрыло ли шторку другое окно «поверх всех».
                int wantOut = View.Expanded ? 80 : 800;
                if (outside.Interval != wantOut) { outside.Interval = wantOut; topTicks = 0; }
                // Пока открыт список, меню или диалог трея (Hold), шторка наверх не лезет — они должны быть выше.
                if (!View.Expanded || ++topTicks >= 10) { topTicks = 0; if (!Hold) RaiseToTop(); }
                if (!View.Expanded || Hold || (DateTime.UtcNow - expandedAt).TotalMilliseconds < 400) return;
                if (Control.MouseButtons == MouseButtons.None || ShapeOnScreen().Contains(NotchView.SafeCursor())) return;
                SetExpanded(false, null);
                RaiseCollapse();
            }
        }

        // Масштаб экрана (DPI / 96). Процесс system-DPI-aware (SetProcessDPIAware в трее): шрифты в пунктах
        // растут с DPI сами, а размеры в пикселях (Theme.S) — только через Scale. Без этого при 150 %
        // текст вылезал из строк и кнопок. При 100 % — ровно 1, всё как раньше.
        public static float ScreenScale() {
            float s = 1f;
            try { using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) s = g.DpiX / 96f; } catch { }
            return s > 0.5f && s < 8f ? s : 1f;
        }

        public void ApplyDpi() { ApplyDpi(false); }
        public void ApplyDpi(bool force) {
            float s = ScreenScale() * NotchView.UserScale;   // размер шторки из настроек — множитель к DPI
            if (!force && Math.Abs(View.Theme.Scale - s) < 0.001f && View.Theme.Dark == !NotchView.Light) return;
            Theme t = Theme.Create(!NotchView.Light);
            t.Scale = s;
            View.ApplyTheme(t);
        }

        int topTicks;
        public int Raised;   // сколько раз поднимали наверх (для проверки)
        public void RaiseToTop() {
            if (!IsHandleCreated || !Visible) return;
            if (Native.KeepOnTop(Handle, ShapeOnScreen())) Raised++;
        }

        public event EventHandler Collapsed;
        void RaiseCollapse() { EventHandler h = Collapsed; if (h != null) h(this, EventArgs.Empty); }

        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80 | 0x08000000 | 0x00080000; return cp; }   // WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED
        }

        LayeredSurface surface;
        Rectangle dirty;
        bool presentPending;
        public LayeredSurface Surface { get { return surface; } }
        public double PresentMaxMs, PresentSumMs; public int PresentCount;   // замер
        public double PaintSum, MaskSum, ComposeSum, PushSum;

        // Перерисовать изменившееся и отдать окну: содержимое и сглаженная форма → попиксельная альфа.
        public void Present() {
            presentPending = false;
            if (IsDisposed || !IsHandleCreated || Width <= 0 || Height <= 0) return;
            // Present вызывается из BeginInvoke и шага анимации: сбой GDI+ (LockBits, нехватка памяти) здесь
            // не должен уходить в цикл сообщений. Следующая перерисовка — заново на всё окно.
            try { PresentCore(); }
            catch (Exception e) { NotchHost.Report(e); dirty = new Rectangle(0, 0, Width, Height); }
        }

        void PresentCore() {
            System.Diagnostics.Stopwatch pw = System.Diagnostics.Stopwatch.StartNew();
            if (surface == null) surface = new LayeredSurface();
            Rectangle d = dirty; dirty = Rectangle.Empty;
            if (surface.Width != Width || surface.Height != Height) { surface.Ensure(Width, Height); d = new Rectangle(0, 0, Width, Height); }
            d.Intersect(new Rectangle(0, 0, Width, Height));
            if (d.Width <= 0 || d.Height <= 0) return;
            using (Graphics g = surface.ContentGraphics()) {
                g.SetClip(d);
                View.PaintInto(g, d);
            }
            double tPaint = pw.Elapsed.TotalMilliseconds;
            using (Graphics m = Graphics.FromImage(surface.Mask)) {
                m.SetClip(d);
                m.CompositingMode = CompositingMode.SourceCopy;
                m.Clear(Color.Transparent);
                m.CompositingMode = CompositingMode.SourceOver;
                m.SmoothingMode = SmoothingMode.AntiAlias;
                m.PixelOffsetMode = PixelOffsetMode.HighQuality;
                using (GraphicsPath p = NotchView.ShapePath(View.ShapeRect, View.CornerRadius))
                using (SolidBrush wb = new SolidBrush(Color.White)) m.FillPath(wb, p);
            }
            double tMask = pw.Elapsed.TotalMilliseconds;
            surface.Compose(d);
            double tCompose = pw.Elapsed.TotalMilliseconds;
            surface.Push(Handle, Location);
            double ms = pw.Elapsed.TotalMilliseconds; PresentSumMs += ms; PresentCount++; if (ms > PresentMaxMs) PresentMaxMs = ms;
            PaintSum += tPaint; MaskSum += tMask - tPaint; ComposeSum += tCompose - tMask; PushSum += ms - tCompose;
        }

        // Свёрнутая полоска; с загрузкой ПК посередине — шире.
        // «Выдох» — шире, по длине строки; главный маскот вырос (долго ждёт вас) — выше.
        public Size CollapsedSizeNow() { return CollapsedSize(); }
        Size CollapsedSize() {
            Theme t = View.Theme;
            int w = t.S(View.ShowStats || View.HasAsk ? 400 : 240), h = t.S(View.Grown ? 48 : 38);
            if (View.PeekActive) w = Math.Max(w, View.PeekWidth);
            int qw = View.QuickWidth;   // кнопки решения у маскота
            if (qw > 0) w = Math.Max(w, t.S(16 + 39 + 12 + 16 + 60) + qw);
            return new Size(Math.Min(w, Math.Max(t.S(240), ScreenBounds.Width - t.S(40))), h);
        }

        // Размер по состоянию: свёрнута — полоска; «Главная» и «Ответ» — панель; остальные страницы — выше (до 600).
        public Size SizeFor() {
            Theme t = View.Theme;
            if (!View.Expanded) return CollapsedSize();
            if (View.Page == "home") return new Size(ExpandedWidth("home"), t.S(232));
            int W = ExpandedWidth(View.Page);
            int top = t.S(10) + t.S(34) + t.S(12) + t.S(14);
            int content = View.Page == "answer" ? View.AnswerContentHeight(W - t.S(28)) : View.ContentHeight(View.Page, W - t.S(28));
            int h = Math.Max(t.S(View.Page == "answer" ? 232 : 320), Math.Min(top + content, t.S(600)));
            return new Size(W, Math.Min(h, ScreenBounds.Height - t.S(40)));
        }

        // Ширина раскрытой шторки — одна для всех страниц (900: настройкам нужны две колонки с подписями): при смене
        // страницы меняется только высота, кнопки не съезжают. На узком мониторе — не шире экрана.
        int ExpandedWidth(string page) {
            Theme t = View.Theme;
            int w = t.S(900);
            if (ScreenBounds.Width > 0) w = Math.Min(w, Math.Max(t.S(760), ScreenBounds.Width - t.S(40)));
            return w;
        }

        public Rectangle ShapeOnScreen() {
            RectangleF s = View.ShapeRect;
            return new Rectangle(Left + (int)s.X, Top + (int)s.Y, (int)Math.Ceiling(s.Width), (int)Math.Ceiling(s.Height));
        }

        public void SetExpanded(bool expanded, string page) {
            bool changed = View.Expanded != expanded;
            View.Expanded = expanded;
            if (expanded) { expandedAt = DateTime.UtcNow; if (!string.IsNullOrEmpty(page)) View.Page = page; }
            Size s = SizeFor();
            Theme t = View.Theme;
            View.LayoutCollapsed = CollapsedSize();
            if (expanded) View.LayoutExpanded = s;
            if (changed && Visible && Motion.Enabled) View.Morphing = true;
            if (expanded) RaiseToTop();
            // Клавиатура: раскрыли — шторка принимает клавиши; свернули — фокус прежнему окну.
            if (expanded && changed) TakeKeyboard();
            if (!expanded) { ReleaseKeyboard(); View.EndTyping(); }
            SetTargetSize(s, true);
            View.Invalidate();
        }

        // Страницу перерисовали (новые строки) — высота могла поменяться.
        public void Refit() { if (View.Expanded && View.Page != "home") SetTargetSize(SizeFor(), true); }

        // Окно: на месте по позиции (слева / по центру / справа), у верхнего края экрана. Меняется только в начале
        // и в конце анимации — не на каждом кадре.
        void ApplyWindow(int w, int h) {
            int x = ScreenBounds.X + (ScreenBounds.Width - w) / 2;
            if (Position == "left") x = ScreenBounds.X + Margin2;
            else if (Position == "right") x = ScreenBounds.Right - w - Margin2;
            Rectangle nb = new Rectangle(x, ScreenBounds.Y, w, h);
            if (Bounds != nb) { Bounds = nb; dirty = new Rectangle(0, 0, w, h); if (Visible) Present(); }
            if (Region != null) { Region old = Region; Region = null; old.Dispose(); }
        }

        // Фигура внутри окна — по ширине привязана к той же стороне, что и окно.
        void ApplyShape(float w, float h) {
            float x = (ClientSize.Width - w) / 2f;
            if (Position == "left") x = 0;
            else if (Position == "right") x = ClientSize.Width - w;
            View.Shape = new RectangleF(x, 0, w, h);
            // Радиус углов плавно меняется вместе с высотой: полоска — почти капсула, панель — мягкий угол.
            Theme t = View.Theme;
            Size le = View.LayoutExpanded;
            float h0 = t.S(38), h1 = Math.Max(h0 + 1, le.Height > 0 ? le.Height : t.S(232));
            float k = Math.Max(0f, Math.Min(1f, (h - h0) / (h1 - h0)));
            View.Progress = k;
            float rc = h0 * 0.45f, re = Math.Min(h * 0.12f + 6, 28);
            View.Corner = rc + (re - rc) * k;
        }

        // Окно всегда одного размера — с самую большую шторку (+ запас на перелёт пружины): окно не меняет размер
        // ни во время, ни в конце анимации (это и давало рывки и «призраки»). Всё вне фигуры прозрачно.
        Size WindowSize() {
            Theme t = View.Theme;
            int extra = t.S(16);
            int w = Math.Max(ExpandedWidth("settings"), t.S(760)) + extra * 2, h = Math.Min(t.S(600), ScreenBounds.Height - t.S(40)) + extra;
            return new Size(Math.Min(w, ScreenBounds.Width), Math.Min(h, ScreenBounds.Height));
        }

        public void SetTargetSize(Size s, bool animate) {
            target = s;
            if (View.Expanded) View.LayoutExpanded = s;
            Size ws = WindowSize();
            ApplyWindow(ws.Width, ws.Height);
            if (!animate || !Motion.Enabled || !Visible) {
                sw[0] = s.Width; sw[1] = 0; sh[0] = s.Height; sh[1] = 0;
                StopSpring();
                return;
            }
            if (sw[0] <= 0) { RectangleF cur = View.ShapeRect; sw[0] = cur.Width; sh[0] = cur.Height; }
            ApplyShape(sw[0], sh[0]);
            View.Invalidate();
            if (!running) {
                clock.Restart(); leftover = 0;
                Frames = 0; MaxGapMs = 0; gapClock.Restart();
                running = true;
                StartVsync();
            }
        }

        // Замер плавности последней анимации: кадров и самая долгая пауза между ними.
        public int Frames; public double MaxGapMs;
        readonly System.Diagnostics.Stopwatch gapClock = new System.Diagnostics.Stopwatch();

        double leftover;
        void Step() {
            // Пружина по реальному времени шагами по 1 мс, остаток копится — без дрожания от округления.
            double ms = clock.Elapsed.TotalMilliseconds; clock.Restart();
            leftover = Math.Min(leftover + ms, 120);
            bool a = false, b = false;
            while (leftover >= 1) {
                leftover -= 1;
                a = CardList.SpringStep(sw, target.Width, 0.001f); b = CardList.SpringStep(sh, target.Height, 0.001f);
                if (a && b) break;
            }
            double gap = gapClock.Elapsed.TotalMilliseconds; gapClock.Restart();
            if (Frames > 0 && gap > MaxGapMs) MaxGapMs = gap;
            Frames++;
            if (a && b) { StopSpring(); return; }
            RectangleF before = View.ShapeRect;
            ApplyShape(Math.Max(1f, sw[0]), Math.Max(1f, sh[0]));
            // Перерисовать только то, где фигура была и стала (остальное окно — прозрачное и не меняется).
            View.Invalidate(Rectangle.Inflate(Rectangle.Round(RectangleF.Union(before, View.ShapeRect)), 2, 2));
            Present();   // нарисовать и отдать окну сейчас, не дожидаясь очереди сообщений
        }

        // Кадры анимации — по обновлению экрана: поток ждёт следующий кадр монитора (DwmFlush) и сразу просит
        // поток шторки сделать шаг и нарисовать. Таймер WinForms для этого плох: его сообщения самые
        // низкоприоритетные и копятся за отрисовкой — отсюда паузы по 20–30 мс.
        void StartVsync() {
            // Поколение вместо проверки IsAlive: старый поток мог как раз выходить (running был false) и уже не
            // увидеть новый running = true — тогда кадров не было бы вовсе. Новый поток стартует всегда,
            // старый замечает смену поколения и завершается сам.
            int gen = System.Threading.Interlocked.Increment(ref vsyncGen);
            vsync = new System.Threading.Thread(delegate () {
                int fails = 0;
                while (running && gen == VsyncGen) {
                    if (Native.WaitVBlank() != 0) { fails++; System.Threading.Thread.Sleep(7); }
                    if (!running || gen != VsyncGen) break;
                    try {
                        if (IsDisposed || !IsHandleCreated) break;
                        Invoke((MethodInvoker)delegate { if (running && gen == VsyncGen) Step(); });
                    } catch {
                        // Сбой шага: снять running/Morphing, иначе SetTargetSize больше не запустит пружину и шторка застынет.
                        try { if (!IsDisposed && IsHandleCreated) BeginInvoke((MethodInvoker)delegate { try { StopSpring(); } catch { running = false; } }); else running = false; } catch { running = false; }
                        break;
                    }
                    if (fails > 30) {   // композиция выключена — вернуться к таймеру
                        try { BeginInvoke((MethodInvoker)delegate { if (running) { Native.TimerPrecise(true); spring.Start(); } }); } catch { }
                        break;
                    }
                }
            });
            vsync.IsBackground = true;
            vsync.Name = "Notch vsync";
            vsync.Start();
        }

        void StopSpring() {
            running = false;
            if (spring.Enabled) { spring.Stop(); Native.TimerPrecise(false); }
            View.Morphing = false;
            RectangleF before = View.ShapeRect;
            ApplyShape(target.Width, target.Height);
            View.Corner = -1; View.Progress = View.Expanded ? 1 : 0;
            View.Invalidate(Rectangle.Inflate(Rectangle.Round(RectangleF.Union(before, View.ShapeRect)), 2, 2));
        }

        protected override void Dispose(bool disposing) { running = false; if (disposing) { if (spring.Enabled) Native.TimerPrecise(false); spring.Dispose(); outside.Dispose(); if (surface != null) surface.Dispose(); } base.Dispose(disposing); }
    }

    // Поток шторки: своё окно и свой цикл сообщений. Все вызовы из трея — через Post (BeginInvoke) в поток шторки;
    // щелчки шторки — в очередь Commands.
    public static class NotchHost {
        static System.Threading.Thread thread;
        static NotchForm form;
        static Microsoft.Win32.SessionSwitchEventHandler onSession;
        static Microsoft.Win32.PowerModeChangedEventHandler onPower;
        public static readonly System.Collections.Concurrent.ConcurrentQueue<NotchEventArgs> Commands = new System.Collections.Concurrent.ConcurrentQueue<NotchEventArgs>();
        // Последняя ошибка в потоке шторки (поток при этом продолжает работать) — для лога трея и проверок.
        public static string LastError;
        public static string LastStack;    // полный текст последнего сбоя (со стеком) — для «Скопировать отчёт»
        public static int ErrorCount;
        public static void ResetErrors() { LastError = null; LastStack = null; ErrorCount = 0; }

        public static bool Running { get { NotchForm f = form; return f != null && !f.IsDisposed && f.IsHandleCreated; } }
        public static NotchForm Form { get { return form; } }

        internal static void Report(Exception e) {
            if (e == null) return;
            LastError = DateTime.UtcNow.ToString("o") + " " + e.GetType().Name + ": " + e.Message;
            string full = e.ToString();
            LastStack = full.Length > 3000 ? full.Substring(0, 3000) : full;
            System.Threading.Interlocked.Increment(ref ErrorCount);
        }

        // Будильник трея: щелчок в шторке будит поток трея сразу (а не на его следующем такте до 100 мс).
        public static TrayWaker Waker;
        static void WakeTray() { TrayWaker w = Waker; if (w != null) w.Wake(); }
        // Разбудить трей сейчас (пришёл хук, событие по каналу или запрос из сети), не дожидаясь его таймера.
        public static void Wake() { WakeTray(); }

        public static void Start() {
            if (Running) return;
            System.Threading.ManualResetEvent ready = new System.Threading.ManualResetEvent(false);
            thread = new System.Threading.Thread(delegate () {
                // Исключение в обработчике окна (таймер, отрисовка) не должно убивать поток шторки:
                // цикл сообщений ловит его, запоминает и продолжает работу.
                try { Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException, false); } catch { }
                Application.ThreadException += delegate (object s, System.Threading.ThreadExceptionEventArgs e) { Report(e.Exception); };
                NotchForm f = new NotchForm();
                f.View.Command += delegate (object s, NotchEventArgs e) { Commands.Enqueue(e); WakeTray(); };
                f.Collapsed += delegate { Commands.Enqueue(new NotchEventArgs("collapse", "", null, Point.Empty)); WakeTray(); };
                IntPtr h = f.Handle;   // создать окно в этом потоке
                form = f;
                // Заблокирован экран или компьютер засыпает — анимация на паузе (не тратим процессор впустую).
                try {
                    onSession = delegate (object s, Microsoft.Win32.SessionSwitchEventArgs e) {
                        Microsoft.Win32.SessionSwitchReason k = e.Reason;
                        if (k == Microsoft.Win32.SessionSwitchReason.SessionLock || k == Microsoft.Win32.SessionSwitchReason.ConsoleDisconnect || k == Microsoft.Win32.SessionSwitchReason.RemoteDisconnect) NotchView.Paused = true;
                        else if (k == Microsoft.Win32.SessionSwitchReason.SessionUnlock || k == Microsoft.Win32.SessionSwitchReason.ConsoleConnect || k == Microsoft.Win32.SessionSwitchReason.RemoteConnect) NotchView.Paused = false;
                    };
                    onPower = delegate (object s, Microsoft.Win32.PowerModeChangedEventArgs e) {
                        if (e.Mode == Microsoft.Win32.PowerModes.Suspend) NotchView.Paused = true;
                        else if (e.Mode == Microsoft.Win32.PowerModes.Resume) NotchView.Paused = false;
                    };
                    Microsoft.Win32.SystemEvents.SessionSwitch += onSession;
                    Microsoft.Win32.SystemEvents.PowerModeChanged += onPower;
                } catch { }
                ready.Set();
                Application.Run(new ApplicationContext());
                try { f.Dispose(); } catch { }
            });
            thread.SetApartmentState(System.Threading.ApartmentState.STA);
            thread.IsBackground = true;
            thread.Name = "Notch";
            thread.Start();
            ready.WaitOne(10000);
        }

        // В поток шторки. Делегат получает ту форму, что была при вызове, а не статическое поле:
        // Stop мог обнулить поле, пока вызов ждал в очереди.
        public static void Post(Action<NotchForm> a) {
            NotchForm f = form;
            if (f == null || f.IsDisposed || !f.IsHandleCreated) return;
            try { f.BeginInvoke((MethodInvoker)delegate { if (f.IsDisposed) return; try { a(f); } catch (Exception e) { Report(e); } }); } catch { }
        }

        // Синхронный вызов в потоке шторки (для тестов и чтения состояния).
        public static T Call<T>(Func<NotchForm, T> fn) {
            NotchForm f = form;
            if (f == null || f.IsDisposed || !f.IsHandleCreated) return default(T);
            try { return (T)f.Invoke((Func<T>)delegate { return fn(f); }); } catch (Exception e) { Report(e); return default(T); }
        }

        public static void Place(Rectangle screen, string position, int margin) {
            Post(delegate (NotchForm f) {
                f.ScreenBounds = screen; f.Position = position; f.Margin2 = margin;
                f.ApplyDpi();
                f.SetTargetSize(f.SizeFor(), false);
                if (!f.Visible) f.Show();
            });
        }

        public static void SetItems(NotchItem[] items) { Post(delegate (NotchForm f) { f.View.SetItems(items); }); }
        // Привлекать внимание (настройка «Привлекать внимание»): «выдох», свечение, зов, рост, бегущая строка, сводка.
        public static void SetAttention(bool on) {
            Post(delegate (NotchForm f) {
                if (f.View.Attention == on) return;
                f.View.Attention = on;
                f.SetExpanded(f.View.Expanded, null);
                f.View.Invalidate();
            });
        }
        // Загрузка ПК посередине свёрнутой шторки (настройка «Загрузка ПК»): ширина свёрнутой меняется пружиной.
        public static void SetShowStats(bool show) {
            Post(delegate (NotchForm f) {
                if (f.View.ShowStats == show) return;
                f.View.ShowStats = show;
                f.View.UpdateTimer();   // замер идёт из таймера шторки — запустить, даже если сеансов нет
                f.SetExpanded(f.View.Expanded, null);
            });
        }
        public static void SetRows(string page, NotchRow[] rows) { Post(delegate (NotchForm f) { f.View.SetRows(page, rows); f.Refit(); }); }
        public static void SetAnswer(string id, string text) { Post(delegate (NotchForm f) { f.View.SetAnswer(id, text); f.Refit(); }); }
        public static void SetLimits(float left5, string detail5, float leftWeek, string detailWeek, bool stale, bool soundOff) {
            Post(delegate (NotchForm f) {
                NotchView v = f.View;
                v.Left5 = left5; v.Detail5 = detail5 ?? ""; v.LeftWeek = leftWeek; v.DetailWeek = detailWeek ?? "";
                v.LimitsStale = stale; v.SoundOff = soundOff; v.Invalidate();
            });
        }
        // Открыть сеанс на главной раскрытой шторки (щелчок по событию в истории).
        public static void Select(string id) { Post(delegate (NotchForm f) { f.View.SelectedId = id; f.View.SetPage("home"); f.View.Invalidate(); }); }
        // Тема (светлая/тёмная) и размер шторки — сразу, с пересчётом раскладки.
        public static void SetLook(bool light, float scale) {
            Post(delegate (NotchForm f) {
                if (NotchView.Light == light && Math.Abs(NotchView.UserScale - scale) < 0.001f) return;
                NotchView.Light = light; NotchView.UserScale = scale;
                f.ApplyDpi(true);
                f.View.LayoutCollapsed = f.CollapsedSizeNow();
                f.SetTargetSize(f.SizeFor(), false);
                f.View.Invalidate();
            });
        }
        public static void ShowQuick(string id) { Post(delegate (NotchForm f) { f.View.ShowQuick(id); }); }
        public static void Peek(string text, int ms) { Post(delegate (NotchForm f) { if (!f.View.Expanded) f.View.StartPeek(text, null, ms); }); }
        // Сообщение: в раскрытой шторке — плашкой внизу, в свёрнутой — «выдохом».
        public static void SetUpdate(bool on) { Post(delegate (NotchForm f) { if (f.View.UpdateAvailable != on) { f.View.UpdateAvailable = on; f.View.Invalidate(); } }); }
        public static void Notice(string text, int ms) { Post(delegate (NotchForm f) { if (f.View.Expanded) f.View.Notice(text, ms); else f.View.StartPeek(text, null, ms); }); }
        public static void React(string id, string kind) { Post(delegate (NotchForm f) { f.View.React(id, kind); }); }
        public static void SetExpanded(bool expanded, string page) { Post(delegate (NotchForm f) { f.SetExpanded(expanded, page); }); }
        public static void Toggle(string page) { Post(delegate (NotchForm f) { f.SetExpanded(!f.View.Expanded, page); }); }
        public static void SetHold(bool hold) { Post(delegate (NotchForm f) { f.Hold = hold; }); }
        public static bool Expanded { get { return Running && Call<bool>(delegate (NotchForm f) { return f.View.Expanded; }); } }
        public static string Page { get { return Running ? Call<string>(delegate (NotchForm f) { return f.View.Page; }) : ""; } }
        public static string AnswerOf(string id) { return Running ? Call<string>(delegate (NotchForm f) { return f.View.Answer(id); }) : null; }
        public static bool IsExpanded() { return Running && Call<bool>(delegate (NotchForm f) { return f.View.Expanded; }); }
        // Без ожидания потока шторки (для частого опроса из таймера трея): раскрыта ли сейчас.
        public static bool ExpandedNow { get { NotchForm f = form; return f != null && !f.IsDisposed && f.View.Expanded; } }
        public static int ItemCount { get { return Running ? Call<int>(delegate (NotchForm f) { return f.View.Count; }) : 0; } }
        public static int RowCount(string page) { return Running ? Call<int>(delegate (NotchForm f) { return f.View.Rows(page).Length; }) : 0; }
        // Щелчок по области шторки в её потоке (для тестов).
        public static void ClickArea(string hit) { if (Running) Call<bool>(delegate (NotchForm f) { f.View.ClickArea(hit, Point.Empty); return true; }); }

        public static void Stop() {
            NotchForm f = form;
            if (f != null && !f.IsDisposed && f.IsHandleCreated) {
                try { f.BeginInvoke(new Action(delegate { f.Close(); Application.ExitThread(); })); } catch { }
            }
            if (thread != null) thread.Join(3000);
            // Обработчики SystemEvents статические: без отписки каждый Start/Stop добавлял бы ещё пару.
            try { if (onSession != null) Microsoft.Win32.SystemEvents.SessionSwitch -= onSession; } catch { }
            try { if (onPower != null) Microsoft.Win32.SystemEvents.PowerModeChanged -= onPower; } catch { }
            onSession = null; onPower = null;
            form = null; thread = null;
        }
    }
}
