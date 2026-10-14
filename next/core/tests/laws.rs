//! The laws of the text pipeline and the shared dictionary, as property tests. Each law says in
//! plain English something that must hold for every input, and is checked on generated inputs
//! every time the tests run. `rebuild/verification.md` lists them with John's verdict on each.
//!
//! The apps agree with each other on 97,003 generated inputs (next/oracle), so a law that fails
//! here fails in the Swift app too. A failure is a question for John, not a bug to fix quietly.
//! Each law's exceptions found so far have a test of their own, pinning what the apps do today.
//!
//! The usual run is a few thousand cases in all. After changing the text pipeline or the sync,
//! sweep deeper: `PROPTEST_CASES=30000 cargo test --release -p linflow-core --test laws`. The
//! exceptions below were found at that depth, one in ten thousand cases or rarer.

use chrono::{DateTime, Duration, TimeZone, Utc};
use linflow_core::learn::{decide, LearnMode};
use linflow_core::net::{HttpRequest, HttpResponse, NetError, Transport};
use linflow_core::sync::dictionary::{sync, Files};
use linflow_core::sync::SyncConfig;
use linflow_core::text::cleaner::{apply_replacements, clean_with, SILENCE_HALLUCINATIONS};
use linflow_core::text::glossary::{parse_replacements, parse_terms, replacements_file, terms_file, ENGLISH_WORDS};
use linflow_core::text::matcher::{name_key, GlossaryMatcher};
use linflow_core::text::numbers;
use linflow_core::text::unicode::swift_key;
use linflow_core::text::Replacement;
use once_cell::sync::Lazy;
use proptest::prelude::*;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

/// Each law's usual number of cases, or PROPTEST_CASES for a deeper sweep.
fn config(cases: u32) -> ProptestConfig {
    let cases = std::env::var("PROPTEST_CASES").ok().and_then(|v| v.parse().ok()).unwrap_or(cases);
    // Laws that filter their inputs reject a share of them, and a deep sweep rejects more.
    ProptestConfig { cases, max_global_rejects: cases.saturating_mul(4).max(1024), failure_persistence: None, ..ProptestConfig::default() }
}

// ---- Spelling numbers the way a person says them -------------------------------------------

const UNITS: [&str; 10] = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];
const TEENS: [&str; 10] = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"];
const TENS: [&str; 10] = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];
const SCALES: [&str; 4] = ["", "thousand", "million", "billion"];

/// 1 to 999 in words, with "and" after the hundreds when `and` is set.
fn under_thousand(n: u64, and: bool) -> Vec<&'static str> {
    let mut out = vec![];
    let (h, r) = (n / 100, n % 100);
    if h > 0 {
        out.extend([UNITS[h as usize], "hundred"]);
        if r > 0 && and {
            out.push("and");
        }
    }
    match r {
        0 => {}
        1..=9 => out.push(UNITS[r as usize]),
        10..=19 => out.push(TEENS[(r - 10) as usize]),
        _ => {
            out.push(TENS[(r / 10) as usize]);
            if r % 10 > 0 {
                out.push(UNITS[(r % 10) as usize]);
            }
        }
    }
    out
}

/// A number below a trillion as it is said: "three hundred forty five thousand six".
fn spell(n: u64, and: bool) -> String {
    if n == 0 {
        return "zero".into();
    }
    let mut words = vec![];
    for g in (0..4).rev() {
        let part = (n / 1000u64.pow(g)) % 1000;
        if part > 0 {
            words.extend(under_thousand(part, and));
            if g > 0 {
                words.push(SCALES[g as usize]);
            }
        }
    }
    words.join(" ")
}

/// The places a number's words say, as powers of ten. "eight hundred fifteen" says the
/// hundreds, and "fifteen" says both the tens and the ones. "two thousand" says only the
/// thousands.
fn said_places(n: u64) -> Vec<u32> {
    let mut out = vec![];
    for g in 0..4u32 {
        let part = (n / 1000u64.pow(g)) % 1000;
        let (h, r) = (part / 100, part % 100);
        if h > 0 {
            out.push(g * 3 + 2);
        }
        if (10..=19).contains(&r) {
            out.extend([g * 3 + 1, g * 3]);
        } else {
            if r / 10 > 0 {
                out.push(g * 3 + 1);
            }
            if r % 10 > 0 {
                out.push(g * 3);
            }
        }
    }
    out
}

