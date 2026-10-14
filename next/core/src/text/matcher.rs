//! Snaps words that sound like a glossary term to the term's spelling: "Lend Flow", "Len Flow"
//! and "LinFlow" become "Lin Flow", "Whisper Flow" becomes "Wispr Flow", "Workbrain" becomes
//! "WORKBRAIN". It compares windows of words the length of the term (plus the glued one-word
//! form) by a length-scaled edit distance, and insists every word start with the same letter so
//! "in flow" never turns into "Lin Flow". A port of the Swift `GlossaryMatcher`.

use super::glossary::is_english_word;
use super::unicode::{count, graphemes, is_punctuation, is_whitespace, lowercased};
use once_cell::sync::Lazy;
use std::collections::HashSet;

pub struct GlossaryMatcher<'a> {
    terms: &'a [String],
}

/// Endings a speaker adds to a name: "Parakeets", "Lin Flow's", "Cambodian", "Cambodians".
const INFLECTIONS: &[&str] = &["'s", "’s", "s'", "s’", "es", "s", "an", "n"];
const PLURAL_OR_POSSESSIVE: &[&str] = &["'s", "’s", "s'", "s’", "es", "s"];

#[derive(Clone)]
struct Token {
    text: String,
    is_word: bool,
    leading: String,
    trailing: String,
    core: String,
}

impl Token {
    fn new(text: String, is_word: bool) -> Token {
        let mut t = Token { text, is_word, leading: String::new(), trailing: String::new(), core: String::new() };
        t.split();
        t
    }

    fn set(&mut self, text: String) {
        self.text = text;
        self.split();
    }

    /// Leading: opening quotes and brackets glued to the front. Trailing: commas, periods and
    /// closing quotes glued to the end; apostrophes stay with the word ("Claude's") and dots
    /// inside a word ("whisper.cpp", "p.m") stay in the core. A closing quote or a bare
    /// possessive apostrophe ("Parakeets'") is trailing too.
    fn split(&mut self) {
        let all = graphemes(&self.text);
        let lead = all.iter().take_while(|g| is_punctuation(g) && **g != "'").count();
        let body = &all[lead..];
        let mut t: Vec<&str> = body.iter().rev().take_while(|g| is_punctuation(g) && **g != "'" && **g != "’").copied().collect();
        t.reverse();
        let rest = &body[..body.len() - t.len()];
        if let Some(last) = rest.last() {
            if *last == "'" || *last == "’" {
                t.insert(0, last);
            }
        }
        self.leading = all[..lead].concat();
        let trail = t.len();
        self.trailing = t.concat();
        self.core = if lead + trail <= all.len() { all[lead..all.len() - trail].concat() } else { String::new() };
    }
}

/// Runs of whitespace and runs of everything else, in order, so the original spacing,
/// newlines included, survives the rebuild.
fn tokenize(s: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut current_is_word = false;
    for g in graphemes(s) {
        let is_word_char = !is_whitespace(g);
        if current.is_empty() {
            current.push_str(g);
            current_is_word = is_word_char;
        } else if is_word_char == current_is_word {
            current.push_str(g);
        } else {
            tokens.push(Token::new(std::mem::take(&mut current), current_is_word));
            current.push_str(g);
            current_is_word = is_word_char;
        }
    }
    if !current.is_empty() {
        tokens.push(Token::new(current, current_is_word));
    }
    tokens
}

fn words(s: &str) -> Vec<&str> {
    s.split(' ').filter(|w| !w.is_empty()).collect()
}

fn first_grapheme(s: &str) -> Option<&str> {
    graphemes(s).first().copied()
}

fn drop_last(s: &str, n: usize) -> String {
    let g = graphemes(s);
    g[..g.len().saturating_sub(n)].concat()
}

fn drop_first(s: &str, n: usize) -> String {
    let g = graphemes(s);
    g[n.min(g.len())..].concat()
}

impl<'a> GlossaryMatcher<'a> {
    pub fn new(terms: &'a [String]) -> Self {
        GlossaryMatcher { terms }
    }

