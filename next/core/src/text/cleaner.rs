//! Instant, rule-based cleanup of dictated text: filler words, spoken commands, dictionary
//! corrections and spellings, spoken numbers, John's style rules, tidy punctuation, sentence
//! capitals. Nothing here rewrites meaning. A port of the Swift `TextCleaner`, step for step and
//! in the same order; `cargo test` and the oracle in `next/oracle/` hold it to the Mac's output.

use super::glossary::{lowercase_terms, Replacement};
use super::matcher::GlossaryMatcher;
use super::numbers;
use super::unicode::{self, graphemes, icu, is_letter, is_number, is_punctuation_char, is_whitespace, lowercased, trim_ws, trim_ws_nl};
use fancy_regex::{Captures, NoExpand, Regex};
use once_cell::sync::Lazy;
use std::collections::HashSet;

#[derive(Clone, Debug)]
pub struct TextCleaner {
    pub glossary: Vec<String>,
    pub replacements: Vec<Replacement>,
    pub remove_fillers: bool,
    pub spoken_commands: bool,
    pub style_rules: bool,
    pub numbers_as_digits: bool,
    /// Each correction's pattern, built once rather than on every dictation.
    compiled: Vec<(Regex, String)>,
    protected: HashSet<String>,
}

fn re(pattern: &str) -> Regex {
    Regex::new(&icu(pattern)).unwrap_or_else(|e| panic!("bad pattern {pattern}: {e}"))
}

/// `replacingOccurrences(of:with:options: .regularExpression)`: every match, `$1` templates.
fn replace(re: &Regex, s: &str, with: &str) -> String {
    re.replace_all(s, with).into_owned()
}

macro_rules! regex {
    ($name:ident, $pattern:expr) => {
        static $name: Lazy<Regex> = Lazy::new(|| re($pattern));
    };
}

regex!(SQUARE, r"\[([^\]]*)\]");
regex!(ROUND, r"\(([^)]*)\)");
regex!(STARRED, r"\*[^*]*\*");
regex!(NOTES, r"♪+");
regex!(
    FILLERS,
    r"(?:,[ \t]*)?(?<![\w'-])(?:[Uu]+m+|[Uu]+h+|[Ee]r(?:m+)?|[Aa]+h+|[Hh]+m+|[Mm]m+-?[Hh]+m+|[Mm]hm)(?![\w'-]),?\s*"
);
regex!(YOU_KNOW, r"(?i)(?:,[ \t]*)?(?<![\w'])you know,\s*");
regex!(I_MEAN, r"(?i)(^|[.!?]\s+)I mean,\s*");
regex!(
    ENTER_RUN,
    r"(?i)[ \t]*([,.;:!?]?)[ \t]*(?<![\w'])((?:comma|period|full stop|colon|question mark|exclamation (?:mark|point)|enter)(?:[ \t]*[,.;:!?]?[ \t]+(?:comma|period|full stop|colon|question mark|exclamation (?:mark|point)|enter))+)(?![\w'])[,.;:!?]?[ \t]*"
);
regex!(NEW_LINE, r"(?i),?\s*\bnew line\b[,.]?\s*");
regex!(NEW_PARAGRAPH, r"(?i),?\s*\bnew paragraph\b[,.]?\s*");
regex!(EXCLAMATION, r"(?i)\s*[,.]?\s*\bexclamation (?:mark|point)\b[,.]?");
regex!(QUESTION, r"(?i)\s*[,.]?\s*\bquestion mark\b[,.]?");
regex!(MARK_THEN_DOT, r"([!?])\s*[.,]");
regex!(DASH, r"[ \t]*[—–][ \t]*");
regex!(SPACED_HYPHEN, r"[ \t]+-[ \t]+");
regex!(SEMICOLON, r";[ \t]*");
regex!(SPACES, r"[ \t]+");
regex!(SPACE_NEWLINE, r" ?\n ?");
regex!(SPACE_BEFORE_MARK, r"[ \t]+([,.!?:;])");
regex!(NEWLINE_COMMA, r"\n[ \t]*,[ \t]*");
regex!(REPEATED_MARK, r"([,.!?:])\1+");
regex!(COMMA_PERIOD, r",\s*\.");
regex!(CLOCK, r"(?i)\b(\d{1,2})[ .](\d{2})(?=\s*[ap]\.?m\b)");
regex!(LEADING_MARKS, r"^[,.\s]+");
regex!(TRAILING_MARKS, r"[,:;\s]+$");