fn numbers_of_every_size() -> impl Strategy<Value = u64> {
    prop_oneof![0u64..100, 100u64..10_000, 10_000u64..10_000_000, 10_000_000u64..1_000_000_000_000]
}

/// Words the number reader has no reason to touch: no number words, no units of measure, no
/// ordinals, no "a", "and" or "point".
const PLAIN: &[&str] = &[
    "the", "that", "works", "no", "knows", "of", "reasons", "is", "it", "we", "said", "just", "again", "for", "me", "here",
    "there", "best", "way", "only", "thing", "this", "more", "was", "right", "you", "like", "good", "about", "every", "other",
];

proptest! {
    #![proptest_config(config(4000))]

    /// N1. A number said in words is written as its digits: "three hundred forty five thousand
    /// six" is 345006. The words join into one number while each says a smaller place than the
    /// last. Lone "one" is the exception (N2).
    #[test]
    fn a_number_said_in_words_becomes_its_digits(n in numbers_of_every_size(), and in any::<bool>()) {
        prop_assume!(n != 1);
        let said = format!("we counted {} today", spell(n, and));
        prop_assert_eq!(numbers::apply(&said), format!("we counted {n} today"));
    }

    /// N3. A number never says the same place twice, so a word that would say a place again
    /// starts the next number: "eight hundred seven hundred" is 800 and 700, and "two thousand
    /// five thousand" is 2000 and 5000.
    ///
    /// Only where the speech has one reading. After a tens word or "hundred" it has two:
    /// "eight hundred twenty three hundred" is 820 and 300, or 800 and 2300, and "one thousand
    /// one hundred two thousand" is 1100 and 2000, or 1000 and 102000. Those are left out, and
    /// so is the exception in `a_hundred_after_a_thousand_splits_early`.
    #[test]
    fn a_number_never_says_the_same_place_twice(a in 100u64..1_000_000_000_000, place in prop::sample::select(&[2u32, 3, 6, 9][..]), digit in 1u64..=9) {
        prop_assume!(said_places(a).contains(&place));
        let last = spell(a, false).rsplit(' ').next().unwrap().to_string();
        prop_assume!(!TENS.contains(&last.as_str()) && !(last == "hundred" && (place > 2 || a >= 1000)));
        let b = digit * 10u64.pow(place);
        let said = format!("{} {}", spell(a, false), spell(b, false));
        prop_assert_eq!(numbers::apply(&said), format!("{a} {b}"));
    }

    /// N4. A year said as two numbers is one number: "nineteen eighty four" is 1984, "twenty
    /// twenty six" is 2026. "twenty thirty" stays two numbers, since it is usually a range.
    #[test]
    fn a_year_said_as_two_numbers_is_one(century in 13u64..=20, decade in 20u64..=99) {
        let said = format!("{} {}", spell(century, false), spell(decade, false));
        let expected = if century == 20 && decade >= 30 { format!("20 {decade}") } else { (century * 100 + decade).to_string() };
        prop_assert_eq!(numbers::apply(&said), expected);
    }
}

/// N3, an exception in both apps. "two thousand two hundred one hundred" should be 2200 and
/// 100. The reader looks ahead from "two" and reads "two hundred one hundred" as 201 hundreds,
/// which would say the thousands again, so it starts a new number there instead.
#[test]
fn a_hundred_after_a_thousand_splits_early() {
    assert_eq!(numbers::apply("two thousand two hundred one hundred"), "2000 200 100");
    assert_eq!(numbers::apply("eight hundred one hundred"), "800 100");
}

