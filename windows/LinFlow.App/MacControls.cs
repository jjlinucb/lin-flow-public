using System.Drawing.Drawing2D;

namespace LinFlow.App;

/// The controls the Mac's window is made of, drawn rather than themed.
///
/// WinForms' own controls cannot be styled this far - a TabControl's tabs, a ListView's column
/// headers and a CheckBox's box are drawn by the OS theme and ignore the colors set on them -
/// so the pieces that carry the look are painted here. Everything derives from Panel or Control
/// so it still lays out, scrolls and scales like any other WinForms control.
///
/// Measurements come from Mac and go through Ui.S. See Mac for why fonts do not.

// ---------------------------------------------------------------- sidebar

/// The section list down the left. One row per section: an accent-blue glyph, a label, and a
/// rounded grey pill behind whichever is current.
internal sealed class MacSidebar : Panel
{
    internal sealed record Item(string Name, string Glyph);

    private readonly List<Item> _items = new();
    private int _selected;
    private int _hot = -1;

    public event Action<int>? SelectionChanged;

    public int SelectedIndex
    {
        get => _selected;
        set
        {
            if (value == _selected || value < 0 || value >= _items.Count) return;
            _selected = value;
            Invalidate();
            SelectionChanged?.Invoke(value);
        }
    }

    public string SelectedName => _items.Count == 0 ? "" : _items[_selected].Name;

    public MacSidebar(IEnumerable<Item> items)
    {
        _items.AddRange(items);
        Dock = DockStyle.Left;
        Width = Ui.S(190);
        BackColor = Mac.SidebarBack;
        Padding = new Padding(0, Ui.S(24), 0, 0);
        Mac.DoubleBuffer(this);
    }

    private const int RowHeight = 32;
    private const int PillInset = 10;

    private Rectangle RowAt(int i) => new(
        0, Padding.Top + i * Ui.S(RowHeight), Width, Ui.S(RowHeight));

    private int IndexAt(Point p)
    {
        for (var i = 0; i < _items.Count; i++) if (RowAt(i).Contains(p)) return i;
        return -1;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var was = _hot;
        _hot = IndexAt(e.Location);
        if (was != _hot) Invalidate();
        base.OnMouseMove(e);
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        if (_hot != -1) { _hot = -1; Invalidate(); }
        base.OnMouseLeave(e);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        var i = IndexAt(e.Location);
        if (i >= 0) SelectedIndex = i;
        base.OnMouseDown(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        Mac.Smooth(g);
        using var icon = Mac.Icon(11f);

        for (var i = 0; i < _items.Count; i++)
        {
            var row = RowAt(i);
            if (i == _selected || i == _hot)
            {
                var pill = new Rectangle(
                    Ui.S(PillInset), row.Y, Width - Ui.S(PillInset * 2), row.Height);
                // Hover is the same pill at a fraction of the strength, which is how the Mac
                // distinguishes "you are here" from "you are about to go here".
                Mac.Fill(g, pill, Ui.S(7),
                    i == _selected ? Mac.SidebarPill : Color.FromArgb(70, Mac.SidebarPill));
            }

            var labelX = Ui.S(icon != null ? 47 : PillInset + 12);
            if (icon != null)
            {
                using var accent = new SolidBrush(Mac.Accent);
                var box = new Rectangle(Ui.S(22), row.Y, Ui.S(22), row.Height);
                g.DrawString(_items[i].Glyph, icon, accent, box,
                    new StringFormat { Alignment = StringAlignment.Near, LineAlignment = StringAlignment.Center });
            }

            using var ink = new SolidBrush(Mac.InkSidebar);
            g.DrawString(_items[i].Name, i == _selected ? Mac.BodySemibold : Mac.Body, ink,
                new Rectangle(labelX, row.Y, Width - labelX - Ui.S(8), row.Height),
                new StringFormat { LineAlignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap });
        }
    }
}

/// The app name and current section, drawn top-left above the sidebar the way the Mac's titlebar
/// carries them. WinForms has no subtitle in its own title bar, so it lives in the client area.
internal sealed class MacTitle : Panel
{
    private string _section = "";

    public string Section { get => _section; set { _section = value; Invalidate(); } }

    public MacTitle()
    {
        Dock = DockStyle.Top;
        Height = Ui.S(52);
        BackColor = Mac.SidebarBack;
        Mac.DoubleBuffer(this);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        Mac.Smooth(e.Graphics);
        using var ink = new SolidBrush(Mac.InkSidebar);
        using var grey = new SolidBrush(Mac.Grey);
        e.Graphics.DrawString("Lin Flow", Mac.TitleName, ink, Ui.S(22), Ui.S(10));
        e.Graphics.DrawString(_section, Mac.Small, grey, Ui.S(22), Ui.S(28));
    }
}

// ---------------------------------------------------------------- content

/// A section's page: white, with the Mac's content margins already applied. Add to Body.
internal sealed class MacPage : Panel
{
    public Panel Body { get; }

