using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

public class HotkeySettingsTests : IDisposable
{
    /// Swallows the log lines the bad-value cases produce. Without this the suite writes
    /// "hotkey \"banana\" is not a key I know" into John's live app.log every run, which looks
    /// exactly like a real failure when he opens it.
    private static readonly Action<string> Quiet = _ => { };

    private readonly string _dir;

    public HotkeySettingsTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "linflow-hotkey-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    private string WriteSettings(string json)
    {
        var path = Path.Combine(_dir, "settings.json");
        File.WriteAllText(path, json);
        return path;
    }

    [Fact]
    public void The_default_is_left_ctrl_plus_left_alt_the_chord_john_uses_everywhere()
    {
        // Both keys are on every keyboard, which is the property the old Right Alt default was
        // chosen for - new laptops have no Right Ctrl. Order matters only for display.
        Assert.Equal(new[] { VirtualKeys.LeftControl, VirtualKeys.LeftAlt }, HotkeySettings.Default);
    }

    [Fact]
    public void A_missing_settings_file_gives_the_default()
    {
        Assert.Equal(HotkeySettings.Default, HotkeySettings.Load(Path.Combine(_dir, "nope.json"), Quiet));
    }

    [Theory]
    [InlineData("RightAlt", VirtualKeys.RightAlt)]
    [InlineData("rightalt", VirtualKeys.RightAlt)]
    [InlineData("AltGr", VirtualKeys.RightAlt)]
    [InlineData("rightOption", VirtualKeys.RightAlt)]   // the name the Mac writes
    [InlineData("Right Alt", VirtualKeys.RightAlt)]
    [InlineData("RightCtrl", VirtualKeys.RightControl)]
    [InlineData("RightControl", VirtualKeys.RightControl)]
    [InlineData("RightShift", VirtualKeys.RightShift)]
    [InlineData("Menu", VirtualKeys.Menu)]
    [InlineData("CapsLock", VirtualKeys.CapsLock)]
    [InlineData("LeftAlt", VirtualKeys.LeftAlt)]
    [InlineData("LeftCtrl", VirtualKeys.LeftControl)]
    [InlineData("LeftShift", VirtualKeys.LeftShift)]
    public void Keys_can_be_named(string name, int expected)
    {
        Assert.Equal(new[] { expected }, HotkeySettings.Parse(name, Quiet));
    }

    [Theory]
    [InlineData("0xA5", VirtualKeys.RightAlt)]
    [InlineData("0x5D", VirtualKeys.Menu)]
    [InlineData("165", VirtualKeys.RightAlt)]
    public void A_key_the_table_does_not_name_can_be_given_as_a_raw_code(string raw, int expected)
    {
        Assert.Equal(new[] { expected }, HotkeySettings.Parse(raw, Quiet));
    }

    [Theory]
    [InlineData("Fn")]              // firmware only, never reaches a hook
    [InlineData("banana")]
    [InlineData("0x00")]            // not a key
    [InlineData("0x1FF")]           // past the virtual-key range
    [InlineData("-3")]
    public void Anything_unusable_falls_back_to_the_default_rather_than_throwing(string raw)
    {
        Assert.Equal(HotkeySettings.Default, HotkeySettings.Parse(raw, Quiet));
    }

    [Fact]
    public void The_key_is_read_from_settings_json()
    {
        var path = WriteSettings("""{ "hotkey": "RightShift" }""");
        Assert.Equal(new[] { VirtualKeys.RightShift }, HotkeySettings.Load(path, Quiet));
    }

    [Fact]
    public void Settings_belonging_to_other_features_are_left_alone()
    {
        var path = WriteSettings("""{ "ollamaHost": "http://localhost:11434", "hotkey": "Menu" }""");
        Assert.Equal(new[] { VirtualKeys.Menu }, HotkeySettings.Load(path, Quiet));
    }

    [Fact]
    public void A_settings_file_without_a_hotkey_gives_the_default()
    {
        var path = WriteSettings("""{ "notesModel": "qwen2.5:3b" }""");
        Assert.Equal(HotkeySettings.Default, HotkeySettings.Load(path, Quiet));
    }

    [Fact]
    public void Broken_json_gives_the_default_instead_of_stopping_the_app_starting()
    {
        var path = WriteSettings("{ this is not json");
        Assert.Equal(HotkeySettings.Default, HotkeySettings.Load(path, Quiet));
    }

    [Theory]
    [InlineData("LeftCtrl+LeftAlt")]
    [InlineData("leftctrl + leftalt")]
    [InlineData("0xA2+0xA4")]
    public void A_chord_is_every_key_that_must_be_held(string raw)
    {
        Assert.Equal(new[] { VirtualKeys.LeftControl, VirtualKeys.LeftAlt }, HotkeySettings.Parse(raw, Quiet));
    }

    [Fact]
    public void A_chord_naming_one_key_twice_keeps_it_once()
    {
        Assert.Equal(new[] { VirtualKeys.LeftAlt }, HotkeySettings.Parse("LeftAlt+LeftAlt", Quiet));
    }

    [Fact]
    public void One_bad_key_in_a_chord_rejects_the_whole_chord()
    {
        Assert.Equal(HotkeySettings.Default, HotkeySettings.Parse("LeftCtrl+Fn", Quiet));
    }

    [Fact]
    public void A_chord_reads_back_for_the_log_line()
    {
        Assert.Equal("leftctrl+leftalt",
                     HotkeySettings.NameOf(new[] { VirtualKeys.LeftControl, VirtualKeys.LeftAlt }));
    }

    [Fact]
    public void Names_round_trip_for_the_log_line()
    {
        Assert.Equal("rightalt", HotkeySettings.NameOf(VirtualKeys.RightAlt));
        Assert.Equal("f12", HotkeySettings.NameOf(0x7B));
        Assert.Equal("0x07", HotkeySettings.NameOf(0x07));    // no key has this code, so no name
    }

