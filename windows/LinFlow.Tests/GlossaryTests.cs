using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

public class GlossaryTests
{
    // The Dictionary reads newest-learned first, then the rules John wrote, in his order.
    // Recency is file order: every rule is appended, so the last learned line is the newest.
    // Same cases as the Mac's selftest.
    [Fact]
    public void DisplayOrderPutsTheNewestLearnedRuleFirst()
    {
        var ordered = Glossary.DisplayOrder(new[]
        {
            new Replacement("Lynn", "Lin"),
            new Replacement("triadge", "triage", true),
            new Replacement("Vin", "Vinh"),
            new Replacement("Brona", "Verona", true),
        });
        Assert.Equal(new[] { "Brona", "triadge", "Lynn", "Vin" }, ordered.ConvertAll(r => r.From));
    }

    [Fact]
    public void DisplayOrderHandlesAnEmptyList() =>
        Assert.Empty(Glossary.DisplayOrder(new List<Replacement>()));

    // replacements.txt is edited by hand, so a line the parser cannot read must survive a save.
    // Every correction learned from an edit saves the file now, with nobody asking.
    private const string Hand =
        "# Lin Flow corrections: what was heard => what you meant, one per line.\n" +
        "# names I keep fixing\n" +
        "Lynn => Lin\n" +
        "wisper flow -> Wispr Flow\n";

    [Fact]
    public void ALineThatCannotBeReadSurvivesASave()
    {
        var written = Glossary.ReplacementsFile(new[] { new Replacement("Lynn", "Lin") }, Hand);
        Assert.Contains("Lynn => Lin", written);
        Assert.Contains("wisper flow -> Wispr Flow", written);   // a typo'd arrow is not deleted
        Assert.Contains("# names I keep fixing", written);       // a hand-written comment survives
        Assert.Equal(2, written.Split("Lynn => Lin").Length);   // the rule is not duplicated
    }

    [Fact]
    public void SavingTwiceChangesNothing()
    {
        // The Mac carried the kept section's own heading forward as one more comment, so every
        // save after the first added another copy of it.
        var once = Glossary.ReplacementsFile(new[] { new Replacement("Lynn", "Lin") }, Hand);
        var twice = Glossary.ReplacementsFile(new[] { new Replacement("Lynn", "Lin") }, once);
        Assert.Equal(once, twice);
    }

    [Fact]
    public void ALearnedRuleIsMarkedInTheFile()
    {
        var file = Glossary.ReplacementsFile(new[]
        {
            new Replacement("wisper flow", "Wispr Flow"),
            new Replacement("K Wynn E D F", "kkwinedf", true),
        }, "");
        Assert.Contains("\nwisper flow => Wispr Flow\n", file);
        Assert.Contains("\nK Wynn E D F => kkwinedf\t# learned\n", file);
        Assert.DoesNotContain("could not read", file);   // nothing kept, no section for it
    }

    [Fact]
    public void AFileSavedByNotepadKeepsItsCommentsToo()
    {
        var written = Glossary.ReplacementsFile(new[] { new Replacement("Lynn", "Lin") }, Hand.Replace("\n", "\r\n"));
        Assert.Contains("# names I keep fixing", written);
        Assert.DoesNotContain("\r", written);
    }
}
