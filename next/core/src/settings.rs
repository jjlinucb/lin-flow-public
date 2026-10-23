//! Settings, as `settings.json` in the data folder on both computers. The keys are the Mac's
//! UserDefaults keys and the Windows app's settings.json keys, which were already the same, so
//! cutover reads either app's values. Unknown keys are kept on save: a newer build's setting is
//! not an older build's to delete.

use crate::fsutil::write_atomic;
use crate::learn::LearnMode;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

/// The Swift app has a third level, Medium, an Apple Intelligence rewrite. Next leaves it out
/// with Style, Snippets and Transforms (John, 2026-10-23), so a "medium" read from the Mac comes
/// in as Light, the default.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum CleanupLevel {
    /// The engine's text as it came.
    None,
    /// The rule-based pass: fillers, dictionary, numbers, punctuation.
    #[default]
    Light,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    #[serde(rename = "modelID")]
    pub model_id: String,
    /// The talk key, as `Hotkey::raw_value` writes it. Empty means the platform default.
    pub hotkey: String,
    /// "en", "auto", or any Whisper language code. Parakeet is English only.
    pub language: String,
    pub beam_size: i32,
    pub temperature_fallback: bool,
    #[serde(rename = "useVAD")]
    pub use_vad: bool,
    pub cleanup_level: CleanupLevel,
    pub learn_corrections: LearnMode,
    pub numbers_as_digits: bool,
    pub spoken_commands: bool,
    pub sounds: bool,
    #[serde(rename = "showHUD")]
    pub show_hud: bool,
    /// Mac: a Dock icon with the running dot. Off makes it a menu-bar-only app.
    pub show_in_dock: bool,
    /// A space after each dictation so the next one does not run on.
    pub trailing_space: bool,
    /// Days to keep each dictation's audio. 0 keeps none.
    pub audio_retention_days: u32,
    pub keep_meeting_audio: bool,
    pub running_notes: bool,
    pub transcribe_after_meeting: bool,
    pub meeting_uses_microphone: bool,
    pub meeting_uses_system_audio: bool,
    pub open_window_at_launch: bool,
    pub launch_at_login: bool,
    /// Offer to record a meeting note when a call app starts using the microphone.
    pub offer_meeting_notes: bool,
    #[serde(rename = "hudX", skip_serializing_if = "Option::is_none")]
    pub hud_x: Option<f64>,
    #[serde(rename = "hudY", skip_serializing_if = "Option::is_none")]
    pub hud_y: Option<f64>,
    /// The Ollama model for running notes and summaries when no Claude key is saved, and where
    /// Ollama listens. Windows' keys. Use 127.0.0.1, never localhost: Ollama binds IPv4 only
    /// and Windows tries ::1 first.
    #[serde(rename = "notesModel")]
    pub ollama_model: String,
    pub ollama_host: String,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            model_id: crate::models::DEFAULT_MODEL_ID.to_string(),
            hotkey: String::new(),
            language: "en".into(),
            beam_size: 5,
            temperature_fallback: false,
            use_vad: true,
            cleanup_level: CleanupLevel::Light,
            learn_corrections: LearnMode::Auto,
            numbers_as_digits: true,
            spoken_commands: true,
            sounds: true,
            show_hud: true,
            show_in_dock: true,
            trailing_space: true,
            audio_retention_days: 30,
            keep_meeting_audio: true,
            running_notes: true,
            transcribe_after_meeting: true,
            meeting_uses_microphone: true,
            meeting_uses_system_audio: true,
            open_window_at_launch: true,
            launch_at_login: false,
            offer_meeting_notes: true,
            hud_x: None,
            hud_y: None,
            ollama_model: "qwen2.5:3b".into(),
            ollama_host: "http://127.0.0.1:11434".into(),
        }
    }
}

/// The settings file, with the keys this build does not know carried through every save.
#[derive(Clone, Debug)]
pub struct SettingsFile {
    pub path: PathBuf,
    pub values: Settings,
    extra: Map<String, Value>,
}

impl SettingsFile {
    pub fn load(path: &Path) -> Self {
        let raw: Map<String, Value> = std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
        Self::from_map(path, raw)
    }

    fn from_map(path: &Path, raw: Map<String, Value>) -> Self {
        // Field by field, so one bad value costs that setting and not the whole file.
        let defaults = serde_json::to_value(Settings::default()).unwrap();
        let known: Vec<String> = defaults.as_object().unwrap().keys().cloned().chain(["hudX".to_string(), "hudY".to_string()]).collect();
        let mut merged = defaults.as_object().unwrap().clone();
        for (k, v) in &raw {
            if known.contains(k) {
                let mut probe = merged.clone();
                probe.insert(k.clone(), v.clone());
                if serde_json::from_value::<Settings>(Value::Object(probe)).is_ok() {
                    merged.insert(k.clone(), v.clone());
                }
            }
        }
        let values: Settings = serde_json::from_value(Value::Object(merged)).unwrap_or_default();
        let extra = raw.into_iter().filter(|(k, _)| !known.contains(k)).collect();
        SettingsFile { path: path.to_path_buf(), values, extra }
    }

    pub fn save(&self) -> std::io::Result<()> {
        let mut map = self.extra.clone();
        if let Value::Object(known) = serde_json::to_value(&self.values).map_err(std::io::Error::other)? {
            map.extend(known);
        }
        let text = serde_json::to_string_pretty(&Value::Object(map)).map_err(std::io::Error::other)?;
        write_atomic(&self.path, text.as_bytes())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_windows_file_and_keeps_unknown_keys() {
        let dir = crate::history::tests::tempdir();
        let path = dir.join("settings.json");
        std::fs::write(&path, r#"{"hotkey":"LeftCtrl+LeftAlt","audioRetentionDays":"bad","futureThing":{"a":1},"spokenCommands":false,"modelID":"ggml-large-v3-turbo-q5_0","notesModel":"llama3.2:3b"}"#).unwrap();
        let s = SettingsFile::load(&path);
        assert_eq!(s.values.hotkey, "LeftCtrl+LeftAlt");
        assert_eq!(s.values.model_id, "ggml-large-v3-turbo-q5_0", "the Mac's key");
        assert_eq!(s.values.ollama_model, "llama3.2:3b", "Windows' key");
        assert_eq!(s.values.ollama_host, "http://127.0.0.1:11434");
        assert_eq!(s.values.audio_retention_days, 30, "a bad value costs only that setting");
        assert!(!s.values.spoken_commands);
        s.save().unwrap();
        let back: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(back["futureThing"]["a"], 1);
        assert_eq!(back["useVAD"], true);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_macs_medium_cleanup_and_snippets_come_in_without_them() {
        let dir = crate::history::tests::tempdir();
        let path = dir.join("settings.json");
        std::fs::write(&path, r#"{"cleanupLevel":"medium","sounds":false,"snippetsEnabled":true,"transforms":[{"name":"Formal"}]}"#).unwrap();
        let s = SettingsFile::load(&path);
        assert_eq!(s.values.cleanup_level, CleanupLevel::Light, "Medium was Apple Intelligence, which is out");
        assert!(!s.values.sounds, "the rest of the file still reads");
        s.save().unwrap();
        let back: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(back["cleanupLevel"], "light");
        assert_eq!(back["transforms"][0]["name"], "Formal", "kept for a later port, never acted on");
        let _ = std::fs::remove_dir_all(dir);
    }
}
