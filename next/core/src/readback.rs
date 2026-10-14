//! Reading back the field Lin Flow just pasted into, so a fix John types by hand can become a
//! dictionary correction. This is the pure half: when to look, how to find the pasted phrase in
//! what the field holds now, and the watch that decides when an edit has settled. Each platform
//! reads the focused text element (Accessibility on the Mac, UI Automation on Windows) and hands
//! the text to a `Watch`.

use crate::text::unicode::{count, graphemes, lowercased, split_graphemes, trim_ws_nl};
use std::collections::HashSet;

/// How long to keep watching after a paste, and how often to look. The window is long because
/// noticing a wrong word takes far longer than fixing one; the interval is short because the fix
/// should reach the dictionary while John is still looking at the field.
pub const WATCH_WINDOW: f64 = 15.0;
pub const POLL_INTERVAL: f64 = 0.8;
/// Early looks that only try to find the field, before any edit could have happened. Chromium
/// needs several: its accessibility tree is not there the instant it is asked for.
pub const ANCHOR_DELAYS: [f64; 3] = [0.6, 1.5, 3.0];
/// Past this many fields at once the oldest watch is retired, so a burst cannot pile up.
pub const MAX_LIVE: usize = 3;

/// Every moment after the anchor attempts, one poll apart, plus two past the window so an edit
/// made at the very end still gets the two looks it needs to settle. Counted rather than
/// accumulated: adding 0.8 repeatedly drifts and drops the last look.
pub fn check_delays(window: f64, poll: f64, anchors: &[f64]) -> Vec<f64> {
    if poll <= 0.0 {
        return vec![];
    }
    let start = anchors.last().copied().unwrap_or(0.0) + poll;
    let steps = (((window - start) / poll).round() as i64 + 2).max(0);
    (0..=steps).map(|k| start + k as f64 * poll).collect()
}

/// The whole schedule of looks, in seconds after the paste.
pub fn schedule() -> Vec<f64> {
    let mut d = ANCHOR_DELAYS.to_vec();
    d.extend(check_delays(WATCH_WINDOW, POLL_INTERVAL, &ANCHOR_DELAYS));
    d
}

/// One phrase Lin Flow pasted, and the order it went out in.
#[derive(Clone, Debug, PartialEq)]
pub struct Paste {
    pub seq: u64,
    pub text: String,
}

/// Whether a dictation later than `mine` is now sitting in this field. From there an older watch
/// cannot tell John's typing from the new dictation, and reading one recognizer output as an
/// edit of another learns rules from nothing he did: re-dictating over a selection turned
/// "Let's meet Thursday." into "Let's meet Tuesday.", one word apart.
pub fn superseded(pastes: &[Paste], mine: u64, field_now: &str) -> bool {
    pastes.iter().any(|p| p.seq > mine && field_now.contains(&p.text))
}

fn split_words(s: &str) -> Vec<String> {
    split_graphemes(s, |g| crate::text::unicode::is_whitespace(g) || crate::text::unicode::is_newline(g)).into_iter().map(String::from).collect()
}

