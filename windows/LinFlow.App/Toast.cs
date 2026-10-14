using System.Drawing.Drawing2D;

namespace LinFlow.App;

/// A short-lived card that says what Lin Flow just learned from an edit. The Mac's ToastPanel.
///
/// Dictation almost always lands in some other app with the Lin Flow window shut, so a rule
/// learned from a real dictation existed, on the Mac, only as a line in the log, which is why the
/// dictionary felt broken there while it was quietly working. This floats above everything for a
/// few seconds, says what changed, and goes away by itself. A tray balloon would have been less
/// code, and Windows files those away in the notification center whenever Do not disturb is on.
///
/// It never takes the focus: he is usually still typing in the field it is about. It is clickable,
/// unlike the pill, because a click is how an offered rule gets added.
internal sealed class Toast : Form
{
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_TOPMOST = 0x00000008;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WM_MOUSEACTIVATE = 0x0021;
    private const int MA_NOACTIVATE = 3;

    private string _title = "", _detail = "";
    private bool _warning;
    private Action? _action;
    private readonly System.Windows.Forms.Timer _dismissal = new();

    // Read at a glance, from the corner of the eye, while typing something else. The Mac's 15 and
    // 13 point, which on this side are these sizes: the fonts are in points and already follow the
    // screen's DPI, so they are not scaled again.
    private static readonly Font TitleFont = new("Segoe UI Semibold", 11.25f);
    private static readonly Font DetailFont = new("Segoe UI", 9.75f);
    private static int S(int px) => Ui.S(px);
    private static int PadX => S(18);
    private static int PadY => S(14);
    private static int Dot => S(9);
    private static int Gap => S(11);
    private static int LineGap => S(5);
    private static int MaxTextWidth => S(420);

    public Toast()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(20, 20, 22);
        DoubleBuffered = true;
        Cursor = Cursors.Hand;
        Opacity = 0.96;
        _dismissal.Tick += (_, _) => HideToast();
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation => true;

    /// A click lands without making this the active window, so the caret stays where it was.
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_MOUSEACTIVATE)
        {
            m.Result = (IntPtr)MA_NOACTIVATE;
            return;
        }
        base.WndProc(ref m);
    }

    /// Shows the message for `seconds`, replacing whatever was up. `warning` turns the dot red,
    /// for something that went wrong rather than something learned. UI thread only.
    public void Show(string title, string detail, int seconds = 6, bool warning = false, Action? onClick = null)
    {
        _title = title;
        _detail = detail;
        _warning = warning;
        _action = onClick;
        Size = Measure();
        Location = Place(Size);
        Round();
        Invalidate();
        if (!Visible) Show();
        _dismissal.Stop();
        _dismissal.Interval = Math.Max(1, seconds) * 1000;
        _dismissal.Start();
    }

    public void HideToast()
    {
        _dismissal.Stop();
        if (Visible) Hide();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        var act = _action;
        HideToast();
        act?.Invoke();
    }

    private Size Measure()
    {
        var t = TextSize(_title, TitleFont);
        var d = TextSize(_detail, DetailFont);
        return new Size(Math.Max(t.Width, d.Width) + PadX * 2 + Dot + Gap,
                        t.Height + LineGap + d.Height + PadY * 2);
    }

    private static Size TextSize(string text, Font font) =>
        TextRenderer.MeasureText(text, font, new Size(MaxTextWidth, 0), TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);

    /// Just above where the pill sits, at the bottom left, so the pill can come up for the next
    /// dictation without covering this. Inside the working area either way: on the Mac a toast
    /// placed above a pill at the top of the screen landed past the edge every time, and John
    /// never saw one.
    private static Point Place(Size size)
    {
        var area = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1920, 1080);
        var pillTop = area.Bottom - S(52) - S(12);
        var x = area.Left + S(16);
        var y = pillTop - S(8) - size.Height;
        x = Math.Min(Math.Max(area.Left + S(8), x), Math.Max(area.Left + S(8), area.Right - size.Width - S(8)));
        y = Math.Min(Math.Max(area.Top + S(8), y), Math.Max(area.Top + S(8), area.Bottom - size.Height - S(8)));
        return new Point(x, y);
    }

    private void Round()
    {
        using var path = Rounded(new Rectangle(0, 0, Width, Height), S(16));
        Region?.Dispose();
        Region = new Region(path);
    }

    private static GraphicsPath Rounded(Rectangle r, int radius)
    {
        var path = new GraphicsPath();
        var d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var t = TextSize(_title, TitleFont);
        var d = TextSize(_detail, DetailFont);
        var x = PadX + Dot + Gap;
        var w = Math.Max(S(10), Width - x - PadX);

        using (var dot = new SolidBrush(_warning ? Color.FromArgb(242, 59, 59) : Color.FromArgb(76, 199, 107)))
            g.FillEllipse(dot, PadX, PadY + (t.Height - Dot) / 2, Dot, Dot);

        TextRenderer.DrawText(g, _title, TitleFont, new Rectangle(x, PadY, w, t.Height), Color.White,
            TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, _detail, DetailFont, new Rectangle(x, PadY + t.Height + LineGap, w, d.Height),
            Color.FromArgb(204, 204, 204), TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
    }
}
