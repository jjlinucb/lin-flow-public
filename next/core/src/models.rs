//! The speech models: which exist, where their files are, and which to retry a take on.
//! The same ids, files and download URLs as both current apps.

use crate::paths;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EngineKind {
    Whisper,
    Parakeet,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelInfo {
    /// The short id settings and the CLI use, e.g. "large-v3-turbo-q5_0".
    pub id: &'static str,
    pub file_name: &'static str,
    pub url: &'static str,
    pub size_mb: u32,
    pub multilingual: bool,
    pub note: &'static str,
    pub engine: EngineKind,
}

pub const DEFAULT_MODEL_ID: &str = "parakeet-tdt-0.6b-v3-q8_0";

macro_rules! hf {
    ($f:literal) => {
        concat!("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/", $f)
    };
}

pub const KNOWN: &[ModelInfo] = &[
    ModelInfo {
        id: "parakeet-tdt-0.6b-v3-q8_0",
        file_name: "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
        url: "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
        size_mb: 669,
        multilingual: false,
        note: "Default. Top English accuracy and ~10x faster than Whisper turbo.",
        engine: EngineKind::Parakeet,
    },
    ModelInfo {
        id: "parakeet-tdt-0.6b-v3-q4_k",
        file_name: "ggml-parakeet-tdt-0.6b-v3-q4_k.bin",
        url: "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q4_k.bin",
        size_mb: 416,
        multilingual: false,
        note: "Smaller Parakeet; slightly less accurate.",
        engine: EngineKind::Parakeet,
    },
    ModelInfo {
        id: "large-v3-turbo-q5_0",
        file_name: "ggml-large-v3-turbo-q5_0.bin",
        url: hf!("ggml-large-v3-turbo-q5_0.bin"),
        size_mb: 574,
        multilingual: true,
        note: "Whisper's best speed/accuracy trade-off; use for Khmer and other languages.",
        engine: EngineKind::Whisper,
    },
    ModelInfo {
        id: "large-v3-turbo-q8_0",
        file_name: "ggml-large-v3-turbo-q8_0.bin",
        url: hf!("ggml-large-v3-turbo-q8_0.bin"),
        size_mb: 874,
        multilingual: true,
        note: "Same model, less quantized. Marginally better, more RAM.",
        engine: EngineKind::Whisper,
    },
    ModelInfo {
        id: "small.en-q8_0",
        file_name: "ggml-small.en-q8_0.bin",
        url: hf!("ggml-small.en-q8_0.bin"),
        size_mb: 264,
        multilingual: false,
        note: "Fast English-only fallback.",
        engine: EngineKind::Whisper,
    },
    ModelInfo {
        id: "medium-q5_0",
        file_name: "ggml-medium-q5_0.bin",
        url: hf!("ggml-medium-q5_0.bin"),
        size_mb: 539,
        multilingual: true,
        note: "Older generation; turbo is better and faster.",
        engine: EngineKind::Whisper,
    },
    ModelInfo {
        id: "base.en",
        file_name: "ggml-base.en.bin",
        url: hf!("ggml-base.en.bin"),
        size_mb: 148,
        multilingual: false,
        note: "Tiny and quick, noticeably less accurate.",
        engine: EngineKind::Whisper,
    },
];

pub const VAD_MODEL: ModelInfo = ModelInfo {
    id: "silero-v6.2.0",
    file_name: "ggml-silero-v6.2.0.bin",
    url: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin",
    size_mb: 1,
    multilingual: true,
    note: "Voice activity detection",
    engine: EngineKind::Whisper,
};

pub fn info(id: &str) -> Option<&'static ModelInfo> {
    KNOWN.iter().find(|m| m.id == id)
}

/// Where model files are looked for: this app's own folder first, then the installed Lin
/// Flow's, read-only, so running beside it does not mean downloading 669 MB again.
pub fn search_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![paths::models_dir()];
    let installed = paths::installed_app_dir().join("models");
    if !dirs.contains(&installed) {
        dirs.push(installed);
    }
    dirs
}