/// The pasted phrase as it now reads, or None when it is gone or untouched.
pub fn edited_version(wrote: &str, now: &str) -> Option<String> {
    let current = trim_ws_nl(now);
    if current.is_empty() || current.contains(wrote) {
        return None;
    }
    let wrote_words = split_words(wrote);
    if wrote_words.is_empty() {
        return None;
    }
    // A field holding little more than the dictation: compare the whole thing, but only while it
    // still reads like that dictation. Sending a message empties the field and the app drops its
    // own placeholder in, and a wholesale retype is not a correction either.
    let (wrote_len, current_len) = (count(wrote), count(current));
    if current_len <= (wrote_len * 3).max(200) {
        let current_words = split_words(current);
        if word_distance(&wrote_words, &current_words) <= (wrote_words.len() / 2).max(1) {
            return Some(current.to_string());
        }
        // A short dictation has almost no word budget: fixing a first and last name at once
        // blows it. Characters still separate a fix from a placeholder where words cannot.
        if wrote_len > 2_000 || current_len > 2_000 {
            return None;
        }
        let distance = crate::text::matcher::levenshtein(&lowercased(wrote), &lowercased(current));
        // Three quarters, measured: John's real fixes sit at 0.04 to 0.62 of the shorter string
        // and everything that must be refused sits at 1.00 to 1.93. Re-measure before moving it.
        return (distance * 4 <= wrote_len.min(current_len) * 3).then(|| current.to_string());
    }
    // A longer document: find the phrase by its own words, then take a window around it.
    let words = split_words(current);
    if words.len() > 20_000 {
        return None;
    }
    let width = wrote_words.len() as i64;
    let mut best: Option<(usize, std::ops::Range<usize>)> = None;
    for anchor in anchors(&wrote_words) {
        let Some(offset) = wrote_words.iter().position(|w| *w == anchor) else { continue };
        for (i, w) in words.iter().enumerate() {
            if *w != anchor {
                continue;
            }
            let start = i.saturating_sub(offset);
            for slack in [0i64, -2, -1, 1, 2] {
                let end = (words.len() as i64).min(start as i64 + (width + slack).max(1)) as usize;
                if start >= end {
                    continue;
                }
                let score = word_distance(&wrote_words, &words[start..end]);
                if best.as_ref().is_none_or(|b| score < b.0) {
                    best = Some((score, start..end));
                }
            }
        }
    }
    let (score, range) = best?;
    if score > (width as usize / 2).max(1) {
        return None;
    }
    Some(words[range].join(" "))
}

/// The most distinctive words of the phrase, longest first: the ones most likely to survive an
/// edit and least likely to appear elsewhere in the document.
pub fn anchors(words: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut unique: Vec<String> = words.iter().filter(|w| seen.insert(crate::text::unicode::swift_key(w))).cloned().collect();
    // Swift sorts (count, word) descending: the longest first, ties by the larger word.
    unique.sort_by_key(|w| std::cmp::Reverse((graphemes(w).len(), crate::text::unicode::swift_key(w))));
    unique.truncate(3);
    unique
}

