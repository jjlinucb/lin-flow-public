using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// The auto / ask / off setting in settings.json, and what the pop-up says. Every file here is
/// a temp file: nothing goes near a real settings.json.
public class LearnSettingsTests
{
    [Theory]
    [InlineData("auto", LearnMode.Auto)]
    [InlineData("ask", LearnMode.Ask)]
    [InlineData("off", LearnMode.Off)]
    [InlineData(" Ask ", LearnMode.Ask)]
    // Anything else is the Mac's default, as `LearnMode(rawValue:) ?? .auto` makes it there.
    [InlineData("", LearnMode.Auto)]
    [InlineData("sometimes", LearnMode.Auto)]
    [InlineData(null, LearnMode.Auto)]
    public void The_Mac_values_are_read(string? raw, LearnMode mode) =>
        Assert.Equal(mode, LearnSettings.Parse(raw));

    [Fact]
    public void The_labels_are_the_Macs()
    {
        Assert.Equal("Add it automatically", LearnSettings.Label(LearnMode.Auto));
        Assert.Equal("Suggest it first", LearnSettings.Label(LearnMode.Ask));
        Assert.Equal("Do nothing", LearnSettings.Label(LearnMode.Off));
    }

    private static string TempSettings(string? contents)
    {
        var path = Path.Combine(Path.GetTempPath(), $"linflow-settings-{Guid.NewGuid():N}.json");
        if (contents is not null) File.WriteAllText(path, contents);
        return path;
    }

    [Fact]
    public void No_file_means_the_default()
    {
        var path = TempSettings(null);
        Assert.Equal(LearnMode.Auto, LearnSettings.Load(path));
    }

    [Fact]
    public void The_setting_is_read_beside_the_hotkey()
    {
        var path = TempSettings("{ \"hotkey\": \"LeftCtrl+LeftAlt\", \"learnCorrections\": \"ask\" }");
        try { Assert.Equal(LearnMode.Ask, LearnSettings.Load(path)); }
        finally { File.Delete(path); }
    }

    [Fact]
    public void A_broken_file_gives_the_default_and_says_why()
    {
        var path = TempSettings("{ not json");
        var errors = new List<string>();
        try
        {
            Assert.Equal(LearnMode.Auto, LearnSettings.Load(path, errors.Add));
            Assert.StartsWith("settings: could not read learnCorrections", Assert.Single(errors));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void A_value_that_is_not_a_string_gives_the_default()
    {
        var path = TempSettings("{ \"learnCorrections\": 2 }");
        try { Assert.Equal(LearnMode.Auto, LearnSettings.Load(path)); }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Saving_keeps_every_other_key()
    {
        var path = TempSettings("{ \"hotkey\": \"LeftCtrl+LeftAlt\", \"notesModel\": \"qwen2.5:3b\" }");
        try
        {
            LearnSettings.Save(LearnMode.Off, path);
            Assert.Equal(LearnMode.Off, LearnSettings.Load(path));
            Assert.Equal(new[] { VirtualKeys.LeftControl, VirtualKeys.LeftAlt }, HotkeySettings.Load(path));
            Assert.Contains("\"notesModel\": \"qwen2.5:3b\"", File.ReadAllText(path));
            Assert.Contains("\"learnCorrections\": \"off\"", File.ReadAllText(path));
        }
        finally { File.Delete(path); }
    }

    // What the pop-up says. A rule that only reached the log was a rule John never saw, which is
    // why the dictionary felt broken on the Mac while it was quietly working.
    [Fact]
    public void The_toast_says_what_was_learned()
    {
        var lines = LearnToast.Lines(new CorrectionLearning.Outcome(added: new() { new Replacement("GWS C L I", "gws cli", true) }));
        Assert.NotNull(lines);
        Assert.Equal("Learned: “GWS C L I” → “gws cli”", lines!.Value.Title);
        Assert.Contains("Used from now on", lines.Value.Detail);
    }

    [Fact]
    public void The_toast_counts_the_rest_and_says_a_suggestion_is_not_a_rule_yet()
    {
        var lines = LearnToast.Lines(new CorrectionLearning.Outcome(suggested: new()
        {
            new Replacement("Wort", "Duarte", true),
            new Replacement("Seneca", "Santa Clara", true),
        }));
        Assert.Equal("Suggested: “Wort” → “Duarte”  +1 more", lines!.Value.Title);
        Assert.Contains("Not applied yet", lines.Value.Detail);
    }

    [Fact]
    public void Nothing_learned_nothing_shown() =>
        Assert.Null(LearnToast.Lines(new CorrectionLearning.Outcome()));

    [Fact]
    public void An_offer_asks()
    {
        var (title, detail) = LearnToast.Declined("Marisvo", "Marisa Vuong");
        Assert.Equal("Add “Marisvo” → “Marisa Vuong”?", title);
        Assert.Equal("Not sure enough to add it alone. Click to add.", detail);
    }
}
