// claude-notifier: главный маскот шторки реагирует на вас (поверх NotchPlay — гладить, тыкать, подкидывать).
//  • Подлетели курсором к шторке (после паузы) — оживляется: подскок, брови вверх, машет лапкой.
//  • Трясёте курсором над ним — кружится голова: глаза-спиральки, звёздочки вокруг головы, покачивается.
//  • Печатаете ответ — смотрит на поле и кивает на каждую клавишу; отправили ответ или нажали кнопку
//    решения — довольно кивает, над головой зелёная галочка.
//  • Вернулись к компьютеру (после «вас нет») — встречает: удивился, улыбнулся, помахал.
//  • Двойной щелчок — сальто.
//  • Курсор замер над ним — тянется к курсору и жмурится («нюхает»).
// «Меньше движения» в Windows — ничего из этого (только обычные статусы).
using System;
using System.Collections.Generic;
using System.Drawing;

namespace ClaudeNotifier.Ui {
    public sealed partial class NotchView {
        public static double HelloAfterSeconds = 6, HelloEvery = 20;   // тесты уменьшают
        DateTime helloAt = DateTime.MinValue, dizzyAt = DateTime.MinValue, okAt = DateTime.MinValue, keyAt = DateTime.MinValue,
            trickAt = DateTime.MinValue, greetAt = DateTime.MinValue, lastMascotClick = DateTime.MinValue, outsideSince = DateTime.UtcNow,
            hoverStillSince = DateTime.MinValue;
        bool cursorInside;
        Point hoverPt;
        // Тряска: последние движения курсора над маскотом (время, x).
        readonly List<KeyValuePair<DateTime, PointF>> shakeTrail = new List<KeyValuePair<DateTime, PointF>>();

        public bool Dizzy { get { return Since(dizzyAt) < 2.6; } }
        public bool Greeting { get { return Since(greetAt) < 2.2; } }
        public bool SaidHello { get { return Since(helloAt) < 1.6; } }

        // Вы что-то сделали в шторке (ответ, решение) — маскот одобрительно кивает.
        public void Approve() { if (!Animate) return; okAt = DateTime.UtcNow; Bump(-1.6f); WakePlay(); }
        // Вернулись к компьютеру — встречает.
        public void Greet() { if (!Animate) return; greetAt = DateTime.UtcNow; Bump(2.6f); WakePlay(); }
        // Нажали клавишу в поле ответа — кивок.
        void UserKey() { if (!Animate) return; keyAt = DateTime.UtcNow; if (Since(okAt) > 1.2) Bump(-0.9f); WakePlay(); }

        // Двойной щелчок по маскоту — сальто. true — щелчок второй (трюк вместо тыка).
        bool MascotDoubleClick() {
            DateTime now = DateTime.UtcNow;
            bool dbl = (now - lastMascotClick).TotalSeconds < 0.4 && Animate && Since(trickAt) > 0.9;
            lastMascotClick = dbl ? DateTime.MinValue : now;
            if (dbl) { trickAt = now; Bump(2.8f); MascotSound.Play("boing", playKind); WakePlay(); }
            return dbl;
        }

        // Угол сальто (градусы) и подъём (доли высоты) для рисования главного маскота.
        float TrickAngle { get { double t = Since(trickAt); return t < 0.75 ? (float)(360 * MascotMotion.Smooth((float)(t / 0.75))) : 0f; } }
        float TrickLift { get { double t = Since(trickAt); return t < 0.75 ? (float)Math.Sin(Math.PI * t / 0.75) : 0f; } }

        // Тряска курсором над маскотом: быстро и туда-сюда (не меньше 5 разворотов за 1,2 с) — голова кружится.
        void TrackShake(Point p) {
            if (!Animate || Dizzy) return;
            DateTime now = DateTime.UtcNow;
            shakeTrail.Add(new KeyValuePair<DateTime, PointF>(now, p));
            shakeTrail.RemoveAll(delegate (KeyValuePair<DateTime, PointF> k) { return (now - k.Key).TotalSeconds > 1.2; });
            if (shakeTrail.Count < 6) return;
            float dist = 0; int turns = 0, lastSign = 0;
            for (int i = 1; i < shakeTrail.Count; i++) {
                float dx = shakeTrail[i].Value.X - shakeTrail[i - 1].Value.X, dy = shakeTrail[i].Value.Y - shakeTrail[i - 1].Value.Y;
                dist += (float)Math.Sqrt(dx * dx + dy * dy);
                int s = Math.Abs(dx) < theme.S(3) ? 0 : Math.Sign(dx);
                if (s != 0) { if (lastSign != 0 && s != lastSign) turns++; lastSign = s; }
            }
            if (turns >= 5 && dist > theme.S(900)) {
                dizzyAt = now; shakeTrail.Clear();
                pet = 0;   // это не поглаживание
                MascotSound.Play("boop", playKind);
                WakePlay();
            }
        }

        // Каждый кадр (из PlayTick): курсор подлетел к шторке — «привет»; курсор замер над маскотом.
        // true — идёт реакция, рисовать каждый кадр.
        bool ReactTick() {
            if (!Animate || !IsHandleCreated) return false;
            DateTime now = DateTime.UtcNow;
            Point c = PointToClient(SafeCursor());
            bool inside = ShapeRect.Contains(c);
            // «Привет» — только свёрнутой шторке и не в момент раскрытия (курсор пришёл, чтобы её открыть).
            if (inside && !cursorInside && !Expanded && !Morphing && (now - outsideSince).TotalSeconds > HelloAfterSeconds && Since(helloAt) > HelloEvery && !dragging && !flying) {
                helloAt = now; Bump(2.2f);
            }
            if (!inside && cursorInside) outsideSince = now;
            cursorInside = inside;
            // Курсор неподвижно над маскотом.
            if (hover == "mascot" && !dragging) {
                if (c != hoverPt) { hoverPt = c; hoverStillSince = now; }
            } else hoverStillSince = DateTime.MinValue;
            return SaidHello || Dizzy || Greeting || Since(okAt) < 1.3 || Since(keyAt) < 1.6 || Since(trickAt) < 0.8 || Sniffing;
        }

