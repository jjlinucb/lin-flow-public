using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// Finding the pasted phrase again in a field, and deciding what a reading of that field means.
/// The first half is the Mac's selftest for PasteWatcher, case for case. The second half drives
/// ReadbackWatch through whole sequences of readings, which on the Mac lives inside the
/// Accessibility code and has only ever been checked by John fixing words by hand.
public class ReadbackTests
{
    private static readonly string Long = string.Concat(Enumerable.Repeat("Filler words to pad the document out. ", 30));

    [Theory]
    [InlineData("Ask John Lynn.", "Ask John Lin.", "Ask John Lin.")]                  // a short field is compared whole
    [InlineData("Hey, change the name Justin.", "Hey, change the name Justine.", "Hey, change the name Justine.")]
    // On the Mac on 2026-09-14 John dictated his wife's name to test it and fixed both words.
    // Two words means a word budget of one, so the word check can never pass; characters can.
    [InlineData("Merissa Wong.", "Marisa Vuong", "Marisa Vuong")]
    [InlineData("Marisvo.", "Marisa Vuong", "Marisa Vuong")]                             // a glued name split in two
    public void An_edit_is_found(string wrote, string now, string edited) =>
        Assert.Equal(edited, Readback.EditedVersion(wrote, now));

    [Theory]
    [InlineData("Ask John Lynn.", "Ask John Lynn.")]                      // unchanged means nothing to learn
    [InlineData("Ask John Lynn.", "")]                                    // an emptied field
    // Hitting send empties the composer and the app puts its placeholder there; that is not an
    // edit of the dictation, and learning from it would poison the dictionary.
    [InlineData("You can merge it in now.", "Type / for commands")]
    [InlineData("Ask John Lynn.", "Message #general")]                    // an unrelated field
    [InlineData("Ask John Lynn.", "Totally different words here now.")]   // a wholesale retype
    [InlineData("Hello there.", "Type a message")]                        // a placeholder of the same shape
    public void Not_an_edit(string wrote, string now) =>
        Assert.Null(Readback.EditedVersion(wrote, now));

    [Fact]
    public void The_phrase_is_found_inside_a_long_document() =>
        Assert.Equal("the quarterly sensor platform preview",
            Readback.EditedVersion("the quarterly sensor platform review", Long + "the quarterly sensor platform preview " + Long));

    [Fact]
    public void A_phrase_gone_from_a_long_document_is_not_an_edit() =>
        Assert.Null(Readback.EditedVersion("the quarterly sensor platform review", Long + Long));

    [Fact]
    public void Word_distance_counts_words() =>
        Assert.Equal(1, Readback.WordDistance(new[] { "a", "b", "c" }, new[] { "a", "x", "c" }));

    /// The whole chain on what actually happened in the Mac's log: a rule added, a rule offered,
    /// or silence. Three separate gates there refused John's wife's name on three different days,
    /// each found only after he re-tested by hand, because every test checked one stage alone.
    private static string Chain(string wrote, string fieldNow)
    {
        if (Readback.EditedVersion(wrote, fieldNow) is not { } edited) return "unseen";
        var scored = LearnedCorrections.Scored(wrote, edited, new List<Replacement>());
        if (scored.Count > 0)
        {
            var first = scored[0];
            return $"{(first.Confidence == LearnedCorrections.Confidence.Apply ? "learn" : "suggest")} {first.Replacement.From}=>{first.Replacement.To}";
        }
        if (CorrectionLearning.LonePair(wrote, edited) is { } p)
            return CorrectionLearning.WorthShowing(p.From, p.To) ? $"offer {p.From}=>{p.To}" : "silent";
        return "silent";
    }

