//! Running notes: a few bullets a minute, written while the meeting is still going. Every pass
//! hands the model the newest stretch of the live transcript and the notes already taken, and
//! gets back zero to three new bullets, each stamped with where in the meeting it came from and
//! appended to the note's `running-notes.md`. This is the pure half: which segments a pass
//! reads, when a pass is due, what of the model's answer is kept, and how it is written down.

use crate::notes::{clock, TranscriptSegment};
use crate::text::matcher::PERSONAL_NAMES;
use crate::text::unicode::{
    count, drop_last_graphemes, find_grapheme, graphemes, has_prefix, has_suffix, is_letter, is_newline, is_number, is_uppercase,
    lowercased, split_at_grapheme, split_graphemes, swift_key, trim_non_alphanumerics, trim_ws, trim_ws_nl, uppercased,
};
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::{HashMap, HashSet};

/// Seconds between passes. A minute is long enough for a point to be made and short enough that
/// the notes keep up with the call.
pub const INTERVAL_SECONDS: f64 = 60.0;
/// A pass with less new material than this waits: the model has nothing to say about a "yeah,
/// okay" and would say it anyway.
pub const MINIMUM_NEW_WORDS: usize = 40;
/// One pass reads at most this much. The rest waits for the next pass, oldest first, so a long
/// silence on the model's side never loses anything, it just catches up.
pub const MAXIMUM_WINDOW_WORDS: usize = 600;
/// The last stretch of the meeting gets a pass with less than the usual minimum.
pub const FINAL_MINIMUM_WORDS: usize = 12;
/// How many earlier bullets the model sees, so it does not write the same thing twice.
pub const CONTEXT_BULLETS: usize = 10;

/// The unprocessed segments in time order, capped to a word budget: never a partial segment,
/// always at least one.
pub fn window(segments: &[TranscriptSegment], processed: &HashSet<String>, max_words: usize) -> Vec<TranscriptSegment> {
    let mut sorted: Vec<&TranscriptSegment> = segments.iter().collect();
    sorted.sort_by(|a, b| a.start.total_cmp(&b.start));
    let mut out = vec![];
    let mut words = 0;
    for s in sorted.into_iter().filter(|s| !processed.contains(&s.id)) {
        let n = word_count(&s.text);
        if !out.is_empty() && words + n > max_words {
            break;
        }
        out.push(s.clone());
        words += n;
    }
    out
}

pub fn word_count(text: &str) -> usize {
    split_graphemes(text, |g| crate::text::unicode::is_whitespace(g) || is_newline(g)).len()
}

pub fn word_count_of(segments: &[TranscriptSegment]) -> usize {
    segments.iter().map(|s| word_count(&s.text)).sum()
}

/// Whether to run a pass now: enough new words and enough time since the last pass, or the
/// meeting has ended and anything of substance is still unnoted.
pub fn is_due(new_words: usize, since_last: f64, last: bool) -> bool {
    if last {
        return new_words >= FINAL_MINIMUM_WORDS;
    }
    new_words >= MINIMUM_NEW_WORDS && since_last >= INTERVAL_SECONDS
}

/// One pass as Markdown: a bullet per note, stamped with where the stretch began.
pub fn format(bullets: &[String], start: f64) -> String {
    let stamp = clock(start);
    let mut out = bullets.iter().map(|b| format!("- [{stamp}] {b}")).collect::<Vec<_>>().join("\n");
    if !bullets.is_empty() {
        out.push('\n');
    }
    out
}

/// The most recent bullets of `running-notes.md`, stamps removed, as context for the model.
pub fn recent(notes: &str, n: usize) -> Vec<String> {
    let all: Vec<String> = split_graphemes(notes, |g| g == "\n")
        .into_iter()
        .filter_map(|line| {
            let s = trim_ws(line);
            if !(has_prefix(s, "- ") || has_prefix(s, "* ")) {
                return None;
            }
            let mut s = trim_ws(split_at_grapheme(s, 2).1);
            if has_prefix(s, "[") {
                if let Some(close) = find_grapheme(s, "]") {
                    s = trim_ws(&s[close + 1..]);
                }
            }
            (!s.is_empty()).then(|| s.to_string())
        })
        .collect();
    all[all.len().saturating_sub(n)..].to_vec()
}

/// What the model gave back, made fit to keep: fragments and labels gone, anything the stretch
/// never said gone, repeats gone.
pub fn filter(bullets: &[String], previous: &[String], transcript: &str) -> Vec<String> {
    let kept: Vec<String> = bullets.iter().filter_map(|b| worth_keeping(b)).filter(|b| grounded(b, transcript, previous)).collect();
    drop_repeats(&kept, previous)
}