        bool Sniffing { get { return hoverStillSince != DateTime.MinValue && Since(hoverStillSince) > 1.0 && pet < 0.2f && !Dizzy && !Morphing && !FlyActive && Since(openedAt) > 1.5; } }

        // Шторку раскрыли или свернули — недоигранные «привет» и подскоки отменяются: раскрытие спокойное.
        DateTime openedAt = DateTime.MinValue;
        public void CalmForMorph(bool opening) {
            helloAt = DateTime.MinValue; greetAt = DateTime.MinValue; hoverStillSince = DateTime.MinValue; openedAt = DateTime.UtcNow; SettleMotions();
            openGreetAt = opening && Animate ? DateTime.UtcNow : DateTime.MinValue;
        }

        // Раскрыли шторку — маскоты по очереди (главный первым, дальше слева направо) замечают вас: брови вверх и
        // круглые глаза («ой!»), потом довольные «^ ^» и взгляд на вас; главный ещё машет лапкой, над ним — сердечко.
        // Тело не прыгает и не тянется: меняются только мордочки.
        DateTime openGreetAt = DateTime.MinValue;
        public bool OpenGreeting { get { return Since(openGreetAt) < 2.6; } }

        void OpenGreetMood(NotchItem it, CatMood md) {
            if (!Animate || !Expanded || openGreetAt == DateTime.MinValue || it == null) return;
            bool main = it.Id == SelectedId;
            int idx = main ? 0 : Math.Min(8, Math.Max(0, items.IndexOf(it)) + 1);
            double a = Since(openGreetAt) - 0.2 - idx * 0.09;   // после проявления содержимого, по очереди
            if (a < 0 || a > 1.6) return;
            if (a < 0.32) { md.EyesOverride = "wide"; md.Brow = Math.Max(md.Brow, (float)Math.Sin(Math.PI * 0.5 * a / 0.32)); }
            else if (a < 1.35) { md.EyesOverride = "smile"; md.Brow = Math.Max(md.Brow, (float)Math.Max(0, 1 - (a - 0.32) / 0.4)); }
            float w = (float)Math.Min(1.0, Math.Min(a / 0.15, (1.6 - a) / 0.3));
            md.HasLook = true; md.LookX = 0f; md.LookY = 0.3f; md.LookW = Math.Max(0f, w);   // смотрят на вас
            if (main) {
                md.Wave = Math.Max(md.Wave, (float)Math.Sin(Math.PI * Math.Max(0, Math.Min(1, (a - 0.3) / 1.1))));
                md.OpenAge = (float)a;
            }
        }

        // Настроение главного маскота от ваших действий (из PlayMood).
        void UserMood(CatMood md, RectangleF face) {
            if (!Animate) return;
            double h = Since(helloAt);
            if (h < 1.6) {
                float b = (float)Math.Sin(Math.PI * h / 1.6);
                md.Brow = Math.Max(md.Brow, b);
                md.Wave = Math.Max(md.Wave, (float)Math.Sin(Math.PI * Math.Min(1.0, h / 1.4)));
                if (h < 0.55) md.EyesOverride = "wide";
            }
            double gr = Since(greetAt);
            if (gr < 2.2) {
                md.Wave = Math.Max(md.Wave, (float)Math.Sin(Math.PI * Math.Min(1.0, gr / 1.8)));
                md.EyesOverride = gr < 0.5 ? "wide" : "smile";
                md.Brow = Math.Max(md.Brow, (float)Math.Max(0, 1 - gr / 0.8));
            }
            double k = Since(keyAt);
            if (k < 1.6) {
                // Печатаете — смотрит на поле ответа (вниз) и чуть кивает.
                md.HasLook = true; md.LookW = (float)Math.Min(1.0, (1.6 - k) / 0.4); md.LookX = 0.25f; md.LookY = -0.9f;
            }
            double ok = Since(okAt);
            if (ok < 1.3) {
                md.OkAge = (float)ok;
                md.EyesOverride = "smile";
                md.SquashY *= 1f - 0.07f * (float)Math.Abs(Math.Sin(ok * Math.PI * 2.4)) * (float)(1 - ok / 1.3);   // кивает дважды
            }
            double dz = Since(dizzyAt);
            if (dz < 2.6) {
                float fade = (float)Math.Min(1.0, (2.6 - dz) / 0.5);
                md.Dizzy = (float)dz;
                md.EyesOverride = "spiral"; md.MouthOverride = "wavy";
                md.Lean += 10f * (float)Math.Sin(T * 6.5) * fade;
                md.HasLook = false;
            }
            if (Sniffing && md.EyesOverride == null) {
                // Тянется к курсору и жмурится.
                float s = (float)Math.Min(1.0, (Since(hoverStillSince) - 1.0) / 0.5);
                float dir = hoverPt.X - origin.X < face.X + face.Width / 2 ? -1f : 1f;
                md.Lean += 9f * dir * s; md.Lift += 0.03f * s;
                md.EyesOverride = "smile";
                md.Brow = Math.Max(md.Brow, 0.3f * s);
            }
            float tl = TrickLift;
            if (tl > 0) { md.Lift += 0.45f * tl; md.SquashY *= 1f + 0.12f * tl; md.EyesOverride = "happy"; }
        }
    }
}
