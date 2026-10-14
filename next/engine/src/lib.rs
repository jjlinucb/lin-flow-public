//! Speech to text: OpenAI's Whisper and NVIDIA's Parakeet through whisper.cpp, the same libraries
//! and the same decoding settings as the Swift app. README.md has the reasoning behind each
//! default; read it before changing one.

pub mod ffi;

use ffi::{api, Api};
use linflow_core::audio::{peak, split_long, SAMPLE_RATE_F};
use std::ffi::{c_void, CStr, CString};
use std::path::{Path, PathBuf};
use std::time::Instant;

pub use linflow_core::models::EngineKind;

fn display_name(kind: EngineKind) -> &'static str {
    match kind {
        EngineKind::Whisper => "Whisper",
        EngineKind::Parakeet => "Parakeet",
    }
}

/// Decoding knobs for one dictation. Defaults are tuned for short push-to-talk clips of one
/// speaker, not for subtitling long files.
#[derive(Clone, Debug)]
pub struct Options {
    /// A two-letter code, or "auto" to let the model detect it. Parakeet ignores it.
    pub language: String,
    /// 1 is greedy (fastest), 5 is beam search (more accurate, a little slower).
    pub beam_size: i32,
    /// Silero VAD model. When set, Whisper drops silent stretches before decoding, which is both
    /// faster and the main defense against "Thank you." on near-empty audio.
    pub vad_model: Option<PathBuf>,
    /// The glossary the decoder is primed with, so Whisper spells those names the way the prompt
    /// does ("Lin Flow", not "Lend Flow").
    pub initial_prompt: Option<String>,
    pub threads: i32,
    /// Retry at higher temperatures when the decoder looks stuck. Costs time only when it fires.
    pub temperature_fallback: bool,
}

impl Default for Options {
    fn default() -> Self {
        let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
        Options { language: "en".into(), beam_size: 5, vad_model: None, initial_prompt: None, threads: cores.clamp(1, 8) as i32, temperature_fallback: true }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Transcription {
    pub text: String,
    pub segments: Vec<String>,
    pub detected_language: Option<String>,
    pub inference_seconds: f64,
    pub audio_seconds: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum EngineError {
    /// The libraries are missing or the wrong version: the sentence says what to do.
    Unavailable(String),
    LoadFailed(String),
    InferenceFailed(i32),
    UnknownLanguage(String),
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::Unavailable(why) => write!(f, "{why}"),
            EngineError::LoadFailed(p) => write!(f, "Could not load the speech model at {p}"),
            EngineError::InferenceFailed(rc) => write!(f, "The speech model failed (rc={rc})"),
            EngineError::UnknownLanguage(l) => write!(f, "Unknown language code '{l}'. Use a two-letter code such as en, km or zh, or auto."),
        }
    }
}

impl std::error::Error for EngineError {}

/// One loaded speech model. Not safe to use from two threads at once, so it takes `&mut self`;
/// it can move between threads.
pub trait Engine: Send {
    fn kind(&self) -> EngineKind;
    fn model_path(&self) -> &Path;
    fn is_multilingual(&self) -> bool;
    fn load_seconds(&self) -> f64;
    /// 16 kHz mono float samples in.
    fn transcribe(&mut self, samples: &[f32], options: &Options) -> Result<Transcription, EngineError>;

    fn model_id(&self) -> String {
        linflow_core::models::id_from_path(self.model_path())
    }

