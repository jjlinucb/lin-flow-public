//! Knowing when a meeting starts and ends, from which apps hold the microphone.
//!
//! John, 2026-10-02: the first Zoom note worked, but nothing offered to record when the call
//! began, and when the call ended ("okay bye", then Zoom closed) the note kept recording until he
//! stopped it by hand. Every call app opens the microphone for the length of the call, muted or
//! not, and lets go of it when the call ends, so the operating system's list of apps using the
//! microphone is the signal: the Mac's audio process objects, Windows' capability access store.
//! This half has no clock and no OS calls: the platform reports what it sees every few seconds
//! and the detector says what to offer.

use std::collections::HashMap;

/// What the platform saw at one moment.
#[derive(Clone, Debug, PartialEq)]
pub struct Observation {
    /// Seconds on any steady clock.
    pub at: f64,
    /// Apps holding the microphone right now, by bundle id (Mac) or executable name (Windows).
    pub mic_users: Vec<String>,
    /// A meeting note is recording, and the app it was offered for, if any.
    pub recording: Option<Recording>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Recording {
    /// The call app the note was started for, when it was started from an offer.
    pub app: Option<String>,
    /// Seconds since either side last had speech above its threshold.
    pub quiet_for: f64,
    /// Seconds each side has delivered nothing but digital zeros.
    pub mic_dead_for: f64,
    pub system_dead_for: f64,
    /// Seconds since the microphone last had speech, so a silent far side is only flagged while
    /// John is talking.
    pub mic_spoke_ago: f64,
    pub seconds: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// A call app has held the microphone long enough to be a call: offer to record.
    OfferToRecord { app: String, name: String },
    /// The app the note was started for let go of the microphone: the call ended. The app stops
    /// the note after `grace` seconds unless John keeps it going.
    CallEnded { app: String, name: String, grace: f64 },
    /// No speech on either side for a long while: offer to stop.
    LongSilence { minutes: u32 },
    /// The microphone is sending digital zeros: a dead input, not a quiet room.
    MicrophoneDead,
    /// The call's audio is digital zeros while John talks: the call is playing somewhere the
    /// recording cannot hear, or the system audio capture failed.
    CallAudioMissing,
}

/// Call apps by the ids the platforms report, with the name John sees.
pub const CALL_APPS: &[(&str, &str)] = &[
    ("us.zoom.xos", "Zoom"),
    ("zoom.exe", "Zoom"),
    ("com.microsoft.teams2", "Teams"),
    ("com.microsoft.teams", "Teams"),
    ("ms-teams.exe", "Teams"),
    ("teams.exe", "Teams"),
    ("com.cisco.webexmeetingsapp", "Webex"),
    ("ciscocollabhost.exe", "Webex"),
    ("webexmta.exe", "Webex"),
    ("com.apple.facetime", "FaceTime"),
    ("com.apple.avconferenced", "FaceTime"),
    ("com.tinyspeck.slackmacgap", "Slack"),
    ("slack.exe", "Slack"),
    ("com.hnc.discord", "Discord"),
    ("discord.exe", "Discord"),
    ("com.google.chrome", "Chrome"),
    ("chrome.exe", "Chrome"),
    ("com.microsoft.edgemac", "Edge"),
    ("msedge.exe", "Edge"),
    ("com.apple.safari", "Safari"),
    ("org.mozilla.firefox", "Firefox"),
    ("firefox.exe", "Firefox"),
    ("company.thebrowser.browser", "Arc"),
    ("com.brave.browser", "Brave"),
    ("brave.exe", "Brave"),
];

/// Apps that open the microphone to dictate, not to call, Lin Flow included.
pub const NOT_CALLS: &[&str] = &["com.johnlin.linflow", "com.johnlin.linflow.next", "linflow.exe", "lin flow.exe", "com.electron.wispr-flow", "wispr flow.exe", "com.superduper.superwhisper"];

pub fn call_app_name(id: &str) -> Option<&'static str> {
    let id = id.to_lowercase();
    if NOT_CALLS.contains(&id.as_str()) {
        return None;
    }
    CALL_APPS.iter().find(|(k, _)| *k == id).map(|(_, n)| *n)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Tuning {
    /// A call app holding the microphone this long is a call, not a sound check.
    pub offer_after: f64,
    /// The call app gone from the microphone this long means the call ended, not a device switch.
    pub ended_after: f64,
    /// What the app waits, with a "keep recording" button, before it stops the note.
    pub stop_grace: f64,
    /// Both sides quiet this long: offer to stop.
    pub long_silence: f64,
    pub mic_dead_after: f64,
    pub call_audio_dead_after: f64,
}

impl Default for Tuning {
    fn default() -> Self {
        Tuning { offer_after: 8.0, ended_after: 6.0, stop_grace: 15.0, long_silence: 300.0, mic_dead_after: 20.0, call_audio_dead_after: 90.0 }
    }
}

#[derive(Default)]
pub struct MeetingDetector {
    pub tuning: Tuning,
    /// When each app was first seen holding the microphone in its current run.
    since: HashMap<String, f64>,
    /// Apps already offered in their current run: one offer per call, never a nag.
    offered: HashMap<String, bool>,
    /// When the recording's app was last seen on the microphone.
    app_last_seen: Option<f64>,
    ended_sent: bool,
    silence_sent: bool,
    mic_dead_sent: bool,
    call_audio_sent: bool,
}

impl MeetingDetector {
    pub fn new(tuning: Tuning) -> Self {
        MeetingDetector { tuning, ..Default::default() }
    }

