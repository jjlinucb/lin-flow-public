using System.Runtime.InteropServices;
using LinFlow.Core;

namespace LinFlow.Engine;

public sealed record TranscriptionResult(
    string Text, List<string> Segments, double InferenceSeconds, double AudioSeconds);

/// NVIDIA Parakeet TDT 0.6B through whisper.cpp's libparakeet, the same engine and the same
/// decode settings as ParakeetEngine.swift.
///
/// Parakeet is a transducer rather than an encoder-decoder with a 30 s window, so there is no
/// prompt, no language switch and no temperature fallback - and it is roughly ten times faster
/// than Whisper turbo. It is the default on both platforms.
///
/// Whisper is deliberately NOT bound yet: whisper_full_params has 59 fields and two nested
/// structs, which is a lot of layout to get exactly right with no Windows machine to test on,
/// and getting it wrong is a silent garbage transcript rather than an error. Parakeet's params
/// struct is six scalars and ten pointers. English dictation - which is all John does - needs
/// only this one. See windows/NOTES.md.
public sealed class ParakeetEngine : IDisposable
{
    private IntPtr _ctx;
    private readonly object _gate = new();

    public string ModelPath { get; }
    public double LoadSeconds { get; }

    private static bool _backendsLoaded;
    private static readonly object BackendGate = new();

    /// ggml loads its CPU/CUDA backends dynamically. Nothing works until this has run: model
    /// init finds zero devices and fails. Same rule as the Mac.
    public static void EnsureBackendsLoaded()
    {
        lock (BackendGate)
        {
            if (_backendsLoaded) return;
            Native.ggml_backend_load_all();
            _backendsLoaded = true;
            Log.Info($"ggml backends loaded: {Native.ggml_backend_reg_count()} registries, " +
                     $"{Native.ggml_backend_dev_count()} devices");
        }
    }

    /// Reads back the params structs the library hands us and checks they are sane.
    ///
    /// This exists because the struct layouts in Native.cs were transcribed by hand from
    /// parakeet.h and never executed on Windows before shipping. If a field is misaligned, the
    /// values come back as garbage; catching that here turns a confusing crash or a nonsense
    /// transcript into one clear sentence. `linflow doctor` runs it before anything else.
    public static string SelfCheck()
    {
        EnsureBackendsLoaded();
        var cp = Native.parakeet_context_default_params();
        var fp = Native.parakeet_full_default_params(Native.ParakeetSamplingStrategy.Greedy);
        var problems = new List<string>();
        if (cp.use_gpu > 1) problems.Add($"context_params.use_gpu = {cp.use_gpu} (expected 0 or 1)");
        if (fp.strategy is < 0 or > 1) problems.Add($"full_params.strategy = {fp.strategy} (expected 0)");
        if (fp.n_threads is < 1 or > 1024) problems.Add($"full_params.n_threads = {fp.n_threads} (expected 1..1024)");
        if (fp.no_context > 1) problems.Add($"full_params.no_context = {fp.no_context} (expected 0 or 1)");
        if (fp.offset_ms != 0) problems.Add($"full_params.offset_ms = {fp.offset_ms} (expected 0)");
        return problems.Count == 0
            ? $"native structs look right (n_threads default {fp.n_threads}, parakeet {Native.StringFrom(Native.parakeet_version())})"
            : "NATIVE STRUCT LAYOUT MISMATCH:\n  " + string.Join("\n  ", problems);
    }

    public ParakeetEngine(string modelPath, bool useGpu = true)
    {
        EnsureBackendsLoaded();
        var cparams = Native.parakeet_context_default_params();
        cparams.use_gpu = (byte)(useGpu ? 1 : 0);

        var t0 = DateTime.UtcNow;
        _ctx = Native.parakeet_init_from_file_with_params(modelPath, cparams);
        if (_ctx == IntPtr.Zero)
            throw new InvalidOperationException($"could not load the model at {modelPath}");

        ModelPath = modelPath;
        LoadSeconds = (DateTime.UtcNow - t0).TotalSeconds;
        Log.Info($"loaded {Path.GetFileName(modelPath)} in {LoadSeconds:F2}s (parakeet)");
    }

    private int _warming;