    fn display_name(&self) -> String {
        format!("{} · {}", display_name(self.kind()), self.model_id())
    }
}

/// Loads the model at `path` with the engine its file name calls for.
pub fn load(path: &Path) -> Result<Box<dyn Engine>, EngineError> {
    match linflow_core::models::kind_of(path) {
        EngineKind::Whisper => Ok(Box::new(WhisperEngine::load(path)?)),
        EngineKind::Parakeet => Ok(Box::new(ParakeetEngine::load(path)?)),
    }
}

/// The libraries' version, or why they will not load.
pub fn library_version() -> Result<String, String> {
    api().map(ffi::version)
}

/// Decodes audio past `limit_seconds` in pieces cut at its quietest points and joins the text
/// back in order, skipping pieces that are digital silence. Both engines lose words on long clips,
/// each in its own way. A 298 s clip came back as 963 words from Whisper turbo and 968 from
/// Parakeet this way.
pub fn decode_in_pieces(
    samples: &[f32],
    limit_seconds: f64,
    search_from_seconds: f64,
    decode: &mut dyn FnMut(&[f32]) -> Result<Transcription, EngineError>,
) -> Result<Transcription, EngineError> {
    let pieces = split_long(samples, limit_seconds, search_from_seconds);
    if pieces.len() <= 1 {
        return decode(samples);
    }
    let mut out = Transcription { audio_seconds: samples.len() as f64 / SAMPLE_RATE_F, ..Default::default() };
    let mut texts = vec![];
    for piece in pieces.iter().filter(|p| peak(p) > 0.002) {
        let r = decode(piece)?;
        if !r.text.is_empty() {
            texts.push(r.text);
        }
        out.segments.extend(r.segments);
        out.inference_seconds += r.inference_seconds;
        out.detected_language = out.detected_language.or(r.detected_language);
    }
    out.text = texts.join(" ");
    Ok(out)
}

fn segment_texts(n: i32, get: impl Fn(i32) -> *const std::ffi::c_char) -> Vec<String> {
    (0..n)
        .filter_map(|i| {
            let p = get(i);
            if p.is_null() {
                return None;
            }
            let s = unsafe { CStr::from_ptr(p) }.to_string_lossy();
            let s = linflow_core::text::unicode::trim_ws_nl(&s).to_string();
            (!s.is_empty()).then_some(s)
        })
        .collect()
}

fn padded(input: &[f32], seconds: f64) -> Vec<f32> {
    let min = (seconds * SAMPLE_RATE_F) as usize;
    let mut s = input.to_vec();
    if s.len() < min {
        s.resize(min, 0.0);
    }
    s
}

// MARK: Whisper

pub struct WhisperEngine {
    api: &'static Api,
    ctx: *mut c_void,
    path: PathBuf,
    multilingual: bool,
    load_seconds: f64,
}

// A whisper context may move between threads; `&mut self` keeps it to one at a time.
unsafe impl Send for WhisperEngine {}

impl WhisperEngine {
    /// Longest clip decoded in one go. Whisper decodes 30 s windows and, with timestamps off,
    /// drops whatever straddles a window edge, so long audio is cut at the quietest stretch first.
    pub const CHUNK_SECONDS: f64 = 28.0;

    pub fn load(path: &Path) -> Result<WhisperEngine, EngineError> {
        let api = api().map_err(EngineError::Unavailable)?;
        let c = CString::new(path.to_string_lossy().as_bytes()).map_err(|_| EngineError::LoadFailed(path.display().to_string()))?;
        let t0 = Instant::now();
        let ctx = unsafe {
            let mut params = (api.whisper_context_default_params)();
            params.use_gpu = true;
            params.flash_attn = true;
            (api.whisper_init_from_file_with_params)(c.as_ptr(), params)
        };
        if ctx.is_null() {
            return Err(EngineError::LoadFailed(path.display().to_string()));
        }
        let multilingual = unsafe { (api.whisper_is_multilingual)(ctx) } != 0;
        let load_seconds = t0.elapsed().as_secs_f64();
        log::info!(target: "engine", "loaded {} in {load_seconds:.2}s (multilingual={multilingual})", path.display());
        Ok(WhisperEngine { api, ctx, path: path.to_path_buf(), multilingual, load_seconds })
    }