proptest! {
    #![proptest_config(config(2000))]

    /// N2. "one" stays a word unless it is counting something: "no one knows", "the one that
    /// works" and "one of the reasons" keep it.
    #[test]
    fn one_stays_a_word_unless_it_counts(before in prop::collection::vec(prop::sample::select(PLAIN), 0..6), after in prop::collection::vec(prop::sample::select(PLAIN), 0..6)) {
        let text = [before.join(" "), "one".into(), after.join(" ")].iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join(" ");
        prop_assert_eq!(numbers::apply(&text), text);
    }

    /// N2. ...and a "one" that counts is a digit: in front of a unit, or inside a run of numbers.
    #[test]
    fn one_counting_something_is_a_digit(unit in prop::sample::select(&["dollar", "percent", "minute", "day", "person", "time", "page"][..]), n in 2u64..10) {
        prop_assert_eq!(numbers::apply(&format!("it took one {unit}")), format!("it took 1 {unit}"));
        prop_assert_eq!(numbers::apply(&format!("press one {}", UNITS[n as usize])), format!("press 1 {n}"));
    }
}

// ---- Corrections and names ----------------------------------------------------------------

/// The English word list as a sorted list, so a generated index picks the same word every run.
static WORDS: Lazy<Vec<&'static str>> = Lazy::new(|| {
    let mut w: Vec<&str> = ENGLISH_WORDS.iter().map(String::as_str).filter(|w| w.chars().all(|c| c.is_ascii_lowercase())).collect();
    w.sort_unstable();
    w
});

fn english_word(min: usize) -> impl Strategy<Value = &'static str> {
    any::<prop::sample::Index>().prop_map(move |i| {
        // The nearest word at least `min` letters long, scanning forward from a random spot.
        let words = &*WORDS;
        let start = i.index(words.len());
        (0..words.len()).map(|k| words[(start + k) % words.len()]).find(|w| w.len() >= min).unwrap()
    })
}

const CONTEXT: [&str; 4] = ["we", "saw", "it", "there"];

proptest! {
    #![proptest_config(config(500))]

    /// C1. A correction replaces whole words only: "cloud => Claude" leaves "clouds", "cloudy"
    /// and "cloud's" alone, and replaces "cloud".
    #[test]
    fn a_correction_replaces_whole_words_only(from in "[a-z]{3,8}", to in "[A-Z][a-z]{2,8}", pre in "[a-z0-9']{1,3}", post in "[a-z0-9']{1,3}") {
        prop_assume!(!CONTEXT.contains(&from.as_str()));
        let rule = [Replacement::new(&from, &to)];
        for glued in [format!("{pre}{from}"), format!("{from}{post}"), format!("{pre}{from}{post}")] {
            let text = format!("we saw {glued} there");
            prop_assert_eq!(apply_replacements(&text, &rule), text);
        }
        prop_assert_eq!(apply_replacements(&format!("we saw {from} there"), &rule), format!("we saw {to} there"));
        prop_assert_eq!(apply_replacements(&format!("we saw {} there", from.to_uppercase()), &rule), format!("we saw {to} there"));
    }

    /// G1. An ordinary English word never becomes a name: with "Claude" in the dictionary,
    /// "cloud" and "clause" stay themselves. Its letters never change. Only a word that is a
    /// term, or a term with an ending ("claudes", "taurian" with "Tauri"), takes the term's
    /// capitals.
    #[test]
    fn an_english_word_never_becomes_a_name(words in prop::collection::vec(english_word(3), 1..12), names in prop::collection::vec("[A-Z][a-z]{3,9}", 0..4)) {
        let mut terms: Vec<String> = ["Claude", "Parakeet", "Supabase", "Tauri", "Wispr", "Ollama", "Northwind"].map(String::from).to_vec();
        terms.extend(names);
        let lower: Vec<String> = terms.iter().map(|t| t.to_lowercase()).collect();
        // A word that is a term, or a term with a plural or possessive ending, or two or three
        // words that spell a term run together, is the term and may be re-cased.
        for n in 1..=3 {
            for run in words.windows(n) {
                let glued = run.concat();
                prop_assume!(!lower.iter().any(|t| glued == *t || glued.strip_prefix(t.as_str()).is_some_and(|rest| ["s", "es", "'s", "s'"].contains(&rest))));
            }
        }
        // A plural whose stem is not a word is the one way an English word becomes a name
        // today: `an_english_plural_can_become_a_name`.
        prop_assume!(!words.iter().any(|w| ["'s", "s'", "es", "s"].iter().any(|end| w.len() > end.len() + 2 && w.ends_with(end) && !ENGLISH_WORDS.contains(&w[..w.len() - end.len()]))));
        let text = words.join(" ");
        let out = GlossaryMatcher::new(&terms).apply(&text);
        let out_words: Vec<&str> = out.split(' ').collect();
        prop_assert_eq!(out_words.len(), words.len(), "{}", out);
        for (was, now) in words.iter().zip(&out_words) {
            let recased = now.to_lowercase() == *was && lower.iter().any(|t| was.starts_with(t.as_str()));
            prop_assert!(was == now || recased, "{} became {}", was, now);
        }
    }

    /// L1. The learner never turns an everyday English word into a rule by itself: fixing
    /// "cloud" to "Claude" once must not rewrite every "cloud" from then on. A name spelled
    /// another way ("Lynn" to "Lin") is the one exception, and needs a capital and the same sound.
    #[test]
    fn the_learner_never_binds_an_everyday_word(from in english_word(4), to in prop_oneof![english_word(4).prop_map(String::from), english_word(4).prop_map(capitalized), "[A-Z][a-z]{3,8}"]) {
        prop_assume!(from != to.to_lowercase());
        prop_assume!(!(to.starts_with(|c: char| c.is_uppercase()) && name_key(from) == name_key(&to.to_lowercase())));
        let wrote = format!("i saved it to the {from} yesterday");
        let now = format!("i saved it to the {to} yesterday");
        let d = decide(&wrote, &now, LearnMode::Auto, &[], &[]);
        prop_assert!(d.outcome.added.is_empty(), "learned {:?}", d.outcome.added);
        prop_assert!(d.save_rules.is_none());
    }
}

