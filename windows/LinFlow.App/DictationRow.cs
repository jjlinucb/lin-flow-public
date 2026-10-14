using System.Runtime.InteropServices;
using LinFlow.Core;

namespace LinFlow.App;

/// One dictation in the Dictation list: when it was, what was said, how fast the engine was, a
/// copy button, and the hairline under it.
///
/// It was a painted MacRow like every other row in the window until 2026-09-23, when John found
/// he could not copy a dictation out of the list. That is most of what the list is for once a
/// paste has missed: the paste only borrows the clipboard and puts the old contents back 0.4 s
/// later, so a dictation that landed nowhere is not on the clipboard either. The Mac's row has
/// selectable text and a copy button (DictationRow in DashboardView.swift), and so does this
/// one. The text is a real read-only TextBox, so selecting part of it, Ctrl+C and Ctrl+A work
/// the way they do everywhere else in Windows; the time, the speed and the button are painted.
///
/// The text wraps, so the row's height depends on its width, and the list sets both through Fit.
internal sealed class DictationRow : Panel, IWrappingRow
{
    // 96-DPI pixels, through Ui.S like every other measurement in the window. PadBottom is under
    // the text box, which ends two pixels below its last line (see Fit).
    private const int PadTop = 7, PadBottom = 5, TextLeft = 80, TimeWidth = 70;
    private const int SpeedWidth = 44, ButtonWidth = 26, RightMargin = 8;

    private readonly string _dictation, _time, _speed;
    private readonly Words _words;
    private bool _overButton;
    private string? _flash;                 // "Copied", briefly, where the speed usually is
    private System.Windows.Forms.Timer? _revert;
    private int _fittedWidth = -1;

    /// Where a copy goes. A check replaces it, so that it never writes to John's clipboard.
    internal static Action<string> SetClipboard = text => Clipboard.SetText(text, TextDataFormat.UnicodeText);

    public DictationRow(string time, string dictation, string speed)
    {
        _time = time;
        _dictation = dictation;
        _speed = speed;
        BackColor = Mac.Content;
        Mac.DoubleBuffer(this);
        ContextMenuStrip = Menu;

        // The edit control breaks lines only at \r\n, and a dictation keeps the \n it was
        // spoken with. A trailing one would only add an empty line under the text.
        _words = new Words(this, dictation.Replace("\r\n", "\n").Replace("\n", "\r\n").TrimEnd());
        Controls.Add(_words);
        Height = Ui.S(30);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _revert?.Dispose();
        base.Dispose(disposing);
    }

    /// One line of the list's font, as the edit control spaces its lines.
    private static int LineHeight => _lineHeight ??= TextRenderer.MeasureText("Ag", Mac.Body,
        new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Height;
    private static int? _lineHeight;

    /// Shared rather than made per paint: every row paints its button, and a list of them
    /// repaints on every resize.
    private static readonly Font? IconFont = Mac.Icon(9.5f);

    private Rectangle ButtonBox => new(
        Width - Ui.S(RightMargin + ButtonWidth), Ui.S(PadTop) + LineHeight / 2 - Ui.S(ButtonWidth) / 2,
        Ui.S(ButtonWidth), Ui.S(ButtonWidth));

    private Rectangle SpeedBox => new(ButtonBox.Left - Ui.S(4 + SpeedWidth), Ui.S(PadTop), Ui.S(SpeedWidth), LineHeight);

    public void Fit(int width)
    {
        if (width == _fittedWidth) return;
        _fittedWidth = width;
        var textWidth = Math.Max(Ui.S(120),
            width - Ui.S(RightMargin + ButtonWidth + 4 + SpeedWidth + 12 + TextLeft));
        // The line count is the edit control's own, so it wraps exactly as it will be drawn,
        // and it needs a window to have one.
        _ = _words.Handle;
        _words.SetBounds(Ui.S(TextLeft), Ui.S(PadTop), textWidth, _words.Height);
        // A pixel or two to spare: an edit control whose last line is even partly hidden
        // scrolls it into view as a selection is dragged down, and the text jumps up a line.
        var text = _words.LineCount * LineHeight + Ui.S(2);
        _words.Height = text;
        Height = Math.Max(Ui.S(30), Ui.S(PadTop) + text + Ui.S(PadBottom));
    }

    /// Copies the dictation, or just `selection` when part of it is selected, and says so on
    /// the row for a moment.
    internal void Copy(string? selection)
    {
        var text = selection ?? _dictation;
        if (text.Length == 0) return;
        try
        {
            SetClipboard(text);
            _flash = "Copied";
        }
        catch (Exception e)
        {
            // Another app can hold the clipboard open, and SetText has already retried.
            Log.Info($"could not copy a dictation: {e.Message}");
            _flash = "Not copied";
        }
        Invalidate();
        _revert ??= RevertTimer();
        _revert.Stop();
        _revert.Start();
    }

    private System.Windows.Forms.Timer RevertTimer()
    {
        var timer = new System.Windows.Forms.Timer { Interval = 1500 };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            _flash = null;
            Invalidate();
        };
        return timer;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var over = ButtonBox.Contains(e.Location);
        if (over != _overButton)
        {
            _overButton = over;
            Cursor = over ? Cursors.Hand : Cursors.Default;
            Invalidate(ButtonBox);
        }
        base.OnMouseMove(e);
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        if (_overButton)
        {
            _overButton = false;
            Cursor = Cursors.Default;
            Invalidate(ButtonBox);
        }
        base.OnMouseLeave(e);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left && ButtonBox.Contains(e.Location)) Copy(null);
        base.OnMouseDown(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        // GDI rather than GDI+ for the words beside the text, so they sit on the same baseline
        // as the text, which the edit control draws with GDI.
        const TextFormatFlags line = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine;
        TextRenderer.DrawText(g, _time, Mac.Body,
            new Rectangle(Ui.S(2), Ui.S(PadTop), Ui.S(TimeWidth), LineHeight), Mac.Grey, line);
        var aside = _flash ?? _speed;
        if (aside.Length > 0)
            TextRenderer.DrawText(g, aside, Mac.Small, SpeedBox, Mac.Grey,
                line | TextFormatFlags.Right | TextFormatFlags.VerticalCenter);

        Mac.Smooth(g);
        var copied = _flash == "Copied";
        using var brush = new SolidBrush(copied ? Mac.Accent : _overButton ? Mac.Ink : Mac.Grey);
        var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        if (IconFont != null)
            g.DrawString(copied ? Mac.GlyphCheck : Mac.GlyphCopy, IconFont, brush, ButtonBox, center);
        else
            g.DrawString("Copy", Mac.Small, brush, ButtonBox, center);

        Mac.Rule(g, 0, Width - Ui.S(RightMargin), Height - Ui.S(1), Mac.Hairline);
    }