    fn run(&mut self, input: &[f32], options: &Options) -> Result<Transcription, EngineError> {
        // whisper_full refuses input shorter than 1 s, and a quick "yes" is well under that.
        let samples = padded(input, 1.5);
        let api = self.api;
        let beam = options.beam_size > 1;
        // ".en" models only know English; whisper.cpp would warn and force it anyway.
        let lang = if self.multilingual { if options.language.is_empty() { "auto".to_string() } else { options.language.clone() } } else { "en".into() };
        let lang_c = CString::new(lang.as_bytes()).map_err(|_| EngineError::UnknownLanguage(lang.clone()))?;
        if lang != "auto" && unsafe { (api.whisper_lang_id)(lang_c.as_ptr()) } < 0 {
            return Err(EngineError::UnknownLanguage(lang));
        }
        let prompt_c = options.initial_prompt.as_ref().filter(|p| !p.is_empty()).and_then(|p| CString::new(p.as_bytes()).ok());
        let vad_c = options.vad_model.as_ref().filter(|p| p.exists()).and_then(|p| CString::new(p.to_string_lossy().as_bytes()).ok());

        let mut p = unsafe { (api.whisper_full_default_params)(if beam { ffi::WHISPER_SAMPLING_BEAM_SEARCH } else { ffi::WHISPER_SAMPLING_GREEDY }) };
        p.n_threads = options.threads;
        p.no_context = true; // each dictation stands alone
        p.no_timestamps = true; // only the text; also a small speed win
        p.single_segment = false;
        p.print_special = false;
        p.print_progress = false;
        p.print_realtime = false;
        p.print_timestamps = false;
        p.suppress_blank = true;
        if !options.temperature_fallback {
            p.temperature_inc = 0.0;
        }
        if beam {
            p.beam_search.beam_size = options.beam_size;
        } else {
            p.greedy.best_of = 1;
        }
        p.language = lang_c.as_ptr();
        p.detect_language = false;
        if let Some(prompt) = &prompt_c {
            p.initial_prompt = prompt.as_ptr();
        }
        if let Some(vad) = &vad_c {
            p.vad = true;
            p.vad_model_path = vad.as_ptr();
            let mut vp = unsafe { (api.whisper_vad_default_params)() };
            vp.threshold = 0.5;
            vp.min_speech_duration_ms = 200;
            vp.min_silence_duration_ms = 100;
            vp.max_speech_duration_s = f32::MAX;
            vp.speech_pad_ms = 60;
            vp.samples_overlap = 0.1;
            p.vad_params = vp;
        }
        let t0 = Instant::now();
        let rc = unsafe { (api.whisper_full)(self.ctx, p, samples.as_ptr(), samples.len() as i32) };
        let dt = t0.elapsed().as_secs_f64();
        // The strings the params point at live until here.
        drop((lang_c, prompt_c, vad_c));
        if rc != 0 {
            return Err(EngineError::InferenceFailed(rc));
        }
        let ctx = self.ctx;
        let segments = segment_texts(unsafe { (api.whisper_full_n_segments)(ctx) }, |i| unsafe { (api.whisper_full_get_segment_text)(ctx, i) });
        let detected = if self.multilingual {
            let id = unsafe { (api.whisper_full_lang_id)(ctx) };
            let s = if id >= 0 { unsafe { (api.whisper_lang_str)(id) } } else { std::ptr::null() };
            (!s.is_null()).then(|| unsafe { CStr::from_ptr(s) }.to_string_lossy().into_owned())
        } else {
            None
        };
        Ok(Transcription { text: segments.join(" "), segments, detected_language: detected, inference_seconds: dt, audio_seconds: input.len() as f64 / SAMPLE_RATE_F })
    }
}

impl Engine for WhisperEngine {
    fn kind(&self) -> EngineKind {
        EngineKind::Whisper
    }
    fn model_path(&self) -> &Path {
        &self.path
    }
    fn is_multilingual(&self) -> bool {
        self.multilingual
    }
    fn load_seconds(&self) -> f64 {
        self.load_seconds
    }
    fn transcribe(&mut self, samples: &[f32], options: &Options) -> Result<Transcription, EngineError> {
        decode_in_pieces(samples, Self::CHUNK_SECONDS, 18.0, &mut |piece| self.run(piece, options))
    }
}

impl Drop for WhisperEngine {
    fn drop(&mut self) {
        unsafe { (self.api.whisper_free)(self.ctx) }
    }
}

// MARK: Parakeet

/// NVIDIA Parakeet TDT 0.6B through libparakeet. A transducer, not an encoder-decoder with a
/// 30 s window, so it has no prompt, no language switch and no temperature fallback, and it is
/// fast.
pub struct ParakeetEngine {
    api: &'static Api,
    ctx: *mut c_void,
    path: PathBuf,
    load_seconds: f64,
}

unsafe impl Send for ParakeetEngine {}

impl ParakeetEngine {
    pub fn load(path: &Path) -> Result<ParakeetEngine, EngineError> {
        let api = api().map_err(EngineError::Unavailable)?;
        let c = CString::new(path.to_string_lossy().as_bytes()).map_err(|_| EngineError::LoadFailed(path.display().to_string()))?;
        let t0 = Instant::now();
        let ctx = unsafe {
            let mut params = (api.parakeet_context_default_params)();
            params.use_gpu = true;
            (api.parakeet_init_from_file_with_params)(c.as_ptr(), params)
        };
        if ctx.is_null() {
            return Err(EngineError::LoadFailed(path.display().to_string()));
        }
        let load_seconds = t0.elapsed().as_secs_f64();
        log::info!(target: "engine", "loaded {} in {load_seconds:.2}s (parakeet)", path.display());
        Ok(ParakeetEngine { api, ctx, path: path.to_path_buf(), load_seconds })
    }

