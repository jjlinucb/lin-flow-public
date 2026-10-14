//! What every part of the service shares: the data folder's stores, the settings, the speech
//! model, the network, and the way out to the window.

use crate::dictionary::Dictionary;
use crate::engine::EngineSlot;
use crate::events::{Event, Sink, Toast};
use linflow_core::history::History;
use linflow_core::hotkey::{Hotkey, Platform};
use linflow_core::net::{Transport, Ureq};
use linflow_core::notes::NotesStore;
use linflow_core::settings::{Settings, SettingsFile};
use linflow_platform::Sound;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

pub struct Context {
    pub data_dir: PathBuf,
    pub events: Sink,
    pub settings: Mutex<SettingsFile>,
    pub dictionary: Dictionary,
    pub history: History,
    pub notes: NotesStore,
    pub engine: Arc<EngineSlot>,
    pub net: Arc<dyn Transport>,
}

/// The talk key when none is set. Beside the installed Lin Flow, which answers to Fn on the Mac
/// and Left Ctrl + Left Alt on Windows, Lin Flow Next must answer to something else or both
/// would dictate at once: Right Option on the Mac, Right Alt on Windows. From cutover, when this
/// app takes over the "Lin Flow" folder, the defaults are the installed app's again.
pub fn default_hotkey() -> Hotkey {
    let p = Platform::current();
    if linflow_core::paths::APP_FOLDER == "Lin Flow Next" {
        return Hotkey::parse("rightOption", p).unwrap_or_else(|| Hotkey::default_for(p));
    }
    Hotkey::default_for(p)
}

impl Context {
    pub fn new(data_dir: PathBuf, events: Sink) -> Arc<Context> {
        let _ = std::fs::create_dir_all(&data_dir);
        Arc::new(Context {
            settings: Mutex::new(SettingsFile::load(&data_dir.join("settings.json"))),
            dictionary: Dictionary::new(&data_dir, events.clone()),
            history: History::new(&data_dir),
            notes: NotesStore::new(&data_dir),
            engine: Arc::new(EngineSlot::default()),
            net: Arc::new(Ureq),
            data_dir,
            events,
        })
    }

    pub fn settings(&self) -> Settings {
        self.settings.lock().map(|s| s.values.clone()).unwrap_or_default()
    }

    /// Changes the settings, saves them, and tells the window.
    pub fn update_settings(&self, change: impl FnOnce(&mut Settings)) {
        if let Ok(mut file) = self.settings.lock() {
            change(&mut file.values);
            if let Err(e) = file.save() {
                log::warn!("settings: could not save: {e}");
            }
        }
        self.emit(Event::SettingsChanged);
    }

    pub fn hotkey(&self) -> Hotkey {
        let raw = self.settings().hotkey;
        if raw.is_empty() {
            default_hotkey()
        } else {
            Hotkey::load(&raw, Platform::current())
        }
    }

    pub fn emit(&self, event: Event) {
        (self.events)(event);
    }

    pub fn toast(&self, toast: Toast) {
        self.emit(Event::Toast { toast });
    }

    pub fn sound(&self, sound: Sound) {
        if self.settings().sounds {
            linflow_platform::play_sound(sound);
        }
    }
}
