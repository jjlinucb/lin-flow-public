using System.Runtime.InteropServices;

namespace LinFlow.App;

/// Turns the sizes written in this app into pixels for the screen it is running on.
///
/// Every window here is laid out in raw pixels against a 96-DPI screen, and the app declares
/// PerMonitorV2, which tells Windows to do no scaling of its own. John's laptop runs at 200%, so
/// on 2026-09-18 the window came out 860x560 physical on a 192-DPI panel - the size a 430x280
/// window reads as - with correctly sized text crammed into it, and the pill was a 115x26 sliver.
/// "I still cannot see the dictionary" was this, not a missing feature.
///
/// WinForms can do this itself through AutoScaleMode, and it was tried first: setting the mode
/// after the dimensions clears the dimensions, the factor comes out as 1, and nothing moves. A
/// multiplier that can be read off a measurement beats a framework pass that silently does
/// nothing.
///
/// Text needs no help. A font is in points, so GDI+ has already drawn it at the screen's DPI;
/// scaling a font size here would double what is already right. Scale boxes, not letters - and
/// prefer AutoSize on anything whose size should follow its text.
internal static class Ui
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();

    /// Read once. Windows reports the system DPI, so this is the primary display's scaling; a
    /// window dragged to a second monitor at a different scale keeps these sizes.
    public static readonly float Scale = Factor();

    private static float Factor()
    {
        try { return GetDpiForSystem() / 96f; }
        catch (EntryPointNotFoundException) { return 1f; }   // before Windows 10 1607
    }

    /// One pixel measurement, scaled.
    public static int S(int px) => (int)Math.Round(px * Scale);

    public static Size S(int width, int height) => new(S(width), S(height));

    public static Padding S(Padding p) => new(S(p.Left), S(p.Top), S(p.Right), S(p.Bottom));

    /// Sets a splitter's panel minimums and its position together, once the container is big
    /// enough for both, and says whether it managed it.
    ///
    /// Two traps, both hit on 2026-09-18. SplitterDistance throws outside [Panel1MinSize, span -
    /// Panel2MinSize - SplitterWidth], and "the container is at least as wide as the two
    /// minimums" is not that range - at exactly that width the only legal distance is
    /// Panel1MinSize. Worse, *setting a minimum* validates the distance that is already there, so
    /// assigning Panel2MinSize in a constructor throws on its own: a new SplitContainer is 150
    /// wide with its splitter at 50, and no minimum worth having fits in that. Hence this order:
    /// wait for a real size, move the splitter while the minimums are still small, then raise
    /// them. The notetaker's constructor threw that way, and because the window was built inside
    /// one try block the app came up with no window at all.
    /// Callers must guard against re-entry: every assignment below raises Layout on this thread
    /// before Place returns, so a Layout handler that calls Place will be called again from
    /// inside it. See the `placing` flag at each call site.
    public static bool Place(SplitContainer split, int wanted, int min1, int min2)
    {
        var span = split.Orientation == Orientation.Vertical ? split.Width : split.Height;
        var most = span - min2 - split.SplitterWidth;
        if (most < min1) return false;                      // no room yet; try again next layout
        split.SplitterDistance = Math.Clamp(wanted, min1, most);
        split.Panel1MinSize = min1;
        split.Panel2MinSize = min2;
        return true;
    }
}
