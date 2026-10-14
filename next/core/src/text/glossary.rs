//! The dictionary's two files, in the formats both current apps read and write: `vocab.txt`,
//! one name or term per line, and `replacements.txt`, one `heard => meant` per line.

use super::unicode::{is_lowercase, trim_ws};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// A dictionary correction: what the recognizer tends to write, and what was meant.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Replacement {
    pub from: String,
    pub to: String,
    /// Added by Lin Flow from an edit, rather than typed by hand.
    #[serde(default)]
    pub learned: bool,
}

impl Replacement {
    pub fn new(from: &str, to: &str) -> Self {
        Replacement { from: from.to_string(), to: to.to_string(), learned: false }
    }

    pub fn learned(from: &str, to: &str) -> Self {
        Replacement { from: from.to_string(), to: to.to_string(), learned: true }
    }

    /// Two rules with the same left side, in any case, are the same rule.
    pub fn id(&self) -> String {
        super::unicode::lowercased(&self.from)
    }
}

/// Marks a correction Lin Flow learned from an edit, in `replacements.txt`.
pub const LEARNED_MARKER: &str = "# learned";
const REPLACEMENTS_HEADER: &str = "# Lin Flow corrections: what was heard => what you meant, one per line.";
const KEPT_HEADER: &str = "# Lines Lin Flow could not read, kept as you wrote them.";

/// The terms a fresh install starts with.
pub const DEFAULT_TERMS: &[&str] = &[
    "John Lin", "Lin Flow", "Wispr Flow", "Parakeet", "whisper.cpp", "MLX", "WORKBRAIN", "MINISTRYBRAIN",
    "Claude", "Claude Code", "Anthropic", "GitHub", "Northwind", "Sunnyvale", "Santa Cruz", "Cambodia", "Khmer",
];

/// Swift's `split(whereSeparator: \.isNewline)`: lines, without the empty ones.
pub(crate) fn lines(text: &str) -> impl Iterator<Item = &str> {
    text.split(['\n', '\u{B}', '\u{C}', '\r', '\u{85}', '\u{2028}', '\u{2029}']).filter(|l| !l.is_empty())
}

/// The terms a `vocab.txt` holds, with no fallback: the shared dictionary has to tell an
/// emptied list from one never written.
pub fn parse_terms(text: &str) -> Vec<String> {
    lines(text).map(trim_ws).filter(|s| !s.is_empty() && !s.starts_with('#')).map(str::to_string).collect()
}

/// The terms to use: the file's, or the defaults when it holds none.
pub fn terms_or_defaults(text: Option<&str>) -> Vec<String> {
    if let Some(t) = text {
        let terms = parse_terms(t);
        if !terms.is_empty() {
            return terms;
        }
    }
    DEFAULT_TERMS.iter().map(|s| s.to_string()).collect()
}

/// The `vocab.txt` written for these terms.
pub fn terms_file(terms: &[String]) -> String {
    let body: Vec<&str> = terms.iter().map(|t| trim_ws(t)).filter(|t| !t.is_empty()).collect();
    format!("# Lin Flow glossary: one name or term per line.\n{}\n", body.join("\n"))
}

/// The first `vocab.txt` on a new computer.
pub fn seed_file() -> String {
    format!(
        "# Lin Flow glossary: one name or term per line. Whisper is primed with these and\n# the cleanup pass snaps near-misses to this exact spelling.\n{}\n",
        DEFAULT_TERMS.join("\n")
    )
}

pub fn parse_replacements(data: &str) -> Vec<Replacement> {
    lines(data)
        .filter_map(|line| {
            let s = trim_ws(line);
            if s.is_empty() || s.starts_with('#') {
                return None;
            }
            let at = s.find("=>")?;
            let from = trim_ws(&s[..at]);
            let mut to = trim_ws(&s[at + 2..]).to_string();
            let mut learned = false;
            if to.ends_with(LEARNED_MARKER) {
                learned = true;
                to = trim_ws(&to[..to.len() - LEARNED_MARKER.len()]).to_string();
            }
            if from.is_empty() {
                None
            } else {
                Some(Replacement { from: from.to_string(), to, learned })
            }
        })
        .collect()
}

