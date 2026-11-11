//! The end-of-call check. When a call ends and its transcript has been rebuilt from the audio,
//! every tracker item, running note and summary line is checked against that transcript, and one
//! the transcript does not back is flagged where John reads it, never silently kept.
//!
//! The promise, John's OK on 2026-11-10: when a call ends, every to-do and note line Lin Flow
//! keeps is one the transcript backs, with its person, date and amount as said; anything else is
//! flagged. Measured first on the 11/1 ministry call: 26 of 45 to-dos and 85 of 115 note lines
//! were backed, and the local model had rewritten its own mistakes into later notes.
//!
//! Each line is checked in three steps: a word search finds the stretch it came from (near its
//! time when it has one), every name, number and date word in it must be in that stretch, and the
//! local model is asked whether the stretch says it. This is the pure half.

use crate::meeting::running;
use crate::meeting::summary::{ModelError, NoteModel, Request};
use crate::meeting::tracker::{Kind, Tracker};
use crate::notes::{transcript_text, TranscriptSegment};
use std::collections::HashSet;

/// What a flagged line carries in `running-notes.md` and `summary.md`.
pub const MARK: &str = " (not backed by the transcript)";
/// The stretch a stamped line is looked for in: a little before its stamp, and the few minutes a
/// pass reads after it.
pub const BEFORE_SECONDS: f64 = 180.0;
pub const AFTER_SECONDS: f64 = 300.0;
/// About a minute or two of talk, well inside the local model's window.
pub const EXCERPT_CHARACTERS: usize = 2_500;

pub const INSTRUCTIONS: &str = "You check one line of meeting notes against the part of the transcript it came from. Transcript lines look like \"[m:ss] Speaker: words\". \"You\" is John and \"Others\" is everyone else; the transcript is machine speech recognition, so read through misheard words. Answer with one word, yes or no. Yes only if the transcript clearly says what the line says: the same person doing it, the same task or question, and every name, number and date as said. No if the line adds anything, gives a task to the wrong person, turns talk or an idea into a task, or is not in the excerpt.";

/// Why a line is not backed, or `None` when it is.
pub type Finding = Option<String>;

/// How many lines were checked and flagged, for the log.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub checked: usize,
    pub flagged: usize,
}

/// The stretch of transcript a line most likely came from: the window, within reach of `near`
/// when given, that shares the most of the line's words.
pub fn locate(segments: &[TranscriptSegment], text: &str, near: Option<f64>) -> String {
    let mut pool: Vec<&TranscriptSegment> = match near {
        Some(at) => segments.iter().filter(|s| s.end >= at - BEFORE_SECONDS && s.start <= at + AFTER_SECONDS).collect(),
        None => segments.iter().collect(),
    };
    if pool.is_empty() {
        // A stamp past where the rebuilt transcript has speech: look over the whole call.
        pool = segments.iter().collect();
    }
    let wanted = content_words(text);
    let each: Vec<HashSet<String>> = pool.iter().map(|s| content_words(&s.text)).collect();
    let (mut best, mut best_score) = (0..0, usize::MAX);
    for i in 0..pool.len() {
        let mut chars = 0;
        let mut j = i;
        while j < pool.len() && (chars == 0 || chars + pool[j].text.len() <= EXCERPT_CHARACTERS) {
            chars += pool[j].text.len() + 12;
            j += 1;
        }
        let score = wanted.iter().filter(|w| each[i..j].iter().any(|set| set.contains(*w))).count();
        if best_score == usize::MAX || score > best_score {
            (best, best_score) = (i..j, score);
        }
    }
    let window: Vec<TranscriptSegment> = pool[best].iter().map(|s| (*s).clone()).collect();
    transcript_text(&window, true)
}

