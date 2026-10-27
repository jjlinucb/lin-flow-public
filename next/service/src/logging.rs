//! The log file: one line per event, in the log folder, rolled over at 5 MB. Where a problem on
//! any of the three computers is read afterwards, so it says what happened in words.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

const LIMIT: u64 = 5 * 1024 * 1024;

struct FileLog {
    path: PathBuf,
    file: Mutex<Option<File>>,
    echo: bool,
}

impl FileLog {
    fn open(&self) -> Option<File> {
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if std::fs::metadata(&self.path).map(|m| m.len() > LIMIT).unwrap_or(false) {
            let _ = std::fs::rename(&self.path, self.path.with_extension("1.log"));
        }
        OpenOptions::new().create(true).append(true).open(&self.path).ok()
    }
}

impl log::Log for FileLog {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Info
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        // Other crates' chatter stays out: only Lin Flow's own lines.
        if !record.target().starts_with("linflow") {
            return;
        }
        let line = format!("{} {:<5} {}\n", chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f"), record.level(), record.args());
        if self.echo {
            eprint!("{line}");
        }
        let Ok(mut slot) = self.file.lock() else { return };
        if slot.as_ref().and_then(|f| f.metadata().ok()).is_some_and(|m| m.len() > LIMIT) {
            *slot = None;
        }
        if slot.is_none() {
            *slot = self.open();
        }
        if let Some(f) = slot.as_mut() {
            let _ = f.write_all(line.as_bytes());
        }
    }

    fn flush(&self) {
        if let Ok(mut slot) = self.file.lock() {
            if let Some(f) = slot.as_mut() {
                let _ = f.flush();
            }
        }
    }
}

/// The log file's path.
pub fn path() -> PathBuf {
    linflow_core::paths::log_dir().join("lin-flow.log")
}

/// Sends `log` lines to the file, and to stderr as well when `echo` is set. Once per process.
pub fn start(echo: bool) {
    let logger = FileLog { path: path(), file: Mutex::new(None), echo };
    if log::set_boxed_logger(Box::new(logger)).is_ok() {
        log::set_max_level(log::LevelFilter::Info);
    }
}
