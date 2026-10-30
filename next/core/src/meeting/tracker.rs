//! The call tracker: what John has to respond to while the call is still going. Every pass hands
//! the local model the newest stretch of the live transcript, with a little of what came before
//! as context, and gets back questions put to John (each with a short angle for answering) and
//! things someone said they would do. Each is checked against the stretch the way running notes
//! are, so a name or number the call never had is dropped, and added to the note's
//! `tracker.json`, where John ticks items off from the panel. This is the pure half.

use crate::meeting::running;
use crate::meeting::summary::{parse_lists, ListSpec, ModelError, NoteModel, Request};
use crate::notes::{transcript_text, TranscriptSegment};
use crate::text::unicode::{lowercased, trim_ws_nl};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// Seconds between passes. A question asked of John should be on screen before he has finished
/// answering it; a 7B model takes about 6 s a pass, so this keeps it busy a third of the time.
pub const INTERVAL_SECONDS: f64 = 20.0;
/// Fewer new words than this is a "yeah" or a pause, not a question.
pub const MINIMUM_NEW_WORDS: usize = 15;
/// One pass reads at most this much new transcript; the rest waits for the next.
pub const MAXIMUM_WINDOW_WORDS: usize = 400;
/// Earlier transcript shown for context, so a question that leans on the line before it reads
/// whole. Nothing is taken from it.
pub const CONTEXT_WORDS: usize = 120;
/// Between a question and its angle, and between who and what.
pub const SEPARATOR: &str = "::";

pub const INSTRUCTIONS: &str = "You keep a live tracker for John during a call. Lines look like \"[m:ss] Speaker: words\". \"You\" is John's microphone and \"Others\" is everyone else on the call; the transcript is machine speech recognition, so read through misheard words. Earlier lines are context only: take items from the newest stretch. Two lists. questions: a question someone in Others put to John in the newest stretch, asked of him or of the group expecting his answer, that he has not answered yet. A question he put off (\"let me think\", \"I'll get back to you\") is still open: list it here, never as an action. Each entry is the question in plain words ending with a question mark, then \" :: \", then one sentence on how John could answer: the angle to take or what to mention, from the call where it can. Not rhetorical questions, not small talk like how are you, not questions John asked. actions: something a person agreed to do, in the newest stretch. Each entry is who (You, or a name said in the call, or Others), then \" :: \", then what, under 15 words. Write each commitment once, for the person who agreed to it. Only a firm yes: not something asked of someone who has not agreed yet, not an idea, not something put off (\"at some point\", \"not today\"). Most stretches have nothing for either list. Never add a name, a number or a date the transcript does not contain. No em dashes.";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Question,
    Action,
}

/// One thing on the tracker. A question's `detail` is the angle for answering it; an action's is
/// who will do it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub kind: Kind,
    /// Seconds into the meeting where the stretch it came from began.
    pub at: f64,
    pub text: String,
    pub detail: String,
    #[serde(default)]
    pub done: bool,
}

/// `tracker.json`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tracker {
    pub items: Vec<Item>,
}

impl Tracker {
    /// Adds items, numbering them on from what is there.
    pub fn add(&mut self, new: Vec<Item>) {
        for mut item in new {
            item.id = format!("{}-{}", if item.kind == Kind::Question { "q" } else { "a" }, self.items.len() + 1);
            self.items.push(item);
        }
    }

    /// Ticks an item off, or back on. False when there is no such item.
    pub fn toggle(&mut self, id: &str) -> bool {
        match self.items.iter_mut().find(|i| i.id == id) {
            Some(i) => {
                i.done = !i.done;
                true
            }
            None => false,
        }
    }

    /// "Asked of you" and "To do" as Markdown task lists, ticked as John left them; empty when
    /// there is nothing on it.
    pub fn markdown(&self) -> String {
        let mut md = String::new();
        for (kind, heading) in [(Kind::Question, "Asked of you"), (Kind::Action, "To do")] {
            let items: Vec<&Item> = self.items.iter().filter(|i| i.kind == kind).collect();
            if items.is_empty() {
                continue;
            }
            md.push_str(&format!("## {heading}\n\n"));
            for i in items {
                let tick = if i.done { "x" } else { " " };
                let line = match kind {
                    Kind::Question if i.detail.is_empty() => i.text.clone(),
                    Kind::Question => format!("{} *{}*", i.text, i.detail),
                    Kind::Action => format!("{}: {}", i.detail, i.text),
                };
                md.push_str(&format!("- [{tick}] [{}] {line}\n", crate::notes::clock(i.at)));
            }
            md.push('\n');
        }
        md
    }