/// The word checks, which need no model: every name, number and date word the line has is in
/// the stretch, and so is the person it gives the task to.
pub fn words(line: &str, who: &str, excerpt: &str) -> Finding {
    if !running::grounded(line, excerpt, &[]) {
        return Some("it has a name, number or date this part of the call never said".into());
    }
    let who = who.trim();
    if !who.is_empty() && !["you", "others", "everyone", "all", "john"].contains(&who.to_lowercase().as_str()) {
        let said: HashSet<String> = excerpt.split(|c: char| !c.is_alphanumeric()).map(str::to_lowercase).collect();
        if who.split_whitespace().any(|w| !said.contains(&w.to_lowercase())) {
            return Some(format!("{who} is not named in this part of the call"));
        }
    }
    None
}

/// Asks the local model whether the stretch says the line. Anything but a yes is a no.
pub fn ask(model: &mut dyn NoteModel, line: &str, excerpt: &str) -> Result<bool, ModelError> {
    let request = Request {
        instructions: INSTRUCTIONS.into(),
        prompt: format!("Line: {line}\n\nTranscript:\n{excerpt}"),
        max_tokens: 4,
        lists: vec![],
        greedy: true,
    };
    let answer = model.complete(&request)?;
    Ok(answer.trim().trim_start_matches(|c: char| !c.is_alphabetic()).to_lowercase().starts_with("yes"))
}

/// One line: located, word-checked, then asked about.
pub fn check(model: &mut dyn NoteModel, segments: &[TranscriptSegment], line: &str, who: &str, near: Option<f64>) -> Result<Finding, ModelError> {
    let said = if who.trim().is_empty() { line.to_string() } else { format!("{who}: {line}") };
    check_as(model, segments, line, who, near, &said)
}

/// `check`, with the model shown `put` instead of the line: a question is checked on its own
/// words but asked about as one put to John.
fn check_as(model: &mut dyn NoteModel, segments: &[TranscriptSegment], line: &str, who: &str, near: Option<f64>, put: &str) -> Result<Finding, ModelError> {
    let excerpt = locate(segments, &format!("{who} {line}"), near);
    if excerpt.is_empty() {
        return Ok(Some("the transcript is empty".into()));
    }
    if let Some(why) = words(line, who, &excerpt) {
        return Ok(Some(why));
    }
    Ok(if ask(model, put, &excerpt)? { None } else { Some("the transcript here does not say this".into()) })
}

/// Every tracker item, each marked backed or not. A done item is checked too: ticking it off
/// does not make it true.
pub fn check_tracker(model: &mut dyn NoteModel, segments: &[TranscriptSegment], tracker: &Tracker) -> Result<(Tracker, Counts), ModelError> {
    let mut out = tracker.clone();
    let mut counts = Counts::default();
    for item in &mut out.items {
        let finding = match item.kind {
            Kind::Question => check_as(model, segments, &item.text, "", Some(item.at), &format!("Someone asked John: {}", item.text))?,
            Kind::Action => check(model, segments, &item.text, &item.detail, Some(item.at))?,
        };
        counts.checked += 1;
        counts.flagged += usize::from(finding.is_some());
        item.unbacked = finding;
    }
    Ok((out, counts))
}

/// A Markdown file's bullets, each checked; a bullet the transcript does not back gets `MARK`.
/// Headings and other lines are left as they are. A line already marked is checked again, so a
/// second run marks nothing twice.
pub fn check_markdown(model: &mut dyn NoteModel, segments: &[TranscriptSegment], markdown: &str) -> Result<(String, Counts), ModelError> {
    let mut out = Vec::new();
    let mut counts = Counts::default();
    for raw in markdown.lines() {
        let Some((lead, body)) = bullet(raw) else {
            out.push(raw.to_string());
            continue;
        };
        let body = body.strip_suffix(MARK).unwrap_or(body);
        let (near, text) = stamp(body);
        if text.trim().is_empty() {
            out.push(format!("{lead}{body}"));
            continue;
        }
        let finding = check(model, segments, text, "", near)?;
        counts.checked += 1;
        counts.flagged += usize::from(finding.is_some());
        out.push(if finding.is_some() { format!("{lead}{body}{MARK}") } else { format!("{lead}{body}") });
    }
    let mut text = out.join("\n");
    if markdown.ends_with('\n') {
        text.push('\n');
    }
    Ok((text, counts))
}