/// The `replacements.txt` to write, carrying forward every line the parser could not read: a
/// comment, a blank-separated group heading, an arrow typed as `->`. A line Lin Flow does not
/// understand is not a line it may throw away.
pub fn replacements_file(replacements: &[Replacement], existing: &str) -> String {
    let kept: Vec<&str> = lines(existing)
        .filter(|line| {
            let s = trim_ws(line);
            if s.is_empty() || s == REPLACEMENTS_HEADER || s == KEPT_HEADER {
                return false;
            }
            !(!s.starts_with('#') && s.contains("=>"))
        })
        .collect();
    let rules: Vec<String> = replacements
        .iter()
        .map(|r| format!("{} => {}{}", r.from, r.to, if r.learned { format!("\t{LEARNED_MARKER}") } else { String::new() }))
        .collect();
    let mut body = format!("{REPLACEMENTS_HEADER}\n{}\n", rules.join("\n"));
    if !kept.is_empty() {
        body.push_str(&format!("\n{KEPT_HEADER}\n{}\n", kept.join("\n")));
    }
    body
}

/// The Dictionary's reading order: what Lin Flow learned most recently first, then the rules
/// written by hand, in the order they were written.
pub fn display_order(replacements: &[Replacement]) -> Vec<Replacement> {
    let mut out: Vec<Replacement> = replacements.iter().filter(|r| r.learned).rev().cloned().collect();
    out.extend(replacements.iter().filter(|r| !r.learned).cloned());
    out
}

/// The Whisper decoder prompt: a plain comma list reads as "here is how these are spelled".
pub fn initial_prompt(terms: &[String]) -> String {
    if terms.is_empty() {
        String::new()
    } else {
        format!("{}.", terms.join(", "))
    }
}

/// Terms spelled with a lowercase initial on purpose (a username, a shell command, a package
/// name), from the right-hand side of the corrections and from the glossary. Sentence
/// capitalization leaves these alone.
pub fn lowercase_terms(replacements: &[Replacement], glossary: &[String]) -> HashSet<String> {
    let mut out = HashSet::new();
    for s in replacements.iter().map(|r| r.to.as_str()).chain(glossary.iter().map(String::as_str)) {
        let Some(first) = s.split(char::is_whitespace).find(|w| !w.is_empty()) else { continue };
        let Some(head) = super::unicode::graphemes(first).first().copied() else { continue };
        if is_lowercase(head) {
            out.insert(first.to_string());
        }
    }
    out
}

/// The English word list both apps use (BSD `web2`, 235,976 words), lowercased. The Mac reads
/// it from `/usr/share/dict/words` and Windows embeds the same file; so does this crate.
pub static ENGLISH_WORDS: Lazy<HashSet<String>> = Lazy::new(|| word_set(include_str!("../../resources/words.txt")));

/// One word a line, lowercased. A Windows checkout can end every line in "\r\n", and a word
/// that kept its "\r" would match nothing, so no everyday word would be safe from a name.
fn word_set(text: &str) -> HashSet<String> {
    text.lines().filter(|w| !w.is_empty()).map(super::unicode::lowercased).collect()
}

pub fn is_english_word(w: &str) -> bool {
    ENGLISH_WORDS.contains(w)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replacements_round_trip_and_keep_unreadable_lines() {
        let file = "# mine\nwisper flow => Wispr Flow\nK Wynn E D F => kkwinedf\t# learned\nbad -> arrow\n";
        let rules = parse_replacements(file);
        assert_eq!(rules.len(), 2);
        assert!(rules[1].learned);
        assert_eq!(rules[1].to, "kkwinedf");
        let out = replacements_file(&rules, file);
        assert!(out.contains("bad -> arrow"));
        assert!(out.contains("# mine"));
        assert_eq!(parse_replacements(&out), rules);
        // Saving twice does not stack the kept section's heading.
        let again = replacements_file(&rules, &out);
        assert_eq!(again.matches(KEPT_HEADER).count(), 1);
    }

    #[test]
    fn terms() {
        assert_eq!(parse_terms("# c\n Lin Flow \n\nClaude\n"), vec!["Lin Flow", "Claude"]);
        assert_eq!(terms_or_defaults(Some("# only a comment\n")).len(), DEFAULT_TERMS.len());
        let lower = lowercase_terms(&[Replacement::new("K Wynn", "kkwinedf")], &["whisper.cpp".into(), "Claude".into()]);
        assert!(lower.contains("kkwinedf") && lower.contains("whisper.cpp") && !lower.contains("Claude"));
    }

    #[test]
    fn word_list() {
        assert!(is_english_word("cloud"));
        // Proper names in web2 are words too, lowercased: "Claude" is one.
        assert!(is_english_word("claude"));
        assert!(!is_english_word("parakeets"));
        assert!(ENGLISH_WORDS.len() > 200_000);
        let crlf = word_set("Cloud\r\ngrove\r\n");
        assert!(crlf.contains("cloud") && crlf.contains("grove") && crlf.len() == 2);
    }
}
