using System.Runtime.CompilerServices;

namespace LinFlow.Tests;

/// Points the whole suite at a throwaway data folder before a single test runs.
///
/// The tests drive real production code, and that code logs as it works: a meeting recovered
/// after an unclean stop, a WAV header repaired, a running note written. Without this, every
/// `dotnet test` appended those lines to %APPDATA%\Lin Flow\app.log - the log of the copy John
/// actually dictates with, and the first place anyone looks when a dictation has gone wrong.
/// Test output sitting in it is worse than noise, because it describes events that never
/// happened on his machine.
///
/// A module initializer is what makes this reliable: it runs when the test assembly loads,
/// which is before any test, any fixture and any static constructor in LinFlow.Core. `Paths`
/// reads the variable once, so setting it afterwards would be too late.
internal static class TestDataDir
{
    [ModuleInitializer]
    internal static void Redirect()
    {
        var dir = Path.Combine(
            Path.GetTempPath(), "lin-flow-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        Environment.SetEnvironmentVariable("LINFLOW_DATA_DIR", dir);
    }
}
