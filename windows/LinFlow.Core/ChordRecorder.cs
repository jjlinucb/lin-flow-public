namespace LinFlow.Core;

/// Turns what is pressed while Settings records a talk key into a hotkey: every key and button
/// held down together, in the order each went down, finished once all of them are let go. The
/// hooks that feed it live in the tray app; the rules live here so they can be tested.
public sealed class ChordRecorder
{
    private readonly HashSet<int> _held = new();
    private readonly List<int> _chord = new();

    /// True once the chord is complete or the recording was called off. Nothing more is taken.
    public bool Done { get; private set; }

    /// The chord, once Done. Null if Escape on its own called the recording off.
    public int[]? Result { get; private set; }

    /// A key or button went down. A held key repeats, and a repeat changes nothing.
    public void Down(int vk)
    {
        if (Done) return;
        if (_held.Add(vk) && !_chord.Contains(vk)) _chord.Add(vk);
    }

    /// A key or button came up. One that went down before the recording started - the click on
    /// Record itself, a key still held from typing - is ignored, so it cannot end the recording
    /// before anything is in it.
    public void Up(int vk)
    {
        if (Done || !_held.Remove(vk) || _held.Count > 0) return;
        Done = true;
        // Escape on its own is the way out. Escape inside a chord is just another key.
        if (_chord is [VirtualKeys.Escape]) return;
        Result = _chord.ToArray();
    }
}
