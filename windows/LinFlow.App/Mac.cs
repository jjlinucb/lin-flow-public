using System.Drawing.Drawing2D;
using System.Drawing.Text;

namespace LinFlow.App;

/// The Mac app's look, in WinForms.
///
/// Every color and measurement here was sampled off screenshots of the running Mac app rather
/// than guessed; `design/README.md` at the repo root has the table, the seven page captures and
/// the command that takes them again. Two things from that file are worth repeating because
/// getting either wrong makes the port look like a different application:
///
/// 1. The sidebar icons are accent blue, selected or not. Selection is the grey pill and the
///    label turning semibold. The first set of reference screenshots was taken with the window
///    inactive, where macOS greys the lot, and a port built from those would have no color in
///    it at all.
/// 2. macOS sizes are points at 1x, which are device-independent pixels; WinForms font sizes are
///    points at 96 dpi. So fonts are the Mac's size x 0.75 and boxes are the Mac's size 1:1,
///    which lands both on the same number of logical pixels. Boxes then go through Ui.S for the
///    screen's real DPI; fonts must not, because GDI+ has already drawn them at it.
internal static class Mac
{
    // ---------- color ----------

    public static readonly Color SidebarBack = Color.FromArgb(0xED, 0xED, 0xEC);
    public static readonly Color SidebarPill = Color.FromArgb(0xD7, 0xD7, 0xD6);
    public static readonly Color Content = Color.White;
    public static readonly Color Ink = Color.FromArgb(0x27, 0x27, 0x27);
    public static readonly Color InkSidebar = Color.Black;
    public static readonly Color Grey = Color.FromArgb(0x80, 0x80, 0x80);
    public static readonly Color Hairline = Color.FromArgb(0xE6, 0xE6, 0xE6);
    public static readonly Color HairlineSoft = Color.FromArgb(0xEB, 0xEB, 0xEB);
    public static readonly Color Accent = Color.FromArgb(0x00, 0x7A, 0xFF);
    public static readonly Color Block = Color.FromArgb(0xF3, 0xF3, 0xF3);
    public static readonly Color Badge = Color.FromArgb(0xE6, 0xE6, 0xE6);

    // ---------- type ----------
    //
    // Sizes are the Mac's x 0.75. "Segoe UI Semibold" is a real family on Windows, not a style
    // flag, so it is named rather than asked for with FontStyle.Bold - bold Segoe is heavier than
    // the Mac's semibold and reads as shouting next to it.

    public static readonly Font Header = new("Segoe UI Semibold", 12.75f);
    public static readonly Font Body = new("Segoe UI", 9.75f);
    public static readonly Font BodySemibold = new("Segoe UI Semibold", 9.75f);
    public static readonly Font Small = new("Segoe UI", 8.25f);
    public static readonly Font TitleName = new("Segoe UI Semibold", 9.75f);

    /// Segoe's icon font, by whichever name this Windows has it under. Windows 11 ships "Segoe
    /// Fluent Icons"; Windows 10 ships "Segoe MDL2 Assets" and the glyphs used here exist in
    /// both. If neither is installed every glyph would draw as a tofu box, so callers check
    /// HasIcons and lay out without them instead.
    public static readonly string? IconFamily = FindIconFamily();
    public static bool HasIcons => IconFamily != null;

    private static string? FindIconFamily()
    {
        using var installed = new InstalledFontCollection();
        var names = installed.Families.Select(f => f.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var candidate in new[] { "Segoe Fluent Icons", "Segoe MDL2 Assets" })
            if (names.Contains(candidate)) return candidate;
        return null;
    }

    public static Font? Icon(float size) => IconFamily is { } f ? new Font(f, size) : null;

    // Glyphs, in both icon fonts. The Mac uses SF Symbols, which Windows does not have; these are
    // the nearest Segoe equivalents for the four sections the Windows port actually has.
    public const string GlyphMic = "";        // Microphone
    public const string GlyphNote = "";       // Page
    public const string GlyphBook = "";       // ReadingMode
    public const string GlyphGear = "";       // Settings
    public const string GlyphTrash = "";      // Delete
    public const string GlyphPlus = "";       // Add
    public const string GlyphCopy = "";       // Copy
    public const string GlyphCheck = "";      // CheckMark

    // ---------- drawing ----------

    public static GraphicsPath Round(Rectangle r, int radius)
    {
        var path = new GraphicsPath();
        var d = radius * 2;
        if (d <= 0 || d > r.Width || d > r.Height) { path.AddRectangle(r); return path; }
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static void Fill(Graphics g, Rectangle r, int radius, Color color)
    {
        var was = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Round(r, radius);
        using var brush = new SolidBrush(color);
        g.FillPath(brush, path);
        g.SmoothingMode = was;
    }

    public static void Outline(Graphics g, Rectangle r, int radius, Color color, int width)
    {
        var was = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        // An outline is drawn on the pixel center, so a rect the full size of the control loses
        // its right and bottom edge off the end of the clip.
        var inset = Rectangle.Inflate(r, -(width + 1) / 2, -(width + 1) / 2);
        using var path = Round(inset, radius);
        using var pen = new Pen(color, width);
        g.DrawPath(pen, path);
        g.SmoothingMode = was;
    }

    /// A 1 pt hairline the width of the control, at the bottom. Mac lists separate rows this way
    /// rather than with a grid.
    public static void Rule(Graphics g, int left, int right, int y, Color color)
    {
        using var pen = new Pen(color, Ui.S(1));
        g.DrawLine(pen, left, y, right, y);
    }

    /// Turns on the text rendering GDI+ needs for this to look like a shipped app rather than a
    /// dialog from 1998. Call at the top of every OnPaint that draws a string.
    public static void Smooth(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
    }

    /// Panels that scroll or repaint per row need this or they flicker; the property is protected
    /// on Control, so it can only be set from inside a subclass.
    public static void DoubleBuffer(Control c) =>
        typeof(Control).GetProperty("DoubleBuffered",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
            ?.SetValue(c, true);
}
