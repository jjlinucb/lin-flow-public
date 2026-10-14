//! Lin Flow's shared core. Everything here is plain Rust with no operating-system calls, so it
//! is the same code on the Mac and on Windows and runs under `cargo test` anywhere.

pub mod audio;
pub mod fsutil;
pub mod history;
pub mod hotkey;
pub mod json;
pub mod learn;
pub mod llm;
pub mod meeting;
pub mod models;
pub mod net;
pub mod notes;
pub mod paths;
pub mod readback;
pub mod repair;
pub mod settings;
pub mod sync;
pub mod text;
pub mod wav;
