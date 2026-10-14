using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// The learner's decision rules, ported from SelfTest.swift. Every case here came off John's
/// real Mac log on 2026-09-14, the day four separate gates were found to be refusing the same
/// correction. Nothing here touches the filesystem: the waiting-list rule is a pure function
/// precisely so a test cannot go near a live pending-corrections.json.
public class LearnedCorrectionsTests
{
    // The one thing that changed, when exactly one thing did. A misheard name most often
    // arrives as one glued word, so the fix splits it in two.
    [Theory]
    [InlineData("Marisvo is here.", "Marisa Vuong is here.", "Marisvo", "Marisa Vuong")]
    [InlineData("Okay, try Marissa Wang.", "Okay, try Marisa Vuong.", "Marissa Wang", "Marisa Vuong")]
    [InlineData("Let's try again with Dwart.", "Let's try again with Duarte.", "Dwart", "Duarte")]
    public void LonePairFindsTheOneChange(string wrote, string now, string from, string to)
    {
        var pair = CorrectionLearning.LonePair(wrote, now);
        Assert.NotNull(pair);
        Assert.Equal(from, pair!.Value.From);
        Assert.Equal(to, pair.Value.To);
    }

    // Carrying on typing after a dictation reads as a substitution, because the last word
    // carried a full stop and the new words did not. Continuing a sentence is not a correction.
    [Theory]
    [InlineData("Ask John.", "Ask John about it.")]
    [InlineData("Ask John Lynn.", "Ask John Lynn.")]
    public void LonePairRefusesContinuationAndSameness(string wrote, string now) =>
        Assert.Null(CorrectionLearning.LonePair(wrote, now));

    // What earns a pop-up. Length was the wrong discriminator: a four-character floor added
    // to stop "go" -> "do" silently refused "Dor" -> "Duarte" while John was testing it.
    // Capitalization tells a misheard name from a change of mind; length cannot.
    [Theory]
    [InlineData("Dor", "Duarte", true)]
    [InlineData("Wort", "Duarte", true)]
    [InlineData("Brona", "Verona", true)]
    [InlineData("Merissa Wong", "Marisa Vuong", true)]
    [InlineData("our decide", "Regicide", true)]
    [InlineData("Mari Sa", "Marisa Vuong", true)]
    // 2026-09-18: everything actually waiting in the Mac's pending-corrections.json, four
    // entries, none worth a click. The first three are ordinary words swapped for ordinary
    // words; the last two are the readback catching John mid-retype, and either one accepted
    // by mistake mangles every dictation after it.
    [InlineData("late", "early", false)]
    [InlineData("growth", "grove", false)]
    [InlineData("fruit", "fridge", false)]
    [InlineData("threat", "thread", false)]
    [InlineData("Let's add them to", "What's item", false)]
    [InlineData("I will charge my laptop", "passed sp", false)]
    [InlineData("go", "do", false)]
    [InlineData("go", "dos", false)]
    [InlineData("the", "a", false)]
    [InlineData("their", "there", false)]
    // Dictated text is capitalized at the start of every sentence, so the name escape hatch
    // covers the commonest spot for a change of mind. Accepting "We" => "He" writes a
    // case-insensitive whole-word rule that rewrites every future "we".
    [InlineData("We", "He", false)]
    [InlineData("Go", "Do", false)]
    [InlineData("Sam", "Pam", false)]
    public void WorthShowingGatesThePopUp(string from, string to, bool shown) =>
        Assert.Equal(shown, CorrectionLearning.WorthShowing(from, to));

