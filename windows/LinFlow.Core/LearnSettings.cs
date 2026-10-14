using System.Text.Json;
using System.Text.Json.Nodes;

namespace LinFlow.Core;

/// What happens when you fix text Lin Flow pasted: `learnCorrections` in settings.json, with the
/// Mac's three values and its default. The Mac keeps the same key in UserDefaults
/// (Settings.learnCorrections), so the strings are its raw values: "auto", "ask" and "off".
public static class LearnSettings
{
    public const string Key = "learnCorrections";

    /// The Mac's default. An unknown value falls back to it too, as `LearnMode(rawValue:) ?? .auto` does.
    public const LearnMode Default = LearnMode.Auto;

    public static IReadOnlyList<LearnMode> All { get; } = new[] { LearnMode.Auto, LearnMode.Ask, LearnMode.Off };

    /// The Mac's labels for the picker, word for word.
    public static string Label(LearnMode mode) => mode switch
    {
        LearnMode.Auto => "Add it automatically",
        LearnMode.Ask => "Suggest it first",
        _ => "Do nothing",
    };

    public static string Name(LearnMode mode) => mode switch
    {
        LearnMode.Auto => "auto",
        LearnMode.Ask => "ask",
        _ => "off",
    };

    public static LearnMode Parse(string? raw) => raw?.Trim().ToLowerInvariant() switch
    {
        "auto" => LearnMode.Auto,
        "ask" => LearnMode.Ask,
        "off" => LearnMode.Off,
        _ => Default,
    };

    /// Read at every paste, so a change in the window applies to the next dictation with no
    /// restart. It is one small file, next to a transcription that just took a quarter second.
    /// `onError` is the same seam HotkeySettings.Load has: a test must not write to the live log.
    public static LearnMode Load(string? path = null, Action<string>? onError = null)
    {
        try
        {
            var file = path ?? Paths.SettingsFile;
            if (!File.Exists(file)) return Default;
            var node = JsonNode.Parse(File.ReadAllText(file))?[Key];
            return node is JsonValue v && v.TryGetValue<string>(out var raw) ? Parse(raw) : Default;
        }
        catch (Exception e)
        {
            (onError ?? Log.Info)($"settings: could not read {Key}: {e.Message}");
            return Default;
        }
    }

    /// Writes only this key, leaving the hotkey and the notetaker's keys as they were.
    public static void Save(LearnMode mode, string? path = null)
    {
        var file = path ?? Paths.SettingsFile;
        var root = File.Exists(file) ? JsonNode.Parse(File.ReadAllText(file)) as JsonObject : null;
        root ??= new JsonObject();
        root[Key] = Name(mode);
        Paths.WriteAtomic(file, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }
}

/// The two lines a learning outcome turns into on screen. The Mac's LearnToast, word for word,
/// kept apart from the window that shows them so the tests can check the wording.
public static class LearnToast
{
    public static (string Title, string Detail)? Lines(CorrectionLearning.Outcome outcome)
    {
        var added = outcome.Added.Count > 0;
        var list = added ? outcome.Added : outcome.Suggested;
        if (list.Count == 0) return null;
        var first = list[0];
        var total = outcome.Added.Count + outcome.Suggested.Count;
        var more = total > 1 ? $"  +{total - 1} more" : "";
        return (
            $"{(added ? "Learned" : "Suggested")}: “{first.From}” → “{first.To}”{more}",
            added ? "Used from now on. Click to change it in the Dictionary."
                  : "Not applied yet. Click to confirm it in the Dictionary.");
    }

    /// An edit Lin Flow saw and refused. Saying nothing here is what made the dictionary feel
    /// broken on the Mac: John fixes a word, the filters decide it is too far from a mishearing
    /// to bind globally, and nothing on screen distinguishes that from the readback never
    /// running. Offered rather than applied, because one click from him is a better signal than
    /// any edit-distance rule.
    public static (string Title, string Detail) Declined(string from, string to) =>
        ($"Add “{from}” → “{to}”?", "Not sure enough to add it alone. Click to add.");

    /// What a click on that offer says once it has added the rule.
    public static (string Title, string Detail) Added(string from, string to) =>
        ($"Added: “{from}” → “{to}”", "Used from now on. Click to change it in the Dictionary.");
}