/// The kind of engine a model file needs, from its name.
pub fn kind_of(path: &Path) -> EngineKind {
    let name = path.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    if name.contains("parakeet") {
        EngineKind::Parakeet
    } else {
        EngineKind::Whisper
    }
}

/// An id, a bare file name or an absolute path, to the file on disk.
pub fn locate(id_or_path: &str) -> Option<PathBuf> {
    let p = Path::new(id_or_path);
    if p.is_absolute() {
        return p.exists().then(|| p.to_path_buf());
    }
    if let Some(rest) = id_or_path.strip_prefix("~/") {
        let full = paths::home().join(rest);
        return full.exists().then_some(full);
    }
    let file = if id_or_path.starts_with("ggml-") {
        id_or_path.to_string()
    } else {
        format!("ggml-{}{}", id_or_path, if id_or_path.ends_with(".bin") { "" } else { ".bin" })
    };
    search_dirs().into_iter().map(|d| d.join(&file)).find(|f| f.exists())
}

pub fn vad_model_path() -> Option<PathBuf> {
    locate(VAD_MODEL.file_name)
}

/// Every ggml speech model on disk, catalog or not, by file name.
pub fn installed() -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    for dir in search_dirs() {
        let Ok(items) = std::fs::read_dir(&dir) else { continue };
        for item in items.flatten() {
            let name = item.file_name().to_string_lossy().to_string();
            if name.starts_with("ggml-") && name.ends_with(".bin") && !name.contains("silero") && !name.contains("-encoder")
                && !out.iter().any(|p| p.file_name() == Some(item.file_name().as_os_str()))
            {
                out.push(item.path());
            }
        }
    }
    out.sort_by_key(|p| p.file_name().map(|n| n.to_os_string()));
    out
}

pub fn id_from_path(path: &Path) -> String {
    let mut s = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    if let Some(r) = s.strip_prefix("ggml-") {
        s = r.to_string();
    }
    if let Some(r) = s.strip_suffix(".bin") {
        s = r.to_string();
    }
    s
}

/// Which model to retry a take on when the first came back with nothing at all. Measured
/// 2026-09-20 (NOISE.md): at 0 dB babble Parakeet returns an empty transcript while Whisper
/// degrades, so the retry has to be a different engine kind, the most capable one installed.
pub fn rescue_model(after: EngineKind, installed: &[PathBuf]) -> Option<PathBuf> {
    let rank = ["large-v3-turbo", "large-v3", "medium", "small", "base", "tiny"];
    let score = |p: &PathBuf| {
        let name = p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
        rank.iter().position(|r| name.contains(r)).unwrap_or(rank.len())
    };
    installed
        .iter()
        .filter(|p| kind_of(p) != after)
        .min_by(|a, b| score(a).cmp(&score(b)).then_with(|| a.file_name().cmp(&b.file_name())))
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rescue_prefers_the_strongest_other_kind() {
        let installed: Vec<PathBuf> =
            ["ggml-parakeet-tdt-0.6b-v3-q8_0.bin", "ggml-base.en.bin", "ggml-large-v3-turbo-q5_0.bin"].iter().map(PathBuf::from).collect();
        assert_eq!(rescue_model(EngineKind::Parakeet, &installed), Some(PathBuf::from("ggml-large-v3-turbo-q5_0.bin")));
        assert_eq!(rescue_model(EngineKind::Whisper, &installed), Some(PathBuf::from("ggml-parakeet-tdt-0.6b-v3-q8_0.bin")));
        assert_eq!(rescue_model(EngineKind::Parakeet, &installed[..1]), None);
    }

    #[test]
    fn ids() {
        assert_eq!(id_from_path(Path::new("/x/ggml-base.en.bin")), "base.en");
        assert_eq!(info(DEFAULT_MODEL_ID).unwrap().engine, EngineKind::Parakeet);
    }
}
