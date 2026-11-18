using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace ClaudeNotifier.Ui {
    // Поверхность layered-окна с попиксельной прозрачностью (UpdateLayeredWindow): гладкие, сглаженные края
    // шторки вместо ступенек «прозрачного цвета». Содержимое рисуется как обычно (GDI+ и текст GDI) в Content,
    // форма — сглаженной заливкой в Mask; итог = содержимое × покрытие формы. Текст GDI портит альфа-канал
    // (пишет 0), поэтому альфа берётся только из маски. Пересчитывается лишь изменившийся прямоугольник:
    // остальное уже лежит в DIB, Windows получает его целиком (копия ~2 МБ — доли миллисекунды).
    public sealed class LayeredSurface : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] struct SIZE { public int Cx, Cy; }
        [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
        [StructLayout(LayoutKind.Sequential)]
        struct BITMAPINFOHEADER {
            public int biSize, biWidth, biHeight; public short biPlanes, biBitCount;
            public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
        }
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
        [DllImport("gdi32.dll")] static extern bool GdiFlush();
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr h);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
        [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
        [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT dst, ref SIZE size, IntPtr hdcSrc, ref POINT src, int key, ref BLENDFUNCTION blend, int flags);

        IntPtr dc, dib, old, bits;            // итог для окна
        IntPtr cdc, cdib, cold, cbits;        // содержимое: DIB с контекстом GDI — текст GDI и GDI+ рисуют прямо в него, без копий
        public Bitmap Mask { get; private set; }
        // Graphics для содержимого (освобождать после рисования).
        public Graphics ContentGraphics() { return Graphics.FromHdc(cdc); }
        public int Width { get; private set; }
        public int Height { get; private set; }
        int[] crow, mrow, orow;

        public void Ensure(int w, int h) {
            if (w == Width && h == Height && Mask != null) return;
            Free();
            Width = w; Height = h;
            Mask = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
            BITMAPINFOHEADER bi = new BITMAPINFOHEADER();
            bi.biSize = Marshal.SizeOf(typeof(BITMAPINFOHEADER)); bi.biWidth = w; bi.biHeight = -h; bi.biPlanes = 1; bi.biBitCount = 32;
            dc = CreateCompatibleDC(IntPtr.Zero);
            dib = CreateDIBSection(dc, ref bi, 0, out bits, IntPtr.Zero, 0);
            old = SelectObject(dc, dib);
            cdc = CreateCompatibleDC(IntPtr.Zero);
            cdib = CreateDIBSection(cdc, ref bi, 0, out cbits, IntPtr.Zero, 0);
            cold = SelectObject(cdc, cdib);
            // При нехватке GDI-объектов любой из DIB может не создаться: без проверки Marshal.Copy читал бы
            // по нулевому адресу (AccessViolation, не перехватывается). Ensure повторится на следующем кадре.
            if (dc == IntPtr.Zero || dib == IntPtr.Zero || bits == IntPtr.Zero || cdc == IntPtr.Zero || cdib == IntPtr.Zero || cbits == IntPtr.Zero) {
                Free();
                throw new OutOfMemoryException("CreateDIBSection failed for layered surface " + w + "x" + h);
            }
            crow = new int[w]; mrow = new int[w]; orow = new int[w];
        }

        // Итог в DIB для прямоугольника d: цвет содержимого, умноженный на покрытие маски (предумноженная альфа).
        public void Compose(Rectangle d) {
            d.Intersect(new Rectangle(0, 0, Width, Height));
            if (d.Width <= 0 || d.Height <= 0 || bits == IntPtr.Zero || cbits == IntPtr.Zero || Mask == null) return;
            GdiFlush();   // дорисовать всё, что GDI держит в очереди
            BitmapData md = Mask.LockBits(d, ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
            try {
                int n = d.Width, W = Width, dx = d.X, dy = d.Y;
                long cs = cbits.ToInt64() + ((long)dy * W + dx) * 4, ms = md.Scan0.ToInt64(), bs = bits.ToInt64();
                int cstride = W * 4, mstride = md.Stride;
                Action<int, int[], int[], int[]> row = delegate (int y, int[] cr, int[] mr, int[] or) {
                    Marshal.Copy(new IntPtr(cs + (long)y * cstride), cr, 0, n);
                    Marshal.Copy(new IntPtr(ms + (long)y * mstride), mr, 0, n);
                    for (int x = 0; x < n; x++) {
                        uint m = (uint)mr[x] >> 24;
                        if (m == 0) { or[x] = 0; continue; }
                        uint c = (uint)cr[x];
                        if (m == 255) { or[x] = unchecked((int)(c | 0xFF000000u)); continue; }
                        uint b = ((c & 0xFF) * m + 127) / 255, g = (((c >> 8) & 0xFF) * m + 127) / 255, r = (((c >> 16) & 0xFF) * m + 127) / 255;
                        or[x] = unchecked((int)((m << 24) | (r << 16) | (g << 8) | b));
                    }
                    Marshal.Copy(or, 0, new IntPtr(bs + ((long)(dy + y) * W + dx) * 4), n);
                };
                if (d.Width * d.Height < 40000) {
                    for (int y = 0; y < d.Height; y++) row(y, crow, mrow, orow);
                } else {
                    // Большая область (раскрытие шторки) — строки параллельно, по полосам на ядро.
                    System.Threading.Tasks.Parallel.For(0, Math.Min(Environment.ProcessorCount, 8), delegate (int part) {
                        int parts = Math.Min(Environment.ProcessorCount, 8);
                        int[] cr = new int[n], mr = new int[n], or = new int[n];
                        for (int y = part; y < d.Height; y += parts) row(y, cr, mr, or);
                    });
                }
            } finally { Mask.UnlockBits(md); }
        }

        // Отдать картинку окну (и поставить его в screen).
        public bool Push(IntPtr hwnd, Point screen) {
            if (dc == IntPtr.Zero) return false;
            POINT dst = new POINT { X = screen.X, Y = screen.Y }, src = new POINT();
            SIZE size = new SIZE { Cx = Width, Cy = Height };
            BLENDFUNCTION bf = new BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
            return UpdateLayeredWindow(hwnd, IntPtr.Zero, ref dst, ref size, dc, ref src, 0, ref bf, 2 /* ULW_ALPHA */);
        }

        // Прозрачность пикселя итога (для проверок).
        public int AlphaAt(int x, int y) {
            if (bits == IntPtr.Zero || x < 0 || y < 0 || x >= Width || y >= Height) return -1;
            return (int)((uint)Marshal.ReadInt32(new IntPtr(bits.ToInt64() + ((long)y * Width + x) * 4)) >> 24);
        }

        void Free() {
            if (dc != IntPtr.Zero) { if (old != IntPtr.Zero) SelectObject(dc, old); DeleteDC(dc); dc = IntPtr.Zero; }
            if (dib != IntPtr.Zero) { DeleteObject(dib); dib = IntPtr.Zero; }
            bits = IntPtr.Zero; old = IntPtr.Zero;
            if (cdc != IntPtr.Zero) { if (cold != IntPtr.Zero) SelectObject(cdc, cold); DeleteDC(cdc); cdc = IntPtr.Zero; }
            if (cdib != IntPtr.Zero) { DeleteObject(cdib); cdib = IntPtr.Zero; }
            cbits = IntPtr.Zero; cold = IntPtr.Zero;
            if (Mask != null) { Mask.Dispose(); Mask = null; }
            Width = Height = 0;
        }

        public void Dispose() { Free(); }
    }
}