    [Theory]
    [InlineData("Merissa Wong.", "Marisa Vuong", "offer Merissa Wong=>Marisa Vuong")]
    [InlineData("Marisvo.", "Marisa Vuong", "offer Marisvo=>Marisa Vuong")]
    [InlineData("Just use the Marisvo 6 Repos.", "Just use the Marisa Vuong 6 Repos.", "offer Marisvo=>Marisa Vuong")]
    [InlineData("Hey change the name Justin.", "Hey change the name Justine.", "learn Justin=>Justine")]
    [InlineData("Then you can draft a better email to Wort.", "Then you can draft a better email to Duarte.", "suggest Wort=>Duarte")]
    [InlineData("You can merge it in now.", "Type / for commands", "unseen")]   // hitting send teaches nothing
    [InlineData("Ask John Lynn.", "Message #general", "unseen")]
    // Carrying on typing is refused before the learner is ever consulted: no offer, no log line.
    [InlineData("Ask John.", "Ask John about it.", "unseen")]
    // One real word for another is never bound: "failed" => "filled" would rewrite every
    // future "the build failed" the way "cloud => Claude" rewrote every "cloud" on the Mac.
    [InlineData("All because I failed out a survey that said this was their service was terrible.",
                "All because I filled out a survey that said this was their service was terrible.", "silent")]
    [InlineData("We need to triadge the bugs.", "We need to triage the bugs.", "learn triadge=>triage")]
    [InlineData("I'm John and I just want to check in on my 2022 Silver Brona to see if you guys have an update cost to fix and time.",
                "Hi is this Mercer Collision? I'm John and I just want to check in on my 2022 Silver Verona to see if you guys have an update cost to fix and time.",
                "suggest Brona=>Verona")]                                         // a misheard name survives a prepended sentence
    [InlineData("By the way, the fix it ticket for the Tesla now everything is in the system, so we were just a little week too late.",
                "By the way, the fix it ticket for the Tesla now everything is in the system, so we were just a little week too early.",
                "silent")]
    // Two letters, a change of mind, and a rule that would rewrite every "go" he dictates.
    [InlineData("I'm going to be remote on Wednesday but you can we can do a Zoom call and you can screen share or we can go Thursday.",
                "I'm going to be remote on Wednesday but you can we can do a Zoom call and you can screen share or we can do Thursday.",
                "silent")]
    [InlineData("Okay then let's try with Dor.", "Okay then let's try with Duarte.", "offer Dor=>Duarte")]
    public void The_whole_chain(string wrote, string fieldNow, string outcome) =>
        Assert.Equal(outcome, Chain(wrote, fieldNow));

    // An older watch must not read the next dictation's paste as John editing its field.
    // Re-dictating over a selection is the case: two ASR outputs one word apart would
    // auto-write a rule from something he never typed.
    private static readonly Readback.Paste P1 = new(1, "Let's meet Thursday.");
    private static readonly Readback.Paste P2 = new(2, "Let's meet Tuesday.");

    [Fact]
    public void The_older_watch_stands_down_once_the_newer_dictation_is_in_its_field() =>
        Assert.True(Readback.Superseded(new[] { P1, P2 }, 1, "Let's meet Tuesday."));

    [Fact]
    public void The_newest_watch_is_never_superseded_by_itself() =>
        Assert.False(Readback.Superseded(new[] { P1, P2 }, 2, "Let's meet Tuesday."));

    [Fact]
    public void A_hand_edit_is_not_a_newer_dictation() =>
        Assert.False(Readback.Superseded(new[] { P1, P2 }, 1, "Let's meet Thursday!"));

    [Fact]
    public void An_appended_second_dictation_also_stands_the_first_down() =>
        Assert.True(Readback.Superseded(new[] { P1, P2 }, 1, "Let's meet Thursday. Let's meet Tuesday."));

    // Settling takes two looks in a row, so the window needs two polls past its end or an edit
    // made in the last second can never be confirmed.
    [Fact]
    public void The_window_leaves_room_for_an_edit_to_settle_at_the_very_end()
    {
        var checks = Readback.CheckDelays();
        Assert.True(checks[^1] >= Readback.WatchWindow + Readback.PollInterval);
        Assert.True(checks.Count >= 2);
        // Counted, not accumulated: 3.8 s to 16.6 s in 0.8 s steps, 17 looks.
        Assert.Equal(3.8, checks[0], 6);
        Assert.Equal(17, checks.Count);
        Assert.Equal(16.6, checks[^1], 6);
        Assert.Equal(20, Readback.Delays().Count);
    }

