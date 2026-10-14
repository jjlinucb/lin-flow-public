using System.Globalization;
using System.Text.Json.Nodes;

namespace LinFlow.Core;

/// The Windows virtual-key codes Lin Flow can hold-to-talk on. Named here rather than in the tray
/// app so the settings parser below can be tested: LinFlow.Tests targets net8.0 and cannot
/// reference a net8.0-windows project.
public static class VirtualKeys
{
    public const int LeftControl = 0xA2;
    public const int RightControl = 0xA3;
    public const int LeftAlt = 0xA4;
    public const int RightAlt = 0xA5;
    public const int LeftShift = 0xA0;
    public const int RightShift = 0xA1;
    public const int Menu = 0x5D;
    public const int CapsLock = 0x14;
    public const int Escape = 0x1B;
    /// The mouse buttons a hotkey can use: VK_MBUTTON, the wheel pressed down, and VK_XBUTTON1 and
    /// VK_XBUTTON2, the Back and Forward buttons on the side of mice that have them. Not keys: the
    /// keyboard hook never sees them, so Hotkey watches them through a mouse hook of its own.
    public const int MiddleMouse = 0x04;
    public const int MouseBack = 0x05;
    public const int MouseForward = 0x06;
    /// The left and right buttons, named only so the parser can refuse them: either one as a talk
    /// key would take over ordinary clicking.
    public const int LeftMouse = 0x01;
    public const int RightMouse = 0x02;
}

/// The hotkey Lin Flow listens for, read from settings.json. The file is shared with the
/// notetaker; unknown keys are left alone.
///
/// The default is Left Ctrl + Left Alt, which is what John uses on every machine: his mouse has a
/// button bound to exactly that chord, so it is one press from either hand (2026-09-23). It was
/// Right Alt until then, and a fresh install - the desktop, or this laptop's own data folder once
/// it had lost its settings - came up on a key he never presses.
///
/// Not Right Ctrl, the original default: laptops shipping from 2024 replaced it with a Copilot key,
/// so on those machines it physically did not exist - dictation never fired, nothing reached the
/// log, and there was no way to tell that from a broken hook. Both keys of this chord are on every
/// keyboard. Fn is not an option on any layout, for the reason given on Hotkey itself.
///
/// Any combination can be the hotkey: every ordinary key has a name below, the middle, Back and
/// Forward mouse buttons can join in, and a code this list does not name can be given raw. Settings
/// records one by having it pressed, and saves it here, without a rebuild:
///
///     { "hotkey": "LeftCtrl+LeftAlt" }
///     { "hotkey": "RightShift" }
///     { "hotkey": "0x5D" }
///     { "hotkey": "MiddleMouse" }
///     { "hotkey": "Ctrl+Shift+Space" }
///
/// A chord earns its keep on the left of the keyboard, where every single key is already busy.
/// Left Alt on its own opens the menu bar in most apps, and Left Ctrl on its own starts a
/// recording on every Ctrl+C the user types. Holding both does neither.
///
/// The mouse buttons came in on DESK-01 (2026-09-25), where John's plain three-button mouse has no
/// button to bind to the chord. A quick click of one still clicks: see ClickLimit.
public static class HotkeySettings
{
    public static readonly int[] Default = { VirtualKeys.LeftControl, VirtualKeys.LeftAlt };

    private static readonly Dictionary<string, int> Names = BuildNames();

    /// The first name listed for a code is the one NameOf gives back, for the log line and the
    /// Settings box, so it has to be one Parse reads back as the same code.
    private static Dictionary<string, int> BuildNames()
    {
        var names = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
        {
            ["leftalt"] = VirtualKeys.LeftAlt,
            ["rightalt"] = VirtualKeys.RightAlt,
            ["altgr"] = VirtualKeys.RightAlt,
            // the Mac writes this key as "rightOption": the same physical key, so a settings value
            // copied between the machines keeps working, which is the rule for every other data file.
            ["rightoption"] = VirtualKeys.RightAlt,
            ["leftoption"] = VirtualKeys.LeftAlt,
            ["leftctrl"] = VirtualKeys.LeftControl,
            ["leftcontrol"] = VirtualKeys.LeftControl,
            ["rightctrl"] = VirtualKeys.RightControl,
            ["rightcontrol"] = VirtualKeys.RightControl,
            ["leftshift"] = VirtualKeys.LeftShift,
            ["rightshift"] = VirtualKeys.RightShift,
            ["menu"] = VirtualKeys.Menu,
            ["apps"] = VirtualKeys.Menu,
            ["capslock"] = VirtualKeys.CapsLock,
            ["leftwin"] = 0x5B,
            ["rightwin"] = 0x5C,
            // A bare Ctrl, Alt, Shift or Win means the left one. The hook reports which side was
            // pressed, never the generic code, so a hotkey on the generic code would never fire.
            ["ctrl"] = VirtualKeys.LeftControl,
            ["control"] = VirtualKeys.LeftControl,
            ["alt"] = VirtualKeys.LeftAlt,
            ["shift"] = VirtualKeys.LeftShift,
            ["win"] = 0x5B,
            // "mbutton" and "xbutton1" are Windows' own names, from VK_MBUTTON and VK_XBUTTON1.
            ["middlemouse"] = VirtualKeys.MiddleMouse,
            ["middlebutton"] = VirtualKeys.MiddleMouse,
            ["mbutton"] = VirtualKeys.MiddleMouse,
            ["mouseback"] = VirtualKeys.MouseBack,
            ["xbutton1"] = VirtualKeys.MouseBack,
            ["mouseforward"] = VirtualKeys.MouseForward,
            ["xbutton2"] = VirtualKeys.MouseForward,
            ["space"] = 0x20,
            ["enter"] = 0x0D,
            ["return"] = 0x0D,
            ["tab"] = 0x09,
            ["backspace"] = 0x08,
            ["escape"] = VirtualKeys.Escape,
            ["esc"] = VirtualKeys.Escape,
            ["insert"] = 0x2D,
            ["delete"] = 0x2E,
            ["home"] = 0x24,
            ["end"] = 0x23,
            ["pageup"] = 0x21,
            ["pagedown"] = 0x22,
            ["leftarrow"] = 0x25,
            ["uparrow"] = 0x26,
            ["rightarrow"] = 0x27,
            ["downarrow"] = 0x28,
            ["printscreen"] = 0x2C,
            ["scrolllock"] = 0x91,
            ["pause"] = 0x13,
            ["numlock"] = 0x90,
            ["semicolon"] = 0xBA,
            ["equals"] = 0xBB,
            ["comma"] = 0xBC,
            ["minus"] = 0xBD,
            ["period"] = 0xBE,
            ["slash"] = 0xBF,
            ["backquote"] = 0xC0,
            ["leftbracket"] = 0xDB,
            ["backslash"] = 0xDC,
            ["rightbracket"] = 0xDD,
            ["quote"] = 0xDE,
            ["numpadmultiply"] = 0x6A,
            ["numpadadd"] = 0x6B,
            ["numpadsubtract"] = 0x6D,
            ["numpaddecimal"] = 0x6E,
            ["numpaddivide"] = 0x6F,
        };
        for (var c = 'a'; c <= 'z'; c++) names[c.ToString()] = 'A' + (c - 'a');
        // "d1" for the number row, the way .NET names those keys: a bare "1" is already a raw code.
        for (var d = 0; d <= 9; d++) names[$"d{d}"] = 0x30 + d;
        for (var d = 0; d <= 9; d++) names[$"numpad{d}"] = 0x60 + d;
        for (var f = 1; f <= 24; f++) names[$"f{f}"] = 0x6F + f;
        return names;
    }

