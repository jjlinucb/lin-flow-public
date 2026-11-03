//! The notetaker's logic, with no audio device and no model in it: where the speech is in a
//! recording, how the live transcript cuts a stream, which microphone lines are the speakers'
//! echo, and how running notes and summaries are filtered and merged. A speech engine comes in
//! through `Recognizer`, a language model through `summary::NoteModel`.

pub mod detect;
pub mod echo;
pub mod live;
pub mod merge;
pub mod regions;
pub mod running;
pub mod summary;
pub mod tracker;

/// A speech engine as the notetaker sees it: 16 kHz mono in, text out.
pub trait Recognizer {
    fn recognize(&mut self, samples: &[f32]) -> Result<String, String>;
}

/// The microphone's speaker.
pub const YOU: &str = "You";
/// The system audio's speaker: everyone else on the call.
pub const OTHERS: &str = "Others";
/// A note's two tracks, as file stem and speaker.
pub const SOURCES: [(&str, &str); 2] = [("mic", YOU), ("system", OTHERS)];
