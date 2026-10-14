using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace LinFlow.App;

/// A floating pill near the bottom of the screen that says what Lin Flow is doing, because the
/// tray dot is not an indicator anybody can actually see.
///
/// Windows 11 hides a new tray icon in the overflow flyout by default, so the dot that tells you a
/// recording is running sits behind a chevron you have to click. On 2026-09-18 John could not tell
/// whether the app had heard him at all, which is the one thing hold-to-talk has to make obvious.
/// The Mac solves it with a floating pill; this is the same idea.
///
/// The window must never take focus. Dictation pastes into whatever had focus when the key went
/// down, so a pill that activated would paste into itself. WS_EX_NOACTIVATE keeps it out of the
/// activation order, WS_EX_TRANSPARENT lets clicks fall through to whatever is underneath, and
/// WS_EX_TOOLWINDOW keeps it out of Alt+Tab.
internal sealed class Indicator : Form
{
    private const int WS_EX_TRANSPARENT = 0x00000020;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_TOPMOST = 0x00000008;
    private const int WS_EX_NOACTIVATE = 0x08000000;

    private string _label = "";
    private Color _color = Color.Gray;

    /// Every number in this file is written for a 96-DPI screen and goes through Ui.S. The pill is
    /// drawn by hand rather than laid out from controls, so on John's 200% laptop it was rendering
    /// 115x26 physical pixels, a sliver - an indicator built to be unmissable that could not be
    /// seen.
    private static int S(int px) => Ui.S(px);

    public Indicator()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(18, 18, 20);
        DoubleBuffered = true;
        Size = new Size(S(230), S(52));
        Opacity = 0.92;
        Reposition();
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    /// Stops the pill stealing focus from the field being dictated into.
    protected override bool ShowWithoutActivation => true;

    /// Bottom left, just above the taskbar, rather than centered: centered sits over whatever you
    /// are dictating into, and John wanted it somewhere a screenshot would catch alongside the
    /// taskbar. WorkingArea already excludes the taskbar, wherever it is docked.
    private void Reposition()
    {
        var area = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1920, 1080);
        Location = new Point(area.Left + S(16), area.Bottom - Height - S(12));
    }

    /// Rounded corners, drawn rather than shipped as an image.
    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        using var path = new GraphicsPath();
        var r = S(26);
        var rect = new Rectangle(0, 0, Width, Height);
        path.AddArc(rect.X, rect.Y, r, r, 180, 90);
        path.AddArc(rect.Right - r, rect.Y, r, r, 270, 90);
        path.AddArc(rect.Right - r, rect.Bottom - r, r, r, 0, 90);
        path.AddArc(rect.X, rect.Bottom - r, r, r, 90, 90);
        path.CloseFigure();
        Region = new Region(path);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        using var dot = new SolidBrush(_color);
        g.FillEllipse(dot, S(18), Height / 2 - S(8), S(16), S(16));

        // The font is in points, so GDI+ already renders it at the screen's DPI: it is the only
        // thing here that was the right size all along, and scaling it again would double it.
        using var font = new Font("Segoe UI", 11f, FontStyle.Regular);
        using var text = new SolidBrush(Color.FromArgb(240, 240, 245));
        var size = g.MeasureString(_label, font);
        g.DrawString(_label, font, text, S(46), (Height - size.Height) / 2);
    }

    /// Called from the UI thread only. Anything else must marshal.
    public void Show(string label, Color color)
    {
        _label = label;
        _color = color;
        Reposition();
        if (!Visible) Show();
        Invalidate();
    }

    public void HidePill()
    {
        if (Visible) Hide();
    }
}