/// G1, an exception in both apps. A plural is matched by its stem, and the stem is what gets the
/// English check: "taurus" is a word, "tauru" is not and is one letter from "Tauri", so
/// "taurus" becomes "Tauris". John's glossary rewrites 1 of the 25,915 English words ending in
/// "s" this way (counted 2026-10-02).
#[test]
fn an_english_plural_can_become_a_name() {
    let terms = vec!["Tauri".to_string()];
    assert_eq!(GlossaryMatcher::new(&terms).apply("the taurus constellation"), "the Tauris constellation");
}

fn capitalized(w: &str) -> String {
    let mut c = w.chars();
    c.next().map(|f| f.to_uppercase().chain(c).collect()).unwrap_or_default()
}

// ---- Cleaning ------------------------------------------------------------------------------

const FILLERS: &[&str] = &["um", "uh"];
static LONE_ONE_BY_A_FIGURE: Lazy<regex::Regex> = Lazy::new(|| regex::Regex::new(r"(?i)\bone\s+\d|\d\s+one\b").unwrap());
const COMMANDS: &[(&str, &str)] = &[("new", "line"), ("new", "paragraph"), ("question", "mark")];

const SPOKEN: &[&str] = &[
    "um", "uh", "so", "i", "think", "we", "should", "ship", "the", "windows", "build", "first", "twenty", "two", "one", "hundred",
    "and", "five", "point", "new", "line", "paragraph", "cloud", "claude", "lin", "flow", "wisper", "code", "it's", "okay", "yes",
    "no", "on", "Monday", "September", "thirtieth", "of", "a", "dollars", "percent", "period", "comma", "question", "mark", "really",
];

