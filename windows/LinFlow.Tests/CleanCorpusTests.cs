using System.Text.Json;
using LinFlow.Core;
using Xunit;
using Xunit.Abstractions;

namespace LinFlow.Tests;

/// The port's real test: dictations John actually spoke, each cleaned by the Swift app on the Mac
/// and recorded with its exact output. The C# has to produce the same string, character for
/// character, for every one of them.
///
/// This is worth more than hand-written assertions. Hand-written cases only cover the behavior
/// somebody thought to write down; this corpus is the real distribution - the fillers he actually
/// says, the names he actually dictates, the numbers, the half-sentences, the 30-second rambles.
///
/// Which is exactly why it is not in the repo. It is real dictation: work addresses, retirement
/// contributions, colleagues by name. README says the dictation history, dictionary and notes live
/// in Application Support, outside the repo, so that pushing source can never publish them - this
/// file was the one place that was not true. It now lives with the rest of the app's data:
///
///     macOS    ~/Library/Application Support/Lin Flow/test-corpus/clean-corpus.json
///     Windows  %APPDATA%\Lin Flow\test-corpus\clean-corpus.json
///
/// `LINFLOW_CORPUS` points somewhere else; `LINFLOW_DATA_DIR` moves it with the rest of the data.
/// Where the file is absent - CI, a fresh clone, anyone else's machine - these tests do not run.
/// A green suite there says nothing about the cleaner, so check <see cref="CorpusWasFound"/>'s
/// output before believing the port is verified.
public class CleanCorpusTests
{
    private readonly ITestOutputHelper _output;

    public CleanCorpusTests(ITestOutputHelper output) => _output = output;

    private sealed record Corpus(
        List<string> Glossary,
        List<RepDto> Replacements,
        List<Case> Cases);

    private sealed record RepDto(string From, string To, bool Learned);
    private sealed record Case(string Input, string Expected);

    private static readonly string Path_ = ResolvePath();
    private static readonly Corpus? Data = Load();

    /// Deliberately not `Paths.DataDir`: TestDataDir's module initializer has already pointed that
    /// at a fresh temp folder, so the corpus would never be found there. This is the installed
    /// app's own folder, which is where the file actually sits.
    private static string ResolvePath()
    {
        var pinned = Environment.GetEnvironmentVariable("LINFLOW_CORPUS");
        if (!string.IsNullOrWhiteSpace(pinned)) return pinned;

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = OperatingSystem.IsMacOS()
            ? Path.Combine(home, "Library", "Application Support")
            : Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

        return Path.Combine(appData, "Lin Flow", "test-corpus", "clean-corpus.json");
    }

    private static Corpus? Load()
    {
        if (!File.Exists(Path_)) return null;
        var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        return JsonSerializer.Deserialize<Corpus>(File.ReadAllText(Path_), opts)!;
    }

    private static TextCleaner MakeCleaner() =>
        new(Data!.Glossary, Data.Replacements.Select(r => new Replacement(r.From, r.To, r.Learned)));

    /// One row per case, or a single -1 when there is no corpus: xunit errors on an empty theory.
    public static TheoryData<int> CaseIndices()
    {
        var d = new TheoryData<int>();
        if (Data is null) { d.Add(-1); return d; }
        for (var i = 0; i < Data.Cases.Count; i++) d.Add(i);
        return d;
    }

    [Theory]
    [MemberData(nameof(CaseIndices))]
    public void MatchesTheSwiftOutput(int index)
    {
        if (index < 0) return; // No corpus on this machine. CorpusWasFound says so.
        var c = Data!.Cases[index];
        var cleaner = MakeCleaner();
        var got = cleaner.Clean(c.Input);
        Assert.Equal(c.Expected, got);
    }

    /// Passes either way - a machine without the corpus is not a broken machine. It reports which
    /// of the two happened, because the difference is 300-odd assertions and a run says nothing
    /// about that on its own.
    [Fact]
    public void CorpusWasFound()
    {
        if (Data is null)
        {
            _output.WriteLine($"No corpus at {Path_} - the cleaner is UNVERIFIED in this run.");
            _output.WriteLine("Copy it from a machine that has one, or set LINFLOW_CORPUS.");
            return;
        }

        _output.WriteLine($"{Data.Cases.Count} cases from {Path_}");
        Assert.True(Data.Cases.Count > 300, $"only {Data.Cases.Count} cases");
    }
}
