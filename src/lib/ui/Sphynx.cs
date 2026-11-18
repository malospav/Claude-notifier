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
    // Настоящая 3D-модель сфинкса (WPF 3D: сетки с нормалями, буфер глубины, трёхточечный свет — как
    // в three.js: ключевой, заполняющий, контровой и общий). Сцена своя у каждого потока; каждый кадр
    // рендерится в картинку с двойной детализацией и рисуется уменьшенной — без лесенок.
    public sealed class SphynxPose {
        public string State = "waiting";
        public float Yaw, Pitch, Roll, Bob, Breathe = 1f;
        public float EarL, EarR;            // >0 — кончик уха отклоняется наружу и вниз, <0 — торчком
        public bool EarsDown;               // ошибка — уши обвисли
        public float GazeX, GazeY;          // −1..1 — глаза смещаются в глазницах
        public float EyeScale = 1f;         // «Ага!» — глаза больше
        public float Open = 1f;             // 1 — открыты, 0 — закрыты (моргание, сон), 0,5 — прищур
        public float Yawn;                  // 0..1 — рот открыт
        public bool Tongue;                 // кончик языка
        public bool CrossEyes;              // ошибка — глаза-крестики (рисуются поверх)
    }

    public static class Sphynx3D {
        sealed class Scene {
            public System.Windows.Controls.Viewport3D View;
            public System.Windows.Media.Media3D.Model3DGroup Head;
            public System.Windows.Media.Media3D.Transform3DGroup HeadXf;
            public System.Windows.Media.Media3D.AxisAngleRotation3D Yaw, Pitch, Roll;
            public System.Windows.Media.Media3D.TranslateTransform3D Bob;
            public System.Windows.Media.Media3D.ScaleTransform3D Breathe;
            public System.Windows.Media.Media3D.AxisAngleRotation3D EarL, EarR;
            public System.Windows.Media.Media3D.ScaleTransform3D EyeLS, EyeRS;
            public System.Windows.Media.Media3D.TranslateTransform3D EyeLT, EyeRT;
            public System.Windows.Media.Media3D.ScaleTransform3D Mouth;
            public System.Windows.Media.Media3D.ScaleTransform3D Tongue;
            public System.Windows.Media.Media3D.DiffuseMaterial SkinMat, InnerMat;
            public System.Windows.Media.SolidColorBrush SkinBrush, InnerBrush, SocketBrush;
            public System.Windows.Media.Imaging.RenderTargetBitmap Rtb;
            public int W, H;
        }

        [ThreadStatic] static Scene scene;
        [ThreadStatic] static bool failed;
        [ThreadStatic] static int failures;   // подряд неудачных рендеров: разовый сбой (нехватка памяти) не отключает 3D навсегда
        const int MaxFailures = 3;
        public static bool Available { get { return !failed; } }

        public const double CamDist = 4.4, CamY = 0.22, Fov = 30;

        static System.Windows.Media.Media3D.Point3D P(double x, double y, double z) { return new System.Windows.Media.Media3D.Point3D(x, y, z); }
        static System.Windows.Media.Media3D.Vector3D V(double x, double y, double z) { return new System.Windows.Media.Media3D.Vector3D(x, y, z); }
        static System.Windows.Media.Color C(int rgb) { return System.Windows.Media.Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb); }

        // Эллипсоид: UV-сфера с аналитическими нормалями (гладкий свет без граней).
        static System.Windows.Media.Media3D.MeshGeometry3D Ellipsoid(double cx, double cy, double cz, double a, double b, double c, int seg) {
            var m = new System.Windows.Media.Media3D.MeshGeometry3D();
            for (int i = 0; i <= seg; i++) {
                double th = Math.PI * i / seg;
                for (int j = 0; j <= seg * 2; j++) {
                    double ph = 2 * Math.PI * j / (seg * 2);
                    double x = Math.Sin(th) * Math.Cos(ph), y = Math.Cos(th), z = Math.Sin(th) * Math.Sin(ph);
                    m.Positions.Add(P(cx + a * x, cy + b * y, cz + c * z));
                    var n = V(x / a, y / b, z / c); n.Normalize();
                    m.Normals.Add(n);
                }
            }
            int row = seg * 2 + 1;
            for (int i = 0; i < seg; i++)
                for (int j = 0; j < seg * 2; j++) {
                    int p0 = i * row + j, p1 = p0 + 1, p2 = p0 + row, p3 = p2 + 1;
                    m.TriangleIndices.Add(p0); m.TriangleIndices.Add(p1); m.TriangleIndices.Add(p2);
                    m.TriangleIndices.Add(p1); m.TriangleIndices.Add(p3); m.TriangleIndices.Add(p2);
                }
            return m;
        }

        // Ухо: изогнутая раковина — конус с плоским эллиптическим основанием; вершина — кончик уха.
        // inner — внутренняя сторона (розовая), чуть меньше и впереди.
        static System.Windows.Media.Media3D.MeshGeometry3D Ear(int side, bool inner) {
            var m = new System.Windows.Media.Media3D.MeshGeometry3D();
            double k = inner ? 0.68 : 1.0;
            // Основание утоплено в череп: оба его края внутри головы, ухо «вырастает» из неё.
            var bc = P(side * 0.36, 0.38, inner ? 0.09 : 0.02);
            var tip = P(side * (0.95 - (inner ? 0.06 : 0)), 1.08 - (inner ? 0.16 : 0), inner ? 0.09 : 0.02);
            // Основание — поперёк оси уха (широкая раковина спереди), неглубокое по Z; посередине прогиб внутрь.
            var axis = V(tip.X - bc.X, tip.Y - bc.Y, 0); axis.Normalize();
            var u = V(-axis.Y, axis.X, 0);
            double ra = 0.31 * k, rb = 0.11 * k;
            int n = 18;
            m.Positions.Add(tip); m.Normals.Add(V(0, 0, 1));
            for (int i = 0; i <= n; i++) {
                double a = Math.PI * 2 * i / n;
                double cu = Math.Cos(a) * ra, cw = Math.Sin(a) * rb;
                m.Positions.Add(P(bc.X + u.X * cu, bc.Y + u.Y * cu, bc.Z + cw - (inner ? 0 : Math.Abs(Math.Cos(a)) * 0.04)));
                var nr = V(u.X * Math.Cos(a) * 0.45, u.Y * Math.Cos(a) * 0.45 + 0.15, 1);
                nr.Normalize();
                m.Normals.Add(nr);
            }
            for (int i = 1; i <= n; i++) { m.TriangleIndices.Add(0); m.TriangleIndices.Add(i); m.TriangleIndices.Add(i + 1); }
            return m;
        }

        static System.Windows.Media.Media3D.GeometryModel3D Model(System.Windows.Media.Media3D.MeshGeometry3D mesh, System.Windows.Media.Media3D.Material mat) {
            return new System.Windows.Media.Media3D.GeometryModel3D(mesh, mat);   // замкнутые фигуры: обратная сторона не видна
        }

        static System.Windows.Media.Media3D.Material Mat(System.Windows.Media.Media3D.DiffuseMaterial diffuse, int spec, double power) {
            var grp = new System.Windows.Media.Media3D.MaterialGroup();
            grp.Children.Add(diffuse);
            if (spec != 0) grp.Children.Add(new System.Windows.Media.Media3D.SpecularMaterial(new System.Windows.Media.SolidColorBrush(C(spec)), power));
            return grp;
        }

        static Scene Build() {
            var s = new Scene();
            s.SkinBrush = new System.Windows.Media.SolidColorBrush(C(0xE9B5A2));
            s.InnerBrush = new System.Windows.Media.SolidColorBrush(C(0xF2C3B8));
            s.SkinMat = new System.Windows.Media.Media3D.DiffuseMaterial(s.SkinBrush);
            s.InnerMat = new System.Windows.Media.Media3D.DiffuseMaterial(s.InnerBrush);
            var skin = Mat(s.SkinMat, 0x2A2420, 18);                       // винил: лёгкий мягкий блеск
            var inner = Mat(s.InnerMat, 0x1A1414, 12);
            var eye = Mat(new System.Windows.Media.Media3D.DiffuseMaterial(new System.Windows.Media.SolidColorBrush(C(0x0C0C0E))), 0xFFFFFF, 90);   // глянец
            var nose = Mat(new System.Windows.Media.Media3D.DiffuseMaterial(new System.Windows.Media.SolidColorBrush(C(0x6B4A3E))), 0x404040, 30);
            var mouth = new System.Windows.Media.Media3D.DiffuseMaterial(new System.Windows.Media.SolidColorBrush(C(0x4A2226)));
            var tongue = Mat(new System.Windows.Media.Media3D.DiffuseMaterial(new System.Windows.Media.SolidColorBrush(C(0xF07F8E))), 0x303030, 20);

            var head = new System.Windows.Media.Media3D.Model3DGroup();
            head.Children.Add(Model(Ellipsoid(0, 0.05, 0, 0.68, 0.54, 0.52, 26), skin));           // череп: широкий лоб и скулы
            head.Children.Add(Model(Ellipsoid(0, -0.22, 0.2, 0.45, 0.3, 0.36, 14), skin));         // мордочка
            head.Children.Add(Model(Ellipsoid(0, -0.43, 0.26, 0.18, 0.12, 0.14, 8), skin));       // подбородок
            head.Children.Add(Model(Ellipsoid(-0.36, -0.08, 0.32, 0.2, 0.15, 0.14, 8), skin));    // скулы под глазами
            head.Children.Add(Model(Ellipsoid(0.36, -0.08, 0.32, 0.2, 0.15, 0.14, 8), skin));
            // Уши — вращаются вокруг основания.
            for (int side = -1; side <= 1; side += 2) {
                var ear = new System.Windows.Media.Media3D.Model3DGroup();
                var outer = Model(Ear(side, false), skin); outer.BackMaterial = skin;   // раковина открыта — видна с обеих сторон
                ear.Children.Add(outer);
                ear.Children.Add(Model(Ellipsoid(side * 0.4, 0.42, 0.02, 0.2, 0.13, 0.13, 10), skin));   // корень уха — переход в голову
                var inn = Model(Ear(side, true), inner); inn.BackMaterial = inner; ear.Children.Add(inn);
                var rot = new System.Windows.Media.Media3D.AxisAngleRotation3D(V(0, 0, 1), 0);
                ear.Transform = new System.Windows.Media.Media3D.RotateTransform3D(rot, P(side * 0.36, 0.38, 0));
                if (side < 0) s.EarL = rot; else s.EarR = rot;
                head.Children.Add(ear);
            }
            // Глаза — глянцевые сферы, утопленные в глазницы: вокруг — ободок-веко из кожи чуть темнее,
            // сам глаз выступает из него совсем немного. Взгляд передаёт поворот головы; глаз в глазнице
            // смещается едва заметно. Масштаб — открыты / прищур / закрыты и «Ага!».
            s.SocketBrush = new System.Windows.Media.SolidColorBrush(C(0xC99482));
            var socket = Mat(new System.Windows.Media.Media3D.DiffuseMaterial(s.SocketBrush), 0x1A1412, 10);
            for (int side = -1; side <= 1; side += 2) {
                head.Children.Add(Model(Ellipsoid(side * 0.3, -0.03, 0.36, 0.235, 0.245, 0.13, 22), socket));
                var e = Model(Ellipsoid(0, 0, 0, 0.19, 0.2, 0.1, 20), eye);
                var sc = new System.Windows.Media.Media3D.ScaleTransform3D(1, 1, 1);
                var tr = new System.Windows.Media.Media3D.TranslateTransform3D(side * 0.3, -0.03, 0.405);
                var gx = new System.Windows.Media.Media3D.Transform3DGroup(); gx.Children.Add(sc); gx.Children.Add(tr);
                e.Transform = gx;
                if (side < 0) { s.EyeLS = sc; s.EyeLT = tr; } else { s.EyeRS = sc; s.EyeRT = tr; }
                head.Children.Add(e);
            }
            head.Children.Add(Model(Ellipsoid(0, -0.21, 0.55, 0.075, 0.05, 0.05, 8), nose));
            // Рот (зевок) и язык — масштаб 0, пока не нужны.
            var mth = Model(Ellipsoid(0, 0, 0, 0.1, 0.12, 0.05, 8), mouth);
            s.Mouth = new System.Windows.Media.Media3D.ScaleTransform3D(0, 0, 0, 0, -0.33, 0.52);
            var mg = new System.Windows.Media.Media3D.Transform3DGroup(); mg.Children.Add(new System.Windows.Media.Media3D.TranslateTransform3D(0, -0.33, 0.52)); mg.Children.Add(s.Mouth);
            mth.Transform = mg; head.Children.Add(mth);
            var tg = Model(Ellipsoid(0, 0, 0, 0.07, 0.06, 0.04, 6), tongue);
            s.Tongue = new System.Windows.Media.Media3D.ScaleTransform3D(0, 0, 0, 0.02, -0.38, 0.53);
            var tgg = new System.Windows.Media.Media3D.Transform3DGroup(); tgg.Children.Add(new System.Windows.Media.Media3D.TranslateTransform3D(0.02, -0.38, 0.53)); tgg.Children.Add(s.Tongue);
            tg.Transform = tgg; head.Children.Add(tg);

            s.Yaw = new System.Windows.Media.Media3D.AxisAngleRotation3D(V(0, 1, 0), 0);
            s.Pitch = new System.Windows.Media.Media3D.AxisAngleRotation3D(V(1, 0, 0), 0);
            s.Roll = new System.Windows.Media.Media3D.AxisAngleRotation3D(V(0, 0, 1), 0);
            s.Bob = new System.Windows.Media.Media3D.TranslateTransform3D(0, 0, 0);
            s.Breathe = new System.Windows.Media.Media3D.ScaleTransform3D(1, 1, 1);
            s.HeadXf = new System.Windows.Media.Media3D.Transform3DGroup();
            s.HeadXf.Children.Add(s.Breathe);
            s.HeadXf.Children.Add(new System.Windows.Media.Media3D.RotateTransform3D(s.Roll));
            s.HeadXf.Children.Add(new System.Windows.Media.Media3D.RotateTransform3D(s.Pitch));
            s.HeadXf.Children.Add(new System.Windows.Media.Media3D.RotateTransform3D(s.Yaw));
            s.HeadXf.Children.Add(s.Bob);
            head.Transform = s.HeadXf;
            s.Head = head;

            // Свет: ключевой тёплый сверху-слева-спереди, заполняющий холодный справа, контровой сзади-сверху, общий.
            var world = new System.Windows.Media.Media3D.Model3DGroup();
            world.Children.Add(new System.Windows.Media.Media3D.AmbientLight(C(0x4A4440)));
            world.Children.Add(new System.Windows.Media.Media3D.DirectionalLight(C(0xF4ECE4), V(0.55, -0.6, -1)));
            world.Children.Add(new System.Windows.Media.Media3D.DirectionalLight(C(0x50566A), V(-0.9, -0.1, -0.5)));
            world.Children.Add(new System.Windows.Media.Media3D.DirectionalLight(C(0x6A6058), V(0, -0.4, 1)));
            world.Children.Add(head);

            s.View = new System.Windows.Controls.Viewport3D();
            s.View.Camera = new System.Windows.Media.Media3D.PerspectiveCamera(P(0, CamY, CamDist), V(0, 0, -1), V(0, 1, 0), Fov);
            s.View.Children.Add(new System.Windows.Media.Media3D.ModelVisual3D { Content = world });
            return s;
        }

        static double Deg(float rad) { return rad * 180.0 / Math.PI; }

        // Пиксели на единицу модели (для наложений поверх: облачко, огоньки) при ширине картинки w.
        public static float PixelsPerUnit(float w) { return (float)(w / (2 * CamDist * Math.Tan(Fov * Math.PI / 360))); }

        // Рендер сфинкса в позе p в картинку w×h (сглаживание — двойной детализацией); null — 3D недоступно.
        public static Bitmap Render(int w, int h, SphynxPose p, Color skin, Color inner) {
            if (failed || w < 2 || h < 2) return null;
            try {
                if (scene == null) scene = Build();
                Scene s = scene;
                int W = w * 2, H = h * 2;
                s.SkinBrush.Color = System.Windows.Media.Color.FromRgb(skin.R, skin.G, skin.B);
                s.SocketBrush.Color = System.Windows.Media.Color.FromRgb((byte)(skin.R * 0.95), (byte)(skin.G * 0.91), (byte)(skin.B * 0.9));
                s.InnerBrush.Color = System.Windows.Media.Color.FromRgb(inner.R, inner.G, inner.B);
                s.Yaw.Angle = Deg(p.Yaw); s.Pitch.Angle = Deg(p.Pitch); s.Roll.Angle = Deg(p.Roll);
                s.Bob.OffsetY = p.Bob;
                s.Breathe.ScaleX = s.Breathe.ScaleY = s.Breathe.ScaleZ = p.Breathe;
                double ear = p.EarsDown ? 38 : 0;
                s.EarL.Angle = ear - Deg(p.EarL) * 1.6;   // ось Z: левое ухо — по часовой наружу
                s.EarR.Angle = -ear + Deg(p.EarR) * 1.6;
                double es = p.EyeScale, open = Math.Max(0.06, p.Open);
                foreach (var sc in new[] { s.EyeLS, s.EyeRS }) { sc.ScaleX = es; sc.ScaleY = es * open; sc.ScaleZ = es; }
                double gx = p.GazeX * 0.015, gy = p.GazeY * 0.012 - (1 - open) * 0.05;
                s.EyeLT.OffsetX = -0.3 + gx; s.EyeRT.OffsetX = 0.3 + gx;
                s.EyeLT.OffsetY = s.EyeRT.OffsetY = -0.03 + gy;
                double y = p.Yawn;
                s.Mouth.ScaleX = y; s.Mouth.ScaleY = y; s.Mouth.ScaleZ = y > 0 ? 1 : 0;
                double t = p.Tongue ? 1 : 0;
                s.Tongue.ScaleX = s.Tongue.ScaleY = s.Tongue.ScaleZ = t;
                if (s.W != W || s.H != H || s.Rtb == null) {
                    s.Rtb = new System.Windows.Media.Imaging.RenderTargetBitmap(W, H, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
                    s.W = W; s.H = H;
                }
                s.View.Width = W; s.View.Height = H;
                s.View.Measure(new System.Windows.Size(W, H));
                s.View.Arrange(new System.Windows.Rect(0, 0, W, H));
                s.View.UpdateLayout();
                s.Rtb.Clear();
                s.Rtb.Render(s.View);
                var bmp = new Bitmap(W, H, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
                try {
                    var data = bmp.LockBits(new Rectangle(0, 0, W, H), System.Drawing.Imaging.ImageLockMode.WriteOnly, bmp.PixelFormat);
                    try { s.Rtb.CopyPixels(new System.Windows.Int32Rect(0, 0, W, H), data.Scan0, data.Stride * H, data.Stride); }
                    finally { bmp.UnlockBits(data); }
                } catch { bmp.Dispose(); throw; }
                failures = 0;
                return bmp;
            }
            catch {
                // Несколько сбоев подряд — 3D на этом потоке выключается (рисуется плоская мордочка); разовый — нет.
                if (++failures >= MaxFailures) failed = true;
                return null;
            }
        }
    }

    // Кэш кадров 3D-сфинкса: программный рендер WPF стоит ~20 мс за кадр почти при любом размере, поэтому
    // каждая поза (с шагом квантования) рендерится один раз и запоминается; анимации повторяются, и кэш быстро
    // наполняется. За одну отрисовку шторки — не больше PerFrame новых рендеров, пока их нет — прежний кадр.
    // Покачивание, наклон и «дыхание» в позу не входят: это сдвиг, поворот и масштаб готовой картинки.
    public static class SphynxSprites {
        sealed class Entry { public string Key; public Bitmap Bmp; public long Bytes; }
        [ThreadStatic] static Dictionary<string, LinkedListNode<Entry>> map;
        [ThreadStatic] static LinkedList<Entry> lru;
        [ThreadStatic] static Dictionary<string, Bitmap> last;
        [ThreadStatic] static long bytes;
        [ThreadStatic] static int budget;
        public static long MaxBytes = 24L * 1024 * 1024;   // кадры в памяти — в итоговом размере (1×), их вчетверо больше, чем было в 2×
        public static int PerFrame = 2;
        public static long Renders;   // сколько кадров отрисовано (для замеров)
        public static long DiskHits;  // сколько взято с диска

        // Кадры на диске: каждый отрисованный кадр сохраняется (PNG), при следующих запусках берётся оттуда — 3D
        // (и сам WPF) нужен только для поз, которых ещё не было. Папка задаётся треем и меняется вместе с исходником
        // интерфейса (новая модель — новые кадры). Пусто — без диска.
        public static string DiskDir = "";
        public static int MaxDiskFiles = 8000;
        [ThreadStatic] static HashSet<string> notOnDisk;
        static int diskFiles = -1;

        static string DiskPath(string key) {
            using (System.Security.Cryptography.SHA1 sha = System.Security.Cryptography.SHA1.Create()) {
                byte[] hash = sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(key));
                System.Text.StringBuilder sb = new System.Text.StringBuilder(32);
                for (int i = 0; i < 12; i++) sb.Append(hash[i].ToString("x2"));
                return System.IO.Path.Combine(DiskDir, sb.ToString() + ".png");
            }
        }

        static Bitmap FromDisk(string key) {
            if (string.IsNullOrEmpty(DiskDir)) return null;
            if (notOnDisk == null) notOnDisk = new HashSet<string>();
            if (notOnDisk.Contains(key)) return null;
            try {
                string path = DiskPath(key);
                if (!System.IO.File.Exists(path)) { notOnDisk.Add(key); return null; }
                using (Bitmap src = new Bitmap(path)) {   // копия: файл не остаётся занятым
                    Bitmap b = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppPArgb);
                    using (Graphics g = Graphics.FromImage(b)) { g.CompositingMode = CompositingMode.SourceCopy; g.DrawImage(src, 0, 0, src.Width, src.Height); }
                    DiskHits++;
                    return b;
                }
            } catch { notOnDisk.Add(key); return null; }
        }

        static void ToDisk(string key, Bitmap b) {
            if (string.IsNullOrEmpty(DiskDir)) return;
            try {
                if (diskFiles < 0) { System.IO.Directory.CreateDirectory(DiskDir); diskFiles = System.IO.Directory.GetFiles(DiskDir, "*.png").Length; }
                if (diskFiles >= MaxDiskFiles) return;
                // Уникальное имя: трей и шторка (разные потоки одного процесса) могут писать один кадр одновременно.
                string path = DiskPath(key), tmp = path + "." + System.Diagnostics.Process.GetCurrentProcess().Id + "-" + System.Threading.Thread.CurrentThread.ManagedThreadId + "-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".tmp";
                try {
                    b.Save(tmp, ImageFormat.Png);
                    if (System.IO.File.Exists(path)) System.IO.File.Delete(tmp); else System.IO.File.Move(tmp, path);
                } catch { try { System.IO.File.Delete(tmp); } catch { } throw; }
                System.Threading.Interlocked.Increment(ref diskFiles);
                if (notOnDisk != null) notOnDisk.Remove(key);
            } catch { }
        }

        // 3D рендерится в 2× (сглаживание), храним уже уменьшенный кадр — рисуется 1:1, без пересчёта на каждом кадре.
        static Bitmap Downscale(Bitmap big, int w, int h) {
            if (big.Width == w && big.Height == h) return big;
            Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
            using (Graphics g = Graphics.FromImage(b)) {
                g.CompositingMode = CompositingMode.SourceCopy;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                using (ImageAttributes ia = new ImageAttributes()) {
                    ia.SetWrapMode(WrapMode.TileFlipXY);   // без тёмной каймы по краю
                    g.DrawImage(big, new Rectangle(0, 0, w, h), 0, 0, big.Width, big.Height, GraphicsUnit.Pixel, ia);
                }
            }
            big.Dispose();
            return b;
        }
        public static int Count { get { return map == null ? 0 : map.Count; } }

        public static void BeginFrame() { budget = PerFrame; }
        public static void BeginFrame(int renders) { budget = renders; }

        // Забыть кадры в памяти этого потока (диск не трогается) — для проверок.
        public static void ClearMemory() {
            if (lru != null) foreach (Entry e in lru) e.Bmp.Dispose();
            if (temps != null) foreach (Bitmap b in temps.Values) b.Dispose();
            map = null; lru = null; last = null; bytes = 0; notOnDisk = null; diskFiles = -1;
            temps = null; tempSig = null; acc = null; buf = null;
        }

        // Потолок новых 3D-кадров в секунду (каждый ~20 мс процессора): пока кадра нет — показывается ближайший
        // готовый. Шторка ставит больше, пока раскрыта, и меньше, пока свёрнута и работает в фоне.
        public static double RatePerSec = 6;
        public const double Burst = 4;
        [ThreadStatic] static double tokens;
        [ThreadStatic] static long tokensAt;
        static bool TakeToken() {
            long now = System.Diagnostics.Stopwatch.GetTimestamp();
            if (tokensAt == 0) tokens = Burst;
            else tokens = Math.Min(Burst, tokens + (now - tokensAt) / (double)System.Diagnostics.Stopwatch.Frequency * RatePerSec);
            tokensAt = now;
            if (tokens < 1) return false;
            tokens -= 1;
            return true;
        }

        // Маленькие мордочки (свёрнутая шторка, плашки): шаги крупнее, подёргивание ушей не видно —
        // меньше разных кадров, кэш наполняется быстро и потом почти не рендерит.
        public const int SmallW = 50;
        static float YawStepFor(int w) { return w < SmallW ? YawStep * 2 : YawStep; }
        static float PitchStepFor(int w) { return w < SmallW ? PitchStep * 2 : PitchStep; }

        static float Q(float v, float step) { return (float)Math.Round(v / step) * step; }

        public static Bitmap Get(int w, int h, SphynxPose p, Color skin, Color inner, int seed) {
            bool exact;
            return Lookup(w, h, p, skin, inner, seed, true, out exact);
        }

        public const float YawStep = 0.045f, PitchStep = 0.05f;
        [ThreadStatic] static Dictionary<string, Bitmap> temps;
        [ThreadStatic] static Dictionary<string, string> tempSig;
        [ThreadStatic] static int[] acc;
        [ThreadStatic] static byte[] buf;

        // Плавный поворот без ступенек: четыре соседних по повороту и наклону кадра смешиваются с весами
        // (билинейно). Недостающие дорисовываются в пределах бюджета; пока их нет — смешиваются те, что есть.
        public static Bitmap GetBlended(int w, int h, SphynxPose p, Color skin, Color inner, int seed) {
            float ys = YawStepFor(w), ps = PitchStepFor(w);
            double fy = p.Yaw / ys, fp = p.Pitch / ps;
            int y0 = (int)Math.Floor(fy), p0 = (int)Math.Floor(fp);
            float ty = (float)(fy - y0), tp = (float)(fp - p0);
            float[] wts = { (1 - ty) * (1 - tp), ty * (1 - tp), (1 - ty) * tp, ty * tp };
            int[] dy = { 0, 1, 0, 1 }, dp = { 0, 0, 1, 1 };
            int[] order = { 0, 1, 2, 3 };
            Array.Sort(order, delegate (int a, int b) { return wts[b].CompareTo(wts[a]); });
            List<KeyValuePair<Bitmap, float>> parts = new List<KeyValuePair<Bitmap, float>>();
            foreach (int i in order) {
                if (wts[i] < 0.03f) continue;
                SphynxPose q = Clone(p);
                q.Yaw = (y0 + dy[i]) * ys; q.Pitch = (p0 + dp[i]) * ps;
                bool exact;
                Bitmap b = Lookup(w, h, q, skin, inner, seed, false, out exact);
                if (b != null && exact) parts.Add(new KeyValuePair<Bitmap, float>(b, wts[i]));
            }
            if (parts.Count == 0) return Get(w, h, p, skin, inner, seed);
            if (parts.Count == 1) return parts[0].Key;
            if (temps == null) { temps = new Dictionary<string, Bitmap>(); tempSig = new Dictionary<string, string>(); }
            Bitmap first = parts[0].Key;
            string tk = w + "x" + h + "|" + seed;
            // Те же кадры с теми же весами (поза не менялась) — готовая смесь.
            float tot = 0; foreach (KeyValuePair<Bitmap, float> kv in parts) tot += kv.Value;
            System.Text.StringBuilder sig = new System.Text.StringBuilder();
            foreach (KeyValuePair<Bitmap, float> kv in parts) sig.Append(kv.Key.GetHashCode()).Append(':').Append((int)(kv.Value / tot * 64)).Append(';');
            string sg = sig.ToString();
            Bitmap tmp; string was;
            if (!temps.TryGetValue(tk, out tmp) || tmp.Width != first.Width || tmp.Height != first.Height) {
                if (tmp != null) tmp.Dispose();
                tmp = new Bitmap(first.Width, first.Height, PixelFormat.Format32bppPArgb);
                temps[tk] = tmp; tempSig.Remove(tk);
            } else if (tempSig.TryGetValue(tk, out was) && was == sg) return tmp;
            tempSig[tk] = sg;
            // Смешиваем сами (байты с предумноженной прозрачностью складываются линейно) — в разы быстрее
            // ColorMatrix из GDI+.
            int W = tmp.Width, H = tmp.Height, n = W * H * 4;
            Rectangle rect = new Rectangle(0, 0, W, H);
            if (acc == null || acc.Length < n) { acc = new int[n]; buf = new byte[n]; }
            Array.Clear(acc, 0, n);
            int sumW = 0;
            foreach (KeyValuePair<Bitmap, float> kv in parts) {
                if (kv.Key.Width != W || kv.Key.Height != H) continue;
                int wi = (int)Math.Round(kv.Value / tot * 256);
                if (wi <= 0) continue;
                sumW += wi;
                BitmapData d = kv.Key.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
                try { System.Runtime.InteropServices.Marshal.Copy(d.Scan0, buf, 0, n); } finally { kv.Key.UnlockBits(d); }
                for (int i = 0; i < n; i++) acc[i] += buf[i] * wi;
            }
            if (sumW <= 0) return first;
            int half = sumW / 2;
            for (int i = 0; i < n; i++) { int v = (acc[i] + half) / sumW; buf[i] = (byte)(v > 255 ? 255 : v); }
            BitmapData o = tmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
            try { System.Runtime.InteropServices.Marshal.Copy(buf, 0, o.Scan0, n); } finally { tmp.UnlockBits(o); }
            return tmp;
        }

        static SphynxPose Clone(SphynxPose p) {
            SphynxPose q = new SphynxPose();
            q.State = p.State; q.Yaw = p.Yaw; q.Pitch = p.Pitch; q.Roll = p.Roll; q.Bob = p.Bob; q.Breathe = p.Breathe;
            q.EarL = p.EarL; q.EarR = p.EarR; q.EarsDown = p.EarsDown; q.GazeX = p.GazeX; q.GazeY = p.GazeY;
            q.EyeScale = p.EyeScale; q.Open = p.Open; q.Yawn = p.Yawn; q.Tongue = p.Tongue; q.CrossEyes = p.CrossEyes;
            return q;
        }

        // exact = false — вернулся прежний кадр этого места (новый не успели отрисовать в этой отрисовке).
        static Bitmap Lookup(int w, int h, SphynxPose p, Color skin, Color inner, int seed, bool quantYawPitch, out bool exact) {
            exact = false;
            if (map == null) { map = new Dictionary<string, LinkedListNode<Entry>>(); lru = new LinkedList<Entry>(); last = new Dictionary<string, Bitmap>(); }
            SphynxPose q = new SphynxPose();
            q.State = p.State;
            bool small = w < SmallW;
            q.Yaw = quantYawPitch ? Q(p.Yaw, YawStepFor(w)) : (float)Math.Round(p.Yaw, 4);
            q.Pitch = quantYawPitch ? Q(p.Pitch, PitchStepFor(w)) : (float)Math.Round(p.Pitch, 4);
            q.GazeX = 0; q.GazeY = 0;   // взгляд — поворот головы; глаз в глазнице не смещается (меньше разных кадров)
            q.Open = Q(p.Open, small ? 0.25f : 0.12f); q.EyeScale = Q(p.EyeScale, small ? 0.15f : 0.06f);
            q.EarL = small ? 0 : Q(p.EarL, 0.025f); q.EarR = small ? 0 : Q(p.EarR, 0.025f);
            q.EarsDown = p.EarsDown; q.Yawn = Q(p.Yawn, small ? 0.5f : 0.2f); q.Tongue = p.Tongue;
            string key = w + "x" + h + "|" + skin.ToArgb() + "|" + q.Yaw + "|" + q.Pitch + "|" + q.GazeX + "|" + q.GazeY + "|" + q.Open + "|" + q.EyeScale + "|" +
                q.EarL + "|" + q.EarR + "|" + (q.EarsDown ? 1 : 0) + "|" + q.Yawn + "|" + (q.Tongue ? 1 : 0);
            string slot = w + "x" + h + "|" + seed;
            LinkedListNode<Entry> node;
            if (map.TryGetValue(key, out node)) {
                lru.Remove(node); lru.AddFirst(node);
                last[slot] = node.Value.Bmp;
                exact = true;
                return node.Value.Bmp;
            }
            // С диска — дёшево (доли мс), без бюджета и без WPF.
            Bitmap b = FromDisk(key);
            if (b == null) {
                Bitmap prev;
                if (last.TryGetValue(slot, out prev) && prev != null && (budget <= 0 || !TakeToken())) return prev;
                budget--;
                b = Sphynx3D.Render(w, h, q, skin, inner);
                if (b == null) return null;
                b = Downscale(b, w, h);
                Renders++;
                ToDisk(key, b);
            }
            exact = true;
            Entry e = new Entry { Key = key, Bmp = b, Bytes = (long)b.Width * b.Height * 4 };
            map[key] = lru.AddFirst(e);
            bytes += e.Bytes;
            while (bytes > MaxBytes && lru.Count > 1) {
                Entry old = lru.Last.Value;
                lru.RemoveLast(); map.Remove(old.Key); bytes -= old.Bytes;
                if (!last.ContainsValue(old.Bmp)) old.Bmp.Dispose();
            }
            last[slot] = b;
            return b;
        }
    }

    // Объёмная мордочка сфинкса — персонаж сеанса. Модель из частей в 3D: голова (лоб и скулы) и мордочка с
    // подбородком — эллипсоиды, большие уши — треугольники; поворот по оси Y и наклон, ортографическая проекция,
    // сортировка по глубине, у каждой части свет сверху-слева. Большие глянцевые глаза, маленький коричневый нос,
    // складочки на лбу, без усов. Кожа розово-бежевая, слегка подкрашена цветом статуса. Поведение: работает —
    // крутит головой, дёргает ушами; нужно разрешение — наклоняет голову, глаза ещё больше; ждёт — моргает;
    // ошибка — уши обвисли, глаза-крестики; сеансов нет — спит.
    public static class Cat {
        sealed class Shape { public float Depth; public Action<Graphics> Paint; }

        static readonly Color Skin = Theme.Hex(0xE9B5A2);

        public static Color Fur(string state) {
            switch (state) {
                case "working": return Mix(Skin, Theme.Hex(0xF08A4B), 0.35f);
                case "permission": return Mix(Skin, Theme.Hex(0xFFB01F), 0.45f);
                case "error": return Mix(Skin, Theme.Hex(0xE5483B), 0.45f);
                case "waiting": return Skin;
                default: return Mix(Skin, Theme.Hex(0x8E8E93), 0.7f);
            }
        }

        static Color Shade(Color c, float k) {
            return Color.FromArgb(c.A, Math.Min(255, (int)(c.R * k)), Math.Min(255, (int)(c.G * k)), Math.Min(255, (int)(c.B * k)));
        }

        static Color Mix(Color a, Color b, float t) {
            return Color.FromArgb(255, (int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }

        // Эллипсоид со светом: градиент от светлого (сверху-слева) к тёмному краю — мягкий, как винил.
        static void Blob(Graphics g, float x, float y, float rx, float ry, Color c, float lightK, float darkK) {
            if (rx < 0.8f || ry < 0.8f) { using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, x - rx, y - ry, rx * 2, ry * 2); return; }
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddEllipse(x - rx, y - ry, rx * 2, ry * 2);
                using (PathGradientBrush b = new PathGradientBrush(p)) {
                    b.CenterColor = Shade(c, lightK);
                    b.SurroundColors = new Color[] { Shade(c, darkK) };
                    b.CenterPoint = new PointF(x - rx * 0.28f, y - ry * 0.34f);
                    b.FocusScales = new PointF(0.5f, 0.5f);
                    g.FillPath(b, p);
                }
            }
        }

        public static void Paint(Graphics g, RectangleF r, string state, float t, int seed, bool animate) { Paint(g, r, state, t, seed, animate, null); }

        static int Hash(int a, int b) {
            unchecked {
                int h = a * 73856093 ^ b * 19349663;
                h ^= h >> 13; h *= 0x5bd1e995; h ^= h >> 15;
                return h & 0x7fffffff;
            }
        }

        // Случайная мелочь раз в ~9 с (у каждого сфинкса своё расписание): 1 — двойное моргание, 2 — дёрнул ухом,
        // 3 — взглянул на вас, 4 — зевнул (реже). Возвращает вид и ход 0..1, или 0, если сейчас ничего.
        public static int EventAt(float t, int seed, out float p) {
            const float period = 9f;
            float tt = t + seed * 3.1f;
            int slot = (int)Math.Floor(tt / period);
            int h = Hash(slot, seed + 7);
            float start = slot * period + (h % 300) / 100f;
            int kind = 1 + (h / 300) % 4;
            if (kind == 4 && (h / 1200) % 3 != 0) kind = 2;
            float dur = kind == 1 ? 0.55f : kind == 2 ? 0.35f : kind == 3 ? 1.3f : 1.7f;
            p = (tt - start) / dur;
            if (p < 0 || p > 1) { p = 0; return 0; }
            return kind;
        }

        public static void Paint(Graphics g, RectangleF r, string state, float t, int seed, bool animate, CatMood mood) {
            if (r.Width < 2 || r.Height < 2) return;
            bool sleep = string.IsNullOrEmpty(state) || state == "none";
            bool working = state == "working", stalled = state == "stalled";
            Color skin = Fur(stalled ? "working" : state), inner = Mix(skin, Theme.Hex(0xF4C7BE), 0.6f), eyeC = Theme.Hex(0x0E0E10), noseC = Theme.Hex(0x6B4A3E);
            if (stalled) skin = Mix(skin, Theme.Hex(0x8E8E93), 0.35f);
            float ph = seed * 1.7f;
            float yaw = 0, roll = 0, bob = 0, breathe = 1f, earL = 0, earR = 0;
            float gazeX = 0, gazeY = 0, eyeScale = 1f, squint = 1f, yawn = 0, dotsSpeed = 3f, pop = 1f;
            bool blink = false, tongue = false, half = false;
            string bubble = null;   // dots | ! | z
            int ev = 0; float evp = 0;
            if (animate) {
                breathe = 1f + 0.015f * (float)Math.Sin(t * 2f + ph);
                blink = ((t + seed * 1.3f) % 4.2f) < 0.14f;
                ev = EventAt(t, seed, out evp);
                switch (state) {
                    case "working": {
                        // Думает: голова чуть наклонена и «дышит», взгляд вверх и в сторону, медленно дрейфует
                        // и раз в несколько секунд переходит на другую сторону.
                        roll = 0.08f + 0.04f * (float)Math.Sin(t * 0.7f + ph);
                        bob = 0.015f * (float)Math.Sin(t * 1.6f + ph);
                        gazeX = 0.65f * (float)Math.Tanh(3.0 * Math.Sin(t * 0.45f + ph)) + 0.12f * (float)Math.Sin(t * 1.7f + ph);
                        gazeY = 0.55f + 0.12f * (float)Math.Sin(t * 0.9f + ph);
                        bubble = "dots";
                        if (mood != null && mood.Deep) { squint = 0.5f; tongue = true; dotsSpeed = 1.3f; gazeY = 0.3f; }
                        if (mood != null && mood.AhaAge >= 0 && mood.AhaAge < 0.8f) {
                            // «Ага!»: глаза округлились, уши торчком, в облачке искра «!».
                            float a = 1f - mood.AhaAge / 0.8f;
                            eyeScale = 1f + 0.3f * a; squint = 1f; tongue = false;
                            earL = earR = -0.1f * a;
                            gazeX *= 0.3f; gazeY = 0.15f;
                            bubble = "!";
                            pop = 1f + 0.4f * (float)Math.Sin(Math.Min(1.0, mood.AhaAge / 0.3) * Math.PI);
                        }
                        break;
                    }
                    case "permission":
                        roll = 0.22f * (float)Math.Sin(t * 2.2f + ph); breathe = 1f + 0.045f * (float)Math.Sin(t * 6f + ph); break;
                    case "waiting":
                        yaw = 0.16f * (float)Math.Sin(t * 0.5f + ph); break;
                    case "error":
                        roll = 0.05f * (float)Math.Sin(t * 9f + ph); break;
                    case "stalled":
                        // Похоже, остановился: сонные глаза, голова клонится, в облачке «z».
                        roll = 0.12f; bob = 0.03f * (float)Math.Sin(t * 0.7f + ph); half = true; bubble = "z"; break;
                    default:
                        bob = 0.035f * (float)Math.Sin(t * 0.9f + ph); roll = 0.05f; break;
                }
                // Случайные мелочи — у работающего и у ждущего; «Ага!» и взгляд на курсор важнее.
                if ((mood != null && mood.AhaAge >= 0 && mood.AhaAge < 0.8f) || (mood != null && mood.HasLook)) ev = 0;
                if (working || state == "waiting") {
                    switch (ev) {
                        case 1: blink = evp < 0.25f || (evp > 0.5f && evp < 0.75f); break;
                        case 2: { float tw = 0.11f * (float)Math.Sin(evp * Math.PI); if (seed % 2 == 0) earL = tw; else earR = tw; break; }
                        case 3: {
                            float w = (float)Math.Sin(evp * Math.PI);
                            gazeX *= 1f - w; gazeY *= 1f - w;
                            if (w > 0.5f && bubble == "dots") bubble = null;
                            break;
                        }
                        case 4: yawn = (float)Math.Sin(evp * Math.PI); bubble = null; break;
                    }
                }
                // В раскрытой шторке: мышь рядом — сфинкс смотрит на курсор.
                if (mood != null && mood.HasLook && !sleep) {
                    float lw = Math.Max(0f, Math.Min(1f, mood.LookW));
                    gazeX = gazeX * (1f - lw) + mood.LookX * lw; gazeY = gazeY * (1f - lw) + mood.LookY * lw;
                }
            }
            // Настоящий 3D (WPF): кадр позы из кэша, поверх — облачко, огоньки агентов, рот, крестики ошибки.
            if (Sphynx3D.Available) {
                SphynxPose sp = new SphynxPose();
                sp.State = state;
                // Взгляд — поворотом головы (глаза в глазницах почти не двигаются): чуть-чуть, когда думает,
                // заметнее, когда смотрит на курсор.
                float lw3 = (mood != null && mood.HasLook && !sleep) ? Math.Max(0f, Math.Min(1f, mood.LookW)) : 0f;
                sp.Yaw = yaw + gazeX * (0.1f + 0.32f * lw3);
                sp.Pitch = -gazeY * ((working ? 0.1f : 0.05f) + 0.16f * lw3);
                sp.GazeX = gazeX; sp.GazeY = gazeY;
                sp.EyeScale = (state == "permission" ? 1.14f : 1f) * eyeScale;
                sp.Open = (sleep || blink || yawn > 0.3f || state == "error") ? 0.06f : (half ? 0.4f : squint);
                sp.Yawn = yawn;
                sp.Tongue = tongue && yawn <= 0.05f;
                sp.EarL = stalled ? 0.1f : earL; sp.EarR = stalled ? 0.1f : earR;
                sp.EarsDown = state == "error";
                Color inner3 = Mix(skin, Theme.Hex(0xF29C98), 0.5f);
                int sw3 = Math.Max(2, (int)Math.Ceiling(r.Width)), sh3 = Math.Max(2, (int)Math.Ceiling(r.Height));
                Bitmap spr = SphynxSprites.GetBlended(sw3, sh3, sp, skin, inner3, seed);
                if (spr != null) {
                    float kk = Sphynx3D.PixelsPerUnit(sw3);
                    float camY = (float)Sphynx3D.CamY;
                    Func<float, float, PointF> W2 = delegate (float x, float y) { return new PointF(x * kk, -(y - camY) * kk); };
                    GraphicsState gs = g.Save();
                    g.TranslateTransform(r.X + r.Width / 2f, r.Y + r.Height / 2f + bob * kk);
                    g.RotateTransform(-(float)(roll * 180 / Math.PI));
                    g.ScaleTransform(breathe, breathe);
                    // Огоньки агентов: задние — до картинки (за головой), передние — после.
                    int ag = mood != null ? Math.Min(5, mood.Agents) : 0;
                    List<KeyValuePair<PointF, bool>> lights = new List<KeyValuePair<PointF, bool>>();
                    if (ag > 0 && kk >= 10)
                        for (int i = 0; i < ag; i++) {
                            float ang = (animate ? t * 1.1f : 0f) + i * (float)(2 * Math.PI / ag) + ph;
                            lights.Add(new KeyValuePair<PointF, bool>(W2((float)Math.Cos(ang) * 0.98f, 0.12f + (float)Math.Sin(ang) * 0.26f), Math.Sin(ang) > 0));
                        }
                    Action<bool> drawLights = delegate (bool front) {
                        foreach (KeyValuePair<PointF, bool> l in lights) {
                            if (l.Value != front) continue;
                            float gr = kk * 0.13f, cr = kk * 0.055f;
                            using (SolidBrush gb = new SolidBrush(Color.FromArgb(70, 255, 214, 10))) g.FillEllipse(gb, l.Key.X - gr, l.Key.Y - gr, gr * 2, gr * 2);
                            using (SolidBrush cb = new SolidBrush(Theme.Hex(0xFFE066))) g.FillEllipse(cb, l.Key.X - cr, l.Key.Y - cr, cr * 2, cr * 2);
                        }
                    };
                    drawLights(false);
                    InterpolationMode im = g.InterpolationMode;
                    g.InterpolationMode = InterpolationMode.HighQualityBilinear;   // кадр уже в итоговом размере: только наклон и «дыхание»
                    g.DrawImage(spr, new RectangleF(-sw3 / 2f, -sh3 / 2f, sw3, sh3));
                    g.InterpolationMode = im;
                    drawLights(true);
                    float cosY = (float)Math.Cos(yaw), sinY = (float)Math.Sin(yaw);
                    // Рот — тонкая «w» под носом (у крупных).
                    if (yawn <= 0.05f && !sp.Tongue && kk > 16) {
                        PointF m0 = W2(0.55f * sinY, -0.31f);
                        float ns = kk * 0.07f;
                        using (Pen mp = new Pen(Color.FromArgb(150, Shade(skin, 0.45f)), Math.Max(1f, kk * 0.02f))) {
                            mp.StartCap = mp.EndCap = LineCap.Round;
                            g.DrawArc(mp, m0.X - ns * 1.6f, m0.Y - ns * 0.6f, ns * 1.6f, ns * 1.2f, 20, 140);
                            g.DrawArc(mp, m0.X, m0.Y - ns * 0.6f, ns * 1.6f, ns * 1.2f, 20, 140);
                        }
                    }
                    // Ошибка — крестики на закрытых глазах.
                    if (state == "error")
                        using (Pen xp = new Pen(Theme.Hex(0x1C1C1E), Math.Max(1f, kk * 0.05f))) {
                            xp.StartCap = xp.EndCap = LineCap.Round;
                            for (int k = -1; k <= 1; k += 2) {
                                PointF e = W2(k * 0.3f * cosY + 0.42f * sinY, -0.03f);
                                float a2 = kk * 0.11f;
                                g.DrawLine(xp, e.X - a2, e.Y - a2, e.X + a2, e.Y + a2); g.DrawLine(xp, e.X - a2, e.Y + a2, e.X + a2, e.Y - a2);
                            }
                        }
                    // Облачко мысли.
                    if (bubble != null && kk >= 12) {
                        PointF c = W2(1.0f, 0.5f), t1 = W2(0.66f, 0.18f), t2 = W2(0.8f, 0.3f);
                        Color bg = Color.FromArgb(235, 248, 246, 244);
                        using (SolidBrush bb = new SolidBrush(bg)) {
                            g.FillEllipse(bb, t1.X - kk * 0.035f, t1.Y - kk * 0.035f, kk * 0.07f, kk * 0.07f);
                            g.FillEllipse(bb, t2.X - kk * 0.055f, t2.Y - kk * 0.055f, kk * 0.11f, kk * 0.11f);
                            float bw = kk * 0.5f * pop, bh = kk * 0.3f * pop;
                            Draw.Fill(g, new RectangleF(c.X - bw / 2, c.Y - bh / 2, bw, bh), bh / 2f, bg);
                        }
                        if (bubble == "dots") {
                            for (int i = 0; i < 3; i++) {
                                float a = (float)Math.Max(0, Math.Sin(t * dotsSpeed - i * 0.7f));
                                float dr = kk * 0.038f;
                                using (SolidBrush db = new SolidBrush(Color.FromArgb((int)(70 + 185 * a), 60, 60, 66)))
                                    g.FillEllipse(db, c.X + (i - 1) * kk * 0.12f - dr, c.Y - dr - a * kk * 0.025f, dr * 2, dr * 2);
                            }
                        } else {
                            bool bang = bubble == "!";
                            float fy = bang ? 0 : -(float)((t * 0.5) % 1.0) * kk * 0.12f;
                            using (Font f = new Font("Segoe UI", Math.Max(6f, kk * (bang ? 0.26f : 0.22f) * pop), bang ? FontStyle.Bold : FontStyle.Italic | FontStyle.Bold, GraphicsUnit.Pixel))
                            using (StringFormat sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                            using (SolidBrush fb = new SolidBrush(bang ? Theme.Hex(0xFF9F0A) : Theme.Hex(0x6E6E73)))
                                g.DrawString(bang ? "!" : "z", f, fb, new PointF(c.X, c.Y + fy), sf);
                        }
                    }
                    g.Restore(gs);
                    return;
                }
            }
            // Запасной вариант без WPF 3D: объёмные части в 2D.
            float S = Math.Min(r.Width / 2.15f, r.Height / 1.72f) * breathe;
            float ox = r.X + r.Width / 2f, oy = r.Y + r.Height / 2f + 0.27f * S;
            List<Shape> shapes = new List<Shape>();

            Func<float, float, float, PointF> proj = delegate (float x, float y, float z) {
                float xr0 = x * (float)Math.Cos(roll) - y * (float)Math.Sin(roll);
                float yr0 = x * (float)Math.Sin(roll) + y * (float)Math.Cos(roll);
                float xr = xr0 * (float)Math.Cos(yaw) + z * (float)Math.Sin(yaw);
                return new PointF(ox + xr * S, oy - (yr0 + bob) * S);
            };
            Func<float, float, float> depth = delegate (float x, float z) { return -x * (float)Math.Sin(yaw) + z * (float)Math.Cos(yaw); };
            Action<float, float, float, float, float, float, Color, float, float> ellipsoid = delegate (float x, float y, float z, float rx, float ry, float rz, Color c, float lk, float dk) {
                PointF p = proj(x, y, z);
                float erx = S * (float)Math.Sqrt(Math.Pow(rx * Math.Cos(yaw), 2) + Math.Pow(rz * Math.Sin(yaw), 2));
                float ery = S * ry;
                shapes.Add(new Shape { Depth = depth(x, z), Paint = delegate (Graphics gg) { Blob(gg, p.X, p.Y, erx, ery, c, lk, dk); } });
            };

            ellipsoid(0f, 0.05f, 0f, 0.66f, 0.52f, 0.5f, skin, 1.12f, 0.74f);
            ellipsoid(0f, -0.24f, 0.2f, 0.44f, 0.28f, 0.34f, skin, 1.14f, 0.8f);
            ellipsoid(0f, -0.43f, 0.27f, 0.17f, 0.11f, 0.13f, skin, 1.12f, 0.82f);
            float headD = depth(0, 0);

            float tipX = state == "error" ? 1.05f : 0.92f, tipY = state == "error" ? 0.5f : 1.1f;
            if (stalled) { tipX = 0.98f; tipY = 0.85f; }
            for (int k = -1; k <= 1; k += 2) {
                float tw = k < 0 ? earL : earR;
                PointF a = proj(k * 0.58f, 0.08f, 0.02f), b = proj(k * 0.12f, 0.5f, 0.02f), tip = proj(k * (tipX + tw), tipY - tw, -0.02f);
                PointF ia = proj(k * 0.5f, 0.17f, 0.06f), ib = proj(k * 0.24f, 0.46f, 0.06f), itp = proj(k * (tipX - 0.1f + tw), tipY - 0.2f - tw, 0.03f);
                bool facing = depth(k * 0.4f, 0.3f) > -0.2f;
                shapes.Add(new Shape { Depth = headD - 0.01f, Paint = delegate (Graphics gg) {
                    using (LinearGradientBrush lb = new LinearGradientBrush(new PointF(tip.X, tip.Y - 1), new PointF(a.X, a.Y + 1), Shade(skin, 1.08f), Shade(skin, 0.74f)))
                        gg.FillPolygon(lb, new PointF[] { a, tip, b });
                    if (facing && S > 6)
                        using (LinearGradientBrush ib2 = new LinearGradientBrush(new PointF(itp.X, itp.Y - 1), new PointF(ia.X, ia.Y + 1), Shade(inner, 1.06f), Shade(inner, 0.86f)))
                            gg.FillPolygon(ib2, new PointF[] { ia, itp, ib });
                } });
            }

            // Огоньки агентов: кружат вокруг головы по наклонной орбите; задние — за головой.
            int agents = mood != null ? Math.Min(5, mood.Agents) : 0;
            if (agents > 0 && S >= 10) {
                for (int i = 0; i < agents; i++) {
                    float ang = (animate ? t * 1.1f : 0f) + i * (float)(2 * Math.PI / agents) + ph;
                    float ax = (float)Math.Cos(ang) * 0.98f, ay = 0.12f + (float)Math.Sin(ang) * 0.26f, az = (float)Math.Sin(ang) * 0.65f;
                    PointF ap = proj(ax, ay, az);
                    shapes.Add(new Shape { Depth = depth(ax, az) + (az > 0 ? 0.7f : 0f), Paint = delegate (Graphics gg) {
                        float gr = S * 0.13f, cr = S * 0.055f;
                        using (SolidBrush gb = new SolidBrush(Color.FromArgb(70, 255, 214, 10))) gg.FillEllipse(gb, ap.X - gr, ap.Y - gr, gr * 2, gr * 2);
                        using (SolidBrush cb = new SolidBrush(Theme.Hex(0xFFE066))) gg.FillEllipse(cb, ap.X - cr, ap.Y - cr, cr * 2, cr * 2);
                    } });
                }
            }

            shapes.Add(new Shape { Depth = headD + 0.6f, Paint = delegate (Graphics gg) {
                if (depth(0, 0.5f) < 0.15f) return;
                if (S > 14) using (Pen wp = new Pen(Color.FromArgb(70, Shade(skin, 0.6f)), Math.Max(1f, S * 0.022f))) {
                    wp.StartCap = wp.EndCap = LineCap.Round;
                    for (int w = 0; w < 3; w++) {
                        float wy = 0.36f - w * 0.075f, ww = 0.11f + w * 0.03f;
                        gg.DrawCurve(wp, new PointF[] { proj(-ww, wy - 0.02f, 0.46f), proj(0f, wy + 0.015f, 0.5f), proj(ww, wy - 0.02f, 0.46f) });
                    }
                }
                float big = (state == "permission" ? 1.16f : 1f) * eyeScale;
                float erx0 = S * 0.2f * big, ery0 = S * 0.21f * big;
                bool closed = sleep || blink || yawn > 0.3f;
                for (int k = -1; k <= 1; k += 2) {
                    PointF e = proj(k * 0.3f, -0.03f, 0.43f);
                    float ex = erx0 * Math.Max(0.3f, (float)Math.Cos(yaw + k * 0.45f)), ery = ery0;
                    using (SolidBrush lid = new SolidBrush(Color.FromArgb(90, Shade(skin, 0.62f))))
                        gg.FillEllipse(lid, e.X - ex * 1.18f, e.Y - ery * 1.16f, ex * 2.36f, ery * 2.3f);
                    if (state == "error") {
                        using (Pen xp = new Pen(eyeC, Math.Max(1f, S * 0.06f))) {
                            xp.StartCap = xp.EndCap = LineCap.Round;
                            float a2 = ery * 0.6f;
                            gg.DrawLine(xp, e.X - a2, e.Y - a2, e.X + a2, e.Y + a2); gg.DrawLine(xp, e.X - a2, e.Y + a2, e.X + a2, e.Y - a2);
                        }
                        continue;
                    }
                    if (closed) {
                        using (Pen cp = new Pen(Shade(skin, 0.45f), Math.Max(1f, S * 0.045f))) {
                            cp.StartCap = cp.EndCap = LineCap.Round;
                            if (ex > 1.5f) gg.DrawArc(cp, e.X - ex * 0.9f, e.Y - ery * 0.6f, ex * 1.8f, ery * 1.2f, 15, 150);
                            else gg.DrawLine(cp, e.X - ex, e.Y, e.X + ex, e.Y);
                        }
                        continue;
                    }
                    // Взгляд: глаз смещается в «глазнице» в сторону взгляда; прищур — глаз ниже и уже.
                    float gx = e.X + gazeX * ex * 0.22f, gy = e.Y - gazeY * ery * 0.2f;
                    float sq = squint, eh = ery * sq;
                    using (GraphicsPath ep = new GraphicsPath()) {
                        ep.AddEllipse(gx - ex, gy - eh + (ery - eh) * 0.6f, ex * 2, eh * 2);
                        using (PathGradientBrush eb = new PathGradientBrush(ep)) {
                            eb.CenterColor = Theme.Hex(0x2A2A30); eb.SurroundColors = new Color[] { eyeC };
                            eb.CenterPoint = new PointF(gx - ex * 0.2f, gy + eh * 0.25f);
                            gg.FillPath(eb, ep);
                        }
                    }
                    if (half) {
                        // Сонное веко: кожа закрывает верхнюю половину глаза.
                        using (SolidBrush lb2 = new SolidBrush(Shade(skin, 0.92f))) gg.FillPie(lb2, gx - ex * 1.05f, gy - eh * 1.05f, ex * 2.1f, eh * 2.1f, 180, 180);
                        using (Pen lp = new Pen(Shade(skin, 0.5f), Math.Max(1f, S * 0.03f))) gg.DrawLine(lp, gx - ex, gy, gx + ex, gy);
                    }
                    if (sq < 0.8f) using (Pen lp = new Pen(Shade(skin, 0.5f), Math.Max(1f, S * 0.035f))) {
                        lp.StartCap = lp.EndCap = LineCap.Round;
                        float ty = gy - eh + (ery - eh) * 0.6f;
                        gg.DrawLine(lp, gx - ex * 1.05f, ty, gx + ex * 1.05f, ty);
                    }
                    if (S > 7 && !half) {
                        float hr = eh * 0.32f / Math.Max(0.5f, sq);
                        float hx = gx + ex * 0.12f - gazeX * ex * 0.08f, hy = gy - eh * 0.62f + (ery - eh) * 0.6f;
                        using (SolidBrush hb = new SolidBrush(Color.FromArgb(240, 255, 255, 255))) gg.FillEllipse(hb, hx, hy, hr * 1.1f, Math.Min(hr, eh * 0.5f));
                        using (SolidBrush hb2 = new SolidBrush(Color.FromArgb(150, 255, 255, 255))) gg.FillEllipse(hb2, gx - ex * 0.5f, gy + eh * 0.35f, hr * 0.45f, hr * 0.4f);
                    }
                }
                PointF n = proj(0f, -0.22f, 0.53f);
                float ns = S * 0.075f;
                using (GraphicsPath np = new GraphicsPath()) {
                    np.AddBezier(n.X - ns, n.Y - ns * 0.55f, n.X - ns * 0.3f, n.Y - ns * 0.8f, n.X + ns * 0.3f, n.Y - ns * 0.8f, n.X + ns, n.Y - ns * 0.55f);
                    np.AddBezier(n.X + ns, n.Y - ns * 0.55f, n.X + ns * 0.8f, n.Y + ns * 0.2f, n.X + ns * 0.2f, n.Y + ns * 0.7f, n.X, n.Y + ns * 0.75f);
                    np.AddBezier(n.X, n.Y + ns * 0.75f, n.X - ns * 0.2f, n.Y + ns * 0.7f, n.X - ns * 0.8f, n.Y + ns * 0.2f, n.X - ns, n.Y - ns * 0.55f);
                    using (SolidBrush nb = new SolidBrush(noseC)) gg.FillPath(nb, np);
                }
                PointF m0 = proj(0f, -0.3f, 0.52f);
                if (yawn > 0.05f) {
                    // Зевок: рот открывается овалом.
                    float mw = S * 0.12f * yawn, mh = S * 0.16f * yawn;
                    using (SolidBrush mb = new SolidBrush(Theme.Hex(0x5A2B2E))) gg.FillEllipse(mb, m0.X - mw, m0.Y, mw * 2, mh * 2);
                    using (SolidBrush tb = new SolidBrush(Theme.Hex(0xF08A96))) gg.FillEllipse(tb, m0.X - mw * 0.6f, m0.Y + mh * 1.1f, mw * 1.2f, mh * 0.8f);
                } else if (S > 14) using (Pen mp = new Pen(Color.FromArgb(150, Shade(skin, 0.5f)), Math.Max(1f, S * 0.022f))) {
                    mp.StartCap = mp.EndCap = LineCap.Round;
                    gg.DrawLine(mp, n.X, n.Y + ns * 0.7f, m0.X, m0.Y);
                    gg.DrawArc(mp, m0.X - ns * 1.6f, m0.Y - ns * 0.6f, ns * 1.6f, ns * 1.2f, 20, 140);
                    gg.DrawArc(mp, m0.X, m0.Y - ns * 0.6f, ns * 1.6f, ns * 1.2f, 20, 140);
                }
                if (tongue && yawn <= 0.05f) {
                    // Кончик языка — старательно думает.
                    float tw2 = S * 0.085f, th = S * 0.075f * (0.75f + 0.25f * (float)Math.Sin(t * 3f));
                    using (SolidBrush tb = new SolidBrush(Theme.Hex(0xF07F8E))) gg.FillEllipse(tb, m0.X - tw2 * 0.35f, m0.Y + S * 0.025f, tw2, th * 1.3f);
                    using (Pen tl = new Pen(Color.FromArgb(120, 150, 50, 60), Math.Max(1f, S * 0.012f))) gg.DrawLine(tl, m0.X + tw2 * 0.15f, m0.Y + S * 0.04f, m0.X + tw2 * 0.15f, m0.Y + S * 0.025f + th);
                }
            } });

            // Облачко мысли у щеки: «…» (точки загораются по очереди), «!» (озарение) или «z» (уснул).
            if (bubble != null && S >= 12) {
                shapes.Add(new Shape { Depth = 99f, Paint = delegate (Graphics gg) {
                    PointF c = proj(1.02f, 0.42f, 0.3f), t1 = proj(0.66f, 0.12f, 0.4f), t2 = proj(0.8f, 0.24f, 0.4f);
                    Color bg = Color.FromArgb(235, 248, 246, 244);
                    using (SolidBrush bb = new SolidBrush(bg)) {
                        gg.FillEllipse(bb, t1.X - S * 0.035f, t1.Y - S * 0.035f, S * 0.07f, S * 0.07f);
                        gg.FillEllipse(bb, t2.X - S * 0.055f, t2.Y - S * 0.055f, S * 0.11f, S * 0.11f);
                        float bw = S * 0.5f * pop, bh = S * 0.3f * pop;
                        Draw.Fill(gg, new RectangleF(c.X - bw / 2, c.Y - bh / 2, bw, bh), bh / 2f, bg);
                    }
                    if (bubble == "dots") {
                        for (int i = 0; i < 3; i++) {
                            float a = (float)Math.Max(0, Math.Sin(t * dotsSpeed - i * 0.7f));
                            float dr = S * 0.038f;
                            using (SolidBrush db = new SolidBrush(Color.FromArgb((int)(70 + 185 * a), 60, 60, 66)))
                                gg.FillEllipse(db, c.X + (i - 1) * S * 0.12f - dr, c.Y - dr - a * S * 0.025f, dr * 2, dr * 2);
                        }
                    } else {
                        bool bang = bubble == "!";
                        float fy = bang ? 0 : -(float)((t * 0.5) % 1.0) * S * 0.12f;
                        using (Font f = new Font("Segoe UI", Math.Max(6f, S * (bang ? 0.26f : 0.22f) * pop), bang ? FontStyle.Bold : FontStyle.Italic | FontStyle.Bold, GraphicsUnit.Pixel))
                        using (StringFormat sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                        using (SolidBrush fb = new SolidBrush(bang ? Theme.Hex(0xFF9F0A) : Theme.Hex(0x6E6E73)))
                            gg.DrawString(bang ? "!" : "z", f, fb, new PointF(c.X, c.Y + fy), sf);
                    }
                } });
            }

            shapes.Sort(delegate (Shape x, Shape y) { return x.Depth.CompareTo(y.Depth); });
            foreach (Shape s in shapes) s.Paint(g);
        }
    }

    public sealed class CatMood {
        public float AhaAge = -1f;
        public bool Deep;
        public int Agents;
        public bool HasLook;
        public float LookX, LookY;
        public float LookW = 1f;          // 0..1 — насколько сфинкс сейчас смотрит на курсор (плавно растёт и спадает)
    }
}
