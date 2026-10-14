using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// Spoken numbers as digits. The Mac's selftest cases for NumberWords
/// (Sources/LinFlow/SelfTest/SelfTest+Cleanup.swift, "spoken numbers as digits"), in the same
/// order and with the same labels, so a case that fails here names the case that fails there.
public class NumberWordsTests
{
    [Theory]
    [InlineData("one two three four five", "1 2 3 4 5")]                 // a run of digits
    [InlineData("one, two, three", "1, 2, 3")]                           // separators kept
    [InlineData("twenty two", "22")]                                     // tens plus unit
    [InlineData("three hundred", "300")]                                 // hundred
    [InlineData("three hundred and five", "305")]                        // hundred and unit
    [InlineData("two thousand twenty six", "2026")]                      // thousands
    [InlineData("two hundred fifty thousand", "250000")]                 // compound scale
    [InlineData("fifteen hundred", "1500")]                              // teen hundred
    [InlineData("nineteen eighty four", "1984")]                         // year said as two
    [InlineData("twenty twenty six", "2026")]                            // this decade
    [InlineData("twenty thirty", "20 30")]                               // a range is not a year
    [InlineData("I have two questions", "I have 2 questions")]           // plain count
    [InlineData("one of the reasons", "one of the reasons")]             // 'one' as a pronoun
    [InlineData("the one that works", "the one that works")]             // 'the one'
    [InlineData("no one knows", "no one knows")]                         // 'no one'
    [InlineData("one dollar", "1 dollar")]                               // 'one' before a unit
    [InlineData("one hundred", "100")]                                   // 'one' inside a number
    [InlineData("the twenty second", "the twenty second")]               // ordinal after a number
    [InlineData("one-on-one", "one-on-one")]                             // hyphenated compound
    [InlineData("a few hundred", "a few hundred")]                       // bare scale word
    [InlineData("a hundred", "100")]                                     // 'a hundred' is a figure
    [InlineData("a hundred forty volts", "140 volts")]                   // 'a hundred' and more
    [InlineData("A hundred people came", "100 people came")]             // 'a hundred' opening a sentence
    [InlineData("about a thousand of them", "about 1000 of them")]       // 'a thousand'
    [InlineData("a hundred and five", "105")]                            // 'a hundred and' a unit
    [InlineData("one in a million", "one in a million")]                 // 'a million' stays words
    [InlineData("a hundred-year flood", "a hundred-year flood")]         // 'a hundred' in a compound
    [InlineData("eight hundred and seven hundred", "800 and 700")]       // a second hundreds is a new number
    [InlineData("a thousand, two thousand", "1000, 2000")]               // a second thousand is a new number
    [InlineData("five hundred thousand, two hundred thousand", "500000, 200000")] // a second thousand after a hundred
    [InlineData("two thousand five, three thousand", "2005, 3000")]      // a number that ends before the next thousand
    [InlineData("one million two hundred thousand", "1200000")]          // a smaller scale after a bigger one
    [InlineData("panels one and two", "panels 1 and 2")]                 // 'and' between two numbers stays
    [InlineData("thousands of people", "thousands of people")]           // plural scale
    [InlineData("someone anyone", "someone anyone")]                     // no partial word match
    [InlineData("version three", "version 3")]                           // after a counter word
    // Dates and decimals, John on 2026-09-29.
    [InlineData("I already got my September thirtieth invoice.", "I already got my September 30th invoice.")] // a day after a month
    [InlineData("September twenty first", "September 21st")]             // a two-word day
    [InlineData("March second, May third, June twelfth", "March 2nd, May 3rd, June 12th")] // day suffixes
    [InlineData("October first one move in date", "October 1st one move in date")] // a day, then a pronoun 'one'
    [InlineData("September thirty first, twenty twenty six", "September 31st, 2026")] // a day, then a year
    [InlineData("the thirtieth of September", "the 30th of September")]  // the day of a month
    [InlineData("my first job", "my first job")]                         // an ordinal with no month stays a word
    [InlineData("you may first check", "you may first check")]           // 'may' that is not the month
    [InlineData("Claude Opus five point five", "Claude Opus 5.5")]       // a decimal
    [InlineData("three point one four", "3.14")]                         // several decimal digits
    [InlineData("one point five hours", "1.5 hours")]                    // 'one point five'
    [InlineData("version two point oh", "version 2.0")]                  // 'point oh'
    [InlineData("five point five million", "5.5 million")]              // a decimal before a scale word
    [InlineData("we made two points", "we made 2 points")]               // 'points' is not a decimal
    [InlineData("no numbers here at all", "no numbers here at all")]     // untouched
    public void Spoken_numbers_are_written_as_digits(string spoken, string written) =>
        Assert.Equal(written, NumberWords.Apply(spoken));

    /// "numbers: through the whole pass". An empty dictionary, so nothing on this machine's disk
    /// can change the answer.
    [Fact]
    public void Numbers_survive_the_whole_cleanup_pass()
    {
        var cleaner = new TextCleaner(Array.Empty<string>(), Array.Empty<Replacement>());
        Assert.Equal("So I need 22 of them.", cleaner.Clean("um so I need twenty two of them"));
        Assert.Equal("Are there any more 140 watt chargers?", cleaner.Clean("Are there any more a hundred forty watt chargers?"));
        Assert.Equal("I already got my September 30th invoice and 5.5 needs to be exact.",
                     cleaner.Clean("I already got my September thirtieth invoice and five point five needs to be exact"));
    }
}