    // ---------- the shared menu ----------

    private static ContextMenuStrip? _menu;

    /// One menu for every row, built on first use: three hundred rows do not need three hundred
    /// menus. "Copy" takes the selection when there is one, and the whole dictation otherwise.
    private static ContextMenuStrip Menu => _menu ??= BuildMenu();

    private static ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        var copy = new ToolStripMenuItem("Copy");
        var all = new ToolStripMenuItem("Select all");
        menu.Items.AddRange(new ToolStripItem[] { copy, all });

        DictationRow? Row() => menu.SourceControl switch
        {
            Words w => w.Row,
            DictationRow r => r,
            _ => null,
        };

        // Read as the menu opens, while the text still has the focus. A selection in a row
        // that does not have the focus is hidden, and copying something invisible would be
        // a surprise.
        string? selection = null;
        menu.Opening += (_, _) =>
        {
            var words = Row()?._words;
            selection = words is { Focused: true, SelectionLength: > 0 } ? words.SelectedText : null;
            copy.Text = selection is null ? "Copy dictation" : "Copy";
        };
        copy.Click += (_, _) => Row()?.Copy(selection);
        all.Click += (_, _) =>
        {
            if (Row()?._words is not { } words) return;
            words.Focus();
            words.SelectAll();
        };
        return menu;
    }

    // ---------- the text ----------

    /// The dictation itself: read-only, borderless, wrapped to the width Fit gives it.
    private sealed class Words : TextBox
    {
        public DictationRow Row { get; }

        public Words(DictationRow row, string text)
        {
            Row = row;
            Multiline = true;
            WordWrap = true;
            ReadOnly = true;
            ScrollBars = ScrollBars.None;
            BorderStyle = BorderStyle.None;
            TabStop = false;
            Font = Mac.Body;
            // After ReadOnly, which otherwise grays the background like a disabled field.
            BackColor = Mac.Content;
            ForeColor = Mac.Ink;
            Text = text;
            ContextMenuStrip = Menu;
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            // No inner margins, so the text starts exactly where the row puts it and wraps at
            // exactly the width Fit set.
            SendMessage(Handle, EM_SETMARGINS, (IntPtr)(EC_LEFTMARGIN | EC_RIGHTMARGIN), IntPtr.Zero);
        }

        /// How many lines the text wraps to at the current width.
        public int LineCount => (int)SendMessage(Handle, EM_GETLINECOUNT, IntPtr.Zero, IntPtr.Zero);

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            switch (keyData)
            {
                // With nothing selected, Ctrl+C copies the whole dictation - what a list does
                // with the item it has selected - rather than nothing at all.
                case Keys.Control | Keys.C:
                case Keys.Control | Keys.Insert:
                    Row.Copy(SelectionLength > 0 ? SelectedText : null);
                    return true;
                case Keys.Control | Keys.A:
                    SelectAll();
                    return true;
            }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        protected override void WndProc(ref Message m)
        {
            // An edit control keeps the wheel even when it has nothing to scroll, so the list
            // would stop scrolling whenever the pointer was over a dictation's text.
            if (m.Msg == WM_MOUSEWHEEL && Row.Parent is { IsHandleCreated: true } list)
            {
                SendMessage(list.Handle, m.Msg, m.WParam, m.LParam);
                return;
            }
            base.WndProc(ref m);
        }

        private const int WM_MOUSEWHEEL = 0x020A;
        private const int EM_GETLINECOUNT = 0x00BA;
        private const int EM_SETMARGINS = 0x00D3;
        private const int EC_LEFTMARGIN = 0x1, EC_RIGHTMARGIN = 0x2;

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    }
}
