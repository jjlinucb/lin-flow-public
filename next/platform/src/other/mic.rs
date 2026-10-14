//! The microphone on any other OS: the names `mic.rs` has on the Mac and Windows, so the service
//! and the CLI build and test in CI. Nothing opens.

use crate::OnChunk;
use std::time::Duration;

pub struct Microphone {
    pub device: String,
    pub sample_rate: u32,
    pub channels: u16,
}

impl Microphone {
    pub fn start(_on_chunk: OnChunk) -> Result<Microphone, String> {
        Err(crate::os::UNSUPPORTED.into())
    }

    pub fn first_audio(&self) -> Option<Duration> {
        None
    }

    pub fn heard_anything(&self) -> bool {
        false
    }

    pub fn error(&self) -> Option<String> {
        None
    }

    pub fn running_for(&self) -> Duration {
        Duration::ZERO
    }
}

pub fn default_input_name() -> Option<String> {
    None
}

pub fn default_output_name() -> Option<String> {
    None
}
