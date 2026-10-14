using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// What Settings' Record button makes of the keys and buttons pressed while it records.
public class ChordRecorderTests
{
    private const int Space = 0x20, F8 = 0x77;

    private static readonly Action<string> Quiet = _ => { };

    [Fact]
    public void Keys_held_together_are_recorded_in_the_order_they_went_down_once_all_are_let_go()
    {
        var r = new ChordRecorder();
        r.Down(VirtualKeys.LeftControl);
        r.Down(VirtualKeys.LeftAlt);
        r.Up(VirtualKeys.LeftAlt);
        Assert.False(r.Done);                 // Left Ctrl is still down
        r.Up(VirtualKeys.LeftControl);
        Assert.True(r.Done);
        Assert.Equal(new[] { VirtualKeys.LeftControl, VirtualKeys.LeftAlt }, r.Result);
    }

    [Fact]
    public void A_mouse_button_on_its_own_is_a_hotkey()
    {
        var r = new ChordRecorder();
        r.Down(VirtualKeys.MiddleMouse);
        r.Up(VirtualKeys.MiddleMouse);
        Assert.Equal(new[] { VirtualKeys.MiddleMouse }, r.Result);
    }

    [Fact]
    public void A_key_and_a_mouse_button_make_one_chord()
    {
        var r = new ChordRecorder();
        r.Down(VirtualKeys.LeftShift);
        r.Down(VirtualKeys.MiddleMouse);
        r.Up(VirtualKeys.LeftShift);
        r.Up(VirtualKeys.MiddleMouse);
        Assert.Equal(new[] { VirtualKeys.LeftShift, VirtualKeys.MiddleMouse }, r.Result);
    }

    [Fact]
    public void A_held_key_repeating_is_recorded_once()
    {
        var r = new ChordRecorder();
        r.Down(VirtualKeys.RightAlt);
        r.Down(VirtualKeys.RightAlt);
        r.Down(VirtualKeys.RightAlt);
        r.Up(VirtualKeys.RightAlt);
        Assert.Equal(new[] { VirtualKeys.RightAlt }, r.Result);
    }

    [Fact]
    public void Escape_on_its_own_calls_the_recording_off()
    {
        var r = new ChordRecorder();
        r.Down(VirtualKeys.Escape);
        r.Up(VirtualKeys.Escape);
        Assert.True(r.Done);
        Assert.Null(r.Result);
    }

    [Fact]
    public void Escape_can_still_be_part_of_a_chord()
    {
        var r = new ChordRecorder();
        r.Down(VirtualKeys.LeftControl);
        r.Down(VirtualKeys.Escape);
        r.Up(VirtualKeys.Escape);
        r.Up(VirtualKeys.LeftControl);
        Assert.Equal(new[] { VirtualKeys.LeftControl, VirtualKeys.Escape }, r.Result);
    }

    [Fact]
    public void A_key_let_go_that_went_down_before_the_recording_started_is_ignored()
    {
        // A key still held from typing must not end the recording before anything is in it.
        var r = new ChordRecorder();
        r.Up(VirtualKeys.LeftControl);
        Assert.False(r.Done);
        r.Down(F8);
        r.Up(F8);
        Assert.Equal(new[] { F8 }, r.Result);
    }

    [Fact]
    public void Nothing_pressed_after_the_chord_is_taken()
    {
        var r = new ChordRecorder();
        r.Down(VirtualKeys.RightShift);
        r.Up(VirtualKeys.RightShift);
        r.Down(VirtualKeys.LeftAlt);
        r.Up(VirtualKeys.LeftAlt);
        Assert.Equal(new[] { VirtualKeys.RightShift }, r.Result);
    }

    [Fact]
    public void A_recorded_chord_shows_as_a_name_that_Save_reads_back_as_the_same_chord()
    {
        // The box shows NameOf(chord), and Save parses whatever the box shows.
        var r = new ChordRecorder();
        r.Down(VirtualKeys.LeftControl);
        r.Down(Space);
        r.Up(Space);
        r.Up(VirtualKeys.LeftControl);
        var shown = HotkeySettings.NameOf(r.Result!);
        Assert.Equal("leftctrl+space", shown);
        Assert.Equal(r.Result, HotkeySettings.Parse(shown, Quiet));
    }
}