    [Theory]
    [InlineData("MiddleMouse")]
    [InlineData("middle mouse")]
    [InlineData("MiddleButton")]
    [InlineData("MButton")]
    [InlineData("0x04")]
    public void The_middle_mouse_button_can_be_the_hotkey(string raw)
    {
        // For a plain three-button mouse, with no spare button to bind to the chord (DESK-01,
        // 2026-09-25). 0x04 is VK_MBUTTON, so the raw code means the same button.
        Assert.Equal(new[] { VirtualKeys.MiddleMouse }, HotkeySettings.Parse(raw, Quiet));
    }

    [Fact]
    public void The_mouse_buttons_read_back_by_name_and_only_those_three_take_the_mouse_hook()
    {
        Assert.Equal("middlemouse", HotkeySettings.NameOf(VirtualKeys.MiddleMouse));
        Assert.Equal("mouseback", HotkeySettings.NameOf(VirtualKeys.MouseBack));
        Assert.Equal("mouseforward", HotkeySettings.NameOf(VirtualKeys.MouseForward));
        Assert.True(HotkeySettings.IsMouseButton(VirtualKeys.MiddleMouse));
        Assert.True(HotkeySettings.IsMouseButton(VirtualKeys.MouseBack));
        Assert.True(HotkeySettings.IsMouseButton(VirtualKeys.MouseForward));
        Assert.False(HotkeySettings.IsMouseButton(VirtualKeys.LeftMouse));
        Assert.False(HotkeySettings.IsMouseButton(VirtualKeys.LeftControl));
        Assert.False(HotkeySettings.IsMouseButton(VirtualKeys.CapsLock));
    }

    [Theory]
    [InlineData("A", 0x41)]
    [InlineData("z", 0x5A)]
    [InlineData("D1", 0x31)]           // the number row; a bare "1" is a raw code
    [InlineData("F1", 0x70)]
    [InlineData("F24", 0x87)]
    [InlineData("Space", 0x20)]
    [InlineData("Enter", 0x0D)]
    [InlineData("Esc", VirtualKeys.Escape)]
    [InlineData("Page Up", 0x21)]
    [InlineData("LeftArrow", 0x25)]
    [InlineData("Numpad0", 0x60)]
    [InlineData("LeftWin", 0x5B)]
    [InlineData("Backslash", 0xDC)]
    [InlineData("MouseBack", VirtualKeys.MouseBack)]
    [InlineData("XButton2", VirtualKeys.MouseForward)]
    public void Any_ordinary_key_or_mouse_button_can_be_named(string name, int expected)
    {
        Assert.Equal(new[] { expected }, HotkeySettings.Parse(name, Quiet));
    }

    [Theory]
    [InlineData("Ctrl", VirtualKeys.LeftControl)]
    [InlineData("Alt", VirtualKeys.LeftAlt)]
    [InlineData("Shift", VirtualKeys.LeftShift)]
    [InlineData("Win", 0x5B)]
    public void A_bare_modifier_means_the_left_one(string name, int expected)
    {
        // The hook reports the side, never the generic code, so the generic code would never fire.
        Assert.Equal(new[] { expected }, HotkeySettings.Parse(name, Quiet));
    }

    [Fact]
    public void Any_combination_of_keys_and_mouse_buttons_can_be_a_chord()
    {
        Assert.Equal(new[] { VirtualKeys.LeftControl, VirtualKeys.LeftShift, 0x20 },
                     HotkeySettings.Parse("Ctrl+Shift+Space", Quiet));
        Assert.Equal(new[] { VirtualKeys.RightAlt, 0x70, VirtualKeys.MouseForward },
                     HotkeySettings.Parse("RightAlt+F1+MouseForward", Quiet));
    }

    [Theory]
    [InlineData("0x01")]           // the left button
    [InlineData("0x02")]           // the right button
    [InlineData("1")]
    [InlineData("LeftCtrl+0x02")]
    public void The_left_and_right_mouse_buttons_are_refused_even_by_raw_code(string raw)
    {
        // Either one as a talk key would take over ordinary clicking.
        Assert.Equal(HotkeySettings.Default, HotkeySettings.Parse(raw, Quiet));
    }

    [Fact]
    public void Every_code_reads_back_as_a_name_that_parses_to_the_same_code()
    {
        // The Settings box shows NameOf and Save parses what it shows, so every code the parser
        // accepts has to survive the trip, whether it has a name or only its hex.
        for (var vk = 1; vk <= 0xFF; vk++)
        {
            var parsed = HotkeySettings.Parse(HotkeySettings.NameOf(vk), Quiet);
            if (vk is VirtualKeys.LeftMouse or VirtualKeys.RightMouse)
                Assert.Equal(HotkeySettings.Default, parsed);
            else
                Assert.Equal(new[] { vk }, parsed);
        }
    }

    [Fact]
    public void The_middle_mouse_button_can_join_a_chord()
    {
        Assert.Equal(new[] { VirtualKeys.LeftControl, VirtualKeys.MiddleMouse },
                     HotkeySettings.Parse("LeftCtrl+MiddleMouse", Quiet));
    }

    [Theory]
    [InlineData(90, true)]       // an ordinary click
    [InlineData(299, true)]
    [InlineData(300, false)]     // 0.3 s, where OnReleased stops dropping a take as a stray tap
    [InlineData(2000, false)]    // a dictation
    public void A_quick_middle_press_is_a_click_and_a_held_one_is_a_dictation(int ms, bool click)
    {
        Assert.Equal(click, HotkeySettings.IsClick(TimeSpan.FromMilliseconds(ms)));
    }
}
