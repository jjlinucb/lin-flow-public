//! Learning from edits: turning "what Lin Flow wrote" and "what the text says now" into
//! dictionary corrections, applied outright or offered, per the learning setting.
//!
//! The hard part is telling a mishearing from an edit. "K Wynn E D F" becoming "kkwinedf" is worth
//! learning forever; "Thursday" becoming "Friday" is a change of mind and would be a destructive
//! rule. A port of the Swift `LearnedCorrections` and `CorrectionLearning`, whose comments carry
//! the dated incidents behind each guard.

use crate::text::cleaner::apply_replacements;
use crate::text::glossary::{is_english_word, Replacement};
use crate::text::matcher::{key, levenshtein, name_key, tolerance};
use crate::text::unicode::{count, graphemes, is_letter, is_number, is_punctuation_char, is_uppercase, is_whitespace, lowercased};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// The learning setting.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum LearnMode {
    Off,
    /// Everything waits for a click.
    Ask,
    /// Sure rules go straight in; suspected ones wait.
    #[default]
    Auto,
}

/// Words too common to ever become a rule: one bad auto-add here would rewrite everything.
const STOPWORDS: &[&str] = &[
    "the", "and", "but", "for", "not", "you", "your", "our", "its", "it's", "this", "that", "these", "those", "with", "from", "have",
    "has", "had", "was", "were", "will", "would", "should", "could", "can", "are", "been", "being", "they", "them", "their", "there",
    "then", "than", "when", "what", "who", "how", "why", "all", "any", "some", "one", "two", "just", "like", "get", "got", "make",
    "made", "want", "know", "think", "now", "here", "out", "about", "into", "over", "more", "most", "very", "too", "also", "yes",
    "yeah", "okay",
];

fn is_stopword(w: &str) -> bool {
    STOPWORDS.contains(&w)
}

/// At most this many rules from one dictation: a heavily rewritten one is not a mishearing.
const MAX_PER_DICTATION: usize = 3;
/// Longest phrase either side of a rule may be.
pub const MAX_PHRASE_WORDS: usize = 6;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Confidence {
    Apply,
    Suggest,
}

/// `trimmingCharacters(in: .punctuationCharacters)`.
fn trim_punctuation(s: &str) -> &str {
    s.trim_matches(is_punctuation_char)
}

/// A fix too distant to write but too clean to throw away: one word swapped for one
/// capitalized word, which is what a misheard name looks like. Only ever offered.
pub fn worth_offering(from: &str, to: &str) -> bool {
    let f = trim_punctuation(from);
    let t = trim_punctuation(to);
    if f.contains(' ') || t.contains(' ') {
        return false;
    }
    if count(f) < 4 || count(t) < 4 || lowercased(f) == lowercased(t) {
        return false;
    }
    if is_stopword(&lowercased(f)) {
        return false;
    }
    let Some(head) = graphemes(t).first().copied() else { return false };
    if !is_uppercase(head) {
        return false;
    }
    let nameish = |g: &&str| is_letter(g) || *g == "'" || *g == "\u{2019}" || *g == "-";
    graphemes(f).iter().all(nameish) && graphemes(t).iter().all(nameish)
}

/// Every rule an edit implies, each marked with how sure Lin Flow is of it.
pub fn scored(wrote: &str, now: &str, existing: &[Replacement]) -> Vec<(Replacement, Confidence)> {
    let a = words(wrote);
    let b = words(now);
    if a.is_empty() || b.is_empty() || a == b {
        return vec![];
    }
    // A near-total rewrite is not a set of mishearings.
    if a.len() > 400 || b.len() > 400 {
        return vec![];
    }
    let mut out = Vec::new();
    let mut seen: HashSet<String> = existing.iter().map(Replacement::id).collect();
    for (ra, rb) in substitutions(&a, &b) {
        if ra.is_empty() || rb.is_empty() || ra.len() > MAX_PHRASE_WORDS || rb.len() > MAX_PHRASE_WORDS {
            continue;
        }
        let from = trim_phrase(&a[ra].join(" "));
        let to = trim_phrase(&b[rb].join(" "));
        let confidence = if plausible(&from, &to) {
            Confidence::Apply
        } else if worth_offering(&from, &to) {
            Confidence::Suggest
        } else {
            continue;
        };
        // Already handled, by this exact rule or by the rules as a whole.
        let candidate = Replacement::learned(&from, &to);
        if seen.contains(&candidate.id()) || apply_replacements(&from, existing) == to {
            continue;
        }
        seen.insert(candidate.id());
        out.push((candidate, confidence));
        if out.len() == MAX_PER_DICTATION {
            break;
        }
    }
    out
}

