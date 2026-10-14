using LinFlow.Core;

namespace LinFlow.Engine;

public enum EngineKind { Parakeet, Whisper }

public sealed record ModelInfo(
    string Id, string FileName, string DownloadUrl, int SizeMB,
    bool Multilingual, string Note, EngineKind Engine);

/// The same model ids, file names and download URLs as ModelCatalog.swift, so a models folder
/// copied from the Mac is recognized here and vice versa.
public static class ModelCatalog
{
    private const string Hf = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";
    private const string Pk = "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/";

    public static readonly IReadOnlyList<ModelInfo> Known = new[]
    {
        new ModelInfo("parakeet-tdt-0.6b-v3-q8_0", "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
            Pk + "ggml-parakeet-tdt-0.6b-v3-q8_0.bin", 669, false,
            "Default. Top English accuracy and ~10x faster than Whisper turbo.", EngineKind.Parakeet),
        new ModelInfo("parakeet-tdt-0.6b-v3-q4_k", "ggml-parakeet-tdt-0.6b-v3-q4_k.bin",
            Pk + "ggml-parakeet-tdt-0.6b-v3-q4_k.bin", 416, false,
            "Smaller Parakeet; slightly less accurate.", EngineKind.Parakeet),
        new ModelInfo("large-v3-turbo-q5_0", "ggml-large-v3-turbo-q5_0.bin",
            Hf + "ggml-large-v3-turbo-q5_0.bin", 574, true,
            "Whisper's best speed/accuracy trade-off; use for Khmer and other languages.", EngineKind.Whisper),
        new ModelInfo("small.en-q8_0", "ggml-small.en-q8_0.bin",
            Hf + "ggml-small.en-q8_0.bin", 264, false,
            "Fast English-only fallback.", EngineKind.Whisper),
    };

    public const string DefaultModelId = "parakeet-tdt-0.6b-v3-q8_0";

    public static ModelInfo? Find(string id) => Known.FirstOrDefault(m => m.Id == id);

    public static string PathFor(ModelInfo m) => Path.Combine(Paths.ModelsDir, m.FileName);

    public static bool IsInstalled(ModelInfo m)
    {
        var p = PathFor(m);
        if (!File.Exists(p)) return false;
        // A download interrupted halfway leaves a file that exists and loads as garbage. Anything
        // far below the published size is a truncated download, not a model.
        var mb = new FileInfo(p).Length / (1024.0 * 1024.0);
        return mb > m.SizeMB * 0.9;
    }

    public static IEnumerable<ModelInfo> Installed() => Known.Where(IsInstalled);

    /// Installed AND openable by this build. The catalog keeps the Whisper entries so a models
    /// folder copied from the Mac is recognized, but only libparakeet is bound on Windows, so a
    /// Whisper file on disk is not something the tray app or the CLI can load. One predicate,
    /// shared by doctor, the CLI and the tray app so the three cannot drift: doctor used to
    /// count a Whisper file as a pass and exit 0 while the app sat at "no model".
    public static bool IsUsable(ModelInfo m) => m.Engine == EngineKind.Parakeet && IsInstalled(m);

    public static ModelInfo? FirstUsable() => Known.FirstOrDefault(IsUsable);

    /// Streams the model to a .part file and renames it only once the whole thing has arrived,
    /// so an interrupted download can never be mistaken for an installed model.
    public static async Task DownloadAsync(ModelInfo m, IProgress<double>? progress = null,
                                           CancellationToken ct = default)
    {
        Directory.CreateDirectory(Paths.ModelsDir);
        var target = PathFor(m);
        var part = target + ".part";

        using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        using var response = await http.GetAsync(m.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength ?? (long)m.SizeMB * 1024 * 1024;

        await using (var src = await response.Content.ReadAsStreamAsync(ct))
        await using (var dst = File.Create(part))
        {
            var buffer = new byte[1 << 20];
            long done = 0;
            int read;
            while ((read = await src.ReadAsync(buffer, ct)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, read), ct);
                done += read;
                progress?.Report(total > 0 ? (double)done / total : 0);
            }
        }
        File.Move(part, target, overwrite: true);
        Log.Info($"downloaded {m.FileName} ({new FileInfo(target).Length / (1024 * 1024)} MB)");
    }
}
