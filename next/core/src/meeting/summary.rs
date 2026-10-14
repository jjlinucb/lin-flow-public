//! Summaries, recaps and running notes, for any model behind `NoteModel`.
//!
//! A model with a large window (Claude) reads a whole meeting in one request. A small one
//! (Apple's on-device model, a local model under Ollama) takes it in pieces: notes on each part
//! as four bounded lists, merged heading by heading in code (`merge`), with a list that still
//! runs long handed back to shorten. Asking a small model for the finished document instead gave
//! one list copied under every heading, a "## None" heading, and numbers that drifted as it
//! rewrote 50 bullets.

use super::merge::{self, Section, Sections};
use super::running;
use crate::text::unicode::{count, lines_keeping_empty, split_at_grapheme, trim_ws_nl};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// The full write-up: summary, decisions, action items, open questions.
    Meeting,
    /// "What did I miss": the gist of the last few minutes, as a few bullets.
    Recap,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ModelError {
    /// Not installed, not running, no key: the sentence says what to do about it.
    Unavailable(String),
    /// The request did not fit the model's window.
    TooLong,
    Refused,
    Empty,
    Failed(String),
}

impl std::fmt::Display for ModelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ModelError::Unavailable(why) => write!(f, "{why}"),
            ModelError::TooLong => write!(f, "The transcript is too long for this model even in pieces."),
            ModelError::Refused => write!(f, "The model declined to answer that."),
            ModelError::Empty => write!(f, "Nothing to summarize yet."),
            ModelError::Failed(why) => write!(f, "Summary failed: {why}"),
        }
    }
}

