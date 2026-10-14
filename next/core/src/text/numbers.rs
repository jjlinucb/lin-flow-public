//! Spoken numbers as digits: "twenty two" is 22, "one two three four five" is 1 2 3 4 5.
//!
//! The whole difficulty is "one", a number half the time and a pronoun the rest ("one of the
//! reasons", "no one knows"). So "one" converts only when the sentence makes it a count: inside
//! a bigger number, inside a run of digits, or in front of a unit. Every other number word
//! converts freely, apart from an ordinal following it ("the twenty second") and hyphenated
//! compounds ("one-on-one"). A scale word with no number in front of it is speech ("a few
//! hundred"), except after "a": "a hundred" is 100. A day after a capitalized month is
//! "September 30th", and "five point five" is 5.5. A port of the Swift `NumberWords`.

use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::{HashMap, HashSet};

fn table(pairs: &[(&'static str, i64)]) -> HashMap<&'static str, i64> {
    pairs.iter().copied().collect()
}

static UNITS: Lazy<HashMap<&str, i64>> = Lazy::new(|| {
    table(&[("zero", 0), ("one", 1), ("two", 2), ("three", 3), ("four", 4), ("five", 5), ("six", 6), ("seven", 7), ("eight", 8), ("nine", 9)])
});
static TEENS: Lazy<HashMap<&str, i64>> = Lazy::new(|| {
    table(&[
        ("ten", 10), ("eleven", 11), ("twelve", 12), ("thirteen", 13), ("fourteen", 14), ("fifteen", 15), ("sixteen", 16),
        ("seventeen", 17), ("eighteen", 18), ("nineteen", 19),
    ])
});
static TENS: Lazy<HashMap<&str, i64>> = Lazy::new(|| {
    table(&[("twenty", 20), ("thirty", 30), ("forty", 40), ("fifty", 50), ("sixty", 60), ("seventy", 70), ("eighty", 80), ("ninety", 90)])
});
static SCALES: Lazy<HashMap<&str, i64>> =
    Lazy::new(|| table(&[("hundred", 100), ("thousand", 1_000), ("million", 1_000_000), ("billion", 1_000_000_000)]));

/// The scale words "a" turns into a figure. Not million or billion: "one in a million" and
/// "thanks a million" are idiom.
const COUNTED_AFTER_A: &[&str] = &["hundred", "thousand"];

/// An ordinal right after a number means the number was part of it: "the twenty second".
const ORDINALS: &[&str] = &[
    "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
    "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth", "thirtieth",
    "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth", "hundredth", "thousandth", "millionth", "half",
    "halves", "thirds", "quarter", "quarters", "fourths", "fifths", "sixths", "eighths",
];

/// What makes a lone "one" a count rather than a pronoun.
static UNITS_OF_MEASURE: Lazy<HashSet<&str>> = Lazy::new(|| {
    [
        "percent", "dollar", "dollars", "cent", "cents", "euro", "euros", "pound", "pounds", "second", "seconds", "minute", "minutes",
        "hour", "hours", "day", "days", "week", "weeks", "month", "months", "year", "years", "time", "times", "o'clock", "degree",
        "degrees", "mile", "miles", "kilometer", "kilometers", "meter", "meters", "foot", "feet", "inch", "inches", "gram", "grams",
        "kilogram", "kilograms", "ounce", "ounces", "liter", "liters", "gallon", "gallons", "byte", "bytes", "kilobyte", "megabyte",
        "gigabyte", "terabyte", "page", "pages", "point", "points", "person", "people", "copy", "copies", "star", "stars", "line",
        "lines", "word", "words",
    ]
    .into_iter()
    .collect()
});

const MONTHS: &[&str] = &["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];

/// The ordinals a day of the month is made of. "twenty first" is 20 and 1.
static DAY_ORDINALS: Lazy<HashMap<&str, i64>> = Lazy::new(|| {
    table(&[
        ("first", 1), ("second", 2), ("third", 3), ("fourth", 4), ("fifth", 5), ("sixth", 6), ("seventh", 7), ("eighth", 8),
        ("ninth", 9), ("tenth", 10), ("eleventh", 11), ("twelfth", 12), ("thirteenth", 13), ("fourteenth", 14), ("fifteenth", 15),
        ("sixteenth", 16), ("seventeenth", 17), ("eighteenth", 18), ("nineteenth", 19), ("twentieth", 20), ("thirtieth", 30),
    ])
});

fn decimal_digit(w: &str) -> Option<i64> {
    if w == "oh" {
        Some(0)
    } else {
        UNITS.get(w).copied()
    }
}

fn value(w: &str) -> Option<i64> {
    UNITS.get(w).or_else(|| TEENS.get(w)).or_else(|| TENS.get(w)).copied()
}

fn is_number_word(w: &str) -> bool {
    value(w).is_some() || SCALES.contains_key(w)
}

/// A word token: its byte range in the text and its lowercase form.
#[derive(Clone, Debug)]
struct Token {
    start: usize,
    end: usize,
    lower: String,
}

static WORD: Lazy<Regex> = Lazy::new(|| Regex::new(r"[A-Za-z][A-Za-z']*").unwrap());

/// "st", "nd", "rd" or "th": 1st, 22nd, 13th.
pub fn ordinal_suffix(n: i64) -> &'static str {
    if (11..=13).contains(&(n % 100)) {
        return "th";
    }
    match n % 10 {
        1 => "st",
        2 => "nd",
        3 => "rd",
        _ => "th",
    }
}

struct Ctx<'a> {
    text: &'a str,
    tokens: Vec<Token>,
}

impl<'a> Ctx<'a> {
    /// Nothing but spaces between tokens `a` and `b`.
    fn spaced(&self, a: usize, b: usize) -> bool {
        let gap = &self.text[self.tokens[a].end..self.tokens[b].start];
        !gap.is_empty() && gap.chars().all(|c| c == ' ')
    }

    fn lower(&self, k: usize) -> &str {
        &self.tokens[k].lower
    }

    /// The day of the month spelled from token `k`, and how many tokens it takes.
    fn day(&self, k: usize) -> Option<(i64, usize)> {
        if k >= self.tokens.len() {
            return None;
        }
        if let Some(&t) = TENS.get(self.lower(k)) {
            if (t == 20 || t == 30) && k + 1 < self.tokens.len() && self.spaced(k, k + 1) {
                if let Some(&o) = DAY_ORDINALS.get(self.lower(k + 1)) {
                    if o <= 9 && t + o <= 31 {
                        return Some((t + o, 2));
                    }
                }
            }
        }
        DAY_ORDINALS.get(self.lower(k)).map(|&d| (d, 1))
    }

    /// A month as the engines write it, capitalized, so "you may first" and "march on" stay words.
    fn is_month(&self, k: isize) -> bool {
        if k < 0 || k as usize >= self.tokens.len() {
            return false;
        }
        let t = &self.tokens[k as usize];
        MONTHS.contains(&t.lower.as_str()) && self.text[t.start..].chars().next().is_some_and(|c| c.is_ascii_uppercase())
    }

    /// Days written as figures, and the tokens they used.
    fn dates(&self) -> (Vec<(usize, usize, String)>, HashSet<usize>) {
        let mut edits = Vec::new();
        let mut used = HashSet::new();
        for k in 0..self.tokens.len() {
            if used.contains(&k) {
                continue;
            }
            let mut start = None;
            if self.is_month(k as isize - 1) && self.spaced(k - 1, k) {
                start = Some(k); // September thirtieth
            } else if k > 0 && self.lower(k - 1) == "the" {
                if let Some((_, n)) = self.day(k) {
                    if k + n + 1 < self.tokens.len() && self.spaced(k + n - 1, k + n) && self.lower(k + n) == "of" && self.is_month((k + n + 1) as isize) {
                        start = Some(k); // the thirtieth of September
                    }
                }
            }
            let Some(start) = start else { continue };
            let Some((d, n)) = self.day(start) else { continue };
            let last = &self.tokens[start + n - 1];
            edits.push((self.tokens[start].start, last.end, format!("{d}{}", ordinal_suffix(d))));
            used.extend(start..start + n);
        }
        (edits, used)
    }

    /// The digit words after "point" that follow token `end`: "point five" is "5".
    fn decimal(&self, end: usize, used: &HashSet<usize>) -> Option<(String, usize)> {
        let p = end + 1;
        if !(p + 1 < self.tokens.len() && self.lower(p) == "point" && self.spaced(end, p)) {
            return None;
        }
        let mut digits = String::new();
        let mut last = p;
        let mut k = p + 1;
        while k < self.tokens.len() && !used.contains(&k) {
            let Some(d) = decimal_digit(self.lower(k)) else { break };
            if !self.spaced(last, k) {
                break;
            }
            digits.push_str(&d.to_string());
            last = k;
            k += 1;
        }
        if digits.is_empty() {
            None
        } else {
            Some((digits, last))
        }
    }

    /// The "a" right before token `index`, with nothing but spaces between the two.
    fn article_before(&self, index: usize) -> Option<(usize, usize)> {
        if index == 0 || self.lower(index - 1) != "a" {
            return None;
        }
        if self.spaced(index - 1, index) {
            let a = &self.tokens[index - 1];
            Some((a.start, a.end))
        } else {
            None
        }
    }

    /// True when the run sits inside a hyphenated compound.
    fn hyphenated(&self, first: usize, last: usize) -> bool {
        let before = self.tokens[first].start;
        let after = self.tokens[last].end;
        self.text[..before].ends_with('-') || self.text[after..].starts_with('-')
    }

    /// A lone "one" is only a number when it is counting something.
    fn convertible(&self, words: &[&str], run: usize, index: usize) -> bool {
        if !(words.len() == 1 && words[0] == "one" && run == 1) {
            return true;
        }
        index + 1 < self.tokens.len() && UNITS_OF_MEASURE.contains(self.lower(index + 1))
    }
}

/// The text with spoken numbers written as digits.
pub fn apply(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    let tokens: Vec<Token> = WORD.find_iter(text).map(|m| Token { start: m.start(), end: m.end(), lower: m.as_str().to_ascii_lowercase() }).collect();
    if tokens.is_empty() {
        return text.to_string();
    }
    let ctx = Ctx { text, tokens };
    let (mut edits, used) = ctx.dates();
    let n = ctx.tokens.len();
    let mut i = 0;
    while i < n {
        if used.contains(&i) || !is_number_word(ctx.lower(i)) {
            i += 1;
            continue;
        }
        // The longest run of number words, with "and" allowed between two of them.
        let mut end = i;
        while end + 1 < n && !used.contains(&(end + 1)) {
            let next = ctx.lower(end + 1);
            if is_number_word(next) {
                end += 1;
                continue;
            }
            if next == "and" && end + 2 < n && is_number_word(ctx.lower(end + 2)) {
                end += 2;
                continue;
            }
            break;
        }
        if end + 1 < n && ORDINALS.contains(&ctx.lower(end + 1)) {
            i = end + 1; // "the twenty second"
            continue;
        }
        if ctx.hyphenated(i, end) {
            i = end + 1; // "one-on-one"
            continue;
        }
        // A bare scale word is speech: "a few hundred", "thousands of them". After "a" it counts:
        // "a hundred" is 100 and "a hundred forty volts" is 140 volts. The "a" goes with it.
        let mut article: Option<(usize, usize)> = None;
        if SCALES.contains_key(ctx.lower(i)) {
            let a = if COUNTED_AFTER_A.contains(&ctx.lower(i)) { ctx.article_before(i) } else { None };
            match a {
                Some(a) => article = Some(a),
                None => {
                    i = end + 1;
                    continue;
                }
            }
        }
        // Each number in the run replaces exactly the words that spell it, so the separators
        // between separate numbers ("1, 2, 3") stay as spoken.
        let run: Vec<&str> = (i..=end).map(|k| ctx.lower(k)).collect();
        let mut next = end + 1;
        for group in merge_years(parse(&run)) {
            let first_tok = i + group.start;
            let last_tok = i + group.end - 1;
            let first_start = if group.start == 0 { article.map_or(ctx.tokens[first_tok].start, |a| a.0) } else { ctx.tokens[first_tok].start };
            // The run's last number may go on as a decimal: "five point five" is 5.5, and "one
            // point five" is 1.5 though a lone "one" is otherwise a pronoun.
            if group.end == run.len() {
                if let Some((digits, last)) = ctx.decimal(end, &used) {
                    edits.push((first_start, ctx.tokens[last].end, format!("{}.{}", group.value, digits)));
                    next = last + 1;
                    continue;
                }
            }
            let words: Vec<&str> = run[group.start..group.end].to_vec();
            if !ctx.convertible(&words, run.len(), first_tok) {
                continue;
            }
            edits.push((first_start, ctx.tokens[last_tok].end, group.value.to_string()));
        }
        i = next;
    }
    if edits.is_empty() {
        return text.to_string();
    }
    edits.sort_by_key(|e| e.0);
    let mut out = text.to_string();
    for (start, end, replacement) in edits.into_iter().rev() {
        out.replace_range(start..end, &replacement);
    }
    out
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Group {
    pub value: i64,
    pub start: usize,
    pub end: usize,
}

/// A year said as two numbers is one number: "nineteen eighty four" is 1984 and "twenty twenty
/// six" is 2026. Kept narrow, because "twenty thirty" is usually a range.
pub fn merge_years(groups: Vec<Group>) -> Vec<Group> {
    if groups.len() < 2 {
        return groups;
    }
    let mut out = Vec::new();
    let mut i = 0;
    while i < groups.len() {
        let a = groups[i];
        if i + 1 < groups.len() {
            let b = groups[i + 1];
            let century = (13..=19).contains(&a.value) || a.value == 20;
            let decade = if a.value == 20 { (20..=29).contains(&b.value) } else { (20..=99).contains(&b.value) };
            if century && decade && a.end == b.start {
                out.push(Group { value: a.value * 100 + b.value, start: a.start, end: b.end });
                i += 2;
                continue;
            }
        }
        out.push(a);
        i += 1;
    }
    out
}

/// Splits a run of number words into the numbers it spells. "twenty two" is one number, "one
/// two three" is three, "two thousand twenty six" is one, and a word that cannot join what is
/// already built starts a new number.
pub fn parse(words: &[&str]) -> Vec<Group> {
    struct State {
        out: Vec<Group>,
        start: usize,
        taken: usize,
        total: i64,
        current: i64,
        smallest_big: Option<i64>,
        ones: bool,
        tenslot: bool,
        hundreds: bool,
        pending: bool,
    }
    impl State {
        // Ends the number at the last word it took, so an "and" between two numbers stays in
        // the text: "panels one and two" is "panels 1 and 2".
        fn flush(&mut self) {
            if !(self.taken > self.start && self.pending) {
                return;
            }
            self.out.push(Group { value: self.total + self.current, start: self.start, end: self.taken });
            self.total = 0;
            self.current = 0;
            self.smallest_big = None;
            self.ones = false;
            self.tenslot = false;
            self.hundreds = false;
            self.pending = false;
        }
    }
    let mut s = State { out: Vec::new(), start: 0, taken: 0, total: 0, current: 0, smallest_big: None, ones: false, tenslot: false, hundreds: false, pending: false };
    let mut i = 0;
    while i < words.len() {
        let w = words[i];
        if w == "and" {
            i += 1;
            continue;
        }
        if let Some(&scale) = SCALES.get(w) {
            if scale == 100 {
                s.current = (if s.current == 0 { 1 } else { s.current }) * 100;
                s.hundreds = true;
                s.ones = false;
                s.tenslot = false;
            } else {
                s.total += (if s.current == 0 && s.total == 0 { 1 } else { s.current }) * scale;
                s.current = 0;
                s.ones = false;
                s.tenslot = false;
                s.hundreds = false;
                s.smallest_big = Some(scale);
            }
            s.pending = true;
            i += 1;
            s.taken = i;
            continue;
        }
        let Some(v) = value(w) else { break };
        let above = s.hundreds || s.total > 0;
        let mut can_join = if TENS.contains_key(w) || TEENS.contains_key(w) {
            !s.tenslot && !s.ones && above
        } else {
            !s.ones && (s.tenslot || above)
        };
        // A number never says the same place twice, so a word that leads into one starts the
        // next number: "eight hundred and seven hundred" is 800 and 700, not 80700.
        if can_join && repeats_a_place(words, i, s.ones, s.tenslot, s.hundreds, s.smallest_big) {
            can_join = false;
        }
        if s.pending && !can_join {
            s.flush();
            s.start = i;
        }
        s.current += v;
        if TENS.contains_key(w) {
            s.tenslot = true;
        } else {
            s.ones = true;
        }
        s.pending = true;
        i += 1;
        s.taken = i;
    }
    s.flush();
    s.out
}

/// True when joining `words[index]` to the number being built would give that number a place it
/// already has: a second hundreds, or a thousand after a thousand. It looks only as far as the
/// words could still belong to this number, so "two thousand five, three thousand" is still
/// 2005 and 3000.
fn repeats_a_place(words: &[&str], index: usize, ones: bool, tenslot: bool, hundreds: bool, smallest_big: Option<i64>) -> bool {
    let (mut ones, mut tenslot, mut hundreds) = (ones, tenslot, hundreds);
    if TENS.contains_key(words[index]) {
        tenslot = true;
    } else {
        ones = true;
    }
    for &w in &words[index + 1..] {
        if w == "and" {
            continue;
        }
        if let Some(&scale) = SCALES.get(w) {
            if scale != 100 {
                return smallest_big.is_some_and(|b| scale >= b);
            }
            if hundreds {
                return true;
            }
            hundreds = true;
            ones = false;
            tenslot = false;
            continue;
        }
        // A word that cannot join ends this number, and nothing after it is this number's.
        let joins = if TENS.contains_key(w) || TEENS.contains_key(w) { !tenslot && !ones } else { !ones };
        if !joins {
            return false;
        }
        if TENS.contains_key(w) {
            tenslot = true;
        } else {
            ones = true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers() {
        let cases = [
            ("twenty two people", "22 people"),
            ("one two three four five", "1 2 3 4 5"),
            ("one of the reasons", "one of the reasons"),
            ("one hour", "1 hour"),
            ("the twenty second", "the twenty second"),
            ("one-on-one", "one-on-one"),
            ("a few hundred", "a few hundred"),
            ("a hundred forty volts", "140 volts"),
            ("nineteen eighty four", "1984"),
            ("twenty twenty six", "2026"),
            ("panels one and two", "panels 1 and 2"),
            ("eight hundred and seven hundred", "800 and 700"),
            ("two thousand five, three thousand", "2005, 3000"),
            ("I already got my September thirtieth invoice.", "I already got my September 30th invoice."),
            ("September twenty first", "September 21st"),
            ("the thirtieth of September", "the 30th of September"),
            ("you may first check", "you may first check"),
            ("my first job", "my first job"),
            ("Claude Opus five point five", "Claude Opus 5.5"),
            ("three point one four", "3.14"),
            ("version two point oh", "version 2.0"),
            ("five point five million", "5.5 million"),
            ("we made two points", "we made 2 points"),
            ("thanks a million", "thanks a million"),
        ];
        for (input, want) in cases {
            assert_eq!(apply(input), want, "{input}");
        }
    }
}