/// Whether a phrase is made of ordinary English words, words John might have meant. A single
/// letter never counts, which is how "K Wynn E D F" stays learnable though "lynn" is a word.
pub fn everyday_english(phrase: &str) -> bool {
    let lower = lowercased(phrase);
    let mut words: Vec<String> = Vec::new();
    let mut cur = String::new();
    for g in graphemes(&lower) {
        if !is_letter(g) && g != "'" && g != "\u{2019}" {
            if !cur.is_empty() {
                words.push(std::mem::take(&mut cur));
            }
        } else {
            cur.push_str(g);
        }
    }
    if !cur.is_empty() {
        words.push(cur);
    }
    let words: Vec<String> = words.iter().map(|w| w.trim_matches(['\'', '\u{2019}']).to_string()).collect();
    if !words.iter().any(|w| count(w) >= 3) {
        return false;
    }
    words.iter().all(|w| count(w) >= 2 && is_english(w))
}

/// One word, or an ordinary inflection of one.
pub fn is_english(w: &str) -> bool {
    if is_english_word(w) {
        return true;
    }
    for suffix in ["s", "es", "ed", "d", "ing"] {
        if !(count(w) > count(suffix) + 2 && w.ends_with(suffix)) {
            continue;
        }
        let stem = &w[..w.len() - suffix.len()];
        if is_english_word(stem) || is_english_word(&format!("{stem}e")) {
            return true;
        }
        let g = graphemes(stem);
        if g.len() >= 2 && g[g.len() - 1] == g[g.len() - 2] && is_english_word(&g[..g.len() - 1].concat()) {
            return true; // "stopped" -> "stop"
        }
        if stem.ends_with('i') && is_english_word(&format!("{}y", &stem[..stem.len() - 1])) {
            return true; // "tried" -> "try"
        }
    }
    false
}

/// Whether one phrase plausibly became the other by mishearing rather than by editing.
pub fn plausible(from: &str, to: &str) -> bool {
    let f = lowercased(from);
    let t = lowercased(to);
    if f.is_empty() || t.is_empty() || (f == t && from == to) {
        return false;
    }
    let alnum = |s: &str| graphemes(s).iter().any(|g| is_letter(g) || is_number(g));
    if !alnum(from) || !alnum(to) {
        return false;
    }
    let f_words: Vec<&str> = f.split(' ').filter(|w| !w.is_empty()).collect();
    // A single short or everyday word is too dangerous to bind globally.
    if f_words.len() == 1 && (count(&f) < 4 || is_stopword(trim_punctuation(&f))) {
        return false;
    }
    // Same letters and digits in the same order: only the spacing or the punctuation moved.
    let body = |s: &str| -> String { graphemes(s).into_iter().filter(|g| is_letter(g) || is_number(g)).collect() };
    if body(&f) == body(&t) && f != t {
        return true;
    }
    // An everyday English word on the left is a word John might have meant, unless the rule is
    // a name spelled another way ("Lynn" => "Lin").
    let same_name = graphemes(to).first().is_some_and(|g| is_uppercase(g)) && name_key(&f) == name_key(&t);
    if everyday_english(from) && !same_name {
        return false;
    }
    if f == t {
        return true; // capitalization only
    }
    // The consonant skeleton is what makes "k wynn e d f" and "kkwinedf" the same word.
    if key(&f) == key(&t) {
        return true;
    }
    levenshtein(&f, &t) <= tolerance(count(&f).min(count(&t)))
}

/// Contiguous runs where the two word lists disagree, as (range in a, range in b).
pub fn substitutions(a: &[String], b: &[String]) -> Vec<(std::ops::Range<usize>, std::ops::Range<usize>)> {
    // Longest common subsequence over words, then the gaps between the matches.
    let mut table = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for i in (0..a.len()).rev() {
        for j in (0..b.len()).rev() {
            table[i][j] = if a[i] == b[j] { table[i + 1][j + 1] + 1 } else { table[i + 1][j].max(table[i][j + 1]) };
        }
    }
    let mut pairs = Vec::new();
    let (mut i, mut j) = (0, 0);
    while i < a.len() || j < b.len() {
        if i < a.len() && j < b.len() && a[i] == b[j] {
            i += 1;
            j += 1;
            continue;
        }
        let (si, sj) = (i, j);
        while i < a.len() || j < b.len() {
            if i < a.len() && j < b.len() && a[i] == b[j] {
                break;
            }
            if j >= b.len() {
                i += 1;
            } else if i >= a.len() {
                j += 1;
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1;
            } else {
                j += 1;
            }
        }
        pairs.push((si..i, sj..j));
    }
    pairs
}