    fn run(&mut self, input: &[f32], options: &Options) -> Result<Transcription, EngineError> {
        let samples = padded(input, 1.0);
        let api = self.api;
        let mut p = unsafe { (api.parakeet_full_default_params)(ffi::PARAKEET_SAMPLING_GREEDY) };
        p.n_threads = options.threads.min(4);
        p.no_context = true;
        let t0 = Instant::now();
        let rc = unsafe { (api.parakeet_full)(self.ctx, p, samples.as_ptr(), samples.len() as i32) };
        let dt = t0.elapsed().as_secs_f64();
        if rc != 0 {
            return Err(EngineError::InferenceFailed(rc));
        }
        let ctx = self.ctx;
        let segments = segment_texts(unsafe { (api.parakeet_full_n_segments)(ctx) }, |i| unsafe { (api.parakeet_full_get_segment_text)(ctx, i) });
        Ok(Transcription { text: segments.join(" "), segments, detected_language: None, inference_seconds: dt, audio_seconds: input.len() as f64 / SAMPLE_RATE_F })
    }
}

impl Engine for ParakeetEngine {
    fn kind(&self) -> EngineKind {
        EngineKind::Parakeet
    }
    fn model_path(&self) -> &Path {
        &self.path
    }
    /// v3 detects 25 European languages by itself and has no switch, so there is nothing to pick.
    fn is_multilingual(&self) -> bool {
        false
    }
    fn load_seconds(&self) -> f64 {
        self.load_seconds
    }
    fn transcribe(&mut self, samples: &[f32], options: &Options) -> Result<Transcription, EngineError> {
        // libparakeet 1.9.1 drops whole sentences after a pause once a clip passes about 60 s.
        decode_in_pieces(samples, 45.0, 30.0, &mut |piece| self.run(piece, options))
    }
}

impl Drop for ParakeetEngine {
    fn drop(&mut self) {
        unsafe { (self.api.parakeet_free)(self.ctx) }
    }
}

/// An engine with its options, as the notetaker's whole-file pass wants it.
pub struct Bound<'a> {
    pub engine: &'a mut dyn Engine,
    pub options: Options,
}

impl linflow_core::meeting::Recognizer for Bound<'_> {
    fn recognize(&mut self, samples: &[f32]) -> Result<String, String> {
        self.engine.transcribe(samples, &self.options).map(|t| t.text).map_err(|e| e.to_string())
    }
}
