//! The Mac: a Quartz event tap for the talk key, the general pasteboard and Cmd+V for paste,
//! Accessibility for the readback, Core Audio for system audio and the list of apps holding the
//! microphone, and an IOKit power assertion while a meeting records.

pub mod audio;
pub mod ax;
pub mod hotkey;
pub mod paste;

use crate::App;

pub use audio::{keep_awake, mic_users, AwakeGuard, SystemAudio};
pub use hotkey::HotkeyListener;
pub use paste::{clipboard_text, copy, paste};

pub fn trusted(prompt: bool) -> bool {
    ax::trusted(prompt)
}

pub fn frontmost_app() -> Option<App> {
    ax::frontmost_app().map(|(pid, id, name)| App { pid: pid as u32, id, name })
}

/// The focused field of another app, held so the readback can keep reading the one it anchored
/// on after the focus moves.
pub struct Field(ax::Element);

/// Reads the field an app has focused. Made and used on the readback's own thread, as the
/// Windows reader must be.
pub struct FieldReader(());

impl FieldReader {
    pub fn new() -> Result<FieldReader, String> {
        Ok(FieldReader(()))
    }

    /// The focused element, system-wide first and then inside `pid`, the app pasted into. Never
    /// a password field, never one of Lin Flow's own.
    pub fn focused(&self, pid: u32) -> Option<Field> {
        if pid == std::process::id() {
            return None;
        }
        ax::focused_element(pid as i32).map(Field)
    }

    pub fn text(&self, field: &Field) -> Option<String> {
        field.0.value()
    }

    /// Asks Chromium and Electron apps to build their accessibility tree, at the paste, so it
    /// is there by the first look.
    pub fn prime(&self, pid: u32) {
        ax::prime(pid as i32)
    }

    /// Reads that ran out of time since launch.
    pub fn timeouts(&self) -> usize {
        ax::TIMEOUTS.load(std::sync::atomic::Ordering::Relaxed)
    }
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventSourceFlagsState(state: i32) -> u64;
}

/// Whether a modifier is held right now, on either side: "shift", "control", "option" or
/// "command". Read from the whole session, so it works from any thread at any moment.
pub fn modifier_held(name: &str) -> bool {
    let mask = match name {
        "shift" => 0x0002_0000,
        "control" => 0x0004_0000,
        "option" | "alt" => 0x0008_0000,
        "command" => 0x0010_0000,
        _ => return false,
    };
    // 0 is kCGEventSourceStateCombinedSessionState.
    let flags = unsafe { CGEventSourceFlagsState(0) };
    flags & mask != 0
}
