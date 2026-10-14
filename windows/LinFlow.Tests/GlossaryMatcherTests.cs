using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// The guards in GlossaryMatcher, ported from SelfTest.swift. The corpus test covers what John
/// actually dictated; these cover what must never happen even though he has not hit it yet.
public class GlossaryMatcherTests
{
    // "John Lee" and "John Lin" are different people. Before the personal-name guard, the
    // exactly-matching "John" donated its length to the edit budget without donating any
    // distance, so the whole budget was free to be spent rewriting the surname.
    [Theory]
    [InlineData("Lee")] [InlineData("Liu")] [InlineData("Long")] [InlineData("Lim")]
    [InlineData("Ling")] [InlineData("Liang")] [InlineData("Lam")] [InlineData("Lang")]
    [InlineData("Lane")] [InlineData("Levin")] [InlineData("Lund")] [InlineData("Lind")]
    [InlineData("Lok")] [InlineData("Low")]
    public void ARealSurnameIsNeverRewrittenIntoADifferentOne(string surname) =>
        Assert.False(GlossaryMatcher.Matches($"John {surname}", "John Lin"),
                     $"\"John {surname}\" must not become \"John Lin\"");

    // ...but a respelling of the same name still snaps.
    [Theory]
    [InlineData("John Lynn")] [InlineData("John Linn")]
    public void ARespellingOfTheSameNameStillSnaps(string candidate) =>
        Assert.True(GlossaryMatcher.Matches(candidate, "John Lin"));

    // Words that are nobody's name are untouched by the guard and still snap.
    [Theory]
    [InlineData("Lend Flow", "Lin Flow")]
    [InlineData("Linflow", "Lin Flow")]
    [InlineData("whisperflow", "Wispr Flow")]
    [InlineData("Cloud Code", "Claude Code")]
    [InlineData("Sunnyvail", "Sunnyvale")]
    public void ANearMissThatIsNobodysNameStillSnaps(string candidate, string term) =>
        Assert.True(GlossaryMatcher.Matches(candidate, term));

    // An ordinary English word is never a misspelling of a name, however close it looks.
    [Theory]
    [InlineData("could", "Claude")]
    [InlineData("cloud", "Claude")]
    [InlineData("clause", "Claude")]
    [InlineData("in flow", "Lin Flow")]
    [InlineData("Lin Flow", "Lin Flow")]   // already right: no self-match
    public void OrdinaryWordsAndExactTermsAreLeftAlone(string candidate, string term) =>
        Assert.False(GlossaryMatcher.Matches(candidate, term));

    [Theory]
    [InlineData("Lynn", "lin")]     // doubled letter collapses
    [InlineData("Lin", "lin")]
    [InlineData("Lane", "lan")]     // silent e dropped
    [InlineData("Lyn", "lin")]      // y folds to i
    public void NameKeyFoldsSpellingVariants(string input, string expected) =>
        Assert.Equal(expected, GlossaryMatcher.NameKey(input));

    [Theory]
    [InlineData("Wispr Flow", "wsprflw")]
    [InlineData("Lin Flow", "lnflw")]
    public void KeyIsTheConsonantSkeleton(string input, string expected) =>
        Assert.Equal(expected, GlossaryMatcher.Key(input));

    [Theory]
    [InlineData(3, 0)] [InlineData(4, 1)] [InlineData(6, 1)]
    [InlineData(7, 2)] [InlineData(11, 2)] [InlineData(12, 3)]
    public void ToleranceScalesWithLength(int length, int budget) =>
        Assert.Equal(budget, GlossaryMatcher.Tolerance(length));

    [Fact]
    public void TheEmbeddedWordListLoaded() =>
        // 235,976 entries in BSD web2. If the embedded resource failed to load, every guard that
        // depends on it silently stops working and "cloud" starts becoming "Claude".
        Assert.True(GlossaryMatcher.IsDictionaryWord("cloud") && GlossaryMatcher.IsDictionaryWord("clause")
                    && !GlossaryMatcher.IsDictionaryWord("linflow"),
                    "the embedded words.txt did not load");

    [Theory]
    [InlineData("")] [InlineData(" ")] [InlineData("a")] [InlineData("'")]
    public void DegenerateInputDoesNotThrow(string input)
    {
        var m = new GlossaryMatcher(new[] { "Lin Flow", "Claude Code", "John Lin" });
        var ex = Record.Exception(() => m.Apply(input));
        Assert.Null(ex);
    }
}