    /// Longer terms first, so "Claude Code" wins over "Claude".
    fn ordered_terms(&self) -> Vec<&'a String> {
        let mut t: Vec<&String> = self.terms.iter().collect();
        t.sort_by(|a, b| {
            let (wa, wb) = (words(a).len(), words(b).len());
            if wa != wb {
                wb.cmp(&wa)
            } else {
                count(b).cmp(&count(a))
            }
        });
        t
    }

    pub fn apply(&self, text: &str) -> String {
        if self.terms.is_empty() {
            return text.to_string();
        }
        let mut tokens = tokenize(text);
        let word_idx: Vec<usize> = tokens.iter().enumerate().filter(|(_, t)| t.is_word).map(|(i, _)| i).collect();
        let mut consumed: HashSet<usize> = HashSet::new();
        let term_set: HashSet<&str> = self.terms.iter().map(String::as_str).collect();

        for term in self.ordered_terms() {
            let term_words = words(term);
            // Windows of the term's own word count plus the glued one-word form ("Linflow"); for
            // one-word terms also the split two-word form ("work brain", "Sunny Veil").
            let sizes: Vec<usize> = if term_words.len() > 1 { vec![term_words.len(), 1] } else { vec![1, 2] };
            for n in sizes {
                let glued = term_words.len() == 1 && n == 2;
                let mut i = 0;
                while i + n <= word_idx.len() {
                    let idxs = &word_idx[i..i + n];
                    if idxs.iter().any(|k| consumed.contains(k)) {
                        i += 1;
                        continue;
                    }
                    let cores: Vec<String> = idxs.iter().map(|&k| tokens[k].core.clone()).collect();
                    if cores.iter().any(String::is_empty) {
                        i += 1;
                        continue;
                    }
                    // Two words split by a period are two words ("whisper.cpp. It").
                    if glued && !tokens[idxs[0]].trailing.is_empty() {
                        i += 1;
                        continue;
                    }
                    if let Some(replacement) = correction(&cores, glued, term, &term_set) {
                        let (first, last) = (idxs[0], *idxs.last().unwrap());
                        let rebuilt = format!("{}{}{}", tokens[first].leading, replacement, tokens[last].trailing);
                        tokens[first].set(rebuilt);
                        for t in &mut tokens[first + 1..=last] {
                            t.set(String::new());
                        }
                        consumed.extend(idxs.iter().copied());
                        i += n;
                    } else {
                        i += 1;
                    }
                }
            }
        }
        tokens.into_iter().map(|t| t.text).collect()
    }
}

