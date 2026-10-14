//! Notes a model took on successive parts of one meeting, merged heading by heading in code. A
//! small model is good at "take notes on this part" and bad at "reorganize all these notes into
//! four sections": given the merged notes it copied one list under every heading, added a
//! "## None" heading and dropped the start and end of the meeting. So the reorganizing happens
//! here, and the model only ever shortens one list at a time.

use crate::text::unicode::{
    count, graphemes, has_prefix, has_suffix, is_letter, is_number, is_uppercase, is_whitespace, lowercased, split_at_grapheme,
    split_graphemes, swift_key, trim_ws, trim_ws_nl,
};
use std::collections::HashSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Section {
    Summary,
    Decisions,
    Actions,
    Questions,
}

impl Section {
    pub const ALL: [Section; 4] = [Section::Summary, Section::Decisions, Section::Actions, Section::Questions];

    pub fn heading(self) -> &'static str {
        match self {
            Section::Summary => "Summary",
            Section::Decisions => "Decisions",
            Section::Actions => "Action items",
            Section::Questions => "Open questions",
        }
    }

    fn index(self) -> usize {
        self as usize
    }
}

/// The four lists, indexed by `Section`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Sections(pub [Vec<String>; 4]);

impl Sections {
    pub fn get(&self, s: Section) -> &Vec<String> {
        &self.0[s.index()]
    }
    pub fn get_mut(&mut self, s: Section) -> &mut Vec<String> {
        &mut self.0[s.index()]
    }
    pub fn set(&mut self, s: Section, items: Vec<String>) {
        self.0[s.index()] = items;
    }
}

/// Strings a model generated into a list: markers and bold stripped, "None" and empty entries
/// dropped.
pub fn tidy(items: &[String]) -> Vec<String> {
    items.iter().filter_map(|i| bullet(trim_ws_nl(i))).collect()
}

/// The sections of successive parts, in order, without repeats. A fact filed under open
/// questions moves to the key points; a near repeat within a section keeps its shorter phrasing.
pub fn merge(parts: &[Sections]) -> Sections {
    let mut out = Sections::default();
    let mut seen = HashSet::new();
    for part in parts.iter().map(refile) {
        for section in Section::ALL {
            for b in part.get(section) {
                if !seen.insert(key(b)) {
                    continue;
                }
                let words = word_set(b);
                let list = out.get_mut(section);
                if let Some(i) = list.iter().position(|x| similar(&word_set(x), &words)) {
                    if count(b) < count(&list[i]) {
                        list[i] = b.clone();
                    }
                    continue;
                }
                list.push(b.clone());
            }
        }
    }
    out
}

/// Entries under open questions that do not read as questions are key points the model had
/// nowhere else to put.
pub fn refile(part: &Sections) -> Sections {
    let mut out = part.clone();
    let (questions, facts): (Vec<String>, Vec<String>) = part.get(Section::Questions).iter().cloned().partition(|e| is_question(e));
    out.set(Section::Questions, questions);
    if !facts.is_empty() {
        let mut summary = part.get(Section::Summary).clone();
        summary.extend(facts);
        out.set(Section::Summary, summary);
    }
    out
}

const QUESTION_STARTS: &[&str] = &[
    "who ", "whom ", "whose ", "what ", "when ", "where ", "why ", "how ", "which ", "whether ", "do we ", "do they ", "does ", "did ",
    "should ", "shall ", "is it ", "is there ", "are we ", "are there ", "can we ", "could ", "will ", "would ", "might ",
    "need to decide", "decide whether", "decision on", "decision about", "open question", "still open", "unresolved", "undecided",
    "unclear", "not yet decided", "not decided", "to be decided", "to be determined", "tbd", "pending", "waiting on", "waiting for",
    "still owe", "still need", "depends on", "question of", "question about", "questions about", "asked whether", "asked if",
    "wants to know", "unknown",
];

pub fn is_question(text: &str) -> bool {
    let t = lowercased(text);
    if has_suffix(&t, "?") {
        return true;
    }
    QUESTION_STARTS.iter().any(|s| has_prefix(&t, s) || (!s.ends_with(' ') && t.contains(s)))
}