    [Theory]
    [InlineData("one\r\ntwo", "one\ntwo")]      // a Win32 edit box
    [InlineData("one\rtwo", "one\ntwo")]        // Word
    [InlineData("one\vtwo", "one\ntwo")]        // Word's line break
    [InlineData("one two", "one two")]     // a web composer's space
    public void Field_text_is_read_the_way_the_dictation_was_written(string field, string read) =>
        Assert.Equal(read, Readback.Normalize(field));

    // ---- ReadbackWatch: whole sequences of readings ----

    private static readonly TimeSpan At = TimeSpan.FromSeconds(0.6);
    private static readonly List<Readback.Paste> Pasted = new() { new(1, "Ask John Lynn about it.") };

    private static ReadbackWatch Anchored(string wrote = "Ask John Lynn about it.")
    {
        var watch = new ReadbackWatch(wrote, 1);
        Assert.Equal(ReadbackWatch.Action.Anchor, watch.Look(wrote, false, Pasted, At).Action);
        return watch;
    }

    [Fact]
    public void A_field_is_only_watched_once_it_holds_the_paste()
    {
        var watch = new ReadbackWatch("Ask John Lynn about it.", 1);
        // Chromium's tree, not there yet; then some other field; then the one with the paste.
        Assert.Equal(ReadbackWatch.Action.None, watch.Look("", false, Pasted, At).Action);
        Assert.Equal(ReadbackWatch.Action.None, watch.Look("Search", false, Pasted, At).Action);
        var step = watch.Look("Hi Sam. Ask John Lynn about it.", false, Pasted, TimeSpan.FromSeconds(1.5));
        Assert.Equal(ReadbackWatch.Action.Anchor, step.Action);
        Assert.Equal("readback: watching the field (1500ms)", step.Log);
        Assert.True(watch.Anchored);
    }

    [Fact]
    public void An_edit_is_handed_over_once_it_has_read_the_same_twice()
    {
        var watch = Anchored();
        Assert.Equal(ReadbackWatch.Action.None, watch.Look("Ask John Lin about it.", false, Pasted, At).Action);
        var step = watch.Look("Ask John Lin about it.", false, Pasted, At);
        Assert.Equal(ReadbackWatch.Action.Report, step.Action);
        Assert.Equal("Ask John Lin about it.", step.Edited);
    }

    [Fact]
    public void A_half_typed_word_waits_for_the_finished_one()
    {
        // The Mac caught "earl" on the way to "early" and offered it.
        var watch = Anchored();
        Assert.Equal(ReadbackWatch.Action.None, watch.Look("Ask John Li about it.", false, Pasted, At).Action);
        Assert.Equal(ReadbackWatch.Action.None, watch.Look("Ask John Lin about it.", false, Pasted, At).Action);
        var step = watch.Look("Ask John Lin about it.", false, Pasted, At);
        Assert.Equal(ReadbackWatch.Action.Report, step.Action);
        Assert.Equal("Ask John Lin about it.", step.Edited);
    }

    [Fact]
    public void An_edit_already_handed_over_is_not_handed_over_again()
    {
        var watch = Anchored();
        watch.Look("Ask John Lin about it.", false, Pasted, At);
        Assert.Equal(ReadbackWatch.Action.Report, watch.Look("Ask John Lin about it.", false, Pasted, At).Action);
        // The learner made nothing of it, so the watch goes on; the same reading is not news.
        Assert.Equal(ReadbackWatch.Action.None, watch.Look("Ask John Lin about it.", false, Pasted, At).Action);
        Assert.Equal(ReadbackWatch.Action.None, watch.Look("Ask John Lin about it.", false, Pasted, At).Action);
        // A different fix still gets its turn.
        watch.Look("Ask Jon Lin about it.", false, Pasted, At);
        Assert.Equal(ReadbackWatch.Action.Report, watch.Look("Ask Jon Lin about it.", false, Pasted, At).Action);
    }

    [Fact]
    public void A_field_cleared_mid_edit_hands_over_the_edit_it_was_settling()
    {
        // The Mac, 2026-09-14: "Siena" fixed to "Verona" and Enter pressed inside the 1.6 s the
        // settle gate needs. The composer emptied and the correction was lost.
        var watch = Anchored("Book the Siena for Friday.");
        watch.Look("Book the Verona for Friday.", false, Pasted, At);
        var step = watch.Look("", false, Pasted, At);
        Assert.Equal(ReadbackWatch.Action.Report, step.Action);
        Assert.Equal("Book the Verona for Friday.", step.Edited);
        Assert.StartsWith("readback: the field was cleared mid-edit", step.Log);
    }

