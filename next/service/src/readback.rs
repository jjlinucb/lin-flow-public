//! Reads back the field Lin Flow just pasted into, so a fix typed by hand becomes a dictionary
//! correction. What a reading means (found the field, an edit has settled, a newer dictation in
//! the same box) is decided by the core's `Watch`; this finds the field, reads it and keeps time.
//!
//! Everything runs on one thread of its own: one read of a busy app can take the whole
//! Accessibility or UI Automation timeout, and neither the talk key nor the window may wait on
//! that, and Windows' reader must stay on the thread that made it.

use crate::context::Context;
use linflow_core::learn::LearnMode;
use linflow_core::readback::{self, Paste, Step, Watch, MAX_LIVE};
use linflow_platform::{Field, FieldReader};
use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

enum Msg {
    Watch { wrote: String, pid: u32, app: String, mode: LearnMode },
}

pub struct Readback {
    tx: Mutex<Sender<Msg>>,
}

struct Live {
    watch: Watch,
    field: Option<Field>,
    pid: u32,
    app: String,
    mode: LearnMode,
    timeouts_at_start: usize,
    retired: bool,
}

/// A look due at `due`: the watch it belongs to, how far into the window, and whether it is
/// the window's last.
struct Look {
    due: Instant,
    order: u64,
    live: usize,
    last: bool,
}

impl PartialEq for Look {
    fn eq(&self, other: &Self) -> bool {
        (self.due, self.order) == (other.due, other.order)
    }
}
impl Eq for Look {}
impl PartialOrd for Look {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Look {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        (self.due, self.order).cmp(&(other.due, other.order))
    }
}

impl Readback {
    pub fn new(ctx: Arc<Context>) -> Arc<Readback> {
        let (tx, rx) = mpsc::channel();
        std::thread::Builder::new().name("linflow.readback".into()).spawn(move || run(ctx, rx)).expect("readback thread");
        Arc::new(Readback { tx: Mutex::new(tx) })
    }

    /// Watches the field `app` (process `pid`) just took the paste in, for the next 15 s.
    pub fn watch(&self, pasted: &str, pid: u32, app: &str, mode: LearnMode) {
        let wrote = pasted.trim();
        if wrote.is_empty() || mode == LearnMode::Off {
            return;
        }
        if let Ok(tx) = self.tx.lock() {
            let _ = tx.send(Msg::Watch { wrote: wrote.to_string(), pid, app: app.to_string(), mode });
        }
    }
}

fn run(ctx: Arc<Context>, rx: Receiver<Msg>) {
    let mut reader: Option<FieldReader> = None;
    let mut reader_failed = false;
    let mut lives: Vec<Live> = Vec::new();
    let mut pastes: Vec<Paste> = Vec::new();
    let mut seq: u64 = 0;
    let mut order: u64 = 0;
    let mut queue: BinaryHeap<Reverse<Look>> = BinaryHeap::new();
    loop {
        let wait = queue.peek().map(|Reverse(l)| l.due.saturating_duration_since(Instant::now()));
        let msg = match wait {
            Some(d) if d.is_zero() => None,
            Some(d) => match rx.recv_timeout(d) {
                Ok(m) => Some(m),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => return,
            },
            None => match rx.recv() {
                Ok(m) => Some(m),
                Err(_) => return,
            },
        };
        if let Some(Msg::Watch { wrote, pid, app, mode }) = msg {
            if reader.is_none() && !reader_failed {
                match FieldReader::new() {
                    Ok(r) => reader = Some(r),
                    Err(why) => {
                        // Once, not per dictation: nothing can be learned until a restart.
                        reader_failed = true;
                        log::info!("readback: {why}; nothing can be learned from an edit");
                    }
                }
            }
            let Some(r) = reader.as_ref() else { continue };
            // Chromium and Electron build their tree only once asked: ask now, at the paste.
            r.prime(pid);
            seq += 1;
            pastes.push(Paste { seq, text: wrote.clone() });
            if pastes.len() > 8 {
                pastes.remove(0);
            }
            lives.push(Live { watch: Watch::new(&wrote, seq), field: None, pid, app: format!("{app} (pid {pid})"), mode, timeouts_at_start: r.timeouts(), retired: false });
            let index = lives.len() - 1;
            // Past MAX_LIVE at once the oldest still watching is retired.
            let watching: Vec<usize> = lives.iter().enumerate().filter(|(_, l)| !l.retired).map(|(i, _)| i).collect();
            if watching.len() > MAX_LIVE {
                retire(&mut lives[watching[0]]);
            }
            let now = Instant::now();
            let delays = readback::schedule();
            for (i, d) in delays.iter().enumerate() {
                order += 1;
                queue.push(Reverse(Look { due: now + Duration::from_secs_f64(*d), order, live: index, last: i == delays.len() - 1 }));
            }
            continue;
        }
        // A look is due.
        let Some(Reverse(look)) = queue.pop() else { continue };
        let Some(r) = reader.as_ref() else { continue };
        look_once(&ctx, r, &mut lives[look.live], &pastes, look.last);
        // Once every watch is over, the list starts again, so indices stay small.
        if queue.is_empty() && lives.iter().all(|l| l.retired) {
            lives.clear();
        }
    }
}

fn retire(live: &mut Live) {
    live.watch.done = true;
    live.field = None;
    live.retired = true;
}

fn look_once(ctx: &Context, reader: &FieldReader, live: &mut Live, pastes: &[Paste], last: bool) {
    if !live.watch.done {
        // The anchored field once there is one, the focused one until then.
        let (field, anchored) = match live.field.take() {
            Some(f) => (Some(f), true),
            None => (reader.focused(live.pid), false),
        };
        let Some(field) = field else {
            if last {
                log::info!("readback: no focused element in {}; nothing can be learned from an edit here", live.app);
            }
            finish(reader, live, last);
            return;
        };
        let mut keep = anchored;
        if let Some(text) = reader.text(&field) {
            match live.watch.look(Some(&text), pastes, last) {
                Step::Anchored => {
                    log::info!("readback: found the pasted text in {}", live.app);
                    keep = true;
                }
                Step::StandDown => {
                    log::info!("readback: a newer dictation landed in this field; standing down");
                    retire(live);
                }
                Step::Offer(now) => {
                    let learned = ctx.dictionary.learn(&live.watch.wrote, &now, live.mode);
                    let taught = !learned.outcome.is_empty();
                    live.watch.answer(taught);
                    if taught {
                        retire(live);
                    }
                }
                Step::Finished(why) => log::info!("readback: {why}"),
                Step::Wait => {}
            }
        }
        if keep && !live.retired {
            live.field = Some(field);
        }
    }
    finish(reader, live, last);
}

fn finish(reader: &FieldReader, live: &mut Live, last: bool) {
    if last {
        let slow = reader.timeouts().saturating_sub(live.timeouts_at_start);
        if slow > 0 {
            log::info!("readback: {slow} read(s) got no answer in time");
        }
        retire(live);
    }
}