    fn texts(&self, kind: Kind) -> Vec<String> {
        self.items.iter().filter(|i| i.kind == kind).map(|i| i.text.clone()).collect()
    }
}

pub fn is_due(new_words: usize, since_last: f64, last: bool) -> bool {
    if last {
        return new_words >= MINIMUM_NEW_WORDS;
    }
    new_words >= MINIMUM_NEW_WORDS && since_last >= INTERVAL_SECONDS
}

/// The read segments just before `fresh`, newest last, up to `CONTEXT_WORDS`.
pub fn context(segments: &[TranscriptSegment], fresh: &[TranscriptSegment]) -> Vec<TranscriptSegment> {
    let Some(first) = fresh.first() else { return vec![] };
    let ids: HashSet<&str> = fresh.iter().map(|s| s.id.as_str()).collect();
    let mut before: Vec<&TranscriptSegment> = segments.iter().filter(|s| s.start < first.start && !ids.contains(s.id.as_str())).collect();
    before.sort_by(|a, b| a.start.total_cmp(&b.start));
    let mut out = vec![];
    let mut words = 0;
    for s in before.into_iter().rev() {
        let n = running::word_count(&s.text);
        if !out.is_empty() && words + n > CONTEXT_WORDS {
            break;
        }
        out.push(s.clone());
        words += n;
    }
    out.reverse();
    out
}

/// One pass: what the newest stretch adds to the tracker. `at` is where the stretch began.
pub fn pass(model: &mut dyn NoteModel, context: &str, fresh: &str, tracker: &Tracker, title: &str, at: f64) -> Result<Vec<Item>, ModelError> {
    let fresh = trim_ws_nl(fresh);
    if fresh.is_empty() {
        return Ok(vec![]);
    }
    let open: Vec<String> = tracker.items.iter().rev().take(8).map(|i| format!("* {}", i.text)).collect();
    let mut prompt = format!("Call: {title}\n");
    if !open.is_empty() {
        prompt.push_str(&format!("Already on the tracker, do not repeat:\n{}\n", open.join("\n")));
    }
    let context = trim_ws_nl(context);
    if !context.is_empty() {
        prompt.push_str(&format!("\nEarlier, for context only:\n{context}\n"));
    }
    prompt.push_str(&format!("\nNewest stretch:\n{fresh}"));
    let request = Request {
        instructions: INSTRUCTIONS.into(),
        prompt,
        max_tokens: 300,
        lists: vec![
            ListSpec { key: "questions".into(), description: "Questions put to John in the newest stretch, each \"question :: how he could answer\". Usually none.".into(), at_most: 2 },
            ListSpec { key: "actions".into(), description: "Commitments in the newest stretch, each \"who :: what\". Usually none.".into(), at_most: 3 },
        ],
        greedy: true,
    };
    let answer = model.complete(&request)?;
    let lists = parse_lists(&answer, &["questions", "actions"]);
    let source = format!("{context} {fresh}");
    let mut out = vec![];
    let questions = lists.first().cloned().unwrap_or_default();
    let kept = keep(questions.iter().map(|q| split_question(q)).filter(|(q, angle)| !angle.is_empty() && !small_talk(q) && grounded(q, &source)).collect(), &tracker.texts(Kind::Question));
    out.extend(kept.into_iter().map(|(text, detail)| Item { id: String::new(), kind: Kind::Question, at, text, detail, done: false }));
    let actions = lists.get(1).cloned().unwrap_or_default();
    let actions: Vec<(String, String)> = actions.iter().map(|a| split(a)).map(|(who, what)| if what.is_empty() { (String::new(), who) } else { (who, what) }).collect();
    let actions = actions.into_iter().filter(|(_, what)| grounded(what, &source)).map(|(who, what)| (what, owner(&who, &source))).collect();
    out.extend(keep(actions, &tracker.texts(Kind::Action)).into_iter().map(|(text, detail)| Item { id: String::new(), kind: Kind::Action, at, text, detail, done: false }));
    Ok(out)
}

/// What one look at the transcript did: how many new words it read and what it added.
#[derive(Debug)]
pub struct Step {
    pub words: usize,
    pub added: usize,
}