/// The term, keeping any inflection the speaker used, if the window sounds like it.
fn correction(cores: &[String], glued: bool, term: &str, term_set: &HashSet<&str>) -> Option<String> {
    let term_lower = lowercased(term);
    if glued {
        // Two words that should be one ("work brain", "git hub"). Two everyday English words are
        // two words ("work again", "another epic"): only a part that is not a word can be a
        // mangled name, and even then within the term's edit tolerance.
        if !cores.iter().all(|c| count(c) >= 3) {
            return None;
        }
        let candidate: String = cores.concat();
        if term_set.contains(candidate.as_str()) {
            return None;
        }
        let c = lowercased(&candidate);
        for suffix in PLURAL_OR_POSSESSIVE {
            if c.ends_with(suffix) && drop_last(&c, count(suffix)) == term_lower {
                return Some(format!("{term}{suffix}"));
            }
        }
        if c == term_lower {
            return Some(term.to_string());
        }
        let all_words = cores.iter().all(|w| is_english_word(&lowercased(w)));
        let tl = count(&term_lower);
        if all_words || first_grapheme(&c) != first_grapheme(&term_lower) || count(&c).abs_diff(tl) > tolerance(tl) {
            return None;
        }
        return if levenshtein(&c, &term_lower) <= tolerance(tl) { Some(term.to_string()) } else { None };
    }
    let candidate = cores.join(" ");
    if term_set.contains(candidate.as_str()) {
        return None; // already right
    }
    if lowercased(&candidate) == term_lower {
        return Some(term.to_string()); // casing only
    }
    // Inflections of a term that is already right stay ("Parakeets", "Lin Flow's"); inflections
    // of a lowercase or glued term keep their ending.
    let term_glued = term_lower.replace(' ', "");
    let mut stems = vec![candidate.clone()];
    for _ in 0..2 {
        let mut next: Vec<String> = Vec::new();
        for s in &stems {
            for suffix in INFLECTIONS {
                if count(s) > count(suffix) + 2 && s.ends_with(suffix) {
                    next.push(drop_last(s, count(suffix)));
                }
            }
        }
        for s in &next {
            if term_set.contains(s.as_str()) {
                return None;
            }
            let l = lowercased(s);
            if l == term_lower || l == term_glued {
                return Some(format!("{term}{}", drop_first(&candidate, count(s)))); // "githubs" -> "GitHubs"
            }
        }
        if next.is_empty() {
            break;
        }
        stems = next;
    }
    // The whole word first ("John Lynn" -> "John Lin"), then a plural or possessive of a near
    // miss ("Lend Flow's" -> "Lin Flow's").
    if matches(&candidate, term) {
        return Some(term.to_string());
    }
    for suffix in PLURAL_OR_POSSESSIVE {
        if count(&candidate) > count(suffix) + 2 && candidate.ends_with(suffix) && matches(&drop_last(&candidate, count(suffix)), term) {
            return Some(format!("{term}{suffix}"));
        }
    }
    None
}

pub fn matches(candidate: &str, term: &str) -> bool {
    if candidate == term {
        return false;
    }
    let c = lowercased(candidate);
    let t = lowercased(term);
    if c == t {
        return true;
    }
    let c_words = words(&c);
    let t_words = words(&t);
    if c_words.len() == 1 && t_words.len() > 1 {
        // "linflow" vs "lin flow": the word has to split into the term's words, each part starting
        // with its word's letter, within the whole term's tolerance. "johnlyn" is "john" + "lyn";
        // "Johnson" has no "l" part.
        let glued: String = t_words.concat();
        if is_english_word(&c) {
            return false;
        }
        if c == glued {
            return true;
        }
        let cg = graphemes(&c);
        let Some(d) = glued_distance(&cg, &t_words) else { return false };
        return d <= tolerance(count(&glued));
    }
    if c_words.len() != t_words.len() {
        return false;
    }
    for (a, b) in c_words.iter().zip(t_words.iter()) {
        if first_grapheme(a) != first_grapheme(b) {
            return false;
        }
        // "Claude's code" is about Claude's code, not "Claude Code".
        let apostrophe = |s: &str| s.contains('\'') || s.contains('’');
        if apostrophe(a) && !apostrophe(b) {
            return false;
        }
        // A verb form is a verb, not a name: "Claude coded" stays.
        if (a.ends_with("ed") && !b.ends_with("ed")) || (a.ends_with("ing") && !b.ends_with("ing")) {
            return false;
        }
        // "John Lee" and "John Lin" are two people. A word that is itself a real name becomes
        // another name only when it sounds like one, and the target is a name too.
        if a != b && PERSONAL_NAMES.contains(*a) && (name_key(a) != name_key(b) || !PERSONAL_NAMES.contains(*b)) {
            return false;
        }
    }
    if c_words.len() == 1 {
        // An ordinary English word is never a misspelling of a name: "clause" and "cloud" stay
        // themselves though each is one edit from "Claude".
        if is_english_word(&c) {
            return false;
        }
        if c.contains('-') && c.split('-').filter(|p| !p.is_empty()).all(is_english_word) {
            return false;
        }
    }
    levenshtein(&c, &t) <= tolerance(count(&t))
}

