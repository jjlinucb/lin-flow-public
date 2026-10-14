//! The one loaded speech model, shared by dictation, the live meeting transcript and the pass
//! over a recording. Each takes it for one piece of audio at a time, so a dictation waits at most
//! one meeting segment, never a whole meeting.

use linflow_core::audio::SAMPLE_RATE;
use linflow_core::meeting::Recognizer;
use linflow_core::models::{self, EngineKind};
use linflow_core::settings::Settings;
use linflow_core::text::glossary;
use linflow_engine::{Engine, EngineError, Options, Transcription};
use std::path::Path;
use std::sync::{Arc, Mutex};

#[derive(Default)]
pub struct EngineSlot {
    engine: Mutex<Option<Box<dyn Engine>>>,
}

impl EngineSlot {
    pub fn is_loaded(&self) -> bool {
        self.engine.lock().map(|e| e.is_some()).unwrap_or(false)
    }

    pub fn set(&self, engine: Option<Box<dyn Engine>>) {
        if let Ok(mut slot) = self.engine.lock() {
            *slot = engine;
        }
    }

    /// The model's id and kind, when one is loaded.
    pub fn describe(&self) -> Option<(String, EngineKind)> {
        let slot = self.engine.lock().ok()?;
        slot.as_ref().map(|e| (e.model_id(), e.kind()))
    }

    pub fn transcribe(&self, samples: &[f32], options: &Options) -> Result<(Transcription, String, EngineKind), EngineError> {
        let mut slot = self.engine.lock().map_err(|_| EngineError::Unavailable("the speech model is unavailable".into()))?;
        let engine = slot.as_mut().ok_or_else(|| EngineError::Unavailable("The speech model is still loading.".into()))?;
        let t = engine.transcribe(samples, options)?;
        Ok((t, engine.model_id(), engine.kind()))
    }
}

/// Decoding options from the settings and the dictionary, as the Mac builds them.
pub fn options(settings: &Settings, terms: &[String]) -> Options {
    Options {
        language: settings.language.clone(),
        beam_size: settings.beam_size.clamp(1, 8),
        vad_model: if settings.use_vad { models::vad_model_path() } else { None },
        initial_prompt: Some(glossary::initial_prompt(terms)),
        temperature_fallback: settings.temperature_fallback,
        ..Options::default()
    }
}

/// Loads a model and pays the first inference's set-up cost now rather than on the first
/// dictation. VAD is off for the warm-up, or Whisper skips the encoder on silence and warms
/// nothing.
pub fn load_warm(path: &Path, settings: &Settings, terms: &[String]) -> Result<Box<dyn Engine>, EngineError> {
    let mut engine = linflow_engine::load(path)?;
    let mut warm = options(settings, terms);
    warm.vad_model = None;
    let _ = engine.transcribe(&vec![0.0; SAMPLE_RATE as usize * 3 / 2], &warm);
    Ok(engine)
}

/// The slot as a recognizer for the meeting passes, taking the model one piece at a time.
pub struct SlotRecognizer {
    pub slot: Arc<EngineSlot>,
    pub options: Options,
}

impl Recognizer for SlotRecognizer {
    fn recognize(&mut self, samples: &[f32]) -> Result<String, String> {
        self.slot.transcribe(samples, &self.options).map(|(t, _, _)| t.text).map_err(|e| e.to_string())
    }
}