/// One look at the transcript as heard so far: when a pass is due, runs it, marks its stretch
/// read and adds what it found. `None` when nothing was due. On a model error the stretch stays
/// unread, so the next look takes it.
pub fn step(model: &mut dyn NoteModel, heard: &[TranscriptSegment], read: &mut HashSet<String>, tracker: &mut Tracker, title: &str, since_last: f64, last: bool) -> Result<Option<Step>, ModelError> {
    let fresh = running::window(heard, read, MAXIMUM_WINDOW_WORDS);
    let words = running::word_count_of(&fresh);
    if fresh.is_empty() || !is_due(words, since_last, last) {
        return Ok(None);
    }
    let before = context(heard, &fresh);
    let items = pass(model, &transcript_text(&before, true), &transcript_text(&fresh, true), tracker, title, fresh[0].start)?;
    read.extend(fresh.iter().map(|s| s.id.clone()));
    let added = items.len();
    tracker.add(items);
    Ok(Some(Step { words, added }))
}

/// "question? :: angle". The model sometimes puts the asker in front ("Dana :: question? ::
/// angle"), so the question is the part that asks.
fn split_question(entry: &str) -> (String, String) {
    let parts: Vec<String> = trim_ws_nl(entry).split(SEPARATOR).map(clean).filter(|p| !p.is_empty()).collect();
    match parts.iter().rposition(|p| p.ends_with('?')) {
        Some(i) => (parts[i].clone(), parts[i + 1..].join(" ")),
        None => split(entry),
    }
}

/// "left :: right", either half trimmed; no separator puts it all on the left.
fn split(entry: &str) -> (String, String) {
    let entry = trim_ws_nl(entry).trim_start_matches(['-', '*', ' ']);
    match entry.split_once(SEPARATOR) {
        Some((l, r)) => (clean(l), clean(r)),
        None => (clean(entry), String::new()),
    }
}

fn clean(s: &str) -> String {
    trim_ws_nl(s).trim_matches(|c: char| c == '"' || c == '\'').replace('\u{2014}', ", ").trim().to_string()
}

/// Something a person could read: three words at least, and nothing the stretch never said.
fn grounded(text: &str, source: &str) -> bool {
    running::word_count(text) >= 3 && running::grounded(text, source, &[])
}

/// The questions every call opens with, which the model lists anyway now and then.
const SMALL_TALK: &[&str] = &["how are you", "how's it going", "how is it going", "can you hear me", "can you see my screen", "can everyone see", "how was your weekend", "are you there"];

fn small_talk(question: &str) -> bool {
    let q = lowercased(question);
    SMALL_TALK.iter().any(|s| q.contains(s))
}

/// Drops what is already on the tracker or repeats an earlier entry of this pass.
fn keep(entries: Vec<(String, String)>, existing: &[String]) -> Vec<(String, String)> {
    let texts: Vec<String> = entries.iter().map(|(t, _)| t.clone()).collect();
    let fresh = running::drop_repeats(&texts, existing);
    entries.into_iter().filter(|(t, _)| fresh.contains(t)).fold(vec![], |mut acc, e| {
        if !acc.iter().any(|(t, _): &(String, String)| *t == e.0) {
            acc.push(e);
        }
        acc
    })
}