const NOISE_WORDS: &[&str] = &[
    "music", "laughs", "laughter", "laughing", "chuckles", "applause", "clapping", "cheering", "inaudible",
    "unintelligible", "indistinct", "silence", "blank", "audio", "noise", "background", "coughs", "coughing",
    "sighs", "sigh", "speaking", "foreign", "language", "crosstalk", "typing", "pause", "static", "beep", "door",
    "phone", "ringing", "upbeat", "soft", "gentle", "dramatic", "breathing", "sniffs", "mumbles", "murmurs",
    "speech", "sound", "sounds", "instrumental", "singing", "humming", "whispering", "clicking", "wind", "rain",
    "crying", "screaming", "gasps", "groans", "grunts", "whistling", "bell", "bells", "chime", "chimes", "intro",
    "outro", "no", "clears", "throat", "sneezes", "yawns", "engine", "traffic",
];

/// Whole outputs the engines invent on silence.
pub const SILENCE_HALLUCINATIONS: &[&str] = &[
    "thank you", "thanks for watching", "thank you for watching", "you", "bye", "the end",
    "subtitles by the amara.org community", "please subscribe", "so", "oh", "hmm", "mm", "mhm", "uh", "um",
];

/// Words a period does not end a sentence after: "p.m.", "e.g.", "etc.", titles.
const ABBREVIATIONS: &[&str] =
    &["p.m", "a.m", "e.g", "i.e", "etc", "vs", "approx", "dept", "mr", "mrs", "ms", "dr", "prof", "st", "mt", "jr", "sr", "inc", "ltd"];

const SENTENCE_ENDERS: &[&str] = &[".", "!", "?", "\n", "。", "！", "？", "…", "។", "؟"];
const CLOSING_MARKS: &[&str] = &["\"", "'", "”", "’", ")", "]"];

impl TextCleaner {
    pub fn new(glossary: Vec<String>, replacements: Vec<Replacement>) -> Self {
        let compiled = compile_replacements(&replacements);
        let protected = lowercase_terms(&replacements, &glossary);
        TextCleaner { glossary, replacements, remove_fillers: true, spoken_commands: true, style_rules: true, numbers_as_digits: true, compiled, protected }
    }

    pub fn clean(&self, raw: &str) -> String {
        let text = trim_ws_nl(raw);
        if text.is_empty() {
            return String::new();
        }
        let mut text = strip_bracketed_noise(text);
        if text.is_empty() {
            return String::new();
        }
        text = apply_compiled(&text, &self.compiled);
        if self.remove_fillers {
            text = remove_fillers(&text);
        }
        if self.spoken_commands {
            text = apply_spoken_commands(&text);
        }
        text = GlossaryMatcher::new(&self.glossary).apply(&text);
        // After the glossary, so a term that contains a number word still matches.
        if self.numbers_as_digits {
            text = numbers::apply(&text);
        }
        if self.style_rules {
            text = apply_style_rules(&text);
        }
        text = tidy_whitespace_and_punctuation(&text);
        // Last, and told what not to touch: the two steps above produce exact spellings, and
        // capitalizing the first letter of a sentence would undo them.
        capitalize_sentences(&text, &self.protected)
    }
}

/// John's style rules alone (no em dashes, no semicolons), for text a model wrote.
pub fn apply_style(s: &str) -> String {
    apply_style_rules(s)
}

/// Exact phrase corrections from the dictionary, case-insensitive, whole words only. Runs
/// before the fuzzy glossary pass.
pub fn apply_replacements(s: &str, replacements: &[Replacement]) -> String {
    apply_compiled(s, &compile_replacements(replacements))
}