    pub fn observe(&mut self, o: &Observation) -> Vec<Event> {
        let mut events = vec![];
        let users: Vec<String> = o.mic_users.iter().map(|u| u.to_lowercase()).collect();
        self.since.retain(|app, _| users.contains(app));
        self.offered.retain(|app, _| users.contains(app));
        for app in &users {
            self.since.entry(app.clone()).or_insert(o.at);
        }

        match &o.recording {
            None => {
                self.app_last_seen = None;
                self.ended_sent = false;
                self.silence_sent = false;
                self.mic_dead_sent = false;
                self.call_audio_sent = false;
                // The longest-running call app first, so a browser tab does not win over Zoom.
                let mut candidates: Vec<(&String, f64)> =
                    users.iter().filter_map(|app| call_app_name(app).map(|_| (app, self.since[app]))).collect();
                candidates.sort_by(|a, b| a.1.total_cmp(&b.1));
                if let Some((app, since)) = candidates.first() {
                    if o.at - since >= self.tuning.offer_after && !self.offered.contains_key(*app) {
                        self.offered.insert((*app).clone(), true);
                        events.push(Event::OfferToRecord { app: (*app).clone(), name: call_app_name(app).unwrap().into() });
                    }
                }
            }
            Some(rec) => {
                // Whatever is recording, nothing is offered again for the apps on the mic now.
                for app in &users {
                    self.offered.insert(app.clone(), true);
                }
                if let Some(app) = rec.app.as_ref().map(|a| a.to_lowercase()) {
                    if users.contains(&app) {
                        self.app_last_seen = Some(o.at);
                        self.ended_sent = false;
                    } else {
                        let last = *self.app_last_seen.get_or_insert(o.at);
                        if !self.ended_sent && o.at - last >= self.tuning.ended_after {
                            self.ended_sent = true;
                            events.push(Event::CallEnded { name: call_app_name(&app).unwrap_or("The call").into(), app, grace: self.tuning.stop_grace });
                        }
                    }
                }
                if rec.quiet_for >= self.tuning.long_silence {
                    if !self.silence_sent {
                        self.silence_sent = true;
                        events.push(Event::LongSilence { minutes: (rec.quiet_for / 60.0) as u32 });
                    }
                } else {
                    self.silence_sent = false;
                }
                if rec.mic_dead_for >= self.tuning.mic_dead_after && !self.mic_dead_sent {
                    self.mic_dead_sent = true;
                    events.push(Event::MicrophoneDead);
                }
                if rec.mic_dead_for == 0.0 {
                    self.mic_dead_sent = false;
                }
                if rec.system_dead_for >= self.tuning.call_audio_dead_after && rec.mic_spoke_ago < 30.0 && !self.call_audio_sent {
                    self.call_audio_sent = true;
                    events.push(Event::CallAudioMissing);
                }
                if rec.system_dead_for == 0.0 {
                    self.call_audio_sent = false;
                }
            }
        }
        events
    }
}

/// What a finished note says about itself, for the recap and for proof that both sides were
/// heard: how much each side spoke and what the summary found.
#[derive(Clone, Debug, PartialEq)]
pub struct Recap {
    pub minutes: u32,
    pub you_seconds: f64,
    pub others_seconds: f64,
    pub you_lines: usize,
    pub others_lines: usize,
    pub action_items: usize,
    pub decisions: usize,
}

impl Recap {
    pub fn of(duration: f64, segments: &[crate::notes::TranscriptSegment], summary: Option<&str>) -> Recap {
        let side = |who: &str| segments.iter().filter(|s| s.speaker == who).fold((0.0, 0), |(t, n), s| (t + (s.end - s.start).max(0.0), n + 1));
        let (you_seconds, you_lines) = side(super::YOU);
        let (others_seconds, others_lines) = side(super::OTHERS);
        let count = |heading: &str| {
            summary.map_or(0, |s| {
                s.split("\n## ")
                    .find(|sec| sec.trim_start_matches("## ").starts_with(heading))
                    .map_or(0, |sec| sec.lines().skip(1).filter(|l| (l.starts_with("* ") || l.starts_with("- ")) && !l[2..].trim().eq_ignore_ascii_case("none")).count())
            })
        };
        Recap { minutes: (duration / 60.0).round() as u32, you_seconds, others_seconds, you_lines, others_lines, action_items: count("Action items"), decisions: count("Decisions") }
    }