/// "You" and "Others" as written; John is "You"; a name the call said stays; anything else is
/// "Others", since the model may not invent a person.
fn owner(who: &str, source: &str) -> String {
    let w = who.trim();
    let lower = lowercased(w);
    if lower.is_empty() || lower == "others" || lower == "they" || lower == "someone" {
        return "Others".into();
    }
    if lower == "you" || lower == "john" || lower == "i" || lower == "me" {
        return "You".into();
    }
    // A name: capitalized, and said in the call.
    let capitalized = w.chars().next().is_some_and(|c| c.is_uppercase());
    if capitalized && running::grounded(&format!("Ask {w}"), source, &[]) {
        return w.to_string();
    }
    "Others".into()
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scripted(Vec<String>, Vec<Request>);

    impl NoteModel for Scripted {
        fn name(&self) -> String {
            "scripted".into()
        }
        fn window_characters(&self) -> usize {
            6_500
        }
        fn complete(&mut self, request: &Request) -> Result<String, ModelError> {
            self.1.push(request.clone());
            Ok(self.0.remove(0))
        }
    }

    const STRETCH: &str = "[2:10] Others: Priya here. So what's your estimate for the parser rewrite, can it land by Friday?\n[2:18] You: Let me check.\n[2:20] Others: Okay, and I'll send the test logs after this call.";

    #[test]
    fn a_pass_finds_the_question_and_the_promise() {
        let answer = r#"{"questions":["Can the parser rewrite land by Friday? :: Give a range, and say what Friday depends on."],"actions":["Priya :: send the test logs after this call"]}"#;
        let mut m = Scripted(vec![answer.into()], vec![]);
        let items = pass(&mut m, "", STRETCH, &Tracker::default(), "Standup", 130.0).unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!((items[0].kind, items[0].text.as_str()), (Kind::Question, "Can the parser rewrite land by Friday?"));
        assert_eq!(items[0].detail, "Give a range, and say what Friday depends on.");
        assert_eq!((items[1].kind, items[1].text.as_str(), items[1].detail.as_str()), (Kind::Action, "send the test logs after this call", "Priya"));
        assert!(m.1[0].prompt.contains("Newest stretch:\n[2:10]"));
    }

    #[test]
    fn what_the_call_never_said_is_dropped() {
        let answer = r#"{"questions":["Can Marcus ship it by Monday? :: Say yes.","How are you?"],"actions":["Dana :: send the test logs","You :: review the budget for 2027","the vendor :: send the test logs after this call"]}"#;
        let mut m = Scripted(vec![answer.into()], vec![]);
        let items = pass(&mut m, "", STRETCH, &Tracker::default(), "Standup", 0.0).unwrap();
        assert_eq!(items.len(), 1, "{items:?}");
        assert_eq!(items[0].detail, "Others", "an invented owner becomes Others, the promise stays");
        assert!(owner("the vendor", STRETCH) == "Others" && owner("Priya", STRETCH) == "Priya" && owner("I", STRETCH) == "You");
    }

    #[test]
    fn the_question_is_the_part_that_asks() {
        assert_eq!(split_question("Priya :: Can it land by Friday? :: Give a range."), ("Can it land by Friday?".into(), "Give a range.".into()));
        assert_eq!(split_question("Can it land by Friday? :: Give a range."), ("Can it land by Friday?".into(), "Give a range.".into()));
        assert!(!grounded(&split_question(":: Suggest lighting fixes.").0, "Suggest lighting fixes."), "no question: dropped");
    }

    #[test]
    fn repeats_are_not_added_twice() {
        let answer = r#"{"questions":["Can the parser rewrite land by Friday? :: Give a range."],"actions":[]}"#;
        let mut tracker = Tracker::default();
        let mut m = Scripted(vec![answer.into(), answer.into()], vec![]);
        let first = pass(&mut m, "", STRETCH, &tracker, "Standup", 0.0).unwrap();
        tracker.add(first);
        assert_eq!(tracker.items[0].id, "q-1");
        let again = pass(&mut m, "", STRETCH, &tracker, "Standup", 20.0).unwrap();
        assert!(again.is_empty());
        assert!(m.1[1].prompt.contains("Already on the tracker"));
    }

    #[test]
    fn ticking_off_and_the_file_shape() {
        let mut t = Tracker::default();
        t.add(vec![Item { id: String::new(), kind: Kind::Action, at: 5.0, text: "send the logs".into(), detail: "You".into(), done: false }]);
        assert!(t.toggle("a-1") && t.items[0].done);
        assert!(!t.toggle("q-9"));
        let json = serde_json::to_string(&t).unwrap();
        assert_eq!(json, r#"{"items":[{"id":"a-1","kind":"action","at":5.0,"text":"send the logs","detail":"You","done":true}]}"#);
        assert_eq!(serde_json::from_str::<Tracker>(&json).unwrap(), t);
        t.add(vec![Item { id: String::new(), kind: Kind::Question, at: 65.0, text: "Ready by Friday?".into(), detail: "Give a range.".into(), done: false }]);
        assert_eq!(t.markdown(), "## Asked of you\n\n- [ ] [1:05] Ready by Friday? *Give a range.*\n\n## To do\n\n- [x] [0:05] You: send the logs\n\n");
        assert_eq!(Tracker::default().markdown(), "");
    }

    #[test]
    fn context_is_the_lines_just_before() {
        let seg = |id: &str, start: f64, text: &str| TranscriptSegment { id: id.into(), speaker: "Others".into(), start, end: start + 1.0, text: text.into() };
        let all = vec![seg("a", 0.0, "old line"), seg("b", 5.0, "just before"), seg("c", 10.0, "new")];
        let ctx = context(&all, &all[2..]);
        assert_eq!(ctx.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), vec!["a", "b"]);
    }
}
