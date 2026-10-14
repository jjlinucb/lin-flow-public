//! whisper.cpp v1.9.1's libwhisper, libparakeet and libggml, loaded at run time.
//!
//! The same binaries everywhere: Homebrew's on the Mac, the official `whisper-bin-x64.zip` release
//! on Windows. Loading them at run time rather than linking means the app starts, and says what is
//! missing, on a computer without them, and the build needs no import libraries.
//!
//! The struct layouts are transcribed from the v1.9.1 headers. The params structs are passed and
//! returned by value, so a layout mistake shifts every field after it. Two guards: the test below
//! holds every field offset as `layout/layout.c` printed it from the real headers, and `check`
//! reads the libraries' own defaults back at load and refuses to run if they are not the values
//! v1.9.1 sets.

#![allow(non_camel_case_types)]

use libloading::Library;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct whisper_ahead {
    pub n_text_layer: c_int,
    pub n_head: c_int,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct whisper_aheads {
    pub n_heads: usize,
    pub heads: *const whisper_ahead,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct whisper_context_params {
    pub use_gpu: bool,
    pub flash_attn: bool,
    pub gpu_device: c_int,
    pub dtw_token_timestamps: bool,
    pub dtw_aheads_preset: c_int,
    pub dtw_n_top: c_int,
    pub dtw_aheads: whisper_aheads,
    pub dtw_mem_size: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct whisper_vad_params {
    pub threshold: f32,
    pub min_speech_duration_ms: c_int,
    pub min_silence_duration_ms: c_int,
    pub max_speech_duration_s: f32,
    pub speech_pad_ms: c_int,
    pub samples_overlap: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct whisper_greedy {
    pub best_of: c_int,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct whisper_beam_search {
    pub beam_size: c_int,
    pub patience: f32,
}

pub const WHISPER_SAMPLING_GREEDY: c_int = 0;
pub const WHISPER_SAMPLING_BEAM_SEARCH: c_int = 1;
pub const PARAKEET_SAMPLING_GREEDY: c_int = 0;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct whisper_full_params {
    pub strategy: c_int,
    pub n_threads: c_int,
    pub n_max_text_ctx: c_int,
    pub offset_ms: c_int,
    pub duration_ms: c_int,
    pub translate: bool,
    pub no_context: bool,
    pub no_timestamps: bool,
    pub single_segment: bool,
    pub print_special: bool,
    pub print_progress: bool,
    pub print_realtime: bool,
    pub print_timestamps: bool,
    pub token_timestamps: bool,
    pub thold_pt: f32,
    pub thold_ptsum: f32,
    pub max_len: c_int,
    pub split_on_word: bool,
    pub max_tokens: c_int,
    pub debug_mode: bool,
    pub audio_ctx: c_int,
    pub tdrz_enable: bool,
    pub suppress_regex: *const c_char,
    pub initial_prompt: *const c_char,
    pub carry_initial_prompt: bool,
    pub prompt_tokens: *const i32,
    pub prompt_n_tokens: c_int,
    pub language: *const c_char,
    pub detect_language: bool,
    pub suppress_blank: bool,
    pub suppress_nst: bool,
    pub temperature: f32,
    pub max_initial_ts: f32,
    pub length_penalty: f32,
    pub temperature_inc: f32,
    pub entropy_thold: f32,
    pub logprob_thold: f32,
    pub no_speech_thold: f32,
    pub greedy: whisper_greedy,
    pub beam_search: whisper_beam_search,
    pub new_segment_callback: *mut c_void,
    pub new_segment_callback_user_data: *mut c_void,
    pub progress_callback: *mut c_void,
    pub progress_callback_user_data: *mut c_void,
    pub encoder_begin_callback: *mut c_void,
    pub encoder_begin_callback_user_data: *mut c_void,
    pub abort_callback: *mut c_void,
    pub abort_callback_user_data: *mut c_void,
    pub logits_filter_callback: *mut c_void,
    pub logits_filter_callback_user_data: *mut c_void,
    pub grammar_rules: *const *const c_void,
    pub n_grammar_rules: usize,
    pub i_start_rule: usize,
    pub grammar_penalty: f32,
    pub vad: bool,
    pub vad_model_path: *const c_char,
    pub vad_params: whisper_vad_params,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct parakeet_context_params {
    pub use_gpu: bool,
    pub gpu_device: c_int,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct parakeet_full_params {
    pub strategy: c_int,
    pub n_threads: c_int,
    pub offset_ms: c_int,
    pub duration_ms: c_int,
    pub no_context: bool,
    pub audio_ctx: c_int,
    pub new_segment_callback: *mut c_void,
    pub new_segment_callback_user_data: *mut c_void,
    pub new_token_callback: *mut c_void,
    pub new_token_callback_user_data: *mut c_void,
    pub progress_callback: *mut c_void,
    pub progress_callback_user_data: *mut c_void,
    pub encoder_begin_callback: *mut c_void,
    pub encoder_begin_callback_user_data: *mut c_void,
    pub abort_callback: *mut c_void,
    pub abort_callback_user_data: *mut c_void,
}

pub type LogCallback = unsafe extern "C" fn(level: c_int, text: *const c_char, user: *mut c_void);

/// Every entry point the engines use, resolved once.
pub struct Api {
    pub whisper_context_default_params: unsafe extern "C" fn() -> whisper_context_params,
    pub whisper_init_from_file_with_params: unsafe extern "C" fn(*const c_char, whisper_context_params) -> *mut c_void,
    pub whisper_free: unsafe extern "C" fn(*mut c_void),
    pub whisper_full_default_params: unsafe extern "C" fn(c_int) -> whisper_full_params,
    pub whisper_full: unsafe extern "C" fn(*mut c_void, whisper_full_params, *const f32, c_int) -> c_int,
    pub whisper_full_n_segments: unsafe extern "C" fn(*mut c_void) -> c_int,
    pub whisper_full_get_segment_text: unsafe extern "C" fn(*mut c_void, c_int) -> *const c_char,
    pub whisper_full_lang_id: unsafe extern "C" fn(*mut c_void) -> c_int,
    pub whisper_lang_id: unsafe extern "C" fn(*const c_char) -> c_int,
    pub whisper_lang_str: unsafe extern "C" fn(c_int) -> *const c_char,
    pub whisper_is_multilingual: unsafe extern "C" fn(*mut c_void) -> c_int,
    pub whisper_vad_default_params: unsafe extern "C" fn() -> whisper_vad_params,
    pub whisper_version: unsafe extern "C" fn() -> *const c_char,
    pub parakeet_context_default_params: unsafe extern "C" fn() -> parakeet_context_params,
    pub parakeet_init_from_file_with_params: unsafe extern "C" fn(*const c_char, parakeet_context_params) -> *mut c_void,
    pub parakeet_free: unsafe extern "C" fn(*mut c_void),
    pub parakeet_full_default_params: unsafe extern "C" fn(c_int) -> parakeet_full_params,
    pub parakeet_full: unsafe extern "C" fn(*mut c_void, parakeet_full_params, *const f32, c_int) -> c_int,
    pub parakeet_full_n_segments: unsafe extern "C" fn(*mut c_void) -> c_int,
    pub parakeet_full_get_segment_text: unsafe extern "C" fn(*mut c_void, c_int) -> *const c_char,
    pub parakeet_version: unsafe extern "C" fn() -> *const c_char,
    pub ggml_backend_dev_count: unsafe extern "C" fn() -> usize,
    pub ggml_backend_reg_count: unsafe extern "C" fn() -> usize,
    /// The folder the libraries came from.
    pub dir: PathBuf,
    _libs: Vec<Library>,
}

// The function pointers are plain code addresses, valid for the process's life since the
// libraries are never unloaded.
unsafe impl Send for Api {}
unsafe impl Sync for Api {}

#[cfg(target_os = "windows")]
const NAMES: [(&str, &[&str]); 4] = [("ggml-base", &["ggml-base.dll"]), ("ggml", &["ggml.dll"]), ("whisper", &["whisper.dll"]), ("parakeet", &["parakeet.dll"])];
#[cfg(target_os = "macos")]
const NAMES: [(&str, &[&str]); 4] = [
    ("ggml-base", &["libggml-base.0.dylib", "libggml-base.dylib"]),
    ("ggml", &["libggml.0.dylib", "libggml.dylib"]),
    ("whisper", &["libwhisper.1.dylib", "libwhisper.dylib"]),
    ("parakeet", &["libparakeet.1.dylib", "libparakeet.dylib"]),
];
#[cfg(not(any(target_os = "windows", target_os = "macos")))]
const NAMES: [(&str, &[&str]); 4] = [
    ("ggml-base", &["libggml-base.so.0", "libggml-base.so"]),
    ("ggml", &["libggml.so.0", "libggml.so"]),
    ("whisper", &["libwhisper.so.1", "libwhisper.so"]),
    ("parakeet", &["libparakeet.so.1", "libparakeet.so"]),
];

/// Where the libraries are looked for, in order: `LINFLOW_NATIVE_DIR`, beside the executable (and
/// in the Mac bundle's Frameworks), then Homebrew.
pub fn search_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![];
    if let Some(d) = std::env::var_os("LINFLOW_NATIVE_DIR") {
        dirs.push(PathBuf::from(d));
    }
    if let Some(exe_dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf)) {
        dirs.push(exe_dir.join("native"));
        dirs.push(exe_dir.join("../Frameworks"));
        dirs.push(exe_dir);
    }
    if cfg!(target_os = "macos") {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            dirs.push(PathBuf::from(format!("{prefix}/opt/whisper-cpp/lib")));
            dirs.push(PathBuf::from(format!("{prefix}/opt/ggml/lib")));
        }
    }
    dirs
}

fn open(path: &Path) -> Result<Library, libloading::Error> {
    #[cfg(windows)]
    {
        // Resolve the library's own dependencies (ggml-base.dll, the CPU backends) from its
        // folder rather than only the executable's.
        const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x0000_0008;
        unsafe { libloading::os::windows::Library::load_with_flags(path, LOAD_WITH_ALTERED_SEARCH_PATH).map(Library::from) }
    }
    #[cfg(not(windows))]
    unsafe {
        Library::new(path)
    }
}

fn find(files: &[&str], dirs: &[PathBuf]) -> Option<PathBuf> {
    dirs.iter().flat_map(|d| files.iter().map(move |f| d.join(f))).find(|p| p.exists())
}

macro_rules! sym {
    ($lib:expr, $name:literal) => {
        *unsafe { $lib.get(concat!($name, "\0").as_bytes()) }.map_err(|e| format!("{} is missing from the speech library: {e}", $name))?
    };
}

unsafe extern "C" fn log_to_rust(level: c_int, text: *const c_char, _user: *mut c_void) {
    if text.is_null() {
        return;
    }
    let s = unsafe { CStr::from_ptr(text) }.to_string_lossy();
    let s = s.trim();
    if s.is_empty() {
        return;
    }
    match level {
        4 => log::error!(target: "engine", "{s}"),
        3 => log::warn!(target: "engine", "{s}"),
        _ => log::debug!(target: "engine", "{s}"),
    }
}

fn load_api() -> Result<Api, String> {
    let dirs = search_dirs();
    let mut libs = vec![];
    let mut found = vec![];
    for (name, files) in NAMES {
        let path = find(files, &dirs).ok_or_else(|| {
            format!(
                "The speech library {name} is not installed (looked for {} in {}). On the Mac: brew install whisper-cpp. On Windows: put the whisper.cpp v1.9.1 DLLs beside linflow.exe.",
                files[0],
                dirs.iter().map(|d| d.display().to_string()).collect::<Vec<_>>().join(", ")
            )
        })?;
        let lib = open(&path).map_err(|e| format!("could not load {}: {e}", path.display()))?;
        found.push(path);
        libs.push(lib);
    }
    let (ggml_base, ggml, whisper, parakeet) = (&libs[0], &libs[1], &libs[2], &libs[3]);
    let api = Api {
        whisper_context_default_params: sym!(whisper, "whisper_context_default_params"),
        whisper_init_from_file_with_params: sym!(whisper, "whisper_init_from_file_with_params"),
        whisper_free: sym!(whisper, "whisper_free"),
        whisper_full_default_params: sym!(whisper, "whisper_full_default_params"),
        whisper_full: sym!(whisper, "whisper_full"),
        whisper_full_n_segments: sym!(whisper, "whisper_full_n_segments"),
        whisper_full_get_segment_text: sym!(whisper, "whisper_full_get_segment_text"),
        whisper_full_lang_id: sym!(whisper, "whisper_full_lang_id"),
        whisper_lang_id: sym!(whisper, "whisper_lang_id"),
        whisper_lang_str: sym!(whisper, "whisper_lang_str"),
        whisper_is_multilingual: sym!(whisper, "whisper_is_multilingual"),
        whisper_vad_default_params: sym!(whisper, "whisper_vad_default_params"),
        whisper_version: sym!(whisper, "whisper_version"),
        parakeet_context_default_params: sym!(parakeet, "parakeet_context_default_params"),
        parakeet_init_from_file_with_params: sym!(parakeet, "parakeet_init_from_file_with_params"),
        parakeet_free: sym!(parakeet, "parakeet_free"),
        parakeet_full_default_params: sym!(parakeet, "parakeet_full_default_params"),
        parakeet_full: sym!(parakeet, "parakeet_full"),
        parakeet_full_n_segments: sym!(parakeet, "parakeet_full_n_segments"),
        parakeet_full_get_segment_text: sym!(parakeet, "parakeet_full_get_segment_text"),
        parakeet_version: sym!(parakeet, "parakeet_version"),
        ggml_backend_dev_count: sym!(ggml, "ggml_backend_dev_count"),
        ggml_backend_reg_count: sym!(ggml, "ggml_backend_reg_count"),
        dir: found[2].parent().map(Path::to_path_buf).unwrap_or_default(),
        _libs: vec![],
    };
    type LogSet = unsafe extern "C" fn(Option<LogCallback>, *mut c_void);
    let whisper_log_set: LogSet = sym!(whisper, "whisper_log_set");
    let parakeet_log_set: LogSet = sym!(parakeet, "parakeet_log_set");
    let ggml_log_set: Option<LogSet> = unsafe { ggml_base.get::<LogSet>(b"ggml_log_set\0") }.ok().map(|s| *s);
    unsafe {
        whisper_log_set(Some(log_to_rust), std::ptr::null_mut());
        parakeet_log_set(Some(log_to_rust), std::ptr::null_mut());
        if let Some(set) = ggml_log_set {
            set(Some(log_to_rust), std::ptr::null_mut());
        }
    }
    // ggml loads its compute backends (Metal, the CPU variants) as separate libraries, and
    // libwhisper does not do it itself: without this there are zero devices. A folder of our own
    // that carries the backends is searched; otherwise ggml's built-in places are.
    let ggml_dir = found[1].parent().map(Path::to_path_buf).unwrap_or_default();
    let has_backends = std::fs::read_dir(&ggml_dir).map(|d| d.flatten().any(|e| e.file_name().to_string_lossy().contains("ggml-cpu"))).unwrap_or(false);
    if has_backends {
        let load_from: unsafe extern "C" fn(*const c_char) = sym!(ggml, "ggml_backend_load_all_from_path");
        let c = CString::new(ggml_dir.to_string_lossy().as_bytes()).map_err(|e| e.to_string())?;
        unsafe { load_from(c.as_ptr()) };
    } else {
        let load_all: unsafe extern "C" fn() = sym!(ggml, "ggml_backend_load_all");
        unsafe { load_all() };
    }
    check(&api)?;
    let mut api = api;
    api._libs = libs;
    log::info!(target: "engine", "speech libraries from {}: whisper.cpp {}, {} backend registries, {} devices", api.dir.display(), version(&api), unsafe { (api.ggml_backend_reg_count)() }, unsafe { (api.ggml_backend_dev_count)() });
    Ok(api)
}

pub fn version(api: &Api) -> String {
    unsafe { CStr::from_ptr((api.whisper_version)()) }.to_string_lossy().into_owned()
}

/// The libraries' own defaults read back through our struct layouts. A wrong layout reads
/// garbage at the shifted fields, so this turns it into a clear message instead of a crash or a
/// garbled transcript.
pub fn check(api: &Api) -> Result<(), String> {
    let (g, b, c, p, pc) = unsafe {
        (
            (api.whisper_full_default_params)(WHISPER_SAMPLING_GREEDY),
            (api.whisper_full_default_params)(WHISPER_SAMPLING_BEAM_SEARCH),
            (api.whisper_context_default_params)(),
            (api.parakeet_full_default_params)(PARAKEET_SAMPLING_GREEDY),
            (api.parakeet_context_default_params)(),
        )
    };
    let lang = if g.language.is_null() { String::new() } else { unsafe { CStr::from_ptr(g.language) }.to_string_lossy().into_owned() };
    let ok = g.strategy == 0
        && b.strategy == 1
        && g.n_max_text_ctx == 16384
        && (g.temperature_inc - 0.2).abs() < 1e-6
        && (g.entropy_thold - 2.4).abs() < 1e-6
        && (g.logprob_thold + 1.0).abs() < 1e-6
        && g.greedy.best_of == 5
        && b.beam_search.beam_size == 5
        && (g.grammar_penalty - 100.0).abs() < 1e-6
        && (g.vad_params.threshold - 0.5).abs() < 1e-6
        && (g.vad_params.samples_overlap - 0.1).abs() < 1e-6
        && lang == "en"
        && c.dtw_n_top == -1
        && c.dtw_mem_size == 128 * 1024 * 1024
        && p.strategy == 0
        && p.no_context
        && p.audio_ctx == 0
        && p.abort_callback.is_null()
        && pc.gpu_device == 0;
    if ok {
        Ok(())
    } else {
        Err(format!(
            "The speech library at {} is not the version Lin Flow was built for (whisper.cpp {}): its settings read back wrong, so it will not be used.",
            api.dir.display(),
            version(api)
        ))
    }
}

static API: OnceLock<Result<Api, String>> = OnceLock::new();

/// The loaded libraries, or why they could not be loaded. Loaded once per process.
pub fn api() -> Result<&'static Api, String> {
    API.get_or_init(load_api).as_ref().map_err(Clone::clone)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{offset_of, size_of};

    /// The offsets `layout/layout.c` printed from the v1.9.1 headers, for 64-bit targets.
    #[test]
    #[cfg(target_pointer_width = "64")]
    fn layouts_match_the_headers() {
        assert_eq!(size_of::<whisper_context_params>(), 48);
        assert_eq!(
            [offset_of!(whisper_context_params, flash_attn), offset_of!(whisper_context_params, gpu_device), offset_of!(whisper_context_params, dtw_token_timestamps),
             offset_of!(whisper_context_params, dtw_aheads_preset), offset_of!(whisper_context_params, dtw_n_top), offset_of!(whisper_context_params, dtw_aheads),
             offset_of!(whisper_context_params, dtw_mem_size)],
            [1, 4, 8, 12, 16, 24, 40]
        );
        assert_eq!(size_of::<whisper_vad_params>(), 24);
        assert_eq!(size_of::<whisper_full_params>(), 304);
        let f = [
            offset_of!(whisper_full_params, n_threads), offset_of!(whisper_full_params, n_max_text_ctx), offset_of!(whisper_full_params, offset_ms),
            offset_of!(whisper_full_params, duration_ms), offset_of!(whisper_full_params, translate), offset_of!(whisper_full_params, no_context),
            offset_of!(whisper_full_params, no_timestamps), offset_of!(whisper_full_params, single_segment), offset_of!(whisper_full_params, print_special),
            offset_of!(whisper_full_params, print_progress), offset_of!(whisper_full_params, print_realtime), offset_of!(whisper_full_params, print_timestamps),
            offset_of!(whisper_full_params, token_timestamps), offset_of!(whisper_full_params, thold_pt), offset_of!(whisper_full_params, thold_ptsum),
            offset_of!(whisper_full_params, max_len), offset_of!(whisper_full_params, split_on_word), offset_of!(whisper_full_params, max_tokens),
            offset_of!(whisper_full_params, debug_mode), offset_of!(whisper_full_params, audio_ctx), offset_of!(whisper_full_params, tdrz_enable),
            offset_of!(whisper_full_params, suppress_regex), offset_of!(whisper_full_params, initial_prompt), offset_of!(whisper_full_params, carry_initial_prompt),
            offset_of!(whisper_full_params, prompt_tokens), offset_of!(whisper_full_params, prompt_n_tokens), offset_of!(whisper_full_params, language),
            offset_of!(whisper_full_params, detect_language), offset_of!(whisper_full_params, suppress_blank), offset_of!(whisper_full_params, suppress_nst),
            offset_of!(whisper_full_params, temperature), offset_of!(whisper_full_params, max_initial_ts), offset_of!(whisper_full_params, length_penalty),
            offset_of!(whisper_full_params, temperature_inc), offset_of!(whisper_full_params, entropy_thold), offset_of!(whisper_full_params, logprob_thold),
            offset_of!(whisper_full_params, no_speech_thold), offset_of!(whisper_full_params, greedy), offset_of!(whisper_full_params, beam_search),
            offset_of!(whisper_full_params, new_segment_callback), offset_of!(whisper_full_params, new_segment_callback_user_data),
            offset_of!(whisper_full_params, progress_callback), offset_of!(whisper_full_params, progress_callback_user_data),
            offset_of!(whisper_full_params, encoder_begin_callback), offset_of!(whisper_full_params, encoder_begin_callback_user_data),
            offset_of!(whisper_full_params, abort_callback), offset_of!(whisper_full_params, abort_callback_user_data),
            offset_of!(whisper_full_params, logits_filter_callback), offset_of!(whisper_full_params, logits_filter_callback_user_data),
            offset_of!(whisper_full_params, grammar_rules), offset_of!(whisper_full_params, n_grammar_rules), offset_of!(whisper_full_params, i_start_rule),
            offset_of!(whisper_full_params, grammar_penalty), offset_of!(whisper_full_params, vad), offset_of!(whisper_full_params, vad_model_path),
            offset_of!(whisper_full_params, vad_params),
        ];
        assert_eq!(
            f,
            [4, 8, 12, 16, 20, 21, 22, 23, 24, 25, 26, 27, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64, 72, 80, 88, 96, 104, 112, 113, 114, 116, 120, 124, 128, 132,
             136, 140, 144, 148, 160, 168, 176, 184, 192, 200, 208, 216, 224, 232, 240, 248, 256, 264, 268, 272, 280]
        );
        assert_eq!(size_of::<parakeet_context_params>(), 8);
        assert_eq!(size_of::<parakeet_full_params>(), 104);
        assert_eq!(
            [offset_of!(parakeet_full_params, no_context), offset_of!(parakeet_full_params, audio_ctx), offset_of!(parakeet_full_params, new_segment_callback),
             offset_of!(parakeet_full_params, abort_callback), offset_of!(parakeet_full_params, abort_callback_user_data)],
            [16, 20, 24, 88, 96]
        );
    }
}
