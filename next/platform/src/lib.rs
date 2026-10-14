//! What Lin Flow needs from each operating system, behind one set of names: the talk key, the
//! microphone, the call's audio, paste, the readback of the focused field, the list of apps
//! holding the microphone, and staying awake through a meeting. Everything that decides
//! anything lives in `linflow-core`; this crate only reports what the OS sees and does what it
//! is told.

#[cfg(any(target_os = "macos", windows))]
pub mod mic;
#[cfg(not(any(target_os = "macos", windows)))]
#[path = "other/mic.rs"]
pub mod mic;
pub mod sound;
mod system;

pub use sound::{play as play_sound, Sound};
pub use system::{computer_name, free_bytes};

#[cfg(target_os = "macos")]
#[path = "mac/mod.rs"]
mod os;

#[cfg(windows)]
#[path = "windows/mod.rs"]
mod os;

#[cfg(not(any(target_os = "macos", windows)))]
#[path = "other/mod.rs"]
mod os;

pub use os::*;

/// An app the platform can name: the one in front, or one holding the microphone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct App {
    pub pid: u32,
    /// Bundle id on the Mac, lowercase executable name on Windows.
    pub id: String,
    pub name: String,
}

/// Called with each press and release of the talk key, on the listener's own thread.
pub type OnSignal = std::sync::Arc<dyn Fn(linflow_core::hotkey::Signal) + Send + Sync>;

/// Settings' Record button: every key and button event while it listens, on the listener's
/// thread. Returns whether to keep the event from the app in front.
pub type OnRecord = Box<dyn FnMut(&linflow_core::hotkey::HotkeyEvent) -> bool + Send>;

/// Receives 16 kHz mono audio on the audio thread.
pub type OnChunk = Box<dyn FnMut(&[f32]) + Send>;