/// Words split on whitespace and newlines.
pub fn words(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for g in graphemes(s) {
        if is_whitespace(g) || super::text::unicode::is_newline(g) {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
        } else {
            cur.push_str(g);
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Drops the punctuation a phrase picked up from its sentence. Inner marks survive
/// ("whisper.cpp"), and "#" is kept at either end so "C#" stays itself.
pub fn trim_phrase(s: &str) -> String {
    let g = graphemes(s);
    let keep = |x: &&str| is_letter(x) || is_number(x) || *x == "#";
    let Some(start) = g.iter().position(keep) else { return String::new() };
    let end = g.iter().rposition(keep).unwrap();
    g[start..=end].concat()
}

/// What came of an edit: rules added outright, and rules waiting to be confirmed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Outcome {
    pub added: Vec<Replacement>,
    pub suggested: Vec<Replacement>,
}

impl Outcome {
    pub fn is_empty(&self) -> bool {
        self.added.is_empty() && self.suggested.is_empty()
    }
}

/// The one thing that changed in an edit, when exactly one thing did. Used only to say what was
/// seen; it decides nothing.
pub fn lone_pair(wrote: &str, now: &str) -> Option<(String, String)> {
    let a = words(wrote);
    let b = words(now);
    if a.is_empty() || b.is_empty() || a == b || a.len() > 400 || b.len() > 400 {
        return None;
    }
    let subs = substitutions(&a, &b);
    if subs.len() != 1 {
        return None;
    }
    let (ra, rb) = subs[0].clone();
    if ra.is_empty() || rb.is_empty() || ra.len() > MAX_PHRASE_WORDS || rb.len() > MAX_PHRASE_WORDS {
        return None;
    }
    let from = trim_phrase(&a[ra].join(" "));
    let to = trim_phrase(&b[rb].join(" "));
    if from.is_empty() || to.is_empty() {
        return None;
    }
    let (f, t) = (lowercased(&from), lowercased(&to));
    if f == t {
        return None;
    }
    // Carrying on typing after a dictation is not a correction: "Ask John." -> "Ask John about it."
    if t.starts_with(&format!("{f} ")) || f.starts_with(&format!("{t} ")) {
        return None;
    }
    Some((from, to))
}

/// Whether a refused pair has earned a pop-up, as opposed to a line in the log.
pub fn worth_showing(from: &str, to: &str) -> bool {
    let from_t = trim_phrase(from);
    let to_t = trim_phrase(to);
    let (f, t) = (lowercased(&from_t), lowercased(&to_t));
    if f.is_empty() || t.is_empty() || f == t || is_stopword(&f) || is_stopword(&t) {
        return false;
    }
    if words(&from_t).len() > 3 || words(&to_t).len() > 3 {
        return false;
    }
    if graphemes(&to_t).first().is_some_and(|g| is_uppercase(g)) && count(&t) >= 4 {
        return true;
    }
    // Lowercase on both sides and ordinary English is the signature of a change of mind.
    if everyday_english(&from_t) {
        return false;
    }
    count(&f) >= 4 && count(&t) >= 4
}

/// The waiting list once a refused pair arrives, or none to leave it alone. A rule already
/// accepted wins; the same left side waiting with a different right side is replaced, since the
/// newest reading is the one that saw him stop typing.
pub fn merging(candidate: &Replacement, waiting: &[Replacement], accepted: &[Replacement]) -> Option<Vec<Replacement>> {
    if accepted.iter().any(|r| r.id() == candidate.id()) {
        return None;
    }
    let Some(i) = waiting.iter().position(|r| r.id() == candidate.id()) else {
        let mut out = waiting.to_vec();
        out.push(candidate.clone());
        return Some(out);
    };
    if waiting[i].to == candidate.to {
        return None;
    }
    let mut out = waiting.to_vec();
    out[i] = candidate.clone();
    Some(out)
}

/// What handling one edit decided, before anything is written.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Decision {
    pub outcome: Outcome,
    /// The corrections list to save, when rules were added.
    pub save_rules: Option<Vec<Replacement>>,
    /// The waiting list to save, when it changed.
    pub save_pending: Option<Vec<Replacement>>,
    /// An edit seen and refused, worth showing.
    pub declined: Option<(String, String)>,
}

/// Applies the learning setting to one edit, given the current corrections and waiting list.
/// Pure: the caller writes what it returns, so no test goes near John's files.
pub fn decide(wrote: &str, now: &str, mode: LearnMode, existing: &[Replacement], pending: &[Replacement]) -> Decision {
    if mode == LearnMode::Off {
        return Decision::default();
    }
    let waiting: HashSet<String> = pending.iter().map(Replacement::id).collect();
    let scored: Vec<(Replacement, Confidence)> = scored(wrote, now, existing).into_iter().filter(|(r, _)| !waiting.contains(&r.id())).collect();
    if scored.is_empty() {
        let Some((from, to)) = lone_pair(wrote, now) else { return Decision::default() };
        if !worth_showing(&from, &to) {
            return Decision::default();
        }
        let candidate = Replacement::learned(&from, &to);
        return Decision { save_pending: merging(&candidate, pending, existing), declined: Some((from, to)), ..Decision::default() };
    }
    let confident: Vec<Replacement> =
        if mode == LearnMode::Auto { scored.iter().filter(|(_, c)| *c == Confidence::Apply).map(|(r, _)| r.clone()).collect() } else { vec![] };
    let offered: Vec<Replacement> =
        scored.iter().filter(|(_, c)| mode == LearnMode::Ask || *c == Confidence::Suggest).map(|(r, _)| r.clone()).collect();
    let mut d = Decision::default();
    if !confident.is_empty() {
        let mut all = existing.to_vec();
        all.extend(confident.iter().cloned());
        d.save_rules = Some(all);
    }
    if !offered.is_empty() {
        let mut all = pending.to_vec();
        all.extend(offered.iter().cloned());
        d.save_pending = Some(all);
    }
    d.outcome = Outcome { added: confident, suggested: offered };
    d
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn learns_misheard_names_not_changes_of_mind() {
        let d = decide("Ask K Wynn E D F about it.", "Ask kkwinedf about it.", LearnMode::Auto, &[], &[]);
        assert_eq!(d.outcome.added, vec![Replacement::learned("K Wynn E D F", "kkwinedf")]);
        // A capitalized one-word swap is offered, never written: the Swift app does the same.
        let d = decide("See you Thursday.", "See you Friday.", LearnMode::Auto, &[], &[]);
        assert!(d.outcome.added.is_empty());
        assert_eq!(d.outcome.suggested, vec![Replacement::learned("Thursday", "Friday")]);
        let d = decide("I saved it to the cloud.", "I saved it to the Claude.", LearnMode::Auto, &[], &[]);
        assert!(d.outcome.added.is_empty(), "an everyday word never becomes a rule");
    }

    #[test]
    fn offers_distant_names() {
        let d = decide("Thanks Wort.", "Thanks Duarte.", LearnMode::Auto, &[], &[]);
        assert_eq!(d.outcome.suggested, vec![Replacement::learned("Wort", "Duarte")]);
        assert!(d.outcome.added.is_empty());
    }

    #[test]
    fn ask_mode_waits_for_everything() {
        let d = decide("Ask K Wynn E D F.", "Ask kkwinedf.", LearnMode::Ask, &[], &[]);
        assert!(d.outcome.added.is_empty());
        assert_eq!(d.outcome.suggested.len(), 1);
    }

    #[test]
    fn continuing_a_sentence_is_not_a_correction() {
        assert_eq!(lone_pair("Ask John.", "Ask John about it."), None);
    }

    #[test]
    fn worth_showing_floors() {
        assert!(!worth_showing("We", "He"));
        assert!(worth_showing("Dor", "Duarte"));
        assert!(!worth_showing("growth", "grove"));
    }

    #[test]
    fn merging_rules() {
        let a = Replacement::learned("Marisvo", "Marisa V");
        let b = Replacement::learned("Marisvo", "Marisa Vuong");
        assert_eq!(merging(&b, std::slice::from_ref(&a), &[]), Some(vec![b.clone()]));
        assert_eq!(merging(&b, std::slice::from_ref(&b), &[]), None);
        assert_eq!(merging(&b, &[], &[a]), None);
    }
}
