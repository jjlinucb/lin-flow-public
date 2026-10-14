namespace LinFlow.Core;

/// Append-only log at %APPDATA%\Lin Flow\app.log, same one-line-per-event shape as the Mac's.
/// Diagnosing a dictation that went wrong means reading this file, so every interesting decision
/// writes one line: what was heard, what was pasted, what was learned and what was refused.
public static class Log
{
    private static readonly object Gate = new();
    public static bool EchoToConsole { get; set; }

    public static void Info(string message)
    {
        var line = $"[lin-flow {DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}";
        if (EchoToConsole) Console.Error.WriteLine(line);
        try
        {
            lock (Gate)
            {
                Paths.EnsureDataDir();
                File.AppendAllText(Paths.LogFile, line + Environment.NewLine);
            }
        }
        catch
        {
            // A log that cannot be written must never take the app down with it.
        }
    }
}