fn compile_replacements(replacements: &[Replacement]) -> Vec<(Regex, String)> {
    replacements
        .iter()
        .filter_map(|r| {
            let from = trim_ws(&r.from);
            if from.is_empty() {
                return None;
            }
            let pattern = format!(r"(?i)(?<![\w']){}(?![\w'])", fancy_regex::escape(from));
            Regex::new(&pattern).ok().map(|rx| (rx, r.to.clone()))
        })
        .collect()
}

fn apply_compiled(s: &str, compiled: &[(Regex, String)]) -> String {
    let mut out = s.to_string();
    for (rx, to) in compiled {
        out = rx.replace_all(&out, NoExpand(to)).into_owned();
    }
    out
}

/// The engines mark non-speech with bracketed tags: [BLANK_AUDIO], (music), *laughs*, ♪.
/// Those go; dictated parentheses such as "(408) 555-1234" stay. If nothing else is left the
/// clip was empty.
pub fn strip_bracketed_noise(s: &str) -> String {
    let mut out = s.to_string();
    for rx in [&*SQUARE, &*ROUND] {
        let mut result = String::new();
        let mut last = 0;
        for caps in rx.captures_iter(&out).flatten() {
            let m = caps.get(0).unwrap();
            result.push_str(&out[last..m.start()]);
            if is_noise_tag(caps.get(1).map_or("", |g| g.as_str())) {
                result.push(' ');
            } else {
                result.push_str(m.as_str());
            }
            last = m.end();
        }
        result.push_str(&out[last..]);
        out = result;
    }
    out = replace(&STARRED, &out, " ");
    out = replace(&NOTES, &out, " ");
    let out = trim_ws_nl(&out).to_string();
    let lowered = lowercased(&out);
    let core = lowered.trim_matches(|c: char| is_punctuation_char(c) || unicode::is_cs_whitespace(c));
    if SILENCE_HALLUCINATIONS.contains(&core) {
        return String::new();
    }
    out
}

/// A bracket the recognizer used as a non-speech tag, not dictated text.
fn is_noise_tag(inner: &str) -> bool {
    let t = trim_ws(inner);
    if t.is_empty() || t.contains('_') {
        return true;
    }
    if graphemes(t).iter().any(|g| is_number(g)) {
        return false;
    }
    let lower = lowercased(t);
    let words: Vec<&str> = lower.split([' ', '-']).filter(|w| !w.is_empty()).collect();
    words.len() <= 3 && words.iter().all(|w| NOISE_WORDS.contains(w))
}

/// Only tokens that are filler in every context. "like" and "so" carry meaning too often.
pub fn remove_fillers(s: &str) -> String {
    let out = replace(&FILLERS, s, " ");
    let out = replace(&YOU_KNOW, &out, " ");
    let out = trim_ws(&out).to_string();
    replace(&I_MEAN, &out, "$1")
}

/// Phrases nobody says literally in prose. "period" and "comma" alone are not commands: the
/// engines punctuate from prosody already and both words are common in real sentences.
pub fn apply_spoken_commands(s: &str) -> String {
    let mut out = apply_enter_runs(s);
    out = replace(&NEW_LINE, &out, "\n");
    out = replace(&NEW_PARAGRAPH, &out, "\n\n");
    out = replace(&EXCLAMATION, &out, "!");
    out = replace(&QUESTION, &out, "?");
    replace(&MARK_THEN_DOT, &out, "$1")
}