/// "- text" or "* text" (any indent), split into the marker and the text.
fn bullet(line: &str) -> Option<(&str, &str)> {
    let indent = line.len() - line.trim_start().len();
    let rest = &line[indent..];
    if rest.starts_with("- ") || rest.starts_with("* ") {
        Some((&line[..indent + 2], &line[indent + 2..]))
    } else {
        None
    }
}

/// "[3:05] text" is (185 s, "text"); a line with no stamp has no time.
fn stamp(body: &str) -> (Option<f64>, &str) {
    let Some(rest) = body.strip_prefix('[') else { return (None, body) };
    let Some((clock, text)) = rest.split_once("] ") else { return (None, body) };
    let parts: Vec<f64> = clock.split(':').map(|p| p.parse::<f64>()).collect::<Result<_, _>>().unwrap_or_default();
    match parts.as_slice() {
        [m, s] => (Some(m * 60.0 + s), text),
        [h, m, s] => (Some(h * 3600.0 + m * 60.0 + s), text),
        _ => (None, body),
    }
}

const COMMON: &[&str] = &["that", "this", "with", "will", "have", "from", "they", "their", "there", "about", "would", "could", "should", "what", "when", "were", "been", "just", "like", "your", "some", "into", "them", "then", "than", "also", "need", "make", "know", "said", "going", "yeah", "okay", "really", "think", "want", "someone", "asked", "john"];

