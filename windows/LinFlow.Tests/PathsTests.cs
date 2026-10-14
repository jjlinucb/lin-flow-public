using Xunit;
using LinFlow.Core;

namespace LinFlow.Tests;

/// Guards the redirect in TestDataDir. If it ever stops working, these fail here rather than
/// showing up weeks later as strange lines in the live log.
public class PathsTests
{
    private static string LiveDataDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lin Flow");

    [Fact]
    public void TheSuiteDoesNotUseTheInstalledAppsDataFolder()
    {
        Assert.NotEqual(
            Path.GetFullPath(LiveDataDir).TrimEnd(Path.DirectorySeparatorChar),
            Path.GetFullPath(Paths.DataDir).TrimEnd(Path.DirectorySeparatorChar));
    }

    [Fact]
    public void LoggingLandsInTheRedirectedFolderAndNotTheLiveOne()
    {
        var live = Path.Combine(LiveDataDir, "app.log");
        var before = File.Exists(live) ? new FileInfo(live).Length : 0L;

        var marker = $"paths test marker {Guid.NewGuid():N}";
        Log.Info(marker);

        Assert.Contains(marker, File.ReadAllText(Paths.LogFile));

        var after = File.Exists(live) ? new FileInfo(live).Length : 0L;
        Assert.Equal(before, after);
    }

    [Fact]
    public void EveryPathSitsUnderTheDataFolder()
    {
        var root = Path.GetFullPath(Paths.DataDir).TrimEnd(Path.DirectorySeparatorChar);
        foreach (var path in new[]
                 {
                     Paths.ModelsDir, Paths.RecordingsDir, Paths.NotesDir, Paths.VocabFile,
                     Paths.ReplacementsFile, Paths.HistoryFile, Paths.SnippetsFile,
                     Paths.TransformsFile, Paths.PendingCorrectionsFile, Paths.SettingsFile,
                     Paths.LogFile,
                 })
        {
            Assert.StartsWith(root, Path.GetFullPath(path));
        }
    }
}