/// One list the answer must contain, for a model that can be held to a schema.
#[derive(Clone, Debug, PartialEq)]
pub struct ListSpec {
    pub key: String,
    pub description: String,
    pub at_most: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Request {
    pub instructions: String,
    pub prompt: String,
    pub max_tokens: u32,
    /// Empty for free text. Otherwise the answer is a JSON object with these keys, each a list
    /// of strings, which `parse_lists` reads back.
    pub lists: Vec<ListSpec>,
    /// Greedy decoding: note-taking is extraction, and sampling only adds ways to misread a number.
    pub greedy: bool,
}

pub trait NoteModel {
    fn name(&self) -> String;
    /// About how much transcript one request can carry, in characters. Claude's is effectively
    /// the whole meeting; the on-device model's 4096 tokens hold about 6,500.
    fn window_characters(&self) -> usize;
    fn complete(&mut self, request: &Request) -> Result<String, ModelError>;
}

// MARK: prompts

pub const RUNNING_INSTRUCTIONS: &str = "You take running notes during a meeting, a minute or two at a time. Lines look like \"[m:ss] Speaker: words\". \"You\" is the note-taker, \"Others\" are the other participants. You are given the notes already taken and the newest stretch of transcript. Write down only what is new in the newest stretch and worth remembering afterwards: something decided, something someone agreed to do and who, a number, a date, a deadline, a question left open, a fact that matters. Each note is one complete sentence, under 20 words, in your own words, that a colleague who missed this minute would understand on its own: say who and what. Not a label, not a heading, not a name or a number on its own, never a transcript line copied out, never \"Task:\" or \"Question:\" in front. Most stretches deserve one note or none: greetings, small talk, filler, thinking aloud and anything already in the notes get nothing. Something asked but not settled is written as a question, not as a fact. Keep names, numbers, dates and product names exactly as written, and never add a number, a date or a name the stretch does not contain. Do not add commentary, do not infer what was not said, do not use em dashes.";

pub const PART_INSTRUCTIONS: &str = "You take notes on a meeting transcript, or on one part of it. Lines look like \"[m:ss] Speaker: words\". \"You\" is the note-taker, \"Others\" are the other participants. Record only what this text actually contains and leave a list empty rather than pad it. Each entry is one short sentence under 20 words in your own words, never a copied transcript line, no greetings or small talk. Keep names, numbers, dates and product names exactly as written. A decision is only something the participants agreed to do. Do not infer dates or numbers that were not said, do not add commentary, do not use em dashes.";

pub const RECAP_INSTRUCTIONS: &str = "Someone stepped away from a meeting and asks what they missed. Given the last few minutes of transcript (\"You\" is the asker, \"Others\" are the other participants), answer in 2 to 5 short plain bullets: what was discussed, anything decided, anything asked of them. Keep names and numbers exactly as given. No headings, no preamble, no commentary, no em dashes.";

/// The whole-meeting write-up from a model that reads it in one go.
pub const MEETING_INSTRUCTIONS: &str = "You write up a meeting from its transcript. \"You\" is the person who recorded it and \"Others\" is everyone else; the transcript is machine speech recognition, so read through misheard words. Answer in exactly these four Markdown sections, in this order, each a list of short bullets, and write \"None\" under a section with nothing in it:\n## Summary\n## Decisions\n## Action items\n## Open questions\nKeep names, numbers, dates and product names as said. Nothing that is not in the transcript. No preamble, no em dashes.";

pub fn shorten_instructions(section: Section) -> String {
    let what = match section {
        Section::Summary => "the key points of a meeting",
        Section::Decisions => "the decisions made in a meeting",
        Section::Actions => "the action items from a meeting",
        Section::Questions => "the open questions from a meeting",
    };
    format!("You shorten a list of {what}. The entries were taken in order from successive parts of the meeting. Keep the order, merge entries that say the same thing, and drop the least important ones to fit. Each entry under 25 words. Keep every name, number, date and product name exactly as written; never change a number. Do not add anything that is not in the list, do not use em dashes or semicolons.")
}

/// How many entries a merged section may show before the model shortens it.
pub fn longest_list(section: Section) -> usize {
    match section {
        Section::Summary => 6,
        Section::Decisions => 10,
        Section::Actions => 12,
        Section::Questions => 8,
    }
}

/// How many entries one part may contribute to a section.
pub fn part_cap(section: Section) -> usize {
    match section {
        Section::Summary => 6,
        Section::Decisions => 5,
        Section::Actions => 8,
        Section::Questions => 4,
    }
}

pub fn part_lists() -> Vec<ListSpec> {
    let spec = |s: Section, key: &str, description: &str| ListSpec { key: key.into(), description: description.into(), at_most: part_cap(s) };
    vec![
        spec(Section::Summary, "keyPoints", "What was discussed or reported in this part, each entry one short sentence under 20 words in your own words, with names, numbers and dates exactly as said"),
        spec(Section::Decisions, "decisions", "Only things the participants agreed to do in this part; a proposal, a question or a status report is not a decision"),
        spec(Section::Actions, "actionItems", "Tasks someone took on in this part: who does what, with the date if one was said"),
        spec(Section::Questions, "openQuestions", "Questions raised in this part and left unanswered"),
    ]
}

/// A model with at least this window reads a meeting whole.
const WHOLE_MEETING_CHARACTERS: usize = 200_000;

// MARK: the passes

/// Running notes for the newest stretch: zero to three bullets, filtered against what the
/// stretch actually said.
pub fn running_notes(model: &mut dyn NoteModel, previous: &[String], transcript: &str, title: &str) -> Result<Vec<String>, ModelError> {
    let text = trim_ws_nl(transcript);
    if text.is_empty() {
        return Ok(vec![]);
    }
    let taken = if previous.is_empty() { "(none yet)".to_string() } else { previous.iter().map(|p| format!("* {p}")).collect::<Vec<_>>().join("\n") };
    let request = Request {
        instructions: RUNNING_INSTRUCTIONS.into(),
        prompt: format!("Meeting: {title}\nNotes already taken:\n{taken}\n\nNewest stretch of the transcript:\n\n{text}"),
        max_tokens: 240,
        lists: vec![ListSpec {
            key: "notes".into(),
            description: "Zero to three complete sentences, each under 20 words, each something new from the newest stretch worth remembering afterwards. Usually one, often none.".into(),
            at_most: 3,
        }],
        greedy: true,
    };
    let answer = model.complete(&request)?;
    let bullets = merge::tidy(parse_lists(&answer, &["notes"]).into_iter().next().unwrap_or_default().as_slice());
    Ok(running::filter(&bullets, previous, text))
}

/// The meeting write-up or the recap, as Markdown.
pub fn summarize(model: &mut dyn NoteModel, transcript: &str, title: &str, kind: Kind, progress: &mut dyn FnMut(&str)) -> Result<String, ModelError> {
    let text = trim_ws_nl(transcript);
    if text.is_empty() {
        return Err(ModelError::Empty);
    }
    let window = model.window_characters();
    if window >= WHOLE_MEETING_CHARACTERS && count(text) <= window {
        progress("Asking Claude…");
        let (instructions, prompt) = match kind {
            Kind::Meeting => (MEETING_INSTRUCTIONS, format!("Meeting: {title}\n\n{text}")),
            Kind::Recap => (RECAP_INSTRUCTIONS, format!("Meeting: {title}\nLast few minutes:\n\n{text}")),
        };
        let request = Request { instructions: instructions.into(), prompt, max_tokens: 8000, lists: vec![], greedy: false };
        return model.complete(&request).map(|a| trim_ws_nl(&a).to_string());
    }
    let mut limit = window;
    let mut attempt = 0;
    loop {
        let result = match kind {
            Kind::Meeting => meeting_notes(model, &split(text, limit), title, progress),
            // A recap is about the last few minutes, so when they run past one request it
            // reads the most recent stretch that fits.
            Kind::Recap => {
                progress("Summarizing…");
                let request = Request {
                    instructions: RECAP_INSTRUCTIONS.into(),
                    prompt: format!("Meeting: {title}\nLast few minutes:\n\n{}", tail(text, limit)),
                    max_tokens: 900,
                    lists: vec![],
                    greedy: false,
                };
                model.complete(&request).map(|a| trim_ws_nl(&a).to_string())
            }
        };
        match result {
            Err(ModelError::TooLong) if attempt < 3 => {
                // Halve the piece size and go again.
                attempt += 1;
                limit = (window >> attempt).max(1_500);
            }
            other => return other,
        }
    }
}

fn meeting_notes(model: &mut dyn NoteModel, chunks: &[String], title: &str, progress: &mut dyn FnMut(&str)) -> Result<String, ModelError> {
    let mut parts = vec![];
    for (i, chunk) in chunks.iter().enumerate() {
        progress(&if chunks.len() == 1 { "Taking notes…".to_string() } else { format!("Reading part {} of {}…", i + 1, chunks.len()) });
        parts.push(part_notes(model, title, i + 1, chunks.len(), chunk)?);
    }
    let mut sections = merge::merge(&parts);
    for section in Section::ALL {
        let bullets = sections.get(section).clone();
        let cap = longest_list(section);
        if bullets.len() <= cap {
            continue;
        }
        progress(&format!("Condensing {}…", section.heading().to_lowercase()));
        let shorter = shorten(model, section, &bullets, title, cap)?;
        if !shorter.is_empty() {
            sections.set(section, shorter);
        }
    }
    Ok(merge::render(&sections))
}

fn part_notes(model: &mut dyn NoteModel, title: &str, part: usize, of: usize, chunk: &str) -> Result<Sections, ModelError> {
    let what = if of == 1 { "The transcript".to_string() } else { format!("Part {part} of {of} of the transcript") };
    let lists = part_lists();
    let request = Request {
        instructions: PART_INSTRUCTIONS.into(),
        prompt: format!("Meeting: {title}\n{what}:\n\n{chunk}"),
        max_tokens: 700,
        lists: lists.clone(),
        greedy: true,
    };
    let answer = model.complete(&request)?;
    let keys: Vec<&str> = lists.iter().map(|l| l.key.as_str()).collect();
    let mut out = Sections::default();
    for (section, items) in Section::ALL.into_iter().zip(parse_lists(&answer, &keys)) {
        out.set(section, merge::tidy(&items));
    }
    Ok(out)
}

fn shorten(model: &mut dyn NoteModel, section: Section, bullets: &[String], title: &str, cap: usize) -> Result<Vec<String>, ModelError> {
    let list = bullets.iter().map(|b| format!("* {b}")).collect::<Vec<_>>().join("\n");
    let request = Request {
        instructions: shorten_instructions(section),
        prompt: format!("Meeting: {title}\n{}, in order:\n\n{list}", section.heading()),
        max_tokens: 600,
        lists: vec![ListSpec {
            key: "entries".into(),
            description: format!("At most {cap} entries, each under 25 words, in the original order, repeats merged, every name, number and date exactly as written"),
            at_most: cap,
        }],
        greedy: true,
    };
    let answer = model.complete(&request)?;
    Ok(merge::tidy(&parse_lists(&answer, &["entries"]).into_iter().next().unwrap_or_default()))
}

// MARK: text

/// Reads back the lists a model was asked for: the JSON object, fenced or not, or, when it
/// answered in prose anyway and only one list was asked for, its bullet lines.
pub fn parse_lists(content: &str, keys: &[&str]) -> Vec<Vec<String>> {
    let mut s = trim_ws_nl(content).to_string();
    if s.starts_with("```") {
        s = match s.find('\n') {
            Some(nl) => s[nl + 1..].to_string(),
            None => s,
        };
        if s.ends_with("```") {
            s.truncate(s.len() - 3);
        }
        s = trim_ws_nl(&s).to_string();
    }
    let strings = |items: &Vec<serde_json::Value>| -> Vec<String> { items.iter().filter_map(|i| i.as_str().map(String::from)).collect() };
    if keys.len() == 1 {
        // A bare list, when the model skipped the object around it.
        if let Ok(serde_json::Value::Array(items)) = serde_json::from_str::<serde_json::Value>(&s) {
            return vec![strings(&items)];
        }
    }
    let json = s.find('{').zip(s.rfind('}')).filter(|(a, b)| a < b).and_then(|(a, b)| serde_json::from_str::<serde_json::Value>(&s[a..=b]).ok());
    if let Some(serde_json::Value::Object(map)) = json {
        return keys
            .iter()
            .map(|k| match map.get(*k) {
                Some(serde_json::Value::Array(items)) => strings(items),
                Some(serde_json::Value::String(one)) => vec![one.clone()],
                _ => vec![],
            })
            .collect();
    }
    let mut out = vec![vec![]; keys.len()];
    if keys.len() == 1 {
        let numbered = |l: &str| {
            let b = l.as_bytes();
            b.len() > 2 && b[0].is_ascii_digit() && (b[1] == b'.' || b[1] == b')')
        };
        out[0] = s
            .lines()
            .map(str::trim)
            .filter(|l| l.starts_with("- ") || l.starts_with("* ") || l.starts_with("• ") || numbered(l))
            .map(String::from)
            .collect();
    }
    out
}

/// The longest run of whole lines at the end of `text` that fits in `max` characters, or its
/// last `max` characters when even the final line is longer than that.
pub fn tail(text: &str, max: usize) -> String {
    if count(text) <= max {
        return text.to_string();
    }
    let mut kept: Vec<&str> = vec![];
    let mut total = 0;
    for line in lines_keeping_empty(text).into_iter().rev() {
        let cost = count(line) + if kept.is_empty() { 0 } else { 1 };
        if total + cost > max {
            break;
        }
        kept.push(line);
        total += cost;
    }
    if kept.is_empty() {
        let n = count(text);
        return split_at_grapheme(text, n - max).1.to_string();
    }
    kept.reverse();
    kept.join("\n")
}

/// Splits on line boundaries so no transcript line is cut in half.
pub fn split(text: &str, max: usize) -> Vec<String> {
    if count(text) <= max {
        return vec![text.to_string()];
    }
    let mut chunks = vec![];
    let mut current = String::new();
    for line in lines_keeping_empty(text) {
        if count(&current) + count(line) + 1 > max && !current.is_empty() {
            chunks.push(std::mem::take(&mut current));
        }
        if count(line) > max {
            // One giant line: hard-split it.
            let mut rest = line;
            while count(rest) > max {
                let (head, tail) = split_at_grapheme(rest, max);
                chunks.push(head.to_string());
                rest = tail;
            }
            current = rest.to_string();
        } else {
            if !current.is_empty() {
                current.push('\n');
            }
            current.push_str(line);
        }
    }
    if !current.is_empty() {
        chunks.push(current);
    }
    chunks
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Answers from a script, and records what it was asked.
    struct Scripted {
        window: usize,
        answers: Vec<Result<String, ModelError>>,
        asked: Vec<Request>,
    }

    impl NoteModel for Scripted {
        fn name(&self) -> String {
            "scripted".into()
        }
        fn window_characters(&self) -> usize {
            self.window
        }
        fn complete(&mut self, request: &Request) -> Result<String, ModelError> {
            self.asked.push(request.clone());
            if self.answers.is_empty() {
                return Err(ModelError::Failed("no more answers".into()));
            }
            self.answers.remove(0)
        }
    }

    #[test]
    fn a_small_model_takes_notes_part_by_part() {
        let transcript = (0..40).map(|i| format!("[{i}:00] Others: line number {i} about the county permit and the inspection")).collect::<Vec<_>>().join("\n");
        let part = r#"{"keyPoints":["The county permit is due by the 18th"],"decisions":[],"actionItems":["Ted calls the county"],"openQuestions":["Inspection fee was paid"]}"#;
        let mut m = Scripted { window: 1_500, answers: vec![Ok(part.into()), Ok(part.into()), Ok(part.into())], asked: vec![] };
        let mut steps = vec![];
        let out = summarize(&mut m, &transcript, "Permit call", Kind::Meeting, &mut |s| steps.push(s.to_string())).unwrap();
        assert_eq!(m.asked.len(), 2, "two parts of at most 1,500 characters");
        assert!(m.asked.iter().all(|r| r.greedy && r.lists.len() == 4));
        assert_eq!(steps[0], "Reading part 1 of 2…");
        assert_eq!(out, "## Summary\n* The county permit is due by the 18th.\n* Inspection fee was paid.\n\n## Decisions\n* None\n\n## Action items\n* Ted calls the county.\n\n## Open questions\n* None");
    }

    #[test]
    fn too_long_halves_the_pieces() {
        let transcript = "x".repeat(5_000);
        let mut m = Scripted { window: 6_500, answers: vec![Err(ModelError::TooLong), Ok("- one\n- two".into())], asked: vec![] };
        let out = summarize(&mut m, &transcript, "t", Kind::Recap, &mut |_| {}).unwrap();
        assert_eq!(out, "- one\n- two");
        assert_eq!(count(&m.asked[1].prompt) - count("Meeting: t\nLast few minutes:\n\n"), 3_250);
    }

    #[test]
    fn claude_reads_the_meeting_whole() {
        let mut m = Scripted { window: 600_000, answers: vec![Ok("## Summary\n- ok".into())], asked: vec![] };
        summarize(&mut m, "[0:01] You: hello there", "t", Kind::Meeting, &mut |_| {}).unwrap();
        assert_eq!(m.asked[0].instructions, MEETING_INSTRUCTIONS);
        assert!(m.asked[0].lists.is_empty());
    }

    #[test]
    fn running_notes_are_filtered_against_the_stretch() {
        let answer = r#"```json
{"notes": ["Task: I", "Ted will call the county about the permit", "The permit is due Friday, October 18th"]}
```"#;
        let mut m = Scripted { window: 6_500, answers: vec![Ok(answer.into())], asked: vec![] };
        let notes = running_notes(&mut m, &[], "[0:05] Others: Ted will call the county about the permit.", "t").unwrap();
        assert_eq!(notes, vec!["Ted will call the county about the permit".to_string()]);
    }

    #[test]
    fn splitting_and_tails_keep_whole_lines() {
        assert_eq!(split("aaa\nbbb\nccc", 7), vec!["aaa\nbbb", "ccc"]);
        assert_eq!(split("abcdefghij", 4), vec!["abcd", "efgh", "ij"]);
        assert_eq!(tail("aaa\nbbb\nccc", 7), "bbb\nccc");
        assert_eq!(tail("abcdefghij", 4), "ghij");
        assert_eq!(parse_lists("- a\n* b\nprose\n1. c", &["notes"]), vec![vec!["- a".to_string(), "* b".to_string(), "1. c".to_string()]]);
        assert_eq!(parse_lists("[\"x\", \"y\"]", &["notes"]), vec![vec!["x".to_string(), "y".to_string()]]);
    }
}
