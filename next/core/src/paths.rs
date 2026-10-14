//! Where Lin Flow keeps its files.
//!
//! Lin Flow Next keeps its own folder until John says cut over, so it never writes beside the
//! installed app: two apps syncing one `dictionary-sync.json` or appending to one
//! `history.jsonl` would corrupt both. `LINFLOW_DATA_DIR` points it anywhere, which is how the
//! oracle reads the installed app's dictionary, read-only.

use std::path::PathBuf;

/// The folder's name. "Lin Flow" is the installed app's; this becomes it at cutover.
pub const APP_FOLDER: &str = "Lin Flow Next";

pub fn data_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("LINFLOW_DATA_DIR") {
        return PathBuf::from(dir);
    }
    base_dir().join(APP_FOLDER)
}

#[cfg(target_os = "macos")]
fn base_dir() -> PathBuf {
    home().join("Library/Application Support")
}

#[cfg(target_os = "windows")]
fn base_dir() -> PathBuf {
    std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(|| home().join("AppData/Roaming"))
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn base_dir() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".local/share"))
}

/// The installed Lin Flow's data folder ("Lin Flow"), which this app only ever reads: its model
/// files, and its history and dictionary for the oracle and for cutover.
pub fn installed_app_dir() -> PathBuf {
    base_dir().join("Lin Flow")
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

pub fn vocab_file() -> PathBuf {
    data_dir().join("vocab.txt")
}

pub fn replacements_file() -> PathBuf {
    data_dir().join("replacements.txt")
}

pub fn history_file() -> PathBuf {
    data_dir().join("history.jsonl")
}

pub fn recordings_dir() -> PathBuf {
    data_dir().join("recordings")
}

pub fn notes_dir() -> PathBuf {
    data_dir().join("notes")
}

pub fn models_dir() -> PathBuf {
    data_dir().join("models")
}

pub fn settings_file() -> PathBuf {
    data_dir().join("settings.json")
}

pub fn log_dir() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        home().join("Library/Logs").join(APP_FOLDER)
    }
    #[cfg(not(target_os = "macos"))]
    {
        data_dir().join("logs")
    }
}