    /// The friendly name for a code, for the log line, so a reader never has to decode hex.
    public static string NameOf(int vk)
    {
        foreach (var pair in Names)
            if (pair.Value == vk) return pair.Key;
        return $"0x{vk:X2}";
    }

    /// The whole chord as one readable string, for the same reason.
    public static string NameOf(IReadOnlyList<int> vks) => string.Join("+", vks.Select(NameOf));

    /// True for the mouse buttons a hotkey can use. Hotkey installs its mouse hook only when the
    /// hotkey names one, so a keyboard hotkey costs the pointer nothing.
    public static bool IsMouseButton(int vk) =>
        vk is VirtualKeys.MiddleMouse or VirtualKeys.MouseBack or VirtualKeys.MouseForward;

    /// A press of one of the hotkey's mouse buttons shorter than this is a click, not a
    /// dictation, and Hotkey hands it back as an ordinary click, so the button keeps its usual
    /// job. It is the same 0.3 s under which Program.OnReleased drops a take as a stray tap, so a
    /// press is a click or a dictation and never both.
    public static readonly TimeSpan ClickLimit = TimeSpan.FromSeconds(0.3);

    public static bool IsClick(TimeSpan held) => held < ClickLimit;

    /// `onError` exists so a test can drive the bad-value paths without writing a line into the
    /// live app.log, the same seam History.Append has and for the same
    /// reason: a test run on John's own machine must be indistinguishable from not having run.
    public static int[] Load(string? path = null, Action<string>? onError = null)
    {
        try
        {
            var file = path ?? Paths.SettingsFile;
            if (!File.Exists(file)) return Default;
            var raw = JsonNode.Parse(File.ReadAllText(file))?["hotkey"]?.GetValue<string>();
            if (string.IsNullOrWhiteSpace(raw)) return Default;
            return Parse(raw, onError);
        }
        catch (Exception e)
        {
            (onError ?? Log.Info)($"settings: could not read the hotkey: {e.Message}");
            return Default;
        }
    }

    /// Accepts a name from the table above, a raw virtual-key code as "0xA5" or "165", or several
    /// of either joined by "+" for a chord. Anything unusable gives the default rather than
    /// leaving the user with no hotkey at all.
    public static int[] Parse(string raw, Action<string>? onError = null)
    {
        var parts = raw.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length == 0) return Default;

        var keys = new List<int>();
        foreach (var part in parts)
        {
            var vk = ParseOne(part);
            if (vk is null)
            {
                (onError ?? Log.Info)($"settings: hotkey \"{raw.Trim()}\" is not a key I know, using {NameOf(Default)}");
                return Default;
            }
            if (!keys.Contains(vk.Value)) keys.Add(vk.Value);
        }
        return keys.ToArray();
    }

    private static int? ParseOne(string text)
    {
        if (Names.TryGetValue(text.Replace(" ", ""), out var named)) return named;

        var hex = text.StartsWith("0x", StringComparison.OrdinalIgnoreCase);
        var digits = hex ? text[2..] : text;
        if (int.TryParse(digits, hex ? NumberStyles.HexNumber : NumberStyles.Integer,
                         CultureInfo.InvariantCulture, out var code) && code is > 0 and <= 0xFF
            // Not the left or right button, even by raw code: either would take over clicking.
            && code is not (VirtualKeys.LeftMouse or VirtualKeys.RightMouse))
            return code;
        return null;
    }
}