    /// "29 min. You spoke 4 min, the others 19. 3 action items, 1 decision."
    pub fn sentence(&self) -> String {
        let mins = |s: f64| (s / 60.0).round() as u32;
        let mut out = format!("{} min. You spoke {} min, the others {}.", self.minutes, mins(self.you_seconds), mins(self.others_seconds));
        if self.others_lines == 0 {
            out.push_str(" Nothing was heard from the other side.");
        }
        let plural = |n: usize, one: &str, many: &str| format!("{n} {}", if n == 1 { one } else { many });
        if self.action_items + self.decisions > 0 {
            out.push_str(&format!(" {}, {}.", plural(self.action_items, "action item", "action items"), plural(self.decisions, "decision", "decisions")));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obs(at: f64, users: &[&str], recording: Option<Recording>) -> Observation {
        Observation { at, mic_users: users.iter().map(|s| s.to_string()).collect(), recording }
    }

    fn rec(app: Option<&str>) -> Recording {
        Recording { app: app.map(String::from), quiet_for: 0.0, mic_dead_for: 0.0, system_dead_for: 0.0, mic_spoke_ago: 0.0, seconds: 60.0 }
    }

    #[test]
    fn a_zoom_call_is_offered_once_and_its_end_is_noticed() {
        let mut d = MeetingDetector::new(Tuning::default());
        assert!(d.observe(&obs(0.0, &["us.zoom.xos"], None)).is_empty());
        assert!(d.observe(&obs(5.0, &["us.zoom.xos"], None)).is_empty(), "a sound check is not a call");
        assert_eq!(d.observe(&obs(9.0, &["us.zoom.xos"], None)), vec![Event::OfferToRecord { app: "us.zoom.xos".into(), name: "Zoom".into() }]);
        assert!(d.observe(&obs(30.0, &["us.zoom.xos"], None)).is_empty(), "declined: no nagging");
        assert!(d.observe(&obs(31.0, &["us.zoom.xos"], Some(rec(Some("us.zoom.xos"))))).is_empty());
        assert!(d.observe(&obs(38.0, &["us.zoom.xos"], Some(rec(Some("us.zoom.xos"))))).is_empty());
        assert!(d.observe(&obs(40.0, &[], Some(rec(Some("us.zoom.xos"))))).is_empty(), "a device switch is not an ending");
        assert_eq!(
            d.observe(&obs(47.0, &[], Some(rec(Some("us.zoom.xos"))))),
            vec![Event::CallEnded { app: "us.zoom.xos".into(), name: "Zoom".into(), grace: 15.0 }]
        );
        assert!(d.observe(&obs(50.0, &[], Some(rec(Some("us.zoom.xos"))))).is_empty(), "said once");
    }

    #[test]
    fn dictation_apps_are_not_calls_and_a_new_call_is_offered_again() {
        let mut d = MeetingDetector::new(Tuning::default());
        assert!(d.observe(&obs(0.0, &["com.electron.wispr-flow", "com.johnlin.linflow"], None)).is_empty());
        assert!(d.observe(&obs(30.0, &["com.electron.wispr-flow", "com.johnlin.linflow"], None)).is_empty());
        d.observe(&obs(31.0, &["ms-teams.exe"], None));
        assert_eq!(d.observe(&obs(40.0, &["ms-teams.exe"], None)).len(), 1);
        d.observe(&obs(41.0, &[], None));
        d.observe(&obs(100.0, &["MS-Teams.exe"], None));
        assert_eq!(d.observe(&obs(110.0, &["MS-Teams.exe"], None)).len(), 1, "the next call is a new offer");
    }

    #[test]
    fn silence_and_dead_sides_are_reported_once() {
        let mut d = MeetingDetector::new(Tuning::default());
        let mut r = rec(None);
        r.quiet_for = 301.0;
        r.mic_dead_for = 25.0;
        r.system_dead_for = 95.0;
        r.mic_spoke_ago = 5.0;
        let e = d.observe(&obs(0.0, &[], Some(r.clone())));
        assert_eq!(e, vec![Event::LongSilence { minutes: 5 }, Event::MicrophoneDead, Event::CallAudioMissing]);
        assert!(d.observe(&obs(5.0, &[], Some(r.clone()))).is_empty());
        r.system_dead_for = 95.0;
        r.mic_spoke_ago = 120.0;
        let mut d2 = MeetingDetector::new(Tuning::default());
        r.quiet_for = 0.0;
        r.mic_dead_for = 0.0;
        assert!(d2.observe(&obs(0.0, &[], Some(r))).is_empty(), "a silent far side while John is quiet is just a quiet call");
    }

    #[test]
    fn the_recap_counts_both_sides_and_the_summary() {
        use crate::notes::TranscriptSegment;
        let segs = vec![TranscriptSegment::new(0.0, 60.0, "Others", "a"), TranscriptSegment::new(60.0, 90.0, "You", "b"), TranscriptSegment::new(90.0, 210.0, "Others", "c")];
        let summary = "## Summary\n* x\n\n## Decisions\n* None\n\n## Action items\n* Ted calls\n* John sends\n\n## Open questions\n* None";
        let r = Recap::of(1762.0, &segs, Some(summary));
        assert_eq!((r.minutes, r.action_items, r.decisions, r.others_lines), (29, 2, 0, 2));
        assert_eq!(r.sentence(), "29 min. You spoke 1 min, the others 3. 2 action items, 0 decisions.");
        assert!(Recap::of(60.0, &segs[1..2], None).sentence().contains("Nothing was heard from the other side"));
    }
}