    [Fact]
    public void A_placeholder_after_send_is_nothing_and_says_so_at_the_end()
    {
        var watch = Anchored("You can merge it in now.");
        Assert.Equal(ReadbackWatch.Action.None, watch.Look("Type / for commands", false, Pasted, At).Action);
        var step = watch.Look("Type / for commands", true, Pasted, At);
        Assert.Equal(ReadbackWatch.Action.None, step.Action);
        Assert.Equal("readback: field changed but it is not recognizably an edit of the dictation", step.Log);
    }

    [Fact]
    public void An_untouched_field_says_so_at_the_end()
    {
        var watch = Anchored();
        Assert.Null(watch.Look("Ask John Lynn about it.", false, Pasted, At).Log);
        Assert.Equal("readback: field unchanged after 15s, nothing to learn",
            watch.Look("Ask John Lynn about it.", true, Pasted, At).Log);
    }

    [Fact]
    public void A_field_never_found_says_so_at_the_end()
    {
        var watch = new ReadbackWatch("Ask John Lynn about it.", 1);
        Assert.Null(watch.Look("Search", false, Pasted, At).Log);
        Assert.Equal("readback: never found the pasted text in a field; nothing can be learned from this one",
            watch.Look("Search", true, Pasted, At).Log);
    }

    [Fact]
    public void Going_back_to_the_dictation_starts_the_settling_over()
    {
        var watch = Anchored();
        watch.Look("Ask John Lin about it.", false, Pasted, At);
        watch.Look("Ask John Lynn about it.", false, Pasted, At);   // undone
        Assert.Equal(ReadbackWatch.Action.None, watch.Look("Ask John Lin about it.", false, Pasted, At).Action);
        Assert.Equal(ReadbackWatch.Action.Report, watch.Look("Ask John Lin about it.", false, Pasted, At).Action);
    }

    [Fact]
    public void Re_dictating_over_a_selection_stands_the_first_watch_down_and_teaches_nothing()
    {
        var pastes = new List<Readback.Paste> { P1 };
        var first = new ReadbackWatch(P1.Text, 1);
        Assert.Equal(ReadbackWatch.Action.Anchor, first.Look(P1.Text, false, pastes, At).Action);
        // John selects the sentence and dictates it again; Parakeet hears Tuesday this time.
        pastes.Add(P2);
        var step = first.Look(P2.Text, false, pastes, At);
        Assert.Equal(ReadbackWatch.Action.StandDown, step.Action);
        Assert.Equal("readback: a newer dictation landed in this field; standing down", step.Log);
        Assert.True(first.Done);
        Assert.Equal(ReadbackWatch.Action.None, first.Look("Let's meet Tuesday!", false, pastes, At).Action);
    }

    [Fact]
    public void A_watch_that_never_found_its_field_stands_down_without_a_word()
    {
        var pastes = new List<Readback.Paste> { P1, P2 };
        var first = new ReadbackWatch(P1.Text, 1);
        var step = first.Look(P2.Text, false, pastes, At);
        Assert.Equal(ReadbackWatch.Action.StandDown, step.Action);
        Assert.Null(step.Log);
    }

    [Fact]
    public void A_retired_watch_does_nothing()
    {
        var watch = Anchored();
        watch.Retire();
        Assert.Equal(default, watch.Look("Ask John Lin about it.", true, Pasted, At));
    }

    [Fact]
    public void A_two_line_dictation_is_found_in_an_edit_box_once_its_line_ends_are_read_back()
    {
        var wrote = "First line.\nSecond line.";
        var watch = new ReadbackWatch(wrote, 1);
        var pastes = new List<Readback.Paste> { new(1, wrote) };
        Assert.Equal(ReadbackWatch.Action.None, watch.Look("First line.\r\nSecond line.", false, pastes, At).Action);
        Assert.Equal(ReadbackWatch.Action.Anchor,
            watch.Look(Readback.Normalize("First line.\r\nSecond line."), false, pastes, At).Action);
    }
}
