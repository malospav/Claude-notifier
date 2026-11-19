// claude-notifier: отклик интерфейса шторки — всё плавно и сразу.
//  • Наведение — подсветка нарастает за ~0,1 с, а не щёлкает; нажатие — кнопка и строка чуть «проседают».
//  • Тумблер — ползунок едет, цвет перетекает; полоски лимитов — подъезжают к новому значению.
//  • Прокрутка колёсиком — плавная; смена страницы и раздела настроек — содержимое въезжает и проявляется,
//    подсветка выбранного раздела переезжает к новому.
//  • Ответ кнопкой («Разрешить», «Продолжай») — на кнопке сразу «✓», пока трей отправляет.
// Значения — по реальному времени (экспонента), «меньше движения» в Windows — без анимации.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace ClaudeNotifier.Ui {
    public sealed partial class NotchView {
        sealed class AnimValue { public float Cur, Target, Rate; public DateTime Seen; }
        readonly Dictionary<string, AnimValue> anims = new Dictionary<string, AnimValue>();
        readonly Dictionary<string, float> scrollShown = new Dictionary<string, float>();
        readonly Dictionary<string, DateTime> sentAt = new Dictionary<string, DateTime>();
        DateTime uiClock = DateTime.UtcNow;
        string pressed;
        bool uiBusy;

        public bool UiBusy { get { return uiBusy; } }
        // Для тестов: ход перехода страницы (0 → 1) и положение ползунка тумблера.
        public float PageProgress { get { AnimValue a; return anims.TryGetValue("page", out a) ? a.Cur : 1f; } }
        // Для тестов: места щелчков (в координатах окна) с их id.
        public KeyValuePair<Rectangle, string>[] HitList() { return hits.ToArray(); }
        public float SwitchPos(string key) { AnimValue a; return anims.TryGetValue("sw:" + key, out a) ? a.Cur : -1f; }

        // Плавное значение: тянется к цели со скоростью rate (1/с). Первый раз — сразу цель.
        float Anim(string key, float target, float rate) {
            AnimValue a;
            if (!anims.TryGetValue(key, out a)) { a = new AnimValue(); a.Cur = target; anims[key] = a; }
            a.Target = target; a.Rate = rate; a.Seen = DateTime.UtcNow;
            if (!Animate) a.Cur = target;
            else if (Math.Abs(a.Cur - target) > 0.002f) WakeUi();
            return a.Cur;
        }

        // Начать значение заново с from (переход страницы, раздела).
        void AnimFrom(string key, float from) {
            AnimValue a;
            if (!anims.TryGetValue(key, out a)) { a = new AnimValue(); a.Target = 1f; anims[key] = a; }
            a.Cur = Animate ? from : a.Target;
            a.Seen = DateTime.UtcNow;
            WakeUi();
        }

        float Hot(string id) { return id == null ? 0f : Anim("h:" + id, hover == id ? 1f : 0f, 22f); }
        float Press(string id) { return id == null ? 0f : Anim("p:" + id, pressed != null && pressed == id && hover == id ? 1f : 0f, pressed == id ? 45f : 14f); }

        void WakeUi() {
            uiBusy = true;
            if (!anim.Enabled && Visible) anim.Start();
            if (anim.Interval > 16) anim.Interval = 16;
        }

        // Кадр: значения подтягиваются к целям. true — что-то ещё движется.
        bool UiTick() {
            DateTime now = DateTime.UtcNow;
            float dt = (float)Math.Max(0, Math.Min(0.1, (now - uiClock).TotalSeconds));
            uiClock = now;
            bool busy = false;
            List<string> stale = null;
            foreach (KeyValuePair<string, AnimValue> kv in anims) {
                AnimValue a = kv.Value;
                if ((now - a.Seen).TotalSeconds > 2) { if (stale == null) stale = new List<string>(); stale.Add(kv.Key); continue; }
                float d = a.Target - a.Cur;
                if (Math.Abs(d) < 0.002f) { a.Cur = a.Target; continue; }
                a.Cur += d * (1f - (float)Math.Exp(-dt * a.Rate));
                busy = true;
            }
            if (stale != null) foreach (string k in stale) anims.Remove(k);
            // Прокрутка.
            foreach (string page in new List<string>(scrollShown.Keys)) {
                int target; scrolls.TryGetValue(page, out target);
                float cur = scrollShown[page], d = target - cur;
                if (Math.Abs(d) < 0.5f) { scrollShown[page] = target; continue; }
                scrollShown[page] = cur + d * (1f - (float)Math.Exp(-dt * 16));
                busy = true;
            }
            uiBusy = busy;
            return busy;
        }

        // Показанная прокрутка страницы (плавно догоняет цель из scrolls).
        int ShownScroll(int target) {
            float s;
            if (!scrollShown.TryGetValue(Page, out s) || !Animate) { scrollShown[Page] = target; return target; }
            if (Math.Abs(s - target) > 0.5f) WakeUi();
            return (int)Math.Round(s);
        }

        void ResetScroll(string page) { scrolls[page] = 0; scrollShown[page] = 0; }

        // Переход страницы: 0 → 1 за ~0,2 с (содержимое въезжает справа на 16 px и проявляется из чёрного).
        float PageK() { return Anim("page", 1f, 13f); }
        float SectionK() { return Anim("section", 1f, 15f); }

        // Кроссфейд страниц и разделов: снимок того, что было на экране, тает поверх нового (~0,22 с). Без чёрного
        // провала и без сдвига — ничего не мигает и не едет.
        Bitmap pageShot;

        void SnapPage() {
            if (pageShot != null) { pageShot.Dispose(); pageShot = null; }
            if (!Animate || !Expanded || !painted || lay.Width <= 0 || lay.Height <= 0) return;
            List<KeyValuePair<Rectangle, string>> keepHits = new List<KeyValuePair<Rectangle, string>>(hits);
            List<KeyValuePair<Rectangle, string>> keepTips = new List<KeyValuePair<Rectangle, string>>(tips);
            List<RectangleF> keepFaces = new List<RectangleF>(faceRects);
            Bitmap b = new Bitmap(lay.Width, lay.Height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            try {
                using (Graphics g2 = Graphics.FromImage(b)) {
                    g2.Clear(Color.Black);
                    g2.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                    PaintExpanded(g2);
                }
                pageShot = b;
                AnimFrom("page", 0f);
            } catch { b.Dispose(); }
            finally {
                hits.Clear(); hits.AddRange(keepHits);
                tips.Clear(); tips.AddRange(keepTips);
                faceRects.Clear(); faceRects.AddRange(keepFaces);
            }
        }

        void PaintPageShot(Graphics g) {
            if (pageShot == null) return;
            float k = PageK();
            if (k >= 0.995f || !Animate) { pageShot.Dispose(); pageShot = null; return; }
            float a = 1f - MascotMotion.Smooth(k);
            using (System.Drawing.Imaging.ImageAttributes ia = new System.Drawing.Imaging.ImageAttributes()) {
                System.Drawing.Imaging.ColorMatrix cm = new System.Drawing.Imaging.ColorMatrix(); cm.Matrix33 = a;
                ia.SetColorMatrix(cm);
                // Верхняя полоса (вкладки, лимиты, звук) одинакова на всех страницах — её не смешиваем.
                int top = theme.S(10) + theme.S(34) + theme.S(6);
                int h = Math.Min(pageShot.Height, lay.Height) - top;
                if (h > 0) g.DrawImage(pageShot, new Rectangle(0, top, pageShot.Width, h), 0, top, pageShot.Width, h, GraphicsUnit.Pixel, ia);
            }
        }

        // Кнопка ответа нажата — на ней «✓» на 1,5 с.
        void MarkSent(string actId) { sentAt[actId] = DateTime.UtcNow; WakeUi(); }
        public bool Sent(string actId) { DateTime t; return sentAt.TryGetValue(actId, out t) && (DateTime.UtcNow - t).TotalSeconds < 1.5; }

        // Капсула с плавным наведением, «проседанием» при нажатии и галочкой после ответа.
        void PaintPill(Graphics g, Rectangle br, string text, string style, string id) {
            float h = Hot(id), p = Press(id);
            bool sent = id != null && (id.StartsWith("act:") || id.StartsWith("qact:")) && Sent(id.Substring(id.IndexOf(':') + 1));
            Color baseC = style == "primary" ? theme.Accent : Theme.Hex(0x2C2C2E);
            Color hotC = style == "primary" ? theme.AccentHover : Theme.Hex(0x3A3A3C);
            Color fill = Draw.Mix(baseC, hotC, h);
            if (p > 0.01f) fill = Draw.Mix(fill, Color.Black, 0.18f * p);
            if (sent) fill = Draw.Mix(fill, Theme.Hex(0x30D158), 0.55f);
            float inset = p * Math.Max(1f, br.Height * 0.05f);
            RectangleF r = new RectangleF(br.X + inset, br.Y + inset, br.Width - inset * 2, br.Height - inset * 2);
            Draw.Fill(g, r, r.Height / 2f, fill);
            Color tc = style == "destructive" && !sent ? Theme.Hex(0xFF6961) : Color.White;
            // С галочкой не помещается — одна галочка.
            string label = text;
            if (sent) label = TextRenderer.MeasureText("✓ " + text, fBold).Width <= br.Width - theme.S(8) ? "✓ " + text : "✓";
            TextRenderer.DrawText(g, label, fBold, br, tc, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }

        // Тумблер: ползунок едет, цвет перетекает; при нажатии ползунок чуть вытягивается (как в iOS).
        void PaintSwitch(Graphics g, Rectangle t, string key, bool on, string hitId) {
            float k = Anim("sw:" + key, on ? 1f : 0f, 16f), p = Press(hitId);
            Draw.Fill(g, t, t.Height / 2f, Draw.Mix(Theme.Hex(0x39393D), Theme.Hex(0x30D158), k));
            float kd = t.Height - theme.S(4), stretch = kd * 0.18f * p;
            float x0 = t.X + theme.S(2), x1 = t.Right - theme.S(2) - kd - stretch;
            float kx = x0 + (x1 - x0) * k;
            Draw.Fill(g, new RectangleF(kx, t.Y + theme.S(2), kd + stretch, kd), kd / 2, Color.White);
        }
    }
}