    public MacPage()
    {
        Dock = DockStyle.Fill;
        BackColor = Mac.Content;
        Body = new Panel { Dock = DockStyle.Fill, BackColor = Mac.Content };
        // 22 pt in from the sidebar, 26 down. The Mac pads 48 down for the macOS 26 glass zone
        // over the top of the detail pane; Windows has no such zone, so the port keeps the look
        // of the spacing without the whole 48.
        Body.Padding = new Padding(Ui.S(22), Ui.S(26), Ui.S(22), Ui.S(16));
        Controls.Add(Body);
    }
}

/// A bold section title with the grey sentence that always follows it. Every Mac page opens this
/// way and it is most of why the app reads as finished rather than as a settings dialog.
internal sealed class MacHeader : Panel
{
    private readonly string _title;
    private readonly string _description;

    public MacHeader(string title, string description)
    {
        _title = title;
        _description = description;
        Dock = DockStyle.Top;
        BackColor = Mac.Content;
        Mac.DoubleBuffer(this);
        Height = Ui.S(description.Length == 0 ? 36 : 76);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        Mac.Smooth(g);
        using var ink = new SolidBrush(Mac.Ink);
        using var grey = new SolidBrush(Mac.Grey);
        g.DrawString(_title, Mac.Header, ink, 0, 0);
        if (_description.Length == 0) return;
        // The box has to be the height OnResize worked out, not a fixed two lines: DrawString
        // clips to the rectangle it is given, so a description that wraps to three lines was
        // drawn with its last line cut in half even though the panel had grown to hold it.
        var box = new RectangleF(0, Ui.S(30), Math.Max(Ui.S(200), Width - Ui.S(40)),
            Math.Max(Ui.S(44), Height - Ui.S(30)));
        g.DrawString(_description, Mac.Body, grey, box);
    }

    /// The description wraps, so its height depends on the width it is given.
    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (_description.Length == 0) return;
        var wrapped = TextRenderer.MeasureText(_description, Mac.Body,
            new Size(Math.Max(Ui.S(200), Width - Ui.S(40)), 0), TextFormatFlags.WordBreak);
        Height = Ui.S(30) + wrapped.Height + Ui.S(14);
        Invalidate();
    }
}

/// A row whose height depends on the width it is given, because its text wraps. MacList calls
/// Fit before it stacks the rows, so the row is sized for the width it is about to get.
internal interface IWrappingRow
{
    void Fit(int width);
}

/// A scrolling list whose rows are separated by a hairline and nothing else - no grid, no column
/// headers, no selection highlight unless a row asks for one.
internal sealed class MacList : Panel
{
    public MacList()
    {
        Dock = DockStyle.Fill;
        BackColor = Mac.Content;
        AutoScroll = true;
        Mac.DoubleBuffer(this);
    }

    /// Shows these rows, in reading order.
    ///
    /// A row already in the list is kept rather than rebuilt, so a caller that hands back the
    /// same controls - the Dictation list does, after every dictation - costs one new row, and
    /// whatever is selected in the others stays selected. Anything not handed back is disposed.
    public void SetRows(IEnumerable<Control> rows)
    {
        var wanted = rows.ToList();
        var keep = new HashSet<Control>(wanted);
        SuspendLayout();
        try
        {
            // Dispose off a copy: disposing a control removes it from this collection, so
            // disposing while iterating it throws "collection was modified" - and it would have
            // thrown on the second refresh, not the first.
            foreach (var c in Controls.Cast<Control>().ToArray())
                if (!keep.Contains(c)) c.Dispose();

            // Rows dock to the top from the last child to the first, so the first row has to be
            // the last child. New rows go on in reverse, which is already the right order when
            // every row is new; then each row is moved to its place, bottom row first, and a
            // row that is already there does not move.
            for (var i = wanted.Count - 1; i >= 0; i--)
            {
                if (wanted[i].Parent == this) continue;
                wanted[i].Dock = DockStyle.Top;
                Controls.Add(wanted[i]);
            }
            for (var i = wanted.Count - 1; i >= 0; i--)
                Controls.SetChildIndex(wanted[i], wanted.Count - 1 - i);
        }
        finally
        {
            ResumeLayout(true);
        }
    }