static SPELLED: Lazy<HashMap<&'static str, &'static str>> = Lazy::new(|| {
    [
        ("zero", "0"), ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"), ("five", "5"), ("six", "6"), ("seven", "7"),
        ("eight", "8"), ("nine", "9"), ("ten", "10"), ("eleven", "11"), ("twelve", "12"), ("thirteen", "13"), ("fourteen", "14"),
        ("fifteen", "15"), ("sixteen", "16"), ("seventeen", "17"), ("eighteen", "18"), ("nineteen", "19"), ("twenty", "20"),
        ("thirty", "30"), ("forty", "40"), ("fifty", "50"), ("sixty", "60"), ("seventy", "70"), ("eighty", "80"), ("ninety", "90"),
        ("hundred", "100"), ("thousand", "1000"), ("million", "1000000"), ("billion", "1000000000"), ("first", "1"), ("second", "2"),
        ("third", "3"), ("fourth", "4"), ("fifth", "5"), ("sixth", "6"), ("seventh", "7"), ("eighth", "8"), ("ninth", "9"),
        ("tenth", "10"),
    ]
    .into_iter()
    .collect()
});

static DATE_WORDS: Lazy<HashSet<&'static str>> = Lazy::new(|| {
    [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "may",
        "june", "july", "august", "september", "october", "november", "december", "tomorrow", "yesterday", "tonight",
    ]
    .into_iter()
    .collect()
});

const PRONOUNS: [&str; 17] = ["You", "Others", "I", "We", "They", "He", "She", "It", "The", "A", "An", "This", "That", "There", "No", "Yes", "OK"];

static DIGIT_COMMA: Lazy<Regex> = Lazy::new(|| Regex::new(r"(\d),(\d)").unwrap());

/// A note that names a number, a date, a month, a weekday or a person the stretch never
/// mentioned is an invention, and an invented deadline is worse than no note: on 2026-09-17 the
/// on-device model produced "Friday, October 18th" and "five deals" for a transcript with none
/// of those words. Numbers are compared as digits ("two" and "2" match, "40,000" and "$40,000"
/// match), names and dates as words.
// One branch per kind of word, so some share a body.
#[allow(clippy::if_same_then_else)]
pub fn grounded(bullet: &str, transcript: &str, previous: &[String]) -> bool {
    let source_words = vocabulary(&format!("{transcript} {}", previous.join(" ")));
    let mut source_numbers: HashSet<String> = source_words.iter().filter_map(|w| number_value(w)).collect();
    source_numbers.extend(source_words.iter().filter(|w| graphemes(w).iter().all(|g| is_number(g))).cloned());
    for (i, raw) in split_graphemes(bullet, |g| g == " ").into_iter().enumerate() {
        let w = trim_non_alphanumerics(raw);
        if w.is_empty() {
            continue;
        }
        let lower = swift_key(&lowercased(w));
        let first_upper = graphemes(w).first().is_some_and(|g| is_uppercase(g));
        if let Some(n) = number_value(&lower) {
            if !source_numbers.contains(&n) {
                return false;
            }
        } else if DATE_WORDS.contains(lower.as_str()) {
            if !source_words.contains(&lower) {
                return false;
            }
        } else if i > 0 && first_upper && !PRONOUNS.contains(&w) && count(w) > 1 {
            if !source_words.contains(&lower) {
                return false;
            }
        } else if i == 0 && first_upper && PERSONAL_NAMES.contains(lower.as_str()) {
            // A sentence's first word is capitalized whatever it is, so only a word that is a
            // known personal name is checked there ("Anna agreed to help" with no Anna said).
            if !source_words.contains(&lower) {
                return false;
            }
        }
    }
    true
}

/// Every word of a text, lowercased, with the commas inside numbers removed first.
fn vocabulary(text: &str) -> HashSet<String> {
    let joined = DIGIT_COMMA.replace_all(&lowercased(text), "$1$2").into_owned();
    split_graphemes(&joined, |g| !is_letter(g) && !is_number(g)).into_iter().map(swift_key).collect()
}

/// "18th" is "18", "40,000" is "40000"; None when the word is not a number.
fn digits(word: &str) -> Option<String> {
    let mut w = word.replace(',', "");
    for suffix in ["st", "nd", "rd", "th"] {
        if has_suffix(&w, suffix) && count(&w) > count(suffix) && graphemes(drop_last_graphemes(&w, count(suffix))).iter().all(|g| is_number(g)) {
            w = drop_last_graphemes(&w, count(suffix)).to_string();
        }
    }
    (!w.is_empty() && graphemes(&w).iter().all(|g| is_number(g))).then_some(w)
}

fn number_value(word: &str) -> Option<String> {
    SPELLED.get(word).map(|s| s.to_string()).or_else(|| digits(word))
}