/// "Hi Solomon comma enter enter where's that" is "Hi Solomon,\n\nwhere's that". Each "enter"
/// is one line break and a punctuation word in the run is its mark. Only a run of two or more
/// command words with at least one "enter" counts, so "press enter" stays words.
pub fn apply_enter_runs(s: &str) -> String {
    let mut out = String::new();
    let mut last = 0;
    for caps in ENTER_RUN.captures_iter(s).flatten() {
        let m = caps.get(0).unwrap();
        let run = caps.get(2).map_or("", |g| g.as_str());
        let lower = lowercased(run);
        let words: Vec<&str> = lower.split(|c: char| !is_letter_or_mark(c)).filter(|w| !w.is_empty()).collect();
        let breaks = words.iter().filter(|w| **w == "enter").count();
        if breaks == 0 {
            continue;
        }
        // One "enter" with a mark between it and the word before is prose: "after the trial
        // period, enter your card". Two in a row are a command however they were punctuated.
        if breaks == 1 && run.chars().any(|c| ",.;:!?".contains(c)) {
            continue;
        }
        let marks = [("comma", ","), ("period", "."), ("stop", "."), ("colon", ":"), ("question", "?"), ("exclamation", "!")];
        // The last mark said wins; with none, the model's own mark before the run stays.
        let spoken = words.iter().rev().find_map(|w| marks.iter().find(|(k, _)| k == w).map(|(_, v)| *v));
        let mark = spoken.unwrap_or_else(|| caps.get(1).map_or("", |g| g.as_str()));
        out.push_str(&s[last..m.start()]);
        out.push_str(mark);
        out.push_str(&"\n".repeat(breaks));
        last = m.end();
    }
    out.push_str(&s[last..]);
    out
}

/// `CharacterSet.letters`: categories L* and M*.
fn is_letter_or_mark(c: char) -> bool {
    use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};
    matches!(c.general_category_group(), GeneralCategoryGroup::Letter | GeneralCategoryGroup::Mark)
}

pub fn apply_style_rules(s: &str) -> String {
    // Em and en dashes used as punctuation become a comma. Horizontal space only, so a newline a
    // spoken command just put in survives.
    let out = replace(&DASH, s, ", ");
    let out = replace(&SPACED_HYPHEN, &out, ", ");
    // Semicolons become periods, and the next word gets its capital later.
    replace(&SEMICOLON, &out, ". ")
}

pub fn tidy_whitespace_and_punctuation(s: &str) -> String {
    let mut out = replace(&SPACES, s, " ");
    out = replace(&SPACE_NEWLINE, &out, "\n");
    out = replace(&SPACE_BEFORE_MARK, &out, "$1");
    out = replace(&NEWLINE_COMMA, &out, "\n"); // a dash that became ", " after a spoken new line
    out = replace(&REPEATED_MARK, &out, "$1");
    out = replace(&COMMA_PERIOD, &out, ".");
    // Clock times the engines write without a colon: "3 45 p.m." is "3:45 p.m.".
    out = replace(&CLOCK, &out, "$1:$2");
    out = replace(&LEADING_MARKS, &out, "");
    out = trim_ws_nl(&out).to_string();
    // A trailing comma or colon (usually where a filler was cut off) is not an ending.
    out = replace(&TRAILING_MARKS, &out, "");
    // A dictation is a sentence: make sure it ends like one. Closing quotes and brackets don't
    // count, and neither does a Chinese, Japanese or Khmer full stop already there.
    let chars = graphemes(&out);
    let core_last = chars.iter().rev().find(|g| !CLOSING_MARKS.contains(g)).copied();
    if let Some(last) = core_last {
        if !SENTENCE_ENDERS.contains(&last) {
            let stop = full_stop(last);
            out.push_str(stop);
        }
    }
    out
}

/// The full stop for the script of the last letter: "。" after Chinese or Japanese, "។" after
/// Khmer, "." otherwise.
fn full_stop(g: &str) -> &'static str {
    let v = g.chars().next().map_or(0, |c| c as u32);
    match v {
        0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x3000..=0x303F => "。",
        0x1780..=0x17FF => "។",
        _ => ".",
    }
}

/// The run of non-space characters at `i`, without the punctuation that ends the sentence.
/// "kkwinedf." is the term; "whisper.cpp" keeps its dot.
fn word_at(chars: &[String], i: usize) -> String {
    let mut j = i;
    while j < chars.len() && !is_whitespace(&chars[j]) {
        j += 1;
    }
    let mut w: Vec<&str> = chars[i..j].iter().map(String::as_str).collect();
    while let Some(last) = w.last() {
        if is_letter(last) || is_number(last) {
            break;
        }
        w.pop();
    }
    w.concat()
}