    protected override void OnLayout(LayoutEventArgs levent)
    {
        // Rows whose text wraps work their height out for the width they are about to be
        // docked at, before the docking pass below stacks them. Suspended, so that each height
        // they set does not lay the whole list out again.
        var width = ClientSize.Width;
        SuspendLayout();
        try
        {
            foreach (Control c in Controls)
                if (c is IWrappingRow row) row.Fit(width);
        }
        finally
        {
            ResumeLayout(false);
        }
        base.OnLayout(levent);
    }

    /// A scrolling panel brings whatever takes the focus into view, so clicking into a
    /// dictation's text half off the bottom of the list would scroll the list under the pointer
    /// as the selection started. Stay where the reader put it.
    protected override Point ScrollToControl(Control activeControl) => AutoScrollPosition;
}

/// One row of a MacList: whatever the caller draws, a hairline under it, and an optional grey
/// trash glyph at the right end that turns red under the pointer.
internal sealed class MacRow : Panel
{
    private readonly Action<Graphics, Rectangle> _draw;
    private readonly Action? _delete;
    private bool _overTrash;
    private bool _selected;

    /// Set on the row the list is currently showing. Drawn as the same grey pill the sidebar
    /// uses for the current section, so "this one" means one thing throughout the app.
    public bool Selected
    {
        get => _selected;
        set { if (_selected == value) return; _selected = value; Invalidate(); }
    }

    /// Raised by a click anywhere except the trash glyph.
    public event Action? Activated;

    public MacRow(int height, Action<Graphics, Rectangle> draw, Action? delete = null)
    {
        _draw = draw;
        _delete = delete;
        Height = Ui.S(height);
        BackColor = Mac.Content;
        Mac.DoubleBuffer(this);
        if (delete != null) Cursor = Cursors.Default;
    }

    private Rectangle TrashBox => new(Width - Ui.S(34), 0, Ui.S(26), Height);

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var over = _delete != null && TrashBox.Contains(e.Location);
        if (over != _overTrash) { _overTrash = over; Invalidate(); }
        base.OnMouseMove(e);
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        if (_overTrash) { _overTrash = false; Invalidate(); }
        base.OnMouseLeave(e);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (_delete != null && TrashBox.Contains(e.Location)) _delete();
        else Activated?.Invoke();
        base.OnMouseDown(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        Mac.Smooth(g);
        if (_selected)
            Mac.Fill(g, new Rectangle(0, Ui.S(1), Width - Ui.S(8), Height - Ui.S(3)), Ui.S(6), Mac.SidebarPill);
        var content = new Rectangle(0, 0, Width - Ui.S(_delete != null ? 40 : 8), Height);
        _draw(g, content);

        if (_delete != null)
        {
            using var icon = Mac.Icon(9.5f);
            using var brush = new SolidBrush(_overTrash ? Color.FromArgb(0xD7, 0x00, 0x15) : Mac.Grey);
            if (icon != null)
                g.DrawString(Mac.GlyphTrash, icon, brush, TrashBox,
                    new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center });
            else
                g.DrawString("Remove", Mac.Small, brush, TrashBox,
                    new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center });
        }

        if (!_selected) Mac.Rule(g, 0, Width - Ui.S(8), Height - Ui.S(1), Mac.Hairline);
    }
}

/// The grey rounded button the Mac uses for "Add", "New" and the like. Accent is reserved for
/// selection and icons, so no button here is ever blue.
///
/// It derives from Button rather than Control so that everything already written against
/// WinForms buttons - Click, Enabled, DialogResult, AcceptButton - keeps working; only the
/// painting is taken over.
internal sealed class MacButton : Button
{
    private bool _hot, _down;

    public MacButton(string text)
    {
        Text = text;
        Font = Mac.Body;
        Cursor = Cursors.Hand;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
               | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        AutoSize = false;
        // TextRenderer measures without a Graphics, so the handle is not forced up inside the
        // constructor, before the button has a parent.
        var size = TextRenderer.MeasureText(text, Mac.Body);
        Size = new Size(size.Width + Ui.S(22), Ui.S(26));
    }

    protected override void OnMouseEnter(EventArgs e) { _hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hot = _down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { _down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        Mac.Smooth(g);
        using (var back = new SolidBrush(Parent?.BackColor ?? Mac.Content)) g.FillRectangle(back, ClientRectangle);
        var fill = !Enabled ? Color.FromArgb(0xF2, 0xF2, 0xF2)
                 : _down ? Color.FromArgb(0xCE, 0xCE, 0xCE)
                 : _hot ? Color.FromArgb(0xDE, 0xDE, 0xDE)
                 : Color.FromArgb(0xE9, 0xE9, 0xE9);
        Mac.Fill(g, new Rectangle(0, 0, Width, Height), Ui.S(6), fill);
        using var ink = new SolidBrush(Enabled ? Mac.Ink : Mac.Grey);
        g.DrawString(Text, Mac.Body, ink, ClientRectangle,
            new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center });
    }
}

