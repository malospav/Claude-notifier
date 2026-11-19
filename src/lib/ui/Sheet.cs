// claude-notifier: окно-лист для диалогов (сообщения, вопросы, поле ввода, «Проверка работы», «Подключить устройство»).
// Без системной полосы заголовка (как ChromeForm): тень, скругление и тонкая рамка — от Windows 11. Сверху — значок
// события в цветном круге, справа — тихий крестик; окно перетаскивается за любое пустое место; Esc закрывает.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ClaudeNotifier.Ui {
    public class SheetForm : ChromeForm {
        Theme theme = Theme.Create(true);
        string glyph;
        Color glyphColor = Color.Empty;
        Rectangle closeRect;
        bool closeHot, closeDown;
        Font iconFont, closeFont;
        string kind = "none";

        public SheetForm() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false; MinimizeBox = false; ShowIcon = false; ShowInTaskbar = false;
            KeyPreview = true;
            CaptionHeight = int.MaxValue;   // перетаскивается за всё пустое место (над элементами — они сами)
            Fonts();
        }

        public Theme Theme { get { return theme; } set { theme = value ?? Theme.Create(true); BackColor = theme.Window; ForeColor = theme.Text; Fonts(); Invalidate(); } }

        // Значок сверху: info | ok | warn | error | edit | device | question | phone | update | none.
        public string Badge { get { return kind; } set { kind = value ?? "none"; Resolve(); Invalidate(); } }

        public static string GlyphFor(string k) {
            switch (k) {
                case "ok": return "";        // галочка
                case "warn": return "";      // предупреждение
                case "error": return "";     // ошибка
                case "edit": return "";      // карандаш
                case "device": return "";    // телефон / устройство
                case "question": return "";  // вопрос
                case "phone": return "";     // уведомление на телефон
                case "update": return "";    // скачать
                case "info": return "";      // сведения
                default: return null;
            }
        }

        void Resolve() {
            glyph = GlyphFor(kind);
            switch (kind) {
                case "ok": glyphColor = Theme.Hex(0x30D158); break;
                case "warn": glyphColor = Theme.Hex(0xFF9F0A); break;
                case "error": glyphColor = theme.Danger; break;
                default: glyphColor = theme.Accent; break;
            }
        }

        void Fonts() {
            if (iconFont != null) iconFont.Dispose();
            if (closeFont != null) closeFont.Dispose();
            iconFont = IconButton.IconFont(19f);
            closeFont = IconButton.IconFont(9f);
            Resolve();
        }

        // Где начинается содержимое (под значком).
        public int ContentTop { get { return glyph != null ? theme.S(24) + theme.S(52) + theme.S(16) : theme.S(30); } }
        public bool ShowClose = true;

        // Заданный размер содержимого: без системного заголовка рамка тоньше — после создания окна его подгоняем,
        // иначе под кнопками оставалась пустая полоса высотой с заголовок.
        Size wanted = Size.Empty;
        protected override void SetClientSizeCore(int x, int y) {
            wanted = new Size(x, y);
            base.SetClientSizeCore(x, y);
            if (IsHandleCreated) FitWanted();
        }

        void FitWanted() {
            if (wanted.IsEmpty) return;
            int dw = ClientSize.Width - wanted.Width, dh = ClientSize.Height - wanted.Height;
            if (dw != 0 || dh != 0) Size = new Size(Width - dw, Height - dh);
        }

        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e);
            Native.StyleWindow(Handle, theme);
            FitWanted();
        }

        protected override void OnLayout(LayoutEventArgs e) {
            base.OnLayout(e);
            int s = theme.S(28);
            closeRect = new Rectangle(ClientSize.Width - theme.S(12) - s, theme.S(12), s, s);
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(theme.Window);
            if (glyph != null) {
                int d = theme.S(52);
                Rectangle b = new Rectangle((ClientSize.Width - d) / 2, theme.S(24), d, d);
                using (SolidBrush halo = new SolidBrush(Color.FromArgb(theme.Dark ? 46 : 34, glyphColor))) g.FillEllipse(halo, b);
                TextRenderer.DrawText(g, glyph, iconFont ?? Font, b, glyphColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            }
            if (ShowClose) {
                if (closeHot) Draw.Fill(g, closeRect, closeRect.Height / 2f, closeDown ? theme.SurfaceSelected : theme.SurfaceHover);
                TextRenderer.DrawText(g, "", closeFont ?? Font, closeRect, closeHot ? theme.Text : theme.Muted,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            }
            base.OnPaint(e);
        }

        protected override void WndProc(ref Message m) {
            base.WndProc(ref m);
            // Крестик — обычная клиентская область (иначе щелчок ушёл бы на перетаскивание).
            if (m.Msg == 0x0084 && (int)m.Result == 2 && ShowClose) {
                int x = unchecked((short)((long)m.LParam & 0xFFFF)), y = unchecked((short)(((long)m.LParam >> 16) & 0xFFFF));
                if (closeRect.Contains(PointToClient(new Point(x, y)))) m.Result = (IntPtr)1;
            }
        }

        protected override void OnMouseMove(MouseEventArgs e) {
            base.OnMouseMove(e);
            bool h = ShowClose && closeRect.Contains(e.Location);
            if (h != closeHot) { closeHot = h; Invalidate(closeRect); Cursor = h ? Cursors.Hand : Cursors.Default; }
        }

        protected override void OnMouseLeave(EventArgs e) {
            base.OnMouseLeave(e);
            if (closeHot || closeDown) { closeHot = false; closeDown = false; Invalidate(closeRect); Cursor = Cursors.Default; }
        }

        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            if (closeHot && e.Button == MouseButtons.Left) { closeDown = true; Invalidate(closeRect); }
        }

        protected override void OnMouseUp(MouseEventArgs e) {
            base.OnMouseUp(e);
            if (closeDown && closeRect.Contains(e.Location)) { DialogResult = DialogResult.Cancel; Close(); }
            closeDown = false;
        }

        protected override void OnKeyDown(KeyEventArgs e) {
            base.OnKeyDown(e);
            if (!e.Handled && e.KeyCode == Keys.Escape && CancelButton == null) { DialogResult = DialogResult.Cancel; Close(); e.Handled = true; }
        }

        protected override void Dispose(bool disposing) {
            if (disposing) { if (iconFont != null) iconFont.Dispose(); if (closeFont != null) closeFont.Dispose(); }
            base.Dispose(disposing);
        }
    }
}
