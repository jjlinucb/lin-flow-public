//! The shared dictionary and the shared word totals, on one worker thread: every ten minutes,
//! and the totals after each dictation. Nothing happens until `sync.env` is in the data folder,
//! and Lin Flow Next's folder is its own, so it never syncs as the installed app's computer.

use crate::context::Context;
use crate::events::Event;
use linflow_core::sync::dictionary::{self, Files};
use linflow_core::sync::totals::{CombinedTotals, TotalsSync};
use linflow_core::sync::{SyncConfig, FILE_NAME};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const EVERY: Duration = Duration::from_secs(600);

enum Msg {
    Dictated,
    Now,
}

pub struct Sync {
    ctx: Arc<Context>,
    totals: Mutex<TotalsSync>,
    tx: Mutex<Sender<Msg>>,
    status: Mutex<String>,
}

/// This computer's name, for a sync.env that does not give one.
pub fn device_name() -> String {
    linflow_platform::computer_name()
}

impl Sync {
    pub fn start(ctx: Arc<Context>) -> Arc<Sync> {
        let (tx, rx) = mpsc::channel();
        let s = Arc::new(Sync { ctx, totals: Mutex::new(TotalsSync::new()), tx: Mutex::new(tx), status: Mutex::new("Off: no sync.env in the data folder.".into()) });
        let me = s.clone();
        std::thread::Builder::new()
            .name("linflow.sync".into())
            .spawn(move || {
                // A moment after launch, so the model and the window come first.
                std::thread::sleep(Duration::from_secs(20));
                me.run_all();
                loop {
                    match rx.recv_timeout(EVERY) {
                        Ok(Msg::Dictated) => me.push_totals(),
                        Ok(Msg::Now) | Err(RecvTimeoutError::Timeout) => me.run_all(),
                        Err(RecvTimeoutError::Disconnected) => return,
                    }
                }
            })
            .expect("sync thread");
        s
    }

    pub fn dictated(&self) {
        let _ = self.tx.lock().map(|t| t.send(Msg::Dictated));
    }

    pub fn now(&self) {
        let _ = self.tx.lock().map(|t| t.send(Msg::Now));
    }

    pub fn status(&self) -> String {
        self.status.lock().unwrap().clone()
    }

    fn config(&self) -> Option<SyncConfig> {
        let (config, problem) = SyncConfig::read(&self.ctx.data_dir.join(FILE_NAME), &device_name());
        if let Some(p) = problem {
            self.set_status(format!("Off: {p}"));
        }
        config
    }

    fn set_status(&self, text: String) {
        *self.status.lock().unwrap() = text.clone();
        self.ctx.emit(Event::Sync { status: text });
    }

    fn run_all(&self) {
        let Some(config) = self.config() else { return };
        match dictionary::sync(&config, &Files::in_dir(&self.ctx.data_dir), self.ctx.net.as_ref(), chrono::Utc::now()) {
            Ok(report) => {
                for line in &report.lines {
                    log::info!("{line}");
                }
                if report.files_changed {
                    self.ctx.emit(Event::DictionaryChanged);
                }
            }
            Err(e) => log::warn!("{e}"),
        }
        self.push_totals();
        let line = self.totals.lock().unwrap().pull(&config, chrono::Utc::now(), self.ctx.net.as_ref());
        if let Some(line) = line {
            log::info!("{line}");
        }
        self.report(&config);
    }

    fn push_totals(&self) {
        let Some(config) = self.config() else { return };
        let history = self.ctx.history.all();
        let line = self.totals.lock().unwrap().push(&config, &history, &chrono::Local, chrono::Utc::now(), self.ctx.net.as_ref());
        if let Some(line) = line {
            log::info!("{line}");
        }
        self.report(&config);
        self.ctx.emit(Event::HistoryChanged);
    }

    fn report(&self, config: &SyncConfig) {
        let status = self.totals.lock().unwrap().status.clone();
        let text = match (status.error, status.last_sync) {
            (Some(e), _) => format!("On as {}, but the last sync failed: {e}", config.device),
            (None, Some(at)) => format!("On as {}. Last synced {}.", config.device, at.with_timezone(&chrono::Local).format("%-I:%M %p")),
            (None, None) => format!("On as {}.", config.device),
        };
        self.set_status(text);
    }

    /// Every computer's totals, once the first read has come back.
    pub fn combined(&self) -> Option<CombinedTotals> {
        let config = self.config()?;
        self.totals.lock().unwrap().combined(&config, &self.ctx.history.all(), &chrono::Local, chrono::Utc::now())
    }
}