/// A note worth keeping is a sentence, not a label or a fragment. A small model likes to answer
/// "Task: I" or "Name: Ted": a leading label of up to three words is stripped, and what is left
/// needs at least five words.
pub fn worth_keeping(bullet: &str) -> Option<String> {
    let mut s = trim_ws_nl(bullet);
    if let Some(colon) = find_grapheme(s, ":") {
        let label = &s[..colon];
        if split_graphemes(label, |g| g == " ").len() <= 3 && graphemes(label).iter().all(|g| is_letter(g) || *g == " ") {
            s = trim_ws(&s[colon + 1..]);
        }
    }
    if word_count(s) < 5 || !graphemes(s).iter().any(|g| is_letter(g)) || has_suffix(s, ":") {
        return None;
    }
    let (head, rest) = split_at_grapheme(s, 1);
    Some(uppercased(head) + rest)
}

/// Drops bullets that say what an earlier bullet already says. Two notes are the same when
/// seven in ten of the shorter one's words, crudely stemmed so "overviewing" is "overview", are
/// in the other. Small models repeat themselves in new words.
pub fn drop_repeats(bullets: &[String], previous: &[String]) -> Vec<String> {
    let mut kept: Vec<HashSet<String>> = previous.iter().map(|p| words(p)).collect();
    let mut out = vec![];
    for b in bullets {
        let w = words(b);
        if w.is_empty() {
            continue;
        }
        let repeats = kept.iter().any(|other| {
            let smaller = w.len().min(other.len());
            if smaller == 0 {
                return false;
            }
            if w == *other {
                return true;
            }
            smaller >= 3 && w.intersection(other).count() as f64 / smaller as f64 >= 0.7
        });
        if repeats {
            continue;
        }
        kept.push(w);
        out.push(b.clone());
    }
    out
}

fn words(s: &str) -> HashSet<String> {
    let lower = lowercased(s);
    split_graphemes(&lower, |g| !is_letter(g) && !is_number(g)).into_iter().map(|w| swift_key(&stem(w))).filter(|w| !w.is_empty()).collect()
}

fn stem(word: &str) -> String {
    let n = count(word);
    if n > 5 && has_suffix(word, "ing") {
        drop_last_graphemes(word, 3).to_string()
    } else if n > 4 && has_suffix(word, "ed") {
        drop_last_graphemes(word, 2).to_string()
    } else if n > 3 && has_suffix(word, "s") {
        drop_last_graphemes(word, 1).to_string()
    } else {
        word.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn invented_numbers_dates_and_names_are_dropped() {
        let t = "[0:05] Others: We need the permit by the 18th. Ted will call the county about the $40,000 fee, all two of them.";
        assert!(grounded("Ted will call the county by the 18th", t, &[]));
        assert!(grounded("The county is owed $40,000", t, &[]));
        assert!(!grounded("The permit is due Friday, October 18th", t, &[]));
        assert!(grounded("The county has 2 fees", t, &[]), "two and 2 match");
        assert!(!grounded("Five deals closed", t, &[]));
        assert!(!grounded("Anna agreed to call the county", t, &[]));
        assert!(!grounded("The permit goes to Marcus", t, &[]));
    }

    #[test]
    fn labels_and_fragments_go() {
        assert_eq!(worth_keeping("Task: I"), None);
        assert_eq!(worth_keeping("Action item: ted calls the county on Monday"), Some("Ted calls the county on Monday".into()));
        assert_eq!(worth_keeping("Next steps:"), None);
    }

    #[test]
    fn repeats_in_new_words_go() {
        let previous = strings(&["The team is overviewing the onboarding checklist"]);
        let out = drop_repeats(&strings(&["Team overviewed the onboarding checklist", "Ted will send the permit forms"]), &previous);
        assert_eq!(out, strings(&["Ted will send the permit forms"]));
    }

    #[test]
    fn recent_strips_markers_and_stamps() {
        let notes = "- [0:05] First point here\n* Second point\nnot a bullet\n- [1:10]   \n";
        assert_eq!(recent(notes, 10), strings(&["First point here", "Second point"]));
        assert_eq!(recent(notes, 1), strings(&["Second point"]));
    }

    #[test]
    fn a_window_never_splits_a_segment() {
        let segs: Vec<TranscriptSegment> = (0..5).map(|i| TranscriptSegment::new(i as f64, i as f64 + 1.0, "You", "one two three four")).collect();
        let done: HashSet<String> = [segs[0].id.clone()].into_iter().collect();
        let w = window(&segs, &done, 10);
        assert_eq!(w.len(), 2);
        assert_eq!(w[0].id, segs[1].id);
        assert_eq!(window(&segs, &HashSet::new(), 1).len(), 1, "always at least one");
        assert_eq!(format(&strings(&["A point"]), 65.0), "- [1:05] A point\n");
        assert!(is_due(40, 60.0, false) && !is_due(39, 600.0, false) && is_due(12, 0.0, true));
    }
}