    // 2026-09-18: three rules the learner wrote by itself, found live in the Mac's dictionary,
    // each firing on every dictation -- "I saved it to the cloud." came out as "I saved it to
    // the Claude." An everyday English word is a word John might have meant, so a global rule
    // on it rewrites his own writing. Key("cloud") and Key("claude") are both "cld", which is
    // exactly what let them in.
    [Theory]
    [InlineData("cloud", "Claude", false)]
    [InlineData("clod", "Claude", false)]
    [InlineData("threat", "thread", false)]
    [InlineData("clause", "Claude", false)]
    [InlineData("Claudia", "Claude", false)]
    [InlineData("failed", "filled", false)]        // an inflection is a word too
    [InlineData("saving", "shaving", false)]       // and so is a participle
    [InlineData("loose", "lose", false)]           // a respelling still has to be a name
    // ...and the rules that must survive it.
    [InlineData("Lynn", "Lin", true)]              // one name spelled two ways
    [InlineData("Claudea", "Claude", true)]        // a mishearing is not a word
    [InlineData("triadge", "triage", true)]        // nor is a mangled one
    [InlineData("Marissa", "Marisa", true)]
    [InlineData("K Wynn E D F", "kkwinedf", true)] // single letters are not English prose
    [InlineData("Q 3", "Q3", true)]
    [InlineData("spider riders", "spiderriders", true)]   // same letters, only the spacing
    [InlineData("cant", "can't", true)]                   // same letters, only the apostrophe
    public void PlausibleRefusesToBindAnEverydayWord(string from, string to, bool bound) =>
        Assert.Equal(bound, LearnedCorrections.Plausible(from, to));

    [Theory]
    [InlineData("like that", true)]
    [InlineData("K Wynn E D F", false)]
    [InlineData("Marisvo", false)]
    [InlineData("Q 3", false)]
    public void EverydayEnglishKnowsProseFromAMishearing(string phrase, bool prose) =>
        Assert.Equal(prose, LearnedCorrections.EverydayEnglish(phrase));

    // Replacement.Id is the left side alone, and the readback keeps watching after an edit
    // that taught nothing, so the same left side arrives more than once as John types. The
    // half-typed pair must not squat the slot and leave a truncated rule to be accepted.
    [Fact]
    public void AFinishedPairReplacesTheHalfTypedOne()
    {
        var waiting = new List<Replacement> { new("Marisvo", "Marisa V", true) };
        var list = CorrectionLearning.Merging(new Replacement("Marisvo", "Marisa Vuong", true),
                                              waiting, new List<Replacement>());
        Assert.NotNull(list);
        Assert.Single(list!);
        Assert.Equal("Marisa Vuong", list![0].To);
    }

    [Fact]
    public void TheSamePairTwiceWritesNothing() =>
        Assert.Null(CorrectionLearning.Merging(new Replacement("Marisvo", "Marisa Vuong", true),
                                               new List<Replacement> { new("Marisvo", "Marisa Vuong", true) },
                                               new List<Replacement>()));

    [Fact]
    public void ARuleAlreadyAcceptedIsNeverReopened() =>
        Assert.Null(CorrectionLearning.Merging(new Replacement("Marisvo", "Marisa Vuong", true),
                                               new List<Replacement>(),
                                               new List<Replacement> { new("Marisvo", "Marisa Vuong") }));

    /// The rules Lin Flow would write by itself, which is what Handle does with the Apply tier.
    private static string Learned(string wrote, string now, params Replacement[] existing) =>
        string.Join("|", LearnedCorrections.Scored(wrote, now, existing)
            .Where(s => s.Confidence == LearnedCorrections.Confidence.Apply)
            .Select(s => $"{s.Replacement.From}=>{s.Replacement.To}"));

    // The Mac's selftest, case for case.
    [Theory]
    [InlineData("My GitHub is K Wynn E D F.", "My GitHub is kkwinedf.", "K Wynn E D F=>kkwinedf")]   // John's own case, five words to one
    [InlineData("Ask John Lynn about it.", "Ask John Lin about it.", "Lynn=>Lin")]                   // one word inside a sentence
    [InlineData("It runs on work brain.", "It runs on WORKBRAIN.", "work brain=>WORKBRAIN")]        // glued form
    [InlineData("Send it to github.", "Send it to GitHub.", "github=>GitHub")]                      // capitalization only
    [InlineData("Let's meet Thursday.", "Let's meet Friday.", "")]                                  // a change of mind
    [InlineData("The build is green.", "The build is broken.", "")]                                 // an unrelated word
    [InlineData("I want the report.", "I want that report.", "")]                                   // a stopword never becomes a rule
    [InlineData("Ship it now.", "Ship it.", "")]                                                    // a deletion is not a correction
    [InlineData("A totally different sentence entirely.", "Nothing whatsoever alike here now.", "")] // a wholesale rewrite
    [InlineData("I saved it to the cloud.", "I saved it to Claude.", "")]                           // the live case of 2026-09-18
    [InlineData("draft a better email to Wort.", "draft a better email to Duarte.", "")]            // a misheard name is only offered
    [InlineData("one two three", "one two three", "")]                                              // no edit, no rule
    public void WhatAnEditTeaches(string wrote, string now, string rules) =>
        Assert.Equal(rules, Learned(wrote, now));

