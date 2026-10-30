//! What the service tells whatever draws it: the pill and tray state, the meter, new dictations,
//! toasts, and everything a meeting does. Serialized as JSON for the window, one shape for both
//! computers.

use linflow_core::history::HistoryEntry;
use linflow_core::notes::TranscriptSegment;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

/// Where dictation stands, as the pill shows it.
#[derive(Clone, Debug, PartialEq)]
pub enum DictationState {
    Loading(String),
    Downloading(String, f64),
    Idle,
    Recording,
    Transcribing,
    Error(String),
}

impl DictationState {
    pub fn label(&self) -> String {
        match self {
            DictationState::Loading(what) => format!("Loading {what}…"),
            DictationState::Downloading(id, p) => format!("Downloading {id} {}%", (p * 100.0) as u32),
            DictationState::Idle => "Lin Flow".into(),
            DictationState::Recording => "Recording…".into(),
            DictationState::Transcribing => "Transcribing…".into(),
            DictationState::Error(msg) => format!("Error: {msg}"),
        }
    }

    /// One word for the pill's color: loading, idle, recording, working or error.
    pub fn phase(&self) -> &'static str {
        match self {
            DictationState::Loading(_) | DictationState::Downloading(..) => "loading",
            DictationState::Idle => "idle",
            DictationState::Recording => "recording",
            DictationState::Transcribing => "working",
            DictationState::Error(_) => "error",
        }
    }
}

/// What clicking a toast does.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ToastAction {
    /// Open the Dictionary, where a learned or suggested rule can be changed.
    OpenDictionary,
    /// Add the rule an edit suggested.
    AddRule { from: String, to: String },
    /// Start a meeting note for the call that just began.
    RecordMeeting { app: String, name: String },
    /// The call ended: keep the note recording anyway.
    KeepRecording,
    /// Stop the meeting note now.
    StopNote,
    /// Write and open the script that restarts the computer's audio.
    RepairAudio,
    /// Open the Notetaker at the note.
    OpenNote { id: String },
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Toast {
    pub id: u64,
    pub title: String,
    pub detail: String,
    pub warning: bool,
    pub seconds: f64,
    pub action: Option<ToastAction>,
    /// A second, quieter button, such as "Keep recording" beside a countdown.
    pub button: Option<(String, ToastAction)>,
}

static TOAST_IDS: AtomicU64 = AtomicU64::new(1);

impl Toast {
    pub fn new(title: impl Into<String>, detail: impl Into<String>) -> Toast {
        Toast { id: TOAST_IDS.fetch_add(1, Ordering::Relaxed), title: title.into(), detail: detail.into(), warning: false, seconds: 6.0, action: None, button: None }
    }

    pub fn warning(mut self) -> Toast {
        self.warning = true;
        self
    }

    pub fn seconds(mut self, s: f64) -> Toast {
        self.seconds = s;
        self
    }

    pub fn on_click(mut self, action: ToastAction) -> Toast {
        self.action = Some(action);
        self
    }

    pub fn button(mut self, label: &str, action: ToastAction) -> Toast {
        self.button = Some((label.into(), action));
        self
    }
}

/// What a meeting note did.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum NoteEvent {
    /// The note list changed: one created, renamed, deleted, recorded.
    Listed,
    Recording { id: String, recording: bool },
    Segment { id: String, segment: TranscriptSegment },
    /// The transcript was replaced as a whole: the pass over the recording, or a relabel.
    Transcript { id: String },
    /// Each side's level, a few times a second while recording.
    Levels { mic: f32, system: f32 },
    RunningNotes { id: String, text: String },
    /// The call tracker changed: a pass added to it, or John ticked something off.
    Tracker { id: String, tracker: linflow_core::meeting::tracker::Tracker },
    /// Running notes cannot run during this recording: no local model and no Claude key.
    RunningNotesOff { id: String, why: String },
    /// Work in progress on a note, such as "From the recording: You 3/12", or None when done.
    Status { id: String, text: Option<String> },
    Summary { id: String, text: String },
    Recap { id: String, sentence: String },
    Answer { id: String },
    Error { text: String },
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    State { phase: String, label: String },
    Level { level: f32 },
    Dictated { entry: HistoryEntry },
    HistoryChanged,
    DictionaryChanged,
    SettingsChanged,
    Toast { toast: Toast },
    Note { event: NoteEvent },
    Sync { status: String },
    /// Settings' Record button caught a talk key, or None when it was cancelled.
    HotkeyRecorded { raw: Option<String>, label: Option<String> },
}

impl Event {
    pub fn state(s: &DictationState) -> Event {
        Event::State { phase: s.phase().into(), label: s.label() }
    }
}

/// Hands events to whatever draws them. Called from many threads.
pub type Sink = Arc<dyn Fn(Event) + Send + Sync>;