/// A macOS switch. WinForms' CheckBox draws its box through the OS theme and ignores any color
/// set on it, so the whole control is painted.
internal sealed class MacSwitch : Control
{
    private bool _on;

    public event Action<bool>? Toggled;

    public bool On
    {
        get => _on;
        set { if (_on == value) return; _on = value; Invalidate(); }
    }

    public MacSwitch()
    {
        Size = Ui.S(38, 22);
        Cursor = Cursors.Hand;
        Mac.DoubleBuffer(this);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        _on = !_on;
        Invalidate();
        Toggled?.Invoke(_on);
        base.OnMouseDown(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var back = new SolidBrush(Parent?.BackColor ?? Mac.Content)) g.FillRectangle(back, ClientRectangle);
        var track = new Rectangle(0, 0, Width - 1, Height - 1);
        Mac.Fill(g, track, Height / 2, _on ? Mac.Accent : Color.FromArgb(0xE0, 0xE0, 0xE0));
        var d = Height - Ui.S(4);
        var knob = new Rectangle(_on ? Width - d - Ui.S(2) : Ui.S(2), Ui.S(2), d, d);
        using var white = new SolidBrush(Color.White);
        using var shadow = new SolidBrush(Color.FromArgb(40, 0, 0, 0));
        g.FillEllipse(shadow, knob.X, knob.Y + Ui.S(1), knob.Width, knob.Height);
        g.FillEllipse(white, knob);
    }
}

/// The rounded card a Settings group sits in: rows inside, each with a label on the left and its
/// control on the right, separated by the soft hairline.
internal sealed class MacCard : Panel
{
    public MacCard()
    {
        Dock = DockStyle.Top;
        BackColor = Mac.Content;
        // Not AutoSize: it and an explicit Height fight, and the loser is whichever ran last.
        // The card is exactly as tall as the rows put in it.
        Padding = new Padding(0, 0, 0, Ui.S(18));
        Height = Ui.S(18);
        Mac.DoubleBuffer(this);
        ControlAdded += (_, _) => Measure();
        ControlRemoved += (_, _) => Measure();
    }

    private void Measure()
    {
        var rows = 0;
        foreach (Control c in Controls) rows += c.Height;
        Height = rows + Padding.Bottom;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var card = new Rectangle(0, 0, Width - Ui.S(1), Height - Padding.Bottom - Ui.S(1));
        if (card.Height <= 0) return;
        Mac.Fill(e.Graphics, card, Ui.S(8), Color.FromArgb(0xFA, 0xFA, 0xFA));
        Mac.Outline(e.Graphics, card, Ui.S(8), Mac.HairlineSoft, Ui.S(1));
    }
}

/// One row inside a MacCard. The control on the right sizes itself; the label takes the rest.
internal sealed class MacCardRow : Panel
{
    private readonly string _label;
    private readonly bool _rule;

    public MacCardRow(string label, Control right, bool rule = true)
    {
        _label = label;
        _rule = rule;
        Dock = DockStyle.Top;
        Height = Ui.S(40);
        BackColor = Color.Transparent;
        Mac.DoubleBuffer(this);
        right.Anchor = AnchorStyles.Right | AnchorStyles.Top;
        right.Left = Width - right.Width - Ui.S(14);
        right.Top = (Height - right.Height) / 2;
        Controls.Add(right);
        Resize += (_, _) =>
        {
            right.Left = Width - right.Width - Ui.S(14);
            right.Top = (Height - right.Height) / 2;
        };
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        Mac.Smooth(g);
        using var ink = new SolidBrush(Mac.Ink);
        g.DrawString(_label, Mac.Body, ink, new Rectangle(Ui.S(14), 0, Width - Ui.S(160), Height),
            new StringFormat { LineAlignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter });
        if (_rule) Mac.Rule(g, Ui.S(14), Width - Ui.S(14), Height - Ui.S(1), Mac.HairlineSoft);
    }
}

/// The grey paragraph that sits under a settings group explaining it. Same role as the sentence
/// under a section header.
internal sealed class MacNote : Label
{
    public MacNote(string text)
    {
        Text = text;
        Dock = DockStyle.Top;
        Font = Mac.Body;
        ForeColor = Mac.Grey;
        BackColor = Mac.Content;
        AutoSize = false;
        Padding = new Padding(Ui.S(2), 0, Ui.S(40), Ui.S(16));
        Height = Ui.S(52);
    }

