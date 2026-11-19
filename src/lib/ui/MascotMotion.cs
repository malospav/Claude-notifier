// claude-notifier: движение маскота целиком — пружины, сжатие и растяжение, запаздывание верха, подъём, наклон.
// Шторка держит у каждого маскота пружины (NotchMotion.cs) и кладёт их значения в CatMood; здесь они превращаются
// в преобразование фигуры вокруг точки опоры внизу. Фигура остаётся цельной (как у Rigid), но становится мягкой:
// перед прыжком приседает, в полёте вытягивается, при приземлении шлёпается, верх догоняет низ при движении вбок.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace ClaudeNotifier.Ui {
    // Пружина с затуханием: значение тянется к цели, перелетает и успокаивается. Шаг — по реальному времени
    // (подшаги по 1/240 с — устойчиво и при 10, и при 60 кадрах в секунду).
    public sealed class Spring {
        public float X, V;
        public Spring(float x) { X = x; }
        // stiffness — жёсткость (чем больше, тем быстрее), damping — доля критического затухания (меньше 1 — с перелётом).
        public void Step(float dt, float target, float stiffness, float damping) {
            float c = 2f * (float)Math.Sqrt(stiffness) * damping;
            int n = Math.Max(1, (int)Math.Ceiling(dt * 240));
            float h = dt / n;
            for (int i = 0; i < n; i++) {
                float a = stiffness * (target - X) - c * V;
                V += a * h;
                X += V * h;
            }
        }
        public void Kick(float v) { V += v; }
        public bool Settled(float target) { return Math.Abs(X - target) < 0.002f && Math.Abs(V) < 0.01f; }
        public void Snap(float target) { X = target; V = 0; }
    }

    public static class MascotMotion {
        // Преобразование фигуры: подъём, наклон, запаздывание верха, сжатие с сохранением объёма — вокруг опоры.
        public static void Apply(Graphics g, RectangleF r, float squashY, float shear, float lift, float lean) {
            float cx = r.X + r.Width / 2f, by = r.Bottom - r.Height * 0.07f;
            float sq = Math.Max(0.55f, Math.Min(1.6f, squashY));
            g.TranslateTransform(cx, by - lift * r.Height);
            if (Math.Abs(lean) > 0.05f) g.RotateTransform(lean);
            if (Math.Abs(shear) > 0.002f) using (Matrix sh = new Matrix(1, 0, -Math.Max(-0.6f, Math.Min(0.6f, shear)), 1, 0, 0)) g.MultiplyTransform(sh);
            if (Math.Abs(sq - 1f) > 0.002f) g.ScaleTransform(1f / (float)Math.Sqrt(sq), sq);
            g.TranslateTransform(-cx, -by);
        }

        // Плавное «с перелётом» 0 → 1 (вход маскота, перелёт при раскрытии шторки).
        public static float EaseOutBack(float x) {
            x = Math.Max(0f, Math.Min(1f, x));
            const float c1 = 1.70158f, c3 = c1 + 1f;
            float p = x - 1f;
            return 1f + c3 * p * p * p + c1 * p * p;
        }
        public static float Smooth(float x) { x = Math.Max(0f, Math.Min(1f, x)); return x * x * (3 - 2 * x); }
    }
}