    /// Runs a second of silence through the model on its own thread and throws the text away.
    ///
    /// Windows trims the memory of a process that sits idle, and on a machine short of it the
    /// model goes out to the page file. The next dictation then paid to bring it back before it
    /// could start: 2.94 s for 2.4 s of speech on 09-22 after 26 minutes idle, where 0.2 s is
    /// normal, and 0.59 s for 2.7 s on 09-23 after 9 minutes. The key going down is the moment
    /// to pay that, because the model then has the whole time he is talking to come back in.
    ///
    /// Transcribe takes the same lock, so a take that ends first waits for the warm-up rather
    /// than running beside it, and the paging it waits on is paging it would have done itself.
    /// A second press while one warm-up is still running does not start another.
    ///
    /// The Mac warms once, at load, for its Metal pipelines (DictationController.load). This is
    /// a different cost, and it comes back after every idle stretch, so it runs at every press.
    public void WarmInBackground()
    {
        if (Interlocked.Exchange(ref _warming, 1) == 1) return;
        new Thread(() =>
        {
            try
            {
                lock (_gate)
                {
                    if (_ctx != IntPtr.Zero) Run(new float[AudioIO.SampleRate], DefaultThreads);
                }
            }
            catch (Exception e)
            {
                Log.Info($"warm-up failed: {e.Message}");
            }
            finally
            {
                Volatile.Write(ref _warming, 0);
            }
        })
        { IsBackground = true, Name = "linflow-warm" }.Start();
    }

    /// Half the logical processors, between 4 and 8. This was the Mac's 4, ported unchanged and
    /// never measured here, and the Mac runs the model on its GPU through Metal. On the laptop's
    /// Core Ultra 7 255H (16 cores, no hyper-threading), 2026-09-23, `bench` medians over two
    /// interleaved rounds, from a hidden process like the tray app:
    ///
    ///     threads      4       6       8      10
    ///     2.5 s     0.195   0.148   0.130   0.118
    ///     7.6 s     0.68    0.54    0.43    0.43
    ///     22.9 s    1.87    1.69    1.54    1.39
    ///
    /// 12 was slower than 8 in the first pass. Half leaves the other half free for the recording
    /// that a warm-up runs beside, and on a hyper-threaded CPU it is one thread per core.
    public static int DefaultThreads { get; } = Math.Clamp(Environment.ProcessorCount / 2, 4, 8);

    /// `threads` 0 means DefaultThreads.
    public TranscriptionResult Transcribe(float[] samples, int threads = 0)
    {
        if (threads <= 0) threads = DefaultThreads;
        lock (_gate)
        {
            // libparakeet 1.9.1 drops whole sentences after a pause once a clip passes about
            // 60 s, so long audio is decoded in pieces cut at quiet points and joined in order.
            var pieces = AudioIO.SplitLong(samples, limitSeconds: 45, searchFromSeconds: 30);
            if (pieces.Count <= 1) return Run(samples, threads);

            var texts = new List<string>();
            var segments = new List<string>();
            var seconds = 0.0;
            foreach (var piece in pieces)
            {
                if (AudioIO.Peak(piece) <= 0.002f) continue;   // a silent tail teaches nothing
                var r = Run(piece, threads);
                if (r.Text.Length > 0) texts.Add(r.Text);
                segments.AddRange(r.Segments);
                seconds += r.InferenceSeconds;
            }
            return new TranscriptionResult(string.Join(" ", texts), segments, seconds,
                                           (double)samples.Length / AudioIO.SampleRate);
        }
    }

    private TranscriptionResult Run(float[] input, int threads)
    {
        if (_ctx == IntPtr.Zero) throw new ObjectDisposedException(nameof(ParakeetEngine));

        // Anything under a second is padded: the model wants a minimum window.
        var samples = input;
        var min = AudioIO.SampleRate;
        if (samples.Length < min)
        {
            var padded = new float[min];
            Array.Copy(samples, padded, samples.Length);
            samples = padded;
        }

        var p = Native.parakeet_full_default_params(Native.ParakeetSamplingStrategy.Greedy);
        p.n_threads = Math.Clamp(threads, 1, Environment.ProcessorCount);
        p.no_context = 1;

        var t0 = DateTime.UtcNow;
        int rc;
        var handle = GCHandle.Alloc(samples, GCHandleType.Pinned);
        try
        {
            rc = Native.parakeet_full(_ctx, p, handle.AddrOfPinnedObject(), samples.Length);
        }
        finally
        {
            handle.Free();
        }
        var dt = (DateTime.UtcNow - t0).TotalSeconds;
        if (rc != 0) throw new InvalidOperationException($"parakeet_full failed ({rc})");

        var segments = new List<string>();
        var n = Native.parakeet_full_n_segments(_ctx);
        for (var i = 0; i < n; i++)
        {
            var s = Native.StringFrom(Native.parakeet_full_get_segment_text(_ctx, i)).Trim();
            if (s.Length > 0) segments.Add(s);
        }
        return new TranscriptionResult(string.Join(" ", segments), segments, dt,
                                       (double)input.Length / AudioIO.SampleRate);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_ctx == IntPtr.Zero) return;
            Native.parakeet_free(_ctx);
            _ctx = IntPtr.Zero;
        }
    }
}