/// Smallest total edit distance over every way of cutting `c` into `words.len()` parts whose
/// first letters match the words, or none when no cut lines up.
fn glued_distance(c: &[&str], words: &[&str]) -> Option<usize> {
    let word = words.first()?;
    if c.first().copied() != first_grapheme(word) {
        return None;
    }
    if words.len() == 1 {
        return Some(levenshtein(&c.concat(), word));
    }
    if c.len() < 2 {
        return None;
    }
    let mut best: Option<usize> = None;
    for cut in 1..c.len() {
        let Some(rest) = glued_distance(&c[cut..], &words[1..]) else { continue };
        let d = levenshtein(&c[..cut].concat(), word) + rest;
        if best.is_none_or(|b| d < b) {
            best = Some(d);
        }
    }
    best
}

pub fn tolerance(length: usize) -> usize {
    match length {
        0..=3 => 0,
        4..=6 => 1,
        7..=11 => 2,
        _ => 3,
    }
}

/// A name reduced to its spelling variants: "Lynn" and "Lin" are the same name written two
/// ways, "Lane" and "Lin" are not.
pub fn name_key(s: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut prev: Option<String> = None;
    for g in graphemes(&lowercased(s)) {
        let c = if g == "y" { "i".to_string() } else { g.to_string() };
        if prev.as_deref() == Some(c.as_str()) {
            continue;
        }
        out.push(c.clone());
        prev = Some(c);
    }
    if out.len() > 2 && out.last().map(String::as_str) == Some("e") {
        out.pop();
    }
    out.concat()
}

/// Consonant skeleton: "Wispr Flow" is "wsprflw", "Lin Flow" is "lnflw".
pub fn key(s: &str) -> String {
    let mut out = String::new();
    let mut prev: Option<String> = None;
    for g in graphemes(&lowercased(s)) {
        if !(super::unicode::is_letter(g) || super::unicode::is_number(g)) {
            continue;
        }
        let is_vowel = matches!(g, "a" | "e" | "i" | "o" | "u" | "y");
        if is_vowel && !out.is_empty() {
            continue;
        }
        if prev.as_deref() == Some(g) {
            continue;
        }
        out.push_str(g);
        prev = Some(g.to_string());
    }
    out
}

/// Edit distance over Swift `Character`s.
pub fn levenshtein(a: &str, b: &str) -> usize {
    let a = graphemes(a);
    let b = graphemes(b);
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
            let cost = if a[i - 1] == b[j - 1] { 0 } else { 1 };
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

/// Common personal names: one real name is never rewritten into a different real name.
/// Weighted toward the names John dictates. Coverage of this list is the maintenance surface:
/// add a surname when one slips through.
pub static PERSONAL_NAMES: Lazy<HashSet<&'static str>> = Lazy::new(|| include_str!("names.txt").split_whitespace().collect());

#[cfg(test)]
mod tests {
    use super::*;

    fn snap(text: &str, terms: &[&str]) -> String {
        let terms: Vec<String> = terms.iter().map(|s| s.to_string()).collect();
        GlossaryMatcher::new(&terms).apply(text)
    }

    #[test]
    fn snaps_near_misses() {
        assert_eq!(snap("I use Lend Flow daily.", &["Lin Flow"]), "I use Lin Flow daily.");
        assert_eq!(snap("Linflow is fast", &["Lin Flow"]), "Lin Flow is fast");
        assert_eq!(snap("the workbrain folder", &["WORKBRAIN"]), "the WORKBRAIN folder");
    }

    #[test]
    fn leaves_words_and_names_alone() {
        assert_eq!(snap("I saved it to the cloud.", &["Claude"]), "I saved it to the cloud.");
        assert_eq!(snap("go with the in flow", &["Lin Flow"]), "go with the in flow");
        assert_eq!(snap("John Lee called", &["John Lin"]), "John Lee called");
        assert_eq!(snap("Claude coded it", &["Claude Code"]), "Claude coded it");
    }

    #[test]
    fn keeps_inflections() {
        assert_eq!(snap("two Parakeets", &["Parakeet"]), "two Parakeets");
        assert_eq!(snap("Lend Flow's window", &["Lin Flow"]), "Lin Flow's window");
    }
}