/// The words worth matching on: lowercased, four letters or more, not the commonest.
fn content_words(text: &str) -> HashSet<String> {
    text.split(|c: char| !c.is_alphanumeric())
        .map(|w| w.to_lowercase())
        .filter(|w| (w.chars().count() >= 4 || w.chars().all(|c| c.is_ascii_digit())) && !w.is_empty() && !COMMON.contains(&w.as_str()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::meeting::tracker::Item;

    /// Answers yes to every question, so a test sees only what the word checks catch, or
    /// answers from a script.
    struct Model(Vec<&'static str>, Vec<String>);
    impl NoteModel for Model {
        fn name(&self) -> String {
            "scripted".into()
        }
        fn window_characters(&self) -> usize {
            6_500
        }
        fn complete(&mut self, request: &Request) -> Result<String, ModelError> {
            self.1.push(request.prompt.clone());
            Ok(if self.0.is_empty() { "yes".into() } else { self.0.remove(0).into() })
        }
    }
    fn yes() -> Model {
        Model(vec![], vec![])
    }

    fn seg(start: f64, speaker: &str, text: &str) -> TranscriptSegment {
        TranscriptSegment::new(start, start + 4.0, speaker, text)
    }

    /// The shape of the 11/1 call's worst miss: Dana buys the kits, the note said Priya.
    fn call() -> Vec<TranscriptSegment> {
        vec![
            seg(5.0, "Others", "Welcome everyone, let's get started with the trip planning."),
            seg(2900.0, "Others", "The remainder minus the 450 deposit goes through the giving page, and about 100 dollars is cash."),
            seg(3351.0, "Others", "Priya, I know you do first aid. Dana Reyes is gonna buy the first aid kits."),
            seg(3360.0, "You", "Sounds good, I'll submit the e-visa this week."),
        ]
    }

    fn item(kind: Kind, at: f64, text: &str, detail: &str) -> Item {
        Item { id: "1".into(), kind, at, text: text.into(), detail: detail.into(), done: false, unbacked: None }
    }

    #[test]
    fn the_stretch_found_is_the_one_the_line_came_from() {
        let excerpt = locate(&call(), "Dana will buy the first aid kits", Some(3326.0));
        assert!(excerpt.contains("Dana Reyes"));
        assert!(!excerpt.contains("Welcome everyone"));
    }

    #[test]
    fn a_task_given_to_someone_never_named_there_is_flagged() {
        let (t, counts) = check_tracker(&mut yes(), &call(), &Tracker { items: vec![item(Kind::Action, 3351.0, "buy the first aid kits", "Marco")] }).unwrap();
        assert_eq!(counts, Counts { checked: 1, flagged: 1 });
        assert!(t.items[0].unbacked.as_deref().unwrap().contains("Marco"));
    }

    #[test]
    fn an_amount_the_call_never_said_is_flagged_without_asking_the_model() {
        let mut m = yes();
        let (text, counts) = check_markdown(&mut m, &call(), "- [48:20] About 250 dollars is left to pay in cash.\n").unwrap();
        assert_eq!(counts.flagged, 1);
        assert_eq!(text, format!("- [48:20] About 250 dollars is left to pay in cash.{MARK}\n"));
        assert!(m.1.is_empty(), "the word check settles it");
    }

    #[test]
    fn the_model_saying_no_flags_a_line_whose_words_all_check_out() {
        // Priya is named and kits are bought, but not by Priya: only the question catches it.
        let mut m = Model(vec!["No."], vec![]);
        let (text, counts) = check_markdown(&mut m, &call(), "## Notes\n- [55:51] Priya will buy the first aid kits.\n").unwrap();
        assert_eq!(counts, Counts { checked: 1, flagged: 1 });
        assert!(text.ends_with(&format!("Priya will buy the first aid kits.{MARK}\n")));
        assert!(text.starts_with("## Notes\n"), "a heading is not a line to check");
        assert!(m.1[0].contains("Dana Reyes"), "the model reads the stretch the line came from");
    }

    #[test]
    fn a_backed_line_stays_as_it_was_and_a_second_run_marks_nothing_twice() {
        let notes = "- [56:00] You will submit the e-visa this week.\n* Dana Reyes will buy the first aid kits.";
        let (once, c1) = check_markdown(&mut yes(), &call(), notes).unwrap();
        assert_eq!((once.as_str(), c1.flagged), (notes, 0));
        let flagged = format!("- [56:00] You will submit the e-visa this week.{MARK}");
        let (again, _) = check_markdown(&mut yes(), &call(), &flagged).unwrap();
        assert_eq!(again, "- [56:00] You will submit the e-visa this week.");
    }

    #[test]
    fn a_ticked_item_is_checked_too() {
        let mut done = item(Kind::Action, 3351.0, "buy 40 first aid kits", "Dana Reyes");
        done.done = true;
        let (t, _) = check_tracker(&mut yes(), &call(), &Tracker { items: vec![done] }).unwrap();
        assert!(t.items[0].unbacked.is_some());
        assert!(t.items[0].done, "the tick stays John's");
    }

    #[test]
    fn a_short_name_said_in_the_stretch_owns_its_task() {
        let (t, _) = check_tracker(&mut yes(), &call(), &Tracker { items: vec![item(Kind::Action, 3351.0, "buy the first aid kits", "Dana Reyes")] }).unwrap();
        assert_eq!(t.items[0].unbacked, None);
    }

    #[test]
    fn a_question_is_word_checked_on_its_own_words_not_johns_name() {
        let calls = vec![seg(10.0, "Others", "Can you lead the opening prayer on Friday?")];
        let mut m = yes();
        let (t, _) = check_tracker(&mut m, &calls, &Tracker { items: vec![item(Kind::Question, 10.0, "Can you lead the opening prayer on Friday?", "Say yes.")] }).unwrap();
        assert_eq!(t.items[0].unbacked, None, "the transcript calls John You, never John");
        assert!(m.1[0].starts_with("Line: Someone asked John:"));
    }

    #[test]
    fn stamps_read_as_seconds() {
        assert_eq!(stamp("[3:05] x"), (Some(185.0), "x"));
        assert_eq!(stamp("[1:02:03] x"), (Some(3723.0), "x"));
        assert_eq!(stamp("no stamp"), (None, "no stamp"));
    }
}