    [Fact]
    public void AnExistingRuleIsNotRepeated() =>
        Assert.Equal("", Learned("Ask John Lynn about it.", "Ask John Lin about it.", new Replacement("Lynn", "Lin")));

    [Fact]
    public void AnEditTheRulesAlreadyMakeIsNotLearned() =>
        Assert.Equal("", Learned("Ask Lynn about it.", "Ask Lin about it.", new Replacement("Lynn", "Lin")));

    // A misheard name is phonetically distant by nature, so it can never be auto-learned; but
    // throwing it away silently is what made the dictionary feel broken. It is offered.
    [Fact]
    public void AMisheardNameIsOfferedNotApplied()
    {
        var scored = LearnedCorrections.Scored("draft a better email to Wort.", "draft a better email to Duarte.", new List<Replacement>());
        var only = Assert.Single(scored);
        Assert.Equal("Wort=>Duarte", $"{only.Replacement.From}=>{only.Replacement.To}");
        Assert.Equal(LearnedCorrections.Confidence.Suggest, only.Confidence);
    }

    [Theory]
    [InlineData("Wort", "Duarte", true)]           // a capitalized one-word name
    [InlineData("email", "message", false)]        // not an ordinary reword
    [InlineData("Wort", "Duarte Silva", false)]    // not a phrase
    [InlineData("that", "Duarte", false)]          // not from a stopword
    [InlineData("Wort", "Duar7e", false)]          // letters only
    [InlineData("Obrien", "O’Brien", true)]        // apostrophes are names too
    public void WorthOffering(string from, string to, bool offered) =>
        Assert.Equal(offered, LearnedCorrections.WorthOffering(from, to));

    [Theory]
    [InlineData("draft an email to Wort.", "draft an email to Duarte.", "Wort=>Duarte")]
    // A retype is still named; the judgment is John's.
    [InlineData("his friends in each of those roles?", "his friends in each of those departmetns?", "roles=>departmetns")]
    [InlineData("Ask John about it.", "Ask John about it.", "")]
    [InlineData("Ask John about it.", "Ask Jane about the other thing.", "")]   // more than one change is not a pair
    [InlineData("Just use the Marisvo 6 Repos that was made in 2020.",
                "Just use the Marisa Vuong 6 Repos that was made in 2020.", "Marisvo=>Marisa Vuong")]
    [InlineData("Ask Marissa Vo about it.", "Ask Marisa Vuong about it.", "Marissa Vo=>Marisa Vuong")]
    [InlineData("meet Marisa Vuong and Mark at noon", "meet Marisa Vuong and Marc at 12", "")]
    [InlineData("", "something", "")]
    public void LonePairNamesTheOneChangeOrNothing(string wrote, string now, string pair) =>
        Assert.Equal(pair, CorrectionLearning.LonePair(wrote, now) is { } p ? $"{p.From}=>{p.To}" : "");

    [Fact]
    public void AnUnrelatedPairIsLeftAlone()
    {
        var list = CorrectionLearning.Merging(new Replacement("Dwart", "Duarte", true),
                                              new List<Replacement> { new("Brona", "Verona", true) },
                                              new List<Replacement>());
        Assert.NotNull(list);
        Assert.Equal(2, list!.Count);
        Assert.Equal("Brona", list[0].From);
        Assert.Equal("Dwart", list[1].From);
    }
}
