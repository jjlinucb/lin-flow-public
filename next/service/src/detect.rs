//! Watches which apps hold the microphone and turns what the core's `MeetingDetector` says into
//! toasts: an offer to record when a call starts, a countdown when the call it was recording
//! ends, and alarms when one side of a recording goes silent.

use crate::context::Context;
use crate::events::{Toast, ToastAction};
use crate::meeting::Meetings;
use linflow_core::meeting::detect::{Event as Detected, MeetingDetector, Observation, Tuning};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// How often the microphone's users are read.
pub const POLL: Duration = Duration::from_secs(2);

pub struct Detection {
    ctx: Arc<Context>,
    meetings: Arc<Meetings>,
    /// When the note for a call that ended stops, unless John keeps it going.
    stop_at: Mutex<Option<(Instant, String)>>,
}

impl Detection {
    pub fn start(ctx: Arc<Context>, meetings: Arc<Meetings>) -> Arc<Detection> {
        let d = Arc::new(Detection { ctx, meetings, stop_at: Mutex::new(None) });
        let me = d.clone();
        std::thread::Builder::new().name("linflow.detect".into()).spawn(move || me.run()).expect("detect thread");
        d
    }

    /// The "Keep recording" button on the call-ended toast.
    pub fn keep_recording(&self) {
        if self.stop_at.lock().unwrap().take().is_some() {
            log::info!("detect: keeping the note recording after the call ended");
        }
    }

    fn run(self: Arc<Self>) {
        let mut detector = MeetingDetector::new(Tuning::default());
        let clock = Instant::now();
        loop {
            std::thread::sleep(POLL);
            // A countdown that ran out stops the note it was for.
            let due = {
                let mut slot = self.stop_at.lock().unwrap();
                match slot.as_ref() {
                    Some((at, id)) if Instant::now() >= *at => {
                        let id = id.clone();
                        *slot = None;
                        Some(id)
                    }
                    _ => None,
                }
            };
            if let Some(id) = due {
                if self.meetings.recording_id().as_deref() == Some(id.as_str()) {
                    log::info!("detect: the call ended; stopping the note");
                    self.meetings.stop(false);
                }
            }
            let recording = self.meetings.observed();
            if recording.is_none() {
                *self.stop_at.lock().unwrap() = None;
            }
            let observation = Observation { at: clock.elapsed().as_secs_f64(), mic_users: linflow_platform::mic_users(), recording };
            for event in detector.observe(&observation) {
                self.handle(event);
            }
        }
    }

    fn handle(&self, event: Detected) {
        log::info!("detect: {event:?}");
        match event {
            Detected::OfferToRecord { app, name } => {
                if !self.ctx.settings().offer_meeting_notes {
                    return;
                }
                self.ctx.toast(
                    Toast::new(format!("{name} is using the microphone"), "Record a meeting note? Click to start.")
                        .seconds(20.0)
                        .on_click(ToastAction::RecordMeeting { app, name }),
                );
            }
            Detected::CallEnded { app: _, name, grace } => {
                let Some(id) = self.meetings.recording_id() else { return };
                *self.stop_at.lock().unwrap() = Some((Instant::now() + Duration::from_secs_f64(grace), id));
                self.ctx.toast(
                    Toast::new(format!("{name} let go of the microphone"), format!("The call looks over. The note stops in {} seconds.", grace as u32))
                        .seconds(grace)
                        .on_click(ToastAction::StopNote)
                        .button("Keep recording", ToastAction::KeepRecording),
                );
            }
            Detected::LongSilence { minutes } => {
                self.ctx.toast(Toast::new(format!("Nobody has spoken for {minutes} minutes"), "Click to stop the meeting note.").seconds(30.0).on_click(ToastAction::StopNote));
            }
            Detected::MicrophoneDead => {
                self.ctx.toast(
                    Toast::new("Your microphone is sending silence", "Check that it is not muted. The call's side keeps recording.").warning().seconds(15.0),
                );
            }
            Detected::CallAudioMissing => {
                let output = linflow_platform::mic::default_output_name().unwrap_or_else(|| "the speakers".into());
                self.ctx.toast(
                    Toast::new("Nothing is coming from the call", format!("Lin Flow hears you but not the others. Check that the call plays through {output}.")).warning().seconds(15.0),
                );
            }
        }
    }
}
