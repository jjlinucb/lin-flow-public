using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// "comma enter enter", the same cases as the Mac's selftest (SelfTest+Cleanup.swift).
public class SpokenCommandsTests
{
    private static string Clean(string raw) =>
        new TextCleaner(new List<string>(), new List<Replacement>()).Clean(raw);

    [Theory]
    // John's Gmail reply on 2026-09-25, as Parakeet heard it.
    [InlineData("Hi Solomon, comma enter enter where's that data store?", "Hi Solomon,\n\nWhere's that data store?")]
    [InlineData("Hi Solomon. Comma, enter, enter. Where's that?", "Hi Solomon,\n\nWhere's that?")]
    [InlineData("Thanks, enter enter John", "Thanks,\n\nJohn.")]
    [InlineData("that's all period enter see you", "That's all.\nSee you.")]
    public void An_enter_run_is_a_command(string raw, string expected) => Assert.Equal(expected, Clean(raw));

    [Theory]
    [InlineData("Please enter the password and press enter.")]
    [InlineData("Put a comma after the name.")]
    [InlineData("After the trial period, enter your card details.")]
    public void A_lone_enter_or_comma_is_a_word(string raw) => Assert.Equal(raw, Clean(raw));
}
