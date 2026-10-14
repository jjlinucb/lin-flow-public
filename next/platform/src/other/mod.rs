//! Any other OS: enough to build and run the core's tests in CI, nothing that captures or types.

use crate::{App, OnChunk, OnRecord, OnSignal};
use linflow_core::hotkey::Hotkey;
use std::time::Duration;

pub(crate) const UNSUPPORTED: &str = "Lin Flow runs on macOS and Windows.";

pub struct HotkeyListener;

impl HotkeyListener {
    pub fn start(_hotkey: Hotkey, _on_signal: OnSignal) -> Result<HotkeyListener, String> {
        Err(UNSUPPORTED.into())
    }

    pub fn set_hotkey(&self, _hotkey: Hotkey) {}

    pub fn set_recorder(&self, _record: Option<OnRecord>) {}
}

pub struct SystemAudio;

impl SystemAudio {
    pub fn start(_on_chunk: OnChunk) -> Result<SystemAudio, String> {
        Err(UNSUPPORTED.into())
    }
}

pub struct AwakeGuard;

pub fn keep_awake(_reason: &str) -> Option<AwakeGuard> {
    None
}

pub fn mic_users() -> Vec<String> {
    vec![]
}

pub fn paste(_text: &str, _restore_after: Duration) {}

pub fn copy(_text: &str) {}

pub fn clipboard_text() -> Option<String> {
    None
}

pub fn trusted(_prompt: bool) -> bool {
    false
}

pub fn frontmost_app() -> Option<App> {
    None
}

pub struct Field;

pub struct FieldReader;

impl FieldReader {
    pub fn new() -> Result<FieldReader, String> {
        Err(UNSUPPORTED.into())
    }

    pub fn focused(&self, _pid: u32) -> Option<Field> {
        None
    }

    pub fn text(&self, _field: &Field) -> Option<String> {
        None
    }

    pub fn prime(&self, _pid: u32) {}

    pub fn timeouts(&self) -> usize {
        0
    }
}
