using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// The learner end to end, into the suite's own data folder (TestDataDir), never John's: a fix
/// becomes a learned line in replacements.txt, a suggestion waits in pending-corrections.json,
/// and an edit too far apart to learn is offered once. PLAN.md's M4 asks for a word fixed within
/// 15 s to land in replacements.txt with the learned marker; this is the half after the readback.
///
/// These are the only tests that write those two files, and xUnit runs one class's tests one at
/// a time, so the rest of the suite running alongside cannot race them.
public class CorrectionLearningTests
{
    private static void Reset()
    {
        File.Delete(Paths.ReplacementsFile);
        File.Delete(Paths.PendingCorrectionsFile);
    }

    [Fact]
    public void A_fix_is_written_as_a_learned_rule_and_announced()
    {
        Reset();
        CorrectionLearning.Outcome? announced = null;
        void OnLearn(CorrectionLearning.Outcome o) => announced = o;
        CorrectionLearning.DidLearn += OnLearn;
        try
        {
            var outcome = CorrectionLearning.Handle("Ask John Lynn about it.", "Ask John Lin about it.", LearnMode.Auto);
            Assert.Equal("Lynn => Lin", Assert.Single(outcome.Added).ToString());
            Assert.Empty(outcome.Suggested);
            Assert.Contains("Lynn => Lin\t# learned", File.ReadAllText(Paths.ReplacementsFile));
            Assert.True(Assert.Single(Glossary.LoadReplacements()).Learned);
            Assert.Same(outcome, announced);
        }
        finally
        {
            CorrectionLearning.DidLearn -= OnLearn;
        }
    }

    [Fact]
    public void Suggest_it_first_writes_nothing_and_waits_for_a_click()
    {
        Reset();
        var outcome = CorrectionLearning.Handle("Ask John Lynn about it.", "Ask John Lin about it.", LearnMode.Ask);
        Assert.Empty(outcome.Added);
        Assert.Equal("Lynn => Lin", Assert.Single(outcome.Suggested).ToString());
        Assert.Empty(Glossary.LoadReplacements());
        Assert.Equal("Lynn => Lin", Assert.Single(CorrectionLearning.Pending()).ToString());
    }

    [Fact]
    public void Do_nothing_does_nothing()
    {
        Reset();
        Assert.True(CorrectionLearning.Handle("Ask John Lynn about it.", "Ask John Lin about it.", LearnMode.Off).IsEmpty);
        Assert.False(File.Exists(Paths.ReplacementsFile));
        Assert.False(File.Exists(Paths.PendingCorrectionsFile));
    }

    [Fact]
    public void A_misheard_name_waits_rather_than_being_written()
    {
        Reset();
        var outcome = CorrectionLearning.Handle("Then draft a better email to Wort.", "Then draft a better email to Duarte.", LearnMode.Auto);
        Assert.Empty(outcome.Added);
        Assert.Equal("Wort => Duarte", Assert.Single(CorrectionLearning.Pending()).ToString());
        Assert.Empty(Glossary.LoadReplacements());
    }

    [Fact]
    public void An_edit_neither_tier_takes_is_offered_once_and_kept()
    {
        Reset();
        (string, string)? offered = null;
        void OnDecline(string from, string to) => offered = (from, to);
        CorrectionLearning.DidDecline += OnDecline;
        try
        {
            // A name misheard as one glued word and fixed into two: too far apart for either
            // tier, and exactly the correction worth keeping.
            Assert.True(CorrectionLearning.Handle("Marisvo.", "Marisa Vuong", LearnMode.Auto).IsEmpty);
            Assert.Equal(("Marisvo", "Marisa Vuong"), offered);
            Assert.Equal("Marisvo => Marisa Vuong", Assert.Single(CorrectionLearning.Pending()).ToString());
            Assert.Empty(Glossary.LoadReplacements());
        }
        finally
        {
            CorrectionLearning.DidDecline -= OnDecline;
        }
    }

    [Fact]
    public void Accepting_a_suggestion_moves_it_into_the_corrections()
    {
        Reset();
        CorrectionLearning.Handle("Marisvo.", "Marisa Vuong", LearnMode.Auto);
        CorrectionLearning.Accept(Assert.Single(CorrectionLearning.Pending()));
        Assert.Empty(CorrectionLearning.Pending());
        var rule = Assert.Single(Glossary.LoadReplacements());
        Assert.Equal("Marisvo => Marisa Vuong", rule.ToString());
        Assert.True(rule.Learned);
    }

    [Fact]
    public void Learning_keeps_what_John_wrote_by_hand()
    {
        Reset();
        File.WriteAllText(Paths.ReplacementsFile,
            "# Lin Flow corrections: what was heard => what you meant, one per line.\n" +
            "# names I keep fixing\n" +
            "Lynn => Lin\n" +
            "wisper flow -> Wispr Flow\n");
        CorrectionLearning.Handle("Send it to github.", "Send it to GitHub.", LearnMode.Auto);
        var file = File.ReadAllText(Paths.ReplacementsFile);
        Assert.Contains("Lynn => Lin\n", file);
        Assert.Contains("github => GitHub\t# learned", file);
        Assert.Contains("# names I keep fixing", file);
        Assert.Contains("wisper flow -> Wispr Flow", file);
    }
}