pub fn capitalize_sentences(s: &str, protected: &HashSet<String>) -> String {
    if s.is_empty() {
        return String::new();
    }
    let mut chars: Vec<String> = graphemes(s).into_iter().map(str::to_string).collect();
    let mut capitalize_next = true;
    for i in 0..chars.len() {
        let c = chars[i].clone();
        let letter = is_letter(&c);
        if capitalize_next && letter && !protected.is_empty() && protected.contains(&word_at(&chars, i)) {
            capitalize_next = false; // a spelling the user chose; leave it alone
        } else if capitalize_next && letter {
            // "ß" uppercases to "SS" and ligatures to two letters; leave those alone.
            let up = unicode::uppercased(&c);
            if unicode::count(&up) == 1 {
                chars[i] = up;
            }
            capitalize_next = false;
        } else if c == "\n" {
            capitalize_next = true;
        } else if c == "." || c == "!" || c == "?" {
            // Only a terminator that ends the token ends a sentence: not the dots in
            // "example.com", "whisper.cpp" or "p.m.", nor the "?" in a URL query.
            let next = chars.get(i + 1);
            let ends_token = next.is_none_or(|n| is_whitespace(n) || CLOSING_MARKS.contains(&n.as_str()));
            if ends_token {
                if !(c == "." && is_abbreviation(i, &chars)) {
                    capitalize_next = true;
                }
            } else {
                capitalize_next = false;
            }
        } else if !is_whitespace(&c) && !["\"", "'", "“", "‘", "("].contains(&c.as_str()) {
            capitalize_next = false;
        }
    }
    chars.concat()
}

/// Is the word before index `i` (letters and dots) an abbreviation or an initial?
fn is_abbreviation(i: usize, chars: &[String]) -> bool {
    let mut word: Vec<&str> = Vec::new();
    let mut j = i;
    while j > 0 {
        let g = chars[j - 1].as_str();
        if is_letter(g) || g == "." {
            word.push(g);
            j -= 1;
        } else {
            break;
        }
    }
    if word.is_empty() {
        return false;
    }
    word.reverse();
    let w = lowercased(&word.concat());
    if ABBREVIATIONS.contains(&w.as_str()) {
        return true;
    }
    // "u.s", "a.m", "e.g": single letters separated by dots.
    w.contains('.') && w.split('.').filter(|p| !p.is_empty()).all(|p| unicode::count(p) == 1)
}

/// For tests and the oracle: a cleaner with the current Mac defaults.
pub fn clean_with(glossary: &[String], replacements: &[Replacement], raw: &str) -> String {
    TextCleaner::new(glossary.to_vec(), replacements.to_vec()).clean(raw)
}

#[allow(dead_code)]
fn _unused(_: &Captures) {}

#[cfg(test)]
mod tests {
    use super::*;

    fn clean(raw: &str) -> String {
        clean_with(&["Lin Flow".to_string(), "Claude".to_string()], &[Replacement::new("K Wynn E D F", "kkwinedf")], raw)
    }

    #[test]
    fn basics() {
        assert_eq!(clean("um so I think, uh, we should go"), "So I think we should go.");
        assert_eq!(clean("[BLANK_AUDIO]"), "");
        assert_eq!(clean("Thank you."), "");
        assert_eq!(clean("call (408) 555-1234"), "Call (408) 555-1234.");
        assert_eq!(clean("this is great — really great; yes"), "This is great, really great. Yes.");
        assert_eq!(clean("meet at 3 45 p.m. today"), "Meet at 3:45 p.m. today.");
    }

    #[test]
    fn spoken_commands() {
        assert_eq!(clean("Hi Solomon comma enter enter where's that"), "Hi Solomon,\n\nWhere's that.");
        assert_eq!(clean("press enter to continue"), "Press enter to continue.");
        assert_eq!(clean("first line new line second line"), "First line\nSecond line.");
        assert_eq!(clean("really question mark"), "Really?");
    }

    #[test]
    fn protected_lowercase_terms() {
        assert_eq!(clean("K Wynn E D F is my handle"), "kkwinedf is my handle.");
    }

    #[test]
    fn numbers_and_glossary() {
        assert_eq!(clean("I use Lend Flow with twenty two people"), "I use Lin Flow with 22 people.");
    }
}