fn word_set(s: &str) -> HashSet<String> {
    let lower = lowercased(s);
    split_graphemes(&lower, |g| !is_letter(g) && !is_number(g))
        .into_iter()
        .filter(|w| count(w) > 2 || graphemes(w).iter().all(|g| is_number(g)))
        .map(swift_key)
        .collect()
}

/// Two entries say the same thing when nearly every word of the shorter is in the longer.
fn similar(a: &HashSet<String>, b: &HashSet<String>) -> bool {
    if a.len() < 4 || b.len() < 4 {
        return false;
    }
    a.intersection(b).count() as f64 / a.len().min(b.len()) as f64 >= 0.8
}

/// The four headings in order, "* None" where there is nothing.
pub fn render(sections: &Sections) -> String {
    Section::ALL
        .iter()
        .map(|&s| {
            let bullets = sections.get(s);
            let body = if bullets.is_empty() { "* None".to_string() } else { bullets.iter().map(|b| format!("* {}", punctuated(b))).collect::<Vec<_>>().join("\n") };
            format!("## {}\n{}", s.heading(), body)
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// The text of a bullet line without its marker, or None for "None" and the like.
pub fn bullet(line: &str) -> Option<String> {
    let g = graphemes(line);
    let mut s: &str = line;
    let first = g.first().copied();
    let marker = first.is_some_and(|f| ["*", "-", "•", "–", "—"].contains(&f))
        && g.len() > 1
        && (["•", "–", "—"].contains(&first.unwrap()) || is_whitespace(g[1]));
    if marker {
        s = split_at_grapheme(line, 1).1;
    } else {
        let digits = g.iter().take_while(|x| is_number(x)).count();
        if digits > 0 && digits <= 2 && g.get(digits).is_some_and(|m| *m == "." || *m == ")") {
            s = split_at_grapheme(line, digits + 1).1;
        }
    }
    let mut text = trim_ws(&s.replace("**", "")).to_string();
    loop {
        let tg = graphemes(&text);
        if tg.len() > 2 && tg[0] == tg[tg.len() - 1] && (tg[0] == "*" || tg[0] == "_") {
            let inner = &text[tg[0].len()..text.len() - tg[tg.len() - 1].len()];
            text = trim_ws(inner).to_string();
        } else {
            break;
        }
    }
    let text = trim_scraps(&text);
    if !graphemes(&text).iter().any(|g| is_letter(g) || is_number(g)) || is_none(&text) {
        return None;
    }
    Some(text)
}

fn punctuated(s: &str) -> String {
    let g = graphemes(s);
    let Some(&last) = g.last() else { return s.to_string() };
    let before_is_end = g.len() >= 2 && [".", "!", "?"].contains(&g[g.len() - 2]);
    let closing = ["\"", "”", "’", "'", ")"].contains(&last);
    if is_letter(last) || is_number(last) || (closing && !before_is_end) {
        format!("{s}.")
    } else {
        s.to_string()
    }
}

/// The transcript's speaker labels and the scraps a copied line drags along: "You: The build is
/// stable. Good, next." becomes "The build is stable."
fn trim_scraps(text: &str) -> String {
    let mut t = text.to_string();
    for label in ["You:", "Others:", "You :", "Others :"] {
        if has_prefix(&t, label) {
            t = trim_ws(split_at_grapheme(&t, count(label)).1).to_string();
        }
    }
    let mut sentences = split_sentences(&t);
    let scrap = |s: &str| split_graphemes(s, |g| g == " ").len() <= 3 && !graphemes(s).iter().any(|g| is_number(g));
    while sentences.len() > 1 && scrap(&sentences[0]) {
        sentences.remove(0);
    }
    while sentences.len() > 1 && scrap(&sentences[sentences.len() - 1]) {
        sentences.pop();
    }
    sentences.join(" ")
}

const ABBREVIATIONS: [&str; 15] = ["mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "jr", "sr", "inc", "ltd", "no", "approx", "dept"];

/// Splits after . ! ? when a space and a capital letter follow, except after "Mr." style
/// abbreviations and single letters.
pub fn split_sentences(text: &str) -> Vec<String> {
    let chars = graphemes(text);
    let mut out = vec![];
    let mut current: Vec<&str> = vec![];
    for (i, &c) in chars.iter().enumerate() {
        current.push(c);
        let end = c == "." || c == "!" || c == "?";
        if !(end && i + 2 < chars.len() && chars[i + 1] == " " && is_uppercase(chars[i + 2])) {
            continue;
        }
        if c == "." {
            let word: Vec<&str> = current[..current.len() - 1].iter().rev().take_while(|g| is_letter(g)).copied().collect();
            let word: String = word.into_iter().rev().collect();
            if count(&word) <= 1 || ABBREVIATIONS.contains(&lowercased(&word).as_str()) {
                continue;
            }
        }
        out.push(trim_ws(&current.concat()).to_string());
        current.clear();
    }
    let rest = current.concat();
    let rest = trim_ws(&rest);
    if !rest.is_empty() {
        out.push(rest.to_string());
    }
    out
}

const NONE_WORDS: [&str; 15] = [
    "none", "n/a", "na", "nothing", "no", "nil", "not applicable", "none yet", "none noted", "none mentioned", "none stated",
    "none discussed", "none recorded", "not discussed", "not mentioned",
];
const NONE_HINTS: [&str; 13] =
    ["decision", "action", "question", "mentioned", "discussed", "item", "noted", "made", "raised", "stated", "recorded", "identified", "specific"];

/// "None", "N/A", "No decisions were made", "None mentioned".
fn is_none(text: &str) -> bool {
    let lower = lowercased(text);
    let t = lower.trim_matches(|c| c == ' ' || c == '.' || c == '!');
    if NONE_WORDS.contains(&t) {
        return true;
    }
    (has_prefix(t, "no ") || has_prefix(t, "none ")) && NONE_HINTS.iter().any(|w| t.contains(w))
}

fn key(b: &str) -> String {
    swift_key(&graphemes(&lowercased(b)).into_iter().filter(|g| is_letter(g) || is_number(g)).collect::<String>())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    fn part(summary: &[&str], decisions: &[&str], actions: &[&str], questions: &[&str]) -> Sections {
        Sections([strings(summary), strings(decisions), strings(actions), strings(questions)])
    }

    #[test]
    fn bullets_lose_markers_bold_and_none() {
        assert_eq!(bullet("* **Permit** is due"), Some("Permit is due".into()));
        assert_eq!(bullet("2) Ted calls the county"), Some("Ted calls the county".into()));
        assert_eq!(bullet("**bold start** stays"), Some("bold start stays".into()));
        assert_eq!(bullet("- None."), None);
        assert_eq!(bullet("No decisions were made"), None);
        assert_eq!(bullet("You: The build is stable. Good, next."), Some("The build is stable.".into()));
        assert_eq!(bullet("_Mr. Smith signs Friday._"), Some("Mr. Smith signs Friday.".into()));
    }

    #[test]
    fn merging_moves_facts_out_of_questions_and_keeps_the_shorter_repeat() {
        let a = part(&["The county inspection is booked for next week"], &[], &["Ted will call the county inspector"], &["Budget was approved by finance"]);
        let b = part(&["County inspection booked for next week"], &[], &[], &["Who pays for the second inspection?"]);
        let m = merge(&[a, b]);
        assert_eq!(m.get(Section::Summary), &strings(&["County inspection booked for next week", "Budget was approved by finance"]));
        assert_eq!(m.get(Section::Questions), &strings(&["Who pays for the second inspection?"]));
        let text = render(&m);
        assert!(text.starts_with("## Summary\n* County inspection booked for next week.\n* Budget was approved by finance."));
        assert!(text.contains("## Decisions\n* None\n\n## Action items\n* Ted will call the county inspector."));
    }

    #[test]
    fn sentences_split_after_real_sentences_only() {
        assert_eq!(split_sentences("Mr. Smith left. Then J. Doe came! Done"), strings(&["Mr. Smith left.", "Then J. Doe came!", "Done"]));
        assert!(is_question("Whether to hire a second inspector"));
        assert!(is_question("Budget still pending"));
        assert!(!is_question("Budget approved"));
    }
}
