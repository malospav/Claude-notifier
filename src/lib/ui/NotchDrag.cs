// claude-notifier: перетаскивание плашек сеансов на главной раскрытой шторки.
// Возьмите плашку мышью и перенесите: она едет за курсором (чуть крупнее, с тенью), остальные плавно раздвигаются,
// на месте вставки — пустое место. Отпустили — порядок меняется сразу, трей запоминает его (notch-order.json).
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace ClaudeNotifier.Ui {
    public sealed partial class NotchView {
        string chipDrag;              // какую плашку взяли
        Point chipDragStart, chipDragPos;
        bool chipDragging;
        readonly List<KeyValuePair<string, Rectangle>> chipSlots = new List<KeyValuePair<string, Rectangle>>();   // места плашек (координаты окна)

        public bool ChipDragging { get { return chipDragging; } }

        bool ChipMouseDown(MouseEventArgs e, string hit) {
            if (e.Button != MouseButtons.Left || hit == null || !hit.StartsWith("item:") || !SessionPage) return false;
            chipDrag = hit.Substring(5); chipDragStart = e.Location; chipDragPos = e.Location; chipDragging = false;
            return false;   // щелчок по-прежнему выбирает сеанс, если не потянули
        }

        bool ChipMouseMove(MouseEventArgs e) {
            if (chipDrag == null || (Control.MouseButtons & MouseButtons.Left) == 0) { chipDrag = null; chipDragging = false; return false; }
            int dx = e.X - chipDragStart.X, dy = e.Y - chipDragStart.Y;
            if (!chipDragging && dx * dx + dy * dy > theme.S(6) * theme.S(6)) { chipDragging = true; pressed = null; }
            if (!chipDragging) return false;
            chipDragPos = e.Location;
            WakeUi(); Invalidate();
            return true;
        }

        // Отпустили: true — это было перетаскивание (щелчок не обрабатывать).
        bool ChipMouseUp(MouseEventArgs e) {
            if (chipDrag == null) return false;
            string id = chipDrag; bool was = chipDragging;
            chipDrag = null; chipDragging = false;
            if (!was) return false;
            string before = DropTarget(e.Location, id);
            MoveItem(id, before);
            EventHandler<NotchEventArgs> h = Command;
            if (h != null) h(this, new NotchEventArgs("order", id, before ?? "", PointToScreen(e.Location)));
            Invalidate();
            return true;
        }

        // Перед какой плашкой встанет перетаскиваемая (null — в конец).
        string DropTarget(Point p, string dragged) {
            string best = null; double bestD = double.MaxValue; bool after = false;
            foreach (KeyValuePair<string, Rectangle> s in chipSlots) {
                if (s.Key == dragged) continue;
                Rectangle r = s.Value;
                double cx = r.X + r.Width / 2.0, cy = r.Y + r.Height / 2.0, d = (p.X - cx) * (p.X - cx) + (p.Y - cy) * (p.Y - cy) * 4;
                if (d < bestD) { bestD = d; best = s.Key; after = p.X > cx && Math.Abs(p.Y - cy) < r.Height; }
            }
            if (best == null) return null;
            if (!after) return best;
            // После найденной — значит перед следующей за ней.
            for (int i = 0; i < items.Count - 1; i++) if (items[i].Id == best) return items[i + 1].Id == dragged ? (i + 2 < items.Count ? items[i + 2].Id : null) : items[i + 1].Id;
            return null;
        }

        void MoveItem(string id, string before) {
            int from = items.FindIndex(delegate (NotchItem x) { return x.Id == id; });
            if (from < 0) return;
            NotchItem it = items[from];
            items.RemoveAt(from);
            int to = before == null ? items.Count : items.FindIndex(delegate (NotchItem x) { return x.Id == before; });
            if (to < 0) to = items.Count;
            items.Insert(to, it);
        }

        // Плашка, которую тянут, — поверх всего, у курсора, чуть крупнее и с тенью.
        void PaintDraggedChip(Graphics g) {
            if (!chipDragging || chipDrag == null) return;
            NotchItem it = null;
            foreach (NotchItem x in items) if (x.Id == chipDrag) it = x;
            Rectangle slot = Rectangle.Empty;
            foreach (KeyValuePair<string, Rectangle> s in chipSlots) if (s.Key == chipDrag) slot = s.Value;
            if (it == null || slot.Width == 0) return;
            float w = slot.Width * 1.04f, h = slot.Height * 1.04f;
            float x0 = chipDragPos.X - origin.X - (chipDragStart.X - slot.X), y0 = chipDragPos.Y - origin.Y - (chipDragStart.Y - slot.Y);
            RectangleF r = new RectangleF(x0 - (w - slot.Width) / 2, y0 - (h - slot.Height) / 2, w, h);
            using (SolidBrush sh = new SolidBrush(Color.FromArgb(90, 0, 0, 0))) g.FillEllipse(sh, r.X + r.Width * 0.08f, r.Bottom - theme.S(4), r.Width * 0.84f, theme.S(10));
            Draw.Fill(g, r, r.Height / 2f, Pal(0x3A3A3C));
            float fh = h * 0.62f, fw = fh * 1.3f;
            PaintFace(g, new RectangleF(r.X + theme.S(8), r.Y + (h - fh) / 2, fw, fh), it, false);
            TextRenderer.DrawText(g, it.Title, fBold, new Rectangle((int)(r.X + theme.S(16) + fw), (int)r.Y, (int)(r.Width - fw - theme.S(24)), (int)h), Fg,
                TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
        }
    }
}