    /// Same as MacHeader's description: the text wraps, so how tall it needs to be depends on the
    /// width it ends up with. Two lines fit in the 52 it starts at; the hotkey paragraph is three
    /// at this width and had its last line cut off.
    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        Fit();
    }

    /// The shared totals note is rewritten as syncs finish, and a longer sentence needs the room.
    protected override void OnTextChanged(EventArgs e)
    {
        base.OnTextChanged(e);
        Fit();
    }

    private void Fit()
    {
        var box = Math.Max(Ui.S(200), Width - Padding.Horizontal);
        var wrapped = TextRenderer.MeasureText(Text, Font, new Size(box, 0), TextFormatFlags.WordBreak);
        var wanted = wrapped.Height + Padding.Vertical;
        if (Height != wanted) Height = wanted;
    }
}

/// The centered "nothing here yet" block: a big grey glyph, a bold line, a grey sentence.
internal sealed class MacEmpty : Panel
{
    private readonly string _glyph, _title, _detail;

    public MacEmpty(string glyph, string title, string detail)
    {
        _glyph = glyph;
        _title = title;
        _detail = detail;
        Dock = DockStyle.Fill;
        BackColor = Mac.Content;
        Mac.DoubleBuffer(this);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        Mac.Smooth(g);
        var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        var y = Height / 2 - Ui.S(60);
        using var faint = new SolidBrush(Color.FromArgb(0xC4, 0xC4, 0xC6));
        using var ink = new SolidBrush(Mac.Ink);
        using var grey = new SolidBrush(Mac.Grey);
        using var big = Mac.Icon(26f);
        if (big != null) g.DrawString(_glyph, big, faint, new Rectangle(0, y, Width, Ui.S(48)), center);
        g.DrawString(_title, Mac.BodySemibold, ink, new Rectangle(0, y + Ui.S(56), Width, Ui.S(24)), center);
        g.DrawString(_detail, Mac.Body, grey,
            new Rectangle(Width / 2 - Ui.S(160), y + Ui.S(82), Ui.S(320), Ui.S(52)),
            new StringFormat { Alignment = StringAlignment.Center });
    }
}

/// A text field with the Mac's rounded 1 pt border. WinForms' TextBox draws its own square
/// border through the theme, so the border is a panel around a borderless box.
internal sealed class MacField : Panel
{
    public TextBox Box { get; }

    public MacField(string placeholder, int width)
    {
        Box = new TextBox
        {
            BorderStyle = BorderStyle.None,
            Font = Mac.Body,
            PlaceholderText = placeholder,
            BackColor = Mac.Content,
            ForeColor = Mac.Ink,
        };
        Size = new Size(Ui.S(width), Ui.S(28));
        BackColor = Mac.Content;
        Mac.DoubleBuffer(this);
        Controls.Add(Box);
        Resize += (_, _) => Lay();
        Lay();
    }

    private void Lay()
    {
        Box.SetBounds(Ui.S(9), (Height - Box.PreferredHeight) / 2 + Ui.S(1),
            Width - Ui.S(18), Box.PreferredHeight);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        Mac.Outline(e.Graphics, new Rectangle(0, 0, Width, Height), Ui.S(6),
            Color.FromArgb(0xD5, 0xD5, 0xD5), Ui.S(1));
    }
}

/// The same rounded border MacField draws, but around a control that already exists. WinForms
/// draws a TextBox's own border through the OS theme, so the only way to round one is to turn
/// its border off and put the frame in the parent.
internal sealed class MacFrame : Panel
{
    public MacFrame(Control inner, int width, int height)
    {
        Size = new Size(Ui.S(width), Ui.S(height));
        BackColor = Mac.Content;
        Mac.DoubleBuffer(this);
        if (inner is TextBox box) box.BorderStyle = BorderStyle.None;
        inner.Font = Mac.Body;
        inner.BackColor = Mac.Content;
        inner.ForeColor = Mac.Ink;
        Controls.Add(inner);
        void Lay()
        {
            var h = inner is TextBox t && !t.Multiline ? t.PreferredHeight : Height - Ui.S(10);
            inner.SetBounds(Ui.S(9), Math.Max(Ui.S(4), (Height - h) / 2), Width - Ui.S(18), h);
        }
        Resize += (_, _) => Lay();
        Lay();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        Mac.Outline(e.Graphics, new Rectangle(0, 0, Width, Height), Ui.S(6),
            Color.FromArgb(0xD5, 0xD5, 0xD5), Ui.S(1));
    }
}