/// Levenshtein over words rather than characters.
pub fn word_distance(a: &[String], b: &[String]) -> usize {
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0; b.len() + 1];
    for i in 1..=a.len() {
        cur[0] = i;
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

/// What one look at the field came to.
#[derive(Clone, Debug, PartialEq)]
pub enum Step {
    /// Nothing to do this time.
    Wait,
    /// The pasted text was found: watch this element from now on.
    Anchored,
    /// A newer dictation landed in this field; the watch is over.
    StandDown,
    /// An edit has settled: hand John's version to the learner. Call `answer` with whether it
    /// made something of it.
    Offer(String),
    /// Said once, at the end of the window, so a readback that decided nothing still leaves a
    /// trace in the log.
    Finished(&'static str),
}

/// One field under watch after one paste.
#[derive(Clone, Debug)]
pub struct Watch {
    pub wrote: String,
    pub seq: u64,
    pub anchored: bool,
    pending: Option<String>,
    stable: u32,
    reported: HashSet<String>,
    pub done: bool,
}

impl Watch {
    pub fn new(wrote: &str, seq: u64) -> Watch {
        Watch { wrote: trim_ws_nl(wrote).to_string(), seq, anchored: false, pending: None, stable: 0, reported: HashSet::new(), done: false }
    }

    /// One look. `field_now` is the focused (or anchored) field's text, None when nothing could
    /// be read; `last` is the final look of the window.
    pub fn look(&mut self, field_now: Option<&str>, pastes: &[Paste], last: bool) -> Step {
        if self.done {
            return Step::Wait;
        }
        let step = self.look_inner(field_now, pastes, last);
        if last {
            self.done = true;
        }
        step
    }

    fn look_inner(&mut self, field_now: Option<&str>, pastes: &[Paste], last: bool) -> Step {
        let Some(now) = field_now else {
            return if last && !self.anchored { Step::Finished("no focused element in this app; nothing can be learned from an edit here") } else { Step::Wait };
        };
        if superseded(pastes, self.seq, now) {
            self.done = true;
            return Step::StandDown;
        }
        if !self.anchored {
            if now.contains(&self.wrote) {
                self.anchored = true;
                return Step::Anchored;
            }
            return if last { Step::Finished("never found the pasted text in a field; nothing can be learned from this one") } else { Step::Wait };
        }
        let edited = if now.contains(&self.wrote) { None } else { edited_version(&self.wrote, now) };
        let Some(edited) = edited else {
            // The field stopped looking like the dictation while an edit was still waiting to
            // settle. That is what hitting send looks like: on 2026-09-14 John fixed "Siena" to
            // "Verona" and pressed Enter inside the 1.6 s the settle gate needs. Take the
            // candidate rather than lose it.
            if !now.contains(&self.wrote) {
                if let Some(candidate) = self.pending.take() {
                    if !self.reported.contains(&candidate) {
                        self.stable = 0;
                        self.reported.insert(candidate.clone());
                        return Step::Offer(candidate);
                    }
                }
            }
            self.pending = None;
            self.stable = 0;
            return if last {
                Step::Finished(if now.contains(&self.wrote) {
                    "field unchanged after the window, nothing to learn"
                } else {
                    "field changed but it is not recognizably an edit of the dictation"
                })
            } else {
                Step::Wait
            };
        };
        // Handed over once already; wait for John to type something different.
        if self.reported.contains(&edited) {
            return Step::Wait;
        }
        // A fix takes several keystrokes and a pause mid-word is ordinary: on 2026-09-14 one look
        // caught "earl" on the way to "early". Two looks in a row reading the same.
        if self.pending.as_deref() != Some(edited.as_str()) {
            self.pending = Some(edited);
            self.stable = 1;
            return Step::Wait;
        }
        self.stable += 1;
        if self.stable < 2 {
            return Step::Wait;
        }
        self.reported.insert(edited.clone());
        Step::Offer(edited)
    }

    /// Whether the learner made something of the last offer. Only an edit that taught something
    /// ends the watch, so a later, better edit still gets its turn.
    pub fn answer(&mut self, learned: bool) {
        if learned {
            self.done = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_schedule_matches_the_mac() {
        let d = check_delays(WATCH_WINDOW, POLL_INTERVAL, &ANCHOR_DELAYS);
        assert_eq!(d.len(), 17);
        assert!((d[0] - 3.8).abs() < 1e-9 && (d[16] - 16.6).abs() < 1e-9);
    }

    #[test]
    fn edits_are_found_and_placeholders_refused() {
        assert_eq!(edited_version("Merissa Wong.", "Marisa Vuong."), Some("Marisa Vuong.".into()));
        assert_eq!(edited_version("you can merge it in now.", "Type / for commands"), None);
        assert_eq!(edited_version("same", "same"), None);
        let doc = format!("{} We should meet on Thursday at noon. {}", "word ".repeat(80), "tail ".repeat(80));
        assert_eq!(edited_version("We should meet on Tuesday at noon.", &doc), Some("We should meet on Thursday at noon.".into()));
    }

    #[test]
    fn a_settled_edit_is_offered_once_and_send_does_not_lose_it() {
        let mut w = Watch::new("Let's meet Siena.", 1);
        assert_eq!(w.look(Some(""), &[], false), Step::Wait);
        assert_eq!(w.look(Some("Let's meet Siena."), &[], false), Step::Anchored);
        assert_eq!(w.look(Some("Let's meet Verona."), &[], false), Step::Wait, "one look is not settled");
        assert_eq!(w.look(Some("Let's meet Verona."), &[], false), Step::Offer("Let's meet Verona.".into()));
        w.answer(false);
        assert_eq!(w.look(Some("Let's meet Verona."), &[], false), Step::Wait, "never offered twice");

        let mut w = Watch::new("Let's meet Siena.", 1);
        w.look(Some("Let's meet Siena."), &[], false);
        w.look(Some("Let's meet Verona."), &[], false);
        assert_eq!(w.look(Some(""), &[], false), Step::Offer("Let's meet Verona.".into()), "sent mid-settle");
    }

    #[test]
    fn a_newer_dictation_ends_the_watch() {
        let mut w = Watch::new("Let's meet Thursday.", 1);
        w.look(Some("Let's meet Thursday."), &[], false);
        let pastes = vec![Paste { seq: 1, text: "Let's meet Thursday.".into() }, Paste { seq: 2, text: "Let's meet Tuesday.".into() }];
        assert_eq!(w.look(Some("Let's meet Tuesday."), &pastes, false), Step::StandDown);
        assert!(w.done);
    }
}
