// claude-notifier: взаимодействие с главным маскотом шторки (тот, что слева в свёрнутой, и крупный в раскрытой).
//  • Решение прямо у маскота: ждёт разрешения — щелчок по нему показывает кнопки ответа посередине свёрнутой
//    шторки (Разрешить / Всегда / Запретить), не раскрывая её.
//  • Подсказка при наведении: что он сейчас делает (NotchItem.Hint от трея) и дружба.
//  • Погладить: водите курсором по маскоту — жмурится, летят сердечки, у каждого свой вкус (MascotPlay).
//  • Тык: щелчок — фирменное движение по требованию.
//  • Разбудить: щелчок по спящему — вздрагивает («!»), зевает и смотрит на вас.
//  • Подкинуть: потяните и отпустите — летит, отскакивает от краёв шторки и возвращается; бросили слишком сильно —
//    злится.
//  • Настроение и дружба: чем чаще гладите, тем чаще он сам радуется и машет лапкой; давно не гладили — скучает
//    (тучка), пока не погладите. Дружбу хранит трей (событие "friend" → friendship.json → SetFriend при старте).
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ClaudeNotifier.Ui {
    public sealed partial class NotchView {
        // Дружба: 0..100 и когда последний раз гладили (UTC ticks, 0 — ещё ни разу). Пишет трей при старте.
        public static double Affection;
        public static long LastPetTicks;
        public static double SadAfterHours = 24;      // столько без поглаживаний — скучает (тесты уменьшают)
        public static double QuickSeconds = 8;        // сколько висят кнопки решения у маскота

        string playId;                 // сеанс главного маскота ("" — сеансов нет)
        DateTime dustAt = DateTime.MinValue;
        // Удар о край или пол: пружина сжатия главного маскота.
        void Bump(float v) { FaceMotion fm; if (playId != null && motions.TryGetValue(playId, out fm)) fm.Squash.Kick(v); }
        string playKind = "flatsphynx"; // его вид — для звуков
        bool purred;                   // за это поглаживание уже мурлыкал
        // Реакции на события сеансов: id сеанса ("" — главный маскот) → вид реакции и когда.
        readonly Dictionary<string, KeyValuePair<string, DateTime>> reactions = new Dictionary<string, KeyValuePair<string, DateTime>>();

        // Задача готова — joy, ошибка — panic, лимит — nervous. id пустой или неизвестный — главный маскот.
        public void React(string id, string kind) {
            if (kind != "joy" && kind != "panic" && kind != "nervous") return;
            string key = "";
            foreach (NotchItem x in items) if (x.Id == id) key = id;
            reactions[key] = new KeyValuePair<string, DateTime>(kind, DateTime.UtcNow);
            WakePlay();
        }

        public string ReactionOf(string id) {
            KeyValuePair<string, DateTime> r;
            if (reactions.TryGetValue(id ?? "", out r) && Since(r.Value) < 2.5) return r.Key;
            return null;
        }

        void ApplyReaction(NotchItem it, CatMood md, bool main) {
            KeyValuePair<string, DateTime> r;
            string id = it != null ? it.Id : "";
            if (!reactions.TryGetValue(id, out r) && !(main && reactions.TryGetValue("", out r))) return;
            double age = Since(r.Value);
            if (age >= 2.5) return;
            md.React = r.Key; md.ReactAge = (float)age;
            if (r.Key == "wave") md.Wave = (float)Math.Sin(Math.PI * Math.Min(1.0, age / 1.6));          // машет ушедшему
            if (r.Key == "notice") md.Brow = (float)Math.Sin(Math.PI * Math.Min(1.0, age / 1.2));        // удивился новенькому
        }
        RectangleF playHome;           // где маскот стоит (координаты раскладки), без сдвига от броска
        float pet;                     // 0..1 — гладят
        DateTime petLast = DateTime.MinValue, pokeAt = DateTime.MinValue, wakeAt = DateTime.MinValue, angryAt = DateTime.MinValue, playClock = DateTime.UtcNow;
        PointF petPrev;
        DateTime friendSent = DateTime.MinValue;
        bool friendDirty;
        bool playActive;
        // Бросок.
        bool dragging, dragMoved, flying;
        Point dragStart;
        PointF tossOff, tossVel, dragBase;
        float tossSpin;
        readonly List<KeyValuePair<DateTime, PointF>> dragHist = new List<KeyValuePair<DateTime, PointF>>();
        // Кнопки решения у маскота.
        string quickId;
        DateTime quickUntil = DateTime.MinValue;

        static double Since(DateTime at) { return at == DateTime.MinValue ? double.MaxValue : (DateTime.UtcNow - at).TotalSeconds; }
        static bool Asleep(NotchItem it) { return it == null || string.IsNullOrEmpty(it.State) || it.State == "none" || it.State == "stalled"; }

        public bool QuickActive { get { return quickId != null && DateTime.UtcNow < quickUntil; } }
        public float PetLevel { get { return pet; } }
        public bool Woken { get { return Since(wakeAt) < 3.5; } }
        public bool Poked { get { return Since(pokeAt) < 3.4; } }
        public bool Angry { get { return Since(angryAt) < 4; } }
        public bool Flying { get { return flying || dragging; } }
        public bool Missing { get { return LastPetTicks > 0 && (DateTime.UtcNow.Ticks - LastPetTicks) / 1e7 / 3600 > SadAfterHours; } }

        // Состояние для рисования главного маскота: проснулся — «ждёт» (глаза открыты).
        string PlayState(NotchItem it) {
            string st = it != null ? it.State : "none";
            if (Asleep(it) && Woken) return "waiting";
            return st;
        }

        // Настроение главного маскота от взаимодействия (поверх «Ага!» и взгляда из MoodFor).
        void PlayMood(NotchItem it, CatMood md, RectangleF face) {
            md.Play = true;
            md.Pet = pet;
            double poke = Since(pokeAt);
            if (poke < 3.4) md.PokeAge = (float)poke;
            double wake = Since(wakeAt);
            if (wake < 3.5) {
                md.Startle = (float)Math.Max(0, 1 - wake / 0.6);
                md.Yawn = wake > 0.7 && wake < 1.9;
                // Смотрит на вас.
                if (IsHandleCreated) {
                    Point c = PointToScreen(new Point((int)(face.X + face.Width / 2) + origin.X, (int)(face.Y + face.Height / 2) + origin.Y));
                    Point cur = SafeCursor();
                    md.HasLook = true; md.LookW = 1f;
                    md.LookX = Math.Max(-1f, Math.Min(1f, (cur.X - c.X) / (float)theme.S(160)));
                    md.LookY = Math.Max(-1f, Math.Min(1f, -(cur.Y - c.Y) / (float)theme.S(120)));
                }
            }
            md.Grumpy = Angry;
            // Полёт после броска: верх отстаёт от движения; приземлился — облачко пыли.
            if (flying || dragging) md.Shear += Math.Max(-0.35f, Math.Min(0.35f, -tossVel.X / theme.S(2500)));
            double dust = Since(dustAt);
            if (dust < 0.5) md.Dust = (float)dust;
            md.Sad = Missing && pet < 0.3f && !md.Grumpy;
            // Любит вас — иногда машет и радуется: чаще, чем крепче дружба (раз в 60 с → раз в 15 с).
            if (Animate && !md.Sad && !md.Grumpy && Affection >= 10 && it != null && (it.State == "waiting" || it.State == "working")) {
                double period = 60 - 0.45 * Math.Min(100, Affection);
                double ph = (T + (it.Id.GetHashCode() & 0xff) * 0.13) % period;
                if (ph < 1.6) {
                    md.Wave = (float)Math.Sin(Math.PI * ph / 1.6);
                    if (md.AhaAge < 0 && ph > 0.2 && ph < 1.0) md.AhaAge = (float)(ph - 0.2);
                }
            }
        }

        // Рисует главного маскота: бросок (сдвиг и поворот), место для щелчка, подсказка.
        void PaintPlayFace(Graphics g, RectangleF r, NotchItem it, CatMood md, int seed) {
            playId = it != null ? it.Id : "";
            playKind = Mascot.For(it != null ? it.Device : null);
            playHome = r;
            PlayMood(it, md, r);
            RectangleF at = r;
            at.Offset(tossOff.X, tossOff.Y);
            Rectangle hr = Rectangle.Round(RectangleF.Inflate(at, -at.Width * 0.12f, -at.Height * 0.04f));
            Hit(hr, "mascot");
            string tip = PlayTip(it);
            if (!string.IsNullOrEmpty(tip) && !dragging) { Rectangle tr = hr; tr.Offset(origin); tips.Insert(0, new KeyValuePair<Rectangle, string>(tr, tip)); }
            GraphicsState gs = null;
            if (tossOff.X != 0 || tossOff.Y != 0 || tossSpin != 0) {
                gs = g.Save();
                float cx = at.X + at.Width / 2, cy = at.Y + at.Height / 2;
                g.TranslateTransform(cx, cy); g.RotateTransform(tossSpin); g.TranslateTransform(-cx, -cy);
            }
            try { DrawMascot(g, at, it, PlayState(it), seed, md, MotionFor(it)); }
            finally { if (gs != null) g.Restore(gs); }
        }

        string PlayTip(NotchItem it) {
            string s = it == null ? "Сеансов нет — спит" : !string.IsNullOrEmpty(it.Hint) ? it.Hint : it.StateText;
            int hearts = (int)Math.Round(Math.Max(0, Math.Min(100, Affection)) / 20);
            string friend = "Дружба: " + new string('♥', hearts) + new string('♡', 5 - hearts);
            if (Missing) friend += " — скучает, погладьте";
            return (s ?? "") + "\n" + friend;
        }

        // --- Мышь ---
        bool PlayMouseDown(MouseEventArgs e, string hit) {
            if (e.Button != MouseButtons.Left || hit != "mascot") return false;
            dragging = true; dragMoved = false; dragStart = e.Location; dragBase = tossOff;
            flying = false;
            dragHist.Clear(); dragHist.Add(new KeyValuePair<DateTime, PointF>(DateTime.UtcNow, e.Location));
            return true;
        }

        bool PlayMouseMove(MouseEventArgs e, string hit) {
            if (dragging) {
                float dx = e.X - dragStart.X, dy = e.Y - dragStart.Y;
                if (!dragMoved && dx * dx + dy * dy > theme.S(5) * theme.S(5)) dragMoved = true;
                if (dragMoved && Animate) {
                    tossOff = ClampToss(new PointF(dragBase.X + dx, dragBase.Y + dy));
                    tossSpin = Math.Max(-25f, Math.Min(25f, dx * 0.15f));
                    dragHist.Add(new KeyValuePair<DateTime, PointF>(DateTime.UtcNow, e.Location));
                    if (dragHist.Count > 12) dragHist.RemoveAt(0);
                    WakePlay();
                    Invalidate();
                }
                return true;
            }
            if (hit == "mascot") {
                // Гладят: чем больше водите курсором, тем приятнее.
                float d = petPrev.IsEmpty ? 0 : (float)Math.Sqrt((e.X - petPrev.X) * (e.X - petPrev.X) + (e.Y - petPrev.Y) * (e.Y - petPrev.Y));
                petPrev = e.Location;
                if (d > 0 && d < theme.S(80)) {
                    pet = Math.Min(1f, pet + d / theme.S(220));
                    petLast = DateTime.UtcNow;
                    if (pet > 0.5f && !purred) { purred = true; MascotSound.Play("purr", playKind); }
                    WakePlay();
                }
            } else petPrev = PointF.Empty;
            return false;
        }

        bool PlayMouseUp(MouseEventArgs e) {
            if (!dragging || e.Button != MouseButtons.Left) return false;
            dragging = false;
            if (!dragMoved) { ClickArea("mascot", PointToScreen(e.Location)); return true; }
            // Скорость за последние ~80 мс.
            DateTime now = DateTime.UtcNow;
            PointF v = PointF.Empty;
            for (int i = 0; i < dragHist.Count; i++) {
                double dt = (now - dragHist[i].Key).TotalSeconds;
                if (dt > 0.12 && i < dragHist.Count - 1) continue;
                double span = (now - dragHist[i].Key).TotalSeconds;
                if (span < 0.01) span = 0.01;
                v = new PointF((float)((e.X - dragHist[i].Value.X) / span), (float)((e.Y - dragHist[i].Value.Y) / span));
                break;
            }
            tossVel = v;
            flying = true;
            float speed = (float)Math.Sqrt(v.X * v.X + v.Y * v.Y);
            if (speed > theme.S(1800)) { angryAt = now; Befriend(-3); MascotSound.Play("grr", playKind); }
            else MascotSound.Play("boing", playKind);
            WakePlay();
            return true;
        }

        // Щелчок по главному маскоту: решение (ждёт разрешения), разбудить (спит) или тык.
        void MascotClick() {
            NotchItem it = null;
            if (playId == null) { it = Expanded ? Selected : Main(); playId = it != null ? it.Id : ""; }   // ещё не рисовали
            else foreach (NotchItem x in items) if (x.Id == playId) it = x;
            if (it != null && !Expanded && it.State == "permission" && it.Actions.Length > 0) {
                if (QuickActive && quickId == it.Id) { quickId = null; Invalidate(); return; }
                quickId = it.Id; quickUntil = DateTime.UtcNow.AddSeconds(QuickSeconds);
                EventHandler h = CollapsedResize; if (h != null) h(this, EventArgs.Empty);
                Invalidate();
                return;
            }
            if (Asleep(it) && !Woken) { wakeAt = DateTime.UtcNow; MascotSound.Play("yawn", playKind); }
            else { pokeAt = DateTime.UtcNow; MascotSound.Play("boop", playKind); }
            WakePlay();
        }

        PointF ClampToss(PointF o) {
            float minX = -playHome.X + theme.S(2), maxX = lay.Width - playHome.Right - theme.S(2);
            float minY = -playHome.Y - playHome.Height * 0.2f, maxY = lay.Height - playHome.Bottom + playHome.Height * 0.05f;
            if (Expanded) { minY = -playHome.Y; maxY = Math.Max(0, lay.Height - playHome.Bottom); }
            return new PointF(Math.Max(minX, Math.Min(maxX, o.X)), Math.Max(minY, Math.Min(Math.Max(minY, maxY), o.Y)));
        }

        void WakePlay() { playActive = true; if (!anim.Enabled) anim.Start(); if (anim.Interval > 33) anim.Interval = 33; Invalidate(); }

        // Кадр взаимодействия (из AnimTick): полёт, возврат домой, спад поглаживания, дружба.
        // true — что-то движется, шторку надо перерисовать целиком.
        bool PlayTick() {
            DateTime now = DateTime.UtcNow;
            float dt = (float)Math.Max(0, Math.Min(0.1, (now - playClock).TotalSeconds));
            playClock = now;
            bool busy = dragging || flying;
            if (flying) {
                tossOff = new PointF(tossOff.X + tossVel.X * dt, tossOff.Y + tossVel.Y * dt);
                tossVel = new PointF(tossVel.X * (float)Math.Exp(-dt * 2.2), tossVel.Y * (float)Math.Exp(-dt * 2.2) + theme.S(900) * dt);   // трение и тяжесть
                PointF c = ClampToss(tossOff);
                if (c.X != tossOff.X) { tossVel.X = -tossVel.X * 0.65f; Bump(-2.2f); }   // отскок от края шторки
                if (c.Y != tossOff.Y) {
                    if (c.Y < tossOff.Y && Math.Abs(tossVel.Y) > theme.S(120)) { Bump(-3.2f); dustAt = DateTime.UtcNow; }   // шлёпнулся — пыль
                    tossVel.Y = -tossVel.Y * 0.55f; tossVel.X *= 0.9f;
                }
                tossOff = c;
                tossSpin += tossVel.X * dt * 0.35f;
                float speed = (float)Math.Sqrt(tossVel.X * tossVel.X + tossVel.Y * tossVel.Y);
                if (speed < theme.S(60)) flying = false;
            } else if (!dragging && (tossOff.X != 0 || tossOff.Y != 0 || tossSpin != 0)) {
                // Возвращается на место.
                float k = 1f - (float)Math.Exp(-dt * 7);
                tossOff = new PointF(tossOff.X * (1 - k), tossOff.Y * (1 - k));
                tossSpin *= 1 - k;
                if (Math.Abs(tossOff.X) < 0.5f && Math.Abs(tossOff.Y) < 0.5f && Math.Abs(tossSpin) < 0.5f) { tossOff = PointF.Empty; tossSpin = 0; }
                busy = true;
            }
            // Поглаживание: держится, пока гладят, потом плавно спадает. Дружба растёт, пока довольно жмурится.
            if (pet > 0) {
                if (Since(petLast) > 0.25) pet = Math.Max(0, pet - dt * 0.7f);
                if (pet < 0.2f) purred = false;
                if (pet > 0.3f) {
                    bool wasMissing = Missing;
                    Befriend(dt * 1.5);
                    LastPetTicks = now.Ticks;
                    if (wasMissing && playId != null) PulseAha(playId);   // соскучился — радость
                }
                busy = true;
            }
            if (friendDirty && (pet <= 0 || Since(friendSent) >= 5)) SendFriend();
            if (quickId != null && now >= quickUntil) { quickId = null; EventHandler h = CollapsedResize; if (h != null) h(this, EventArgs.Empty); busy = true; }
            if (QuickActive || Since(pokeAt) < 3.4 || Since(wakeAt) < 3.5 || Angry) busy = true;
            foreach (KeyValuePair<string, DateTime> rv in reactions.Values) if (Since(rv.Value) < 2.6) busy = true;
            if (Missing) busy = true;   // тучка с каплями
            if (busy) { playActive = true; return true; }
            if (playActive) { playActive = false; UpdateTimer(); Invalidate(); }
            return false;
        }

        void Befriend(double delta) {
            Affection = Math.Max(0, Math.Min(100, Affection + delta));
            friendDirty = true;
        }

        // Трею — сохранить дружбу (не чаще раза в 5 с, пока гладят, и в конце поглаживания).
        void SendFriend() {
            friendDirty = false;
            friendSent = DateTime.UtcNow;
            EventHandler<NotchEventArgs> h = Command;
            if (h != null) h(this, new NotchEventArgs("friend", "", Math.Round(Affection, 2).ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + LastPetTicks, Point.Empty));
        }

        // Кнопки решения посередине свёрнутой шторки. Возвращает занятую область (или пусто).
        Rectangle PaintQuick(Graphics g, int h, int left) {
            NotchItem it = null;
            if (QuickActive) foreach (NotchItem q in items) if (q.Id == quickId) it = q;
            if (it == null || it.State != "permission" || it.Actions.Length == 0) return Rectangle.Empty;
            int bh = Math.Min(h - theme.S(6), theme.S(24)), x0 = left, y = (h - bh) / 2;
            int x = x0, right = lay.Width - theme.S(16);
            foreach (string a in it.Actions) {
                string[] p = a.Split('|');
                string id = p[0], text = p.Length > 1 ? p[1] : p[0], style = p.Length > 2 ? p[2] : "secondary";
                int bw = TextRenderer.MeasureText(text, fBold).Width + theme.S(18);
                if (x + bw > right) break;
                Rectangle br = new Rectangle(x, y, bw, bh);
                PaintPill(g, br, text, style, "qact:" + id);
                Hit(br, "qact:" + id);
                x += bw + theme.S(5);
            }
            return x > x0 ? new Rectangle(x0, y, x - x0, bh) : Rectangle.Empty;
        }

        // Ширина, которую просят кнопки решения (свёрнутой нужно место).
        public int QuickWidth {
            get {
                NotchItem it = null;
                if (QuickActive) foreach (NotchItem x in items) if (x.Id == quickId) it = x;
                if (it == null || fBold == null) return 0;
                int w = 0;
                foreach (string a in it.Actions) { string[] p = a.Split('|'); w += TextRenderer.MeasureText(p.Length > 1 ? p[1] : p[0], fBold).Width + theme.S(23); }
                return w;
            }
        }

        // Щелчок по кнопке решения у маскота — ответ сеансу маскота, кнопки убираются.
        void QuickAnswer(string action, Point p) {
            string id = quickId;
            MarkSent(action);
            quickId = null;
            EventHandler h0 = CollapsedResize; if (h0 != null) h0(this, EventArgs.Empty);
            Invalidate();
            EventHandler<NotchEventArgs> h = Command;
            if (id != null && h != null) h(this, new NotchEventArgs("action", id, action, p));
        }
    }
}
