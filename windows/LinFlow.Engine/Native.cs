using System.Runtime.InteropServices;

namespace LinFlow.Engine;

/// P/Invoke into whisper.cpp v1.9.1's libparakeet and libggml, the same binaries the Mac links
/// through Homebrew. The DLLs come from the official `whisper-bin-x64.zip` release asset and sit
/// beside the exe; `scripts/fetch-native.ps1` puts them there.
///
/// The struct layouts below are transcribed from `include/parakeet.h` at the v1.9.1 tag, read from
/// the Homebrew install on John's Mac, which is byte-for-byte the same release. Two things matter
/// and are easy to get wrong:
///
///   1. C `bool` is ONE byte. C#'s `bool` marshals as a 4-byte Win32 BOOL by default, which would
///      silently shift every field after it. Every C bool here is declared as `byte`.
///   2. The params structs are returned BY VALUE from the library, so the layout has to be right
///      before the very first call. `ParakeetEngine.SelfCheck` reads the values back and refuses to
///      run if they are not sane, which turns a layout mistake into a clear message instead of a
///      crash or a garbage transcript.
internal static class Native
{
    private const string Parakeet = "parakeet";

    /// ggml-base is the compute core: ggml.c, ggml-alloc.c, ggml-backend.cpp, ggml-opt.cpp,
    /// ggml-threading.cpp, ggml-quants.c and gguf.cpp. The backend REGISTRY lives in
    /// ggml-backend-reg.cpp, which upstream compiles into ggml itself, so every ggml_backend_*
    /// entry point below is exported by ggml.dll and NOT by ggml-base.dll. Binding them to
    /// "ggml-base" throws EntryPointNotFoundException on the first call, and on Windows that
    /// first call is ensureBackendsLoaded() during startup, so the tray app dies before it can
    /// load a model. Verified against the shipped v1.9.1 DLLs with GetProcAddress.
    private const string Ggml = "ggml";

    // ggml ------------------------------------------------------------------------------------

    /// Homebrew's (and the Windows zip's) ggml loads its CPU/CUDA backends dynamically. Nothing
    /// works until this has run: model init finds zero devices and fails.
    [DllImport(Ggml, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void ggml_backend_load_all();

    [DllImport(Ggml, CallingConvention = CallingConvention.Cdecl)]
    internal static extern nuint ggml_backend_reg_count();

    [DllImport(Ggml, CallingConvention = CallingConvention.Cdecl)]
    internal static extern nuint ggml_backend_dev_count();

    // parakeet --------------------------------------------------------------------------------

    /// struct parakeet_context_params { bool use_gpu; int gpu_device; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ParakeetContextParams
    {
        internal byte use_gpu;
        internal int gpu_device;
    }

    internal enum ParakeetSamplingStrategy
    {
        Greedy = 0,
    }

    /// struct parakeet_full_params, parakeet.h v1.9.1. Five callback/user-data pairs follow the
    /// scalars; we never set them, but they must be present or the struct is the wrong size.
    [StructLayout(LayoutKind.Sequential)]
    internal struct ParakeetFullParams
    {
        internal int strategy;
        internal int n_threads;
        internal int offset_ms;
        internal int duration_ms;
        internal byte no_context;
        internal int audio_ctx;

        internal IntPtr new_segment_callback;
        internal IntPtr new_segment_callback_user_data;
        internal IntPtr new_token_callback;
        internal IntPtr new_token_callback_user_data;
        internal IntPtr progress_callback;
        internal IntPtr progress_callback_user_data;
        internal IntPtr encoder_begin_callback;
        internal IntPtr encoder_begin_callback_user_data;
        internal IntPtr abort_callback;
        internal IntPtr abort_callback_user_data;
    }

    [DllImport(Parakeet, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ParakeetContextParams parakeet_context_default_params();

    [DllImport(Parakeet, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ParakeetFullParams parakeet_full_default_params(ParakeetSamplingStrategy strategy);

    [DllImport(Parakeet, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi, BestFitMapping = false)]
    internal static extern IntPtr parakeet_init_from_file_with_params(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string pathModel, ParakeetContextParams parameters);

    [DllImport(Parakeet, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int parakeet_full(IntPtr ctx, ParakeetFullParams parameters, IntPtr samples, int nSamples);

    [DllImport(Parakeet, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int parakeet_full_n_segments(IntPtr ctx);

    [DllImport(Parakeet, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr parakeet_full_get_segment_text(IntPtr ctx, int iSegment);

    [DllImport(Parakeet, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void parakeet_free(IntPtr ctx);

    [DllImport(Parakeet, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr parakeet_version();

    /// A UTF-8 C string from the library, or "" when it handed back null.
    internal static string StringFrom(IntPtr p) =>
        p == IntPtr.Zero ? "" : (Marshal.PtrToStringUTF8(p) ?? "");
}
