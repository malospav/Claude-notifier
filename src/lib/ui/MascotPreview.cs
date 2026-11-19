// claude-notifier: окно «Анимации» — по очереди показывает все движения выбранного маскота с подписью:
// статусы, «Ага!», фирменный номер, поглаживание, реакции на события, сценки, прыжок со сжатием, наряды.
// Каждая сценка — 2,6 с; щелчок — следующая, правый щелчок — предыдущая.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ClaudeNotifier.Ui {
    public sealed class MascotPreview : Form {
        public static readonly string[] Scenes = {
            "Работает", "Ждёт ответа", "«Ага!» — новое действие", "Задумался", "Ждёт решения", "Ошибка", "Спит",
            "Фирменный номер (щелчок)", "Гладят", "Задача готова — радость", "Ошибка — паника", "Лимит — нервничает",
            "Разбудили", "Подкинули слишком сильно", "Скучает", "Машет вам", "Потягивается", "Дремлет", "Прыжок",
            "Ночной колпак", "Новый год", "Хэллоуин" };
        const float SceneSeconds = 2.6f;

        readonly string kind;
        readonly Timer timer = new Timer();
        readonly DateTime born = DateTime.UtcNow;
        DateTime sceneAt = DateTime.UtcNow;
        int scene;
        readonly Spring squash = new Spring(1f);
        DateTime last = DateTime.UtcNow;
        Font fTitle, fSmall;

        public int Scene { get { return scene; } }

        public static MascotPreview Open(string kind, string title) {
            MascotPreview f = new MascotPreview(kind, title);
            f.Show();
            return f;
        }

        public MascotPreview(string kind, string title) {
            this.kind = Mascot.Normalize(kind);
            Text = "Анимации · " + (title ?? this.kind);
            FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(420, 330);
            BackColor = Color.FromArgb(18, 18, 20);
            TopMost = true;
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
            fTitle = new Font("Segoe UI Semibold", 12f); fSmall = new Font("Segoe UI", 9f);
            timer.Interval = 16;
            timer.Tick += delegate { Step(); Invalidate(); };
            timer.Start();
            MouseUp += delegate (object s, MouseEventArgs e) { Go(e.Button == MouseButtons.Right ? -1 : 1); };
        }

        public void Go(int d) {
            scene = ((scene + d) % Scenes.Length + Scenes.Length) % Scenes.Length;
            sceneAt = DateTime.UtcNow;
            squash.Kick(-2.4f);   // переход между сценками — мягкий шлепок
        }

        void Step() {
            DateTime now = DateTime.UtcNow;
            float dt = (float)Math.Min(0.1, (now - last).TotalSeconds); last = now;
            squash.Step(dt, 1f, 220f, 0.3f);
            if ((now - sceneAt).TotalSeconds >= SceneSeconds) Go(1);
        }

        // Состояние и настроение сценки на её секунде a.
        public static string Build(int scene, float a, float t, CatMood m) {
            string st = "waiting";
            switch (scene) {
                case 0: st = "working"; break;
                case 1: break;
                case 2: st = "working"; m.AhaAge = a % 1.2f < 0.8f ? a % 1.2f : -1f; if (m.AhaAge >= 0) m.Brow = (float)Math.Sin(Math.PI * m.AhaAge / 0.8f); break;
                case 3: st = "working"; m.Deep = true; m.Cross = a > 1.0f; break;
                case 4: st = "permission"; break;
                case 5: st = "error"; break;
                case 6: st = "none"; break;
                case 7: m.Play = true; m.PokeAge = a; break;
                case 8: m.Play = true; m.Pet = Math.Min(1f, a * 1.5f); break;
                case 9: m.React = "joy"; m.ReactAge = a % 2.5f; break;
                case 10: m.React = "panic"; m.ReactAge = a % 2.5f; break;
                case 11: m.React = "nervous"; m.ReactAge = a % 2.5f; break;
                case 12: m.Play = true; m.Startle = Math.Max(0, 1 - a / 0.6f); m.Yawn = a > 0.7f && a < 1.9f; break;
                case 13: m.Play = true; m.Grumpy = true; break;
                case 14: m.Play = true; m.Sad = true; break;
                case 15: m.Play = true; m.Wave = (float)Math.Sin(Math.PI * Math.Min(1f, a / 2.4f)); break;
                case 16: { float b = (float)Math.Sin(Math.PI * Math.Min(1f, a / 2.4f)); m.SquashY *= 1f + 0.16f * b; if (b > 0.3f) { m.EyesOverride = "closed"; m.MouthOverride = "o"; } break; }
                case 17: { float s = MascotMotion.Smooth(Math.Min(1f, a / 1.8f)); m.Lean = 16f * s; m.Lift = -0.02f * s; if (s > 0.2f) { m.EyesOverride = "closed"; m.MouthOverride = "flat"; } break; }
                case 18: {
                    // Прыжок: присел — вытянулся в полёте — шлёпнулся — пыль.
                    float p = a % 1.3f;
                    if (p < 0.25f) m.SquashY *= 1f - 0.2f * (float)Math.Sin(Math.PI * p / 0.25f);
                    else if (p < 0.85f) { float f = (p - 0.25f) / 0.6f; m.Lift = 0.45f * 4 * f * (1 - f); m.SquashY *= 1.12f; }
                    else { float f = (p - 0.85f) / 0.45f; m.SquashY *= 1f - 0.22f * (float)Math.Sin(Math.PI * Math.Min(1f, f)); m.Dust = f * 0.5f; }
                    break;
                }
                case 19: m.Play = true; m.Outfit = "night"; break;
                case 20: m.Play = true; m.Outfit = "newyear"; break;
                case 21: m.Play = true; m.Outfit = "halloween"; break;
            }
            return st;
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(BackColor);
            float t = (float)(DateTime.UtcNow - born).TotalSeconds, a = (float)(DateTime.UtcNow - sceneAt).TotalSeconds;
            CatMood m = new CatMood();
            m.SquashY = squash.X;
            string st = Build(scene, a, t, m);
            RectangleF r = new RectangleF(110, 50, 200, 160);
            try { Mascot.PaintKind(g, r, kind, st, t, 3, true, m); } catch { }
            TextRenderer.DrawText(g, Scenes[scene], fTitle, new Rectangle(0, 238, ClientSize.Width, 28), Color.White, TextFormatFlags.HorizontalCenter);
            TextRenderer.DrawText(g, (scene + 1) + " из " + Scenes.Length + " · щелчок — дальше, правый — назад", fSmall, new Rectangle(0, 270, ClientSize.Width, 22), Color.FromArgb(142, 142, 147), TextFormatFlags.HorizontalCenter);
            // Полоска времени сценки.
            float k = Math.Min(1f, a / SceneSeconds);
            using (SolidBrush b = new SolidBrush(Color.FromArgb(58, 58, 60))) g.FillRectangle(b, 60, 304, ClientSize.Width - 120, 3);
            using (SolidBrush b = new SolidBrush(Color.FromArgb(217, 119, 87))) g.FillRectangle(b, 60, 304, (ClientSize.Width - 120) * k, 3);
        }

        protected override void Dispose(bool disposing) {
            if (disposing) { timer.Dispose(); if (fTitle != null) fTitle.Dispose(); if (fSmall != null) fSmall.Dispose(); }
            base.Dispose(disposing);
        }
    }
}