proptest! {
    #![proptest_config(config(1000))]

    /// I1. Cleaning a text twice gives the same result as cleaning it once. Five exceptions,
    /// each with its own test below: a rule whose result contains its own left side, a
    /// dictation that cleans down to a phrase the engines invent on silence, a spoken command
    /// with a filler inside it, a month the engine wrote in lowercase, and a lone "one" that
    /// cleaning leaves beside a figure. Months are generated capitalized, as the engines write
    /// them.
    #[test]
    fn cleaning_twice_is_cleaning_once(words in prop::collection::vec(prop::sample::select(SPOKEN), 1..25)) {
        let glossary: Vec<String> = ["Lin Flow", "Claude", "Claude Code", "Wispr Flow", "Parakeet"].map(String::from).to_vec();
        let rules = [Replacement::new("wisper flow", "Wispr Flow")];
        let kept: Vec<&str> = words.iter().copied().filter(|w| !FILLERS.contains(w)).collect();
        let joined_by_removal = kept.windows(2).any(|p| COMMANDS.contains(&(p[0], p[1])) && !words.windows(2).any(|q| q == p));
        prop_assume!(!joined_by_removal);
        let once = clean_with(&glossary, &rules, &words.join(" "));
        let core = once.to_lowercase().trim_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace()).to_string();
        prop_assume!(!SILENCE_HALLUCINATIONS.contains(&core.as_str()));
        prop_assume!(!LONE_ONE_BY_A_FIGURE.is_match(&once));
        prop_assert_eq!(clean_with(&glossary, &rules, &once), once);
    }
}

/// I1, an exception. "new um line" keeps its words, since removing the filler leaves two spaces
/// inside the command. Cleaned again, the one space left makes it a line break.
#[test]
fn cleaning_twice_can_finish_a_command() {
    let once = clean_with(&[], &[], "new um line");
    assert_eq!(once, "New line.");
    assert_eq!(clean_with(&[], &[], &once), "");
}

/// I1, an exception. A month is a month only with its capital, so "may" and "march" stay
/// verbs. A dictation starting "september thirtieth" keeps the words, and the capital the cleaner
/// adds last makes a second pass write "September 30th".
#[test]
fn cleaning_twice_can_date_a_lowercase_month() {
    let once = clean_with(&[], &[], "september thirtieth");
    assert_eq!(once, "September thirtieth.");
    assert_eq!(clean_with(&[], &[], &once), "September 30th.");
}

/// I1, an exception. In "one a hundred dollars" the "one" stands alone and stays a word, and "a
/// hundred" is 100. Cleaned again, "One 100 dollars." has "one" beside a figure, inside a run of
/// numbers, so it becomes 1.
#[test]
fn cleaning_twice_can_count_a_lone_one() {
    let once = clean_with(&[], &[], "one a hundred dollars");
    assert_eq!(once, "One 100 dollars.");
    assert_eq!(clean_with(&[], &[], &once), "1 100 dollars.");
}

/// I1, an exception. "um so" is a dictation and cleans to "So.", which is also what the engines
/// write on silence, so a second pass removes it. Nothing in the app cleans a cleaned text today.
#[test]
fn cleaning_twice_can_empty_a_short_dictation() {
    let once = clean_with(&[], &[], "um so");
    assert_eq!(once, "So.");
    assert_eq!(clean_with(&[], &[], &once), "");
}

/// I1, an exception. A rule whose result contains its own left side grows each time the
/// text is cleaned: "Lin => Lin Flow" turns "Lin Flow" into "Lin Flow Flow". Nothing in the app
/// cleans a cleaned text today, so this only matters if something starts to.
#[test]
fn cleaning_twice_can_grow_a_rule() {
    let rules = [Replacement::new("Lin", "Lin Flow")];
    let once = clean_with(&[], &rules, "lin is here");
    assert_eq!(once, "Lin Flow is here.");
    assert_eq!(clean_with(&[], &rules, &once), "Lin Flow Flow is here.");
}

// ---- The shared dictionary -----------------------------------------------------------------

/// The table as PostgREST serves it: rows keyed by (kind, key) and returned in that order, an
/// upsert replacing the row with the same key and answering with what it stored.
#[derive(Default)]
struct Table {
    rows: Mutex<BTreeMap<(String, String), Value>>,
}

