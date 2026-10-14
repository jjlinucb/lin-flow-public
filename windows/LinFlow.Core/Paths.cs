namespace LinFlow.Core;

/// Where Lin Flow keeps everything on Windows: %APPDATA%\Lin Flow\.
///
/// The file names and formats are deliberately identical to the Mac's
/// ~/Library/Application Support/Lin Flow/, so a dictionary or a history file copied from one
/// machine loads unchanged on the other. Settings are the one exception: the Mac uses
/// UserDefaults, which has no Windows equivalent, so they live in settings.json here with the
/// same keys.
public static class Paths
{
    /// Normally %APPDATA%\Lin Flow. `LINFLOW_DATA_DIR` moves everything Lin Flow owns somewhere
    /// else, which is how the test suite stays out of the folder the installed app is using: the
    /// tests exercise real production code, that code logs as it goes, and without this they
    /// append to the log John reads when a dictation has gone wrong. It is read once, at startup,
    /// so a running app cannot have the folder moved out from under it.
    public static string DataDir { get; } = ResolveDataDir();

    private static string ResolveDataDir()
    {
        var overridden = Environment.GetEnvironmentVariable("LINFLOW_DATA_DIR");
        if (!string.IsNullOrWhiteSpace(overridden)) return overridden;
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lin Flow");
    }

    public static string ModelsDir => Path.Combine(DataDir, "models");
    public static string RecordingsDir => Path.Combine(DataDir, "recordings");
    public static string NotesDir => Path.Combine(DataDir, "notes");

    public static string VocabFile => Path.Combine(DataDir, "vocab.txt");
    public static string ReplacementsFile => Path.Combine(DataDir, "replacements.txt");
    public static string HistoryFile => Path.Combine(DataDir, "history.jsonl");
    public static string SnippetsFile => Path.Combine(DataDir, "snippets.json");
    public static string TransformsFile => Path.Combine(DataDir, "transforms.json");
    public static string PendingCorrectionsFile => Path.Combine(DataDir, "pending-corrections.json");
    public static string SettingsFile => Path.Combine(DataDir, "settings.json");
    public static string LogFile => Path.Combine(DataDir, "app.log");
    /// Where the shared totals live and what this computer is called there. Written by
    /// scripts/setup-sync.sh, never by the app; absent means the totals stay on this PC.
    public static string SyncFile => Path.Combine(DataDir, "sync.env");
    public static string DictionaryStateFile => Path.Combine(DataDir, "dictionary-sync.json");

    public static void EnsureDataDir() => Directory.CreateDirectory(DataDir);

    /// Write a file so a crash mid-write cannot leave a truncated one: write a sibling temp
    /// file, flush it, then replace. The Mac gets this from `Data.write(options: .atomic)`.
    public static void WriteAtomic(string path, string contents)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, contents, new System.Text.UTF8Encoding(false));
        // File.Move over an existing file is atomic enough on NTFS; Replace needs the target to exist.
        File.Move(tmp, path, overwrite: true);
    }
}