impl Transport for Table {
    fn send(&self, request: &HttpRequest) -> Result<HttpResponse, NetError> {
        let mut rows = self.rows.lock().unwrap();
        if request.method == "GET" {
            let query = request.url.split_once('?').map(|(_, q)| q).unwrap_or("");
            let param = |name: &str| query.split('&').find_map(|p| p.strip_prefix(&format!("{name}="))).and_then(|v| v.parse::<usize>().ok()).unwrap();
            let page: Vec<&Value> = rows.values().skip(param("offset")).take(param("limit")).collect();
            return Ok(HttpResponse { status: 200, body: serde_json::to_vec(&page).unwrap() });
        }
        let sent: Vec<Value> = serde_json::from_slice(request.body.as_deref().unwrap()).unwrap();
        for row in &sent {
            rows.insert((row["kind"].as_str().unwrap().into(), row["key"].as_str().unwrap().into()), row.clone());
        }
        Ok(HttpResponse { status: 201, body: serde_json::to_vec(&sent).unwrap() })
    }
}

/// A temporary data folder per computer, removed when the case ends however it ends.
struct Computers(Vec<PathBuf>);

impl Computers {
    fn new(n: usize) -> Computers {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        Computers(
            (0..n)
                .map(|_| {
                    let dir = std::env::temp_dir().join(format!("linflow-laws-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
                    std::fs::create_dir_all(&dir).unwrap();
                    dir
                })
                .collect(),
        )
    }
}

impl Drop for Computers {
    fn drop(&mut self) {
        for dir in &self.0 {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}

// Canonically equivalent spellings ("Café" composed and decomposed) and case variants are in
// the pools on purpose: the table keys on lowercase text, the apps on canonical equivalence.
const TERMS: &[&str] = &["Claude", "claude", "Lin Flow", "lin flow", "Parakeet", "Supabase", "Tauri", "Caf\u{e9}", "Cafe\u{301}", "DESK-01", "Wispr", "Ollama"];
const FROM: &[&str] = &["wisper flow", "Wisper Flow", "cloud code", "olama", "super base", "tory", "cafe"];
const TO: &[&str] = &["Wispr Flow", "Claude Code", "Ollama", "Supabase", "Tauri", "Caf\u{e9}", "Cafe\u{301}"];

#[derive(Clone, Debug)]
enum Edit {
    AddTerm(usize, &'static str),
    RemoveTerm(usize, usize),
    AddRule(usize, &'static str, &'static str, bool),
    RemoveRule(usize, usize),
    Sync(usize),
}

fn edit(computers: usize) -> impl Strategy<Value = Edit> {
    prop_oneof![
        1 => (0..computers, prop::sample::select(TERMS)).prop_map(|(c, t)| Edit::AddTerm(c, t)),
        1 => (0..computers, 0..8usize).prop_map(|(c, i)| Edit::RemoveTerm(c, i)),
        1 => (0..computers, prop::sample::select(FROM), prop::sample::select(TO), any::<bool>()).prop_map(|(c, f, t, l)| Edit::AddRule(c, f, t, l)),
        1 => (0..computers, 0..8usize).prop_map(|(c, i)| Edit::RemoveRule(c, i)),
        3 => (0..computers).prop_map(Edit::Sync),
    ]
}

fn read_terms(dir: &std::path::Path) -> Vec<String> {
    std::fs::read_to_string(dir.join("vocab.txt")).map(|t| parse_terms(&t)).unwrap_or_default()
}

fn read_rules(dir: &std::path::Path) -> (Vec<Replacement>, String) {
    let text = std::fs::read_to_string(dir.join("replacements.txt")).unwrap_or_default();
    (parse_replacements(&text), text)
}

/// A computer's dictionary in a form that ignores line order (what arrived goes at the end) and
/// compares text the way Swift does, where "Café" composed and decomposed are one string.
fn dictionary(dir: &std::path::Path) -> (Vec<String>, Vec<(String, String, bool)>) {
    let mut terms: Vec<String> = read_terms(dir).iter().map(|t| swift_key(t)).collect();
    terms.sort();
    let mut rules: Vec<(String, String, bool)> = read_rules(dir).0.into_iter().map(|r| (swift_key(&r.from), swift_key(&r.to), r.learned)).collect();
    rules.sort();
    (terms, rules)
}

proptest! {
    #![proptest_config(config(60))]

    /// S1. After every computer has synced twice with nothing new written, every computer holds
    /// the same dictionary, deletions included, and it is the table's: the last change synced
    /// for each entry, and nothing deleted coming back. The table keeps one row per entry.
    #[test]
    fn every_computer_ends_with_the_same_dictionary(edits in prop::collection::vec(edit(3), 1..40)) {
        check_sync(&edits)?;
    }
}

/// S1, the case that found the second row: "Café" added, synced, deleted, synced, then added
/// again in its decomposed spelling. The re-add went to a row of its own and the old deletion
/// won, so the word vanished.
#[test]
fn a_word_added_back_in_another_spelling_stays() {
    let edits = [Edit::AddTerm(0, "Caf\u{e9}"), Edit::Sync(0), Edit::RemoveTerm(0, 0), Edit::Sync(0), Edit::AddTerm(0, "Cafe\u{301}")];
    check_sync(&edits).unwrap();
}

fn check_sync(edits: &[Edit]) -> Result<(), TestCaseError> {
        let computers = Computers::new(3);
        let table = Table::default();
        let start: DateTime<Utc> = Utc.with_ymd_and_hms(2026, 10, 2, 9, 0, 0).unwrap();
        let mut clock = 0;
        let mut sync_one = |c: usize| {
            clock += 1;
            let config = SyncConfig { url: "https://example.supabase.co".into(), key: "sb_publishable_test".into(), device: format!("computer-{c}") };
            sync(&config, &Files::in_dir(&computers.0[c]), &table, start + Duration::seconds(clock)).unwrap();
        };
        for e in edits {
            match *e {
                Edit::AddTerm(c, t) => {
                    let mut terms = read_terms(&computers.0[c]);
                    terms.push(t.into());
                    std::fs::write(computers.0[c].join("vocab.txt"), terms_file(&terms)).unwrap();
                }
                Edit::RemoveTerm(c, i) => {
                    let mut terms = read_terms(&computers.0[c]);
                    if i < terms.len() {
                        terms.remove(i);
                        std::fs::write(computers.0[c].join("vocab.txt"), terms_file(&terms)).unwrap();
                    }
                }
                Edit::AddRule(c, from, to, learned) => {
                    let (mut rules, text) = read_rules(&computers.0[c]);
                    rules.push(Replacement { from: from.into(), to: to.into(), learned });
                    std::fs::write(computers.0[c].join("replacements.txt"), replacements_file(&rules, &text)).unwrap();
                }
                Edit::RemoveRule(c, i) => {
                    let (mut rules, text) = read_rules(&computers.0[c]);
                    if i < rules.len() {
                        rules.remove(i);
                        std::fs::write(computers.0[c].join("replacements.txt"), replacements_file(&rules, &text)).unwrap();
                    }
                }
                Edit::Sync(c) => sync_one(c),
            }
        }
        for _ in 0..2 {
            for c in 0..3 {
                sync_one(c);
            }
        }
        let first = dictionary(&computers.0[0]);
        for dir in &computers.0[1..] {
            prop_assert_eq!(&dictionary(dir), &first);
        }
        // And it is the table's live rows, one row per entry.
        let rows = table.rows.lock().unwrap();
        let mut entries: Vec<String> = rows.values().map(|r| swift_key(&format!("{}|{}", r["kind"], r["text"].as_str().unwrap().to_lowercase()))).collect();
        let all = entries.len();
        entries.sort();
        entries.dedup();
        prop_assert_eq!(entries.len(), all, "two rows for one entry");
        let live = rows.values().filter(|r| !r["deleted"].as_bool().unwrap());
        let (mut terms, mut rules) = (vec![], vec![]);
        for r in live {
            let text = swift_key(r["text"].as_str().unwrap());
            if r["kind"] == "term" {
                terms.push(text);
            } else {
                rules.push((text, swift_key(r["target"].as_str().unwrap()), r["learned"].as_bool().unwrap()));
            }
        }
        terms.sort();
        rules.sort();
        prop_assert_eq!(&first, &(terms, rules));
        Ok(())
}

