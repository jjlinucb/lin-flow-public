//! Character rules that match Swift's, so the Rust pipeline reads text the way the Mac app does.
//!
//! The Swift cleaner walks `Character`s (extended grapheme clusters) and asks each one
//! `isLetter`, `isPunctuation` and so on, which Swift answers from the cluster's first scalar.
//! Its regular expressions are ICU's, whose `\s` is narrower than Rust's. Each helper here names
//! the Swift or ICU behavior it reproduces.

use unicode_properties::{GeneralCategory, GeneralCategoryGroup, UnicodeGeneralCategory};
use unicode_segmentation::UnicodeSegmentation;

/// The text as Swift `Character`s.
pub fn graphemes(s: &str) -> Vec<&str> {
    s.graphemes(true).collect()
}

/// `String.count`: grapheme clusters, not bytes or scalars.
pub fn count(s: &str) -> usize {
    s.graphemes(true).count()
}

fn first(g: &str) -> char {
    g.chars().next().unwrap_or('\0')
}

/// `Character.isLetter`: the first scalar is Alphabetic.
pub fn is_letter(g: &str) -> bool {
    first(g).is_alphabetic()
}

/// `Character.isNumber`: the first scalar has a numeric type.
pub fn is_number(g: &str) -> bool {
    first(g).is_numeric()
}

/// `Character.isWhitespace`: the first scalar is White_Space.
pub fn is_whitespace(g: &str) -> bool {
    first(g).is_whitespace()
}

/// `Character.isNewline`.
pub fn is_newline(g: &str) -> bool {
    matches!(first(g), '\n' | '\u{B}' | '\u{C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

pub fn is_punctuation_char(c: char) -> bool {
    c.general_category_group() == GeneralCategoryGroup::Punctuation
}

/// `Character.isPunctuation`: the first scalar is in a P* category.
pub fn is_punctuation(g: &str) -> bool {
    is_punctuation_char(first(g))
}

fn single_scalar(g: &str) -> Option<char> {
    let mut it = g.chars();
    let c = it.next()?;
    if it.next().is_none() {
        Some(c)
    } else {
        None
    }
}

/// `Character.isLowercase`.
pub fn is_lowercase(g: &str) -> bool {
    if let Some(c) = single_scalar(g) {
        if c.is_lowercase() {
            return true;
        }
    }
    lowercased(g) == g && uppercased(g) != g
}

/// `Character.isUppercase`.
pub fn is_uppercase(g: &str) -> bool {
    if let Some(c) = single_scalar(g) {
        if c.is_uppercase() {
            return true;
        }
    }
    uppercased(g) == g && lowercased(g) != g
}

/// Whether most of the letters are outside the Latin alphabet: Cyrillic, Greek and the like. Parakeet
/// v3 picks its language by itself and has no switch, and on 2026-10-27 it heard John's "Hey, wrap
/// up here" as "Гей, раппак кир". With the language set to English, such a take is decoded again.
pub fn mostly_not_latin(s: &str) -> bool {
    let latin = |c: char| c.is_ascii_alphabetic() || ('\u{C0}'..='\u{24F}').contains(&c) || ('\u{1E00}'..='\u{1EFF}').contains(&c);
    let (mut letters, mut other) = (0usize, 0usize);
    for c in s.chars().filter(|c| c.is_alphabetic()) {
        letters += 1;
        if !latin(c) {
            other += 1;
        }
    }
    letters > 0 && other * 2 > letters
}

/// `String.lowercased()`: each scalar's full lowercase mapping, with no final-sigma rule, which
/// is where Rust's `str::to_lowercase` differs.
pub fn lowercased(s: &str) -> String {
    s.chars().flat_map(char::to_lowercase).collect()
}

/// `String.uppercased()`.
pub fn uppercased(s: &str) -> String {
    s.chars().flat_map(char::to_uppercase).collect()
}

fn is_space_separator(c: char) -> bool {
    c.general_category() == GeneralCategory::SpaceSeparator
}

/// `CharacterSet.whitespaces`: Zs and tab.
pub fn is_cs_whitespace(c: char) -> bool {
    c == '\t' || is_space_separator(c)
}

/// `CharacterSet.whitespacesAndNewlines`.
pub fn is_cs_whitespace_or_newline(c: char) -> bool {
    is_cs_whitespace(c) || matches!(c, '\n' | '\u{B}' | '\u{C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `trimmingCharacters(in: .whitespaces)`.
pub fn trim_ws(s: &str) -> &str {
    s.trim_matches(is_cs_whitespace)
}

/// `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub fn trim_ws_nl(s: &str) -> &str {
    s.trim_matches(is_cs_whitespace_or_newline)
}

/// A string as Swift compares it. Swift's `==`, `<`, `Set` and `Dictionary` treat canonically
/// equivalent strings as one ("é" precomposed and "e" plus a combining accent) and order them by
/// the scalars of their NFC form, so a set or map key built from this matches Swift's behavior,
/// and byte order on it is Swift's sort order.
pub fn swift_key(s: &str) -> String {
    use unicode_normalization::UnicodeNormalization;
    if s.is_ascii() {
        return s.to_string();
    }
    s.nfc().collect()
}

/// Swift's `==` on strings.
pub fn swift_eq(a: &str, b: &str) -> bool {
    a == b || (!(a.is_ascii() && b.is_ascii()) && swift_key(a) == swift_key(b))
}

/// `split(whereSeparator:)` over `Character`s: the non-empty runs between separators.
pub fn split_graphemes(s: &str, mut separator: impl FnMut(&str) -> bool) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start: Option<usize> = None;
    for (i, g) in s.grapheme_indices(true) {
        if separator(g) {
            if let Some(st) = start.take() {
                out.push(&s[st..i]);
            }
        } else if start.is_none() {
            start = Some(i);
        }
    }
    if let Some(st) = start {
        out.push(&s[st..]);
    }
    out
}

/// `split(separator: "\n", omittingEmptySubsequences: false)`: the lines, empty ones kept. A
/// "\r\n" is one `Character` and does not end a line.
pub fn lines_keeping_empty(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    for (i, g) in s.grapheme_indices(true) {
        if g == "\n" {
            out.push(&s[start..i]);
            start = i + 1;
        }
    }
    out.push(&s[start..]);
    out
}

fn is_grapheme_boundary(s: &str, at: usize) -> bool {
    at == 0 || at == s.len() || s.grapheme_indices(true).any(|(i, _)| i == at)
}

/// `String.hasPrefix`, which compares whole `Character`s: "e" is not a prefix of "e\u{301}".
pub fn has_prefix(s: &str, prefix: &str) -> bool {
    s.starts_with(prefix) && is_grapheme_boundary(s, prefix.len())
}

/// `String.hasSuffix`.
pub fn has_suffix(s: &str, suffix: &str) -> bool {
    s.ends_with(suffix) && is_grapheme_boundary(s, s.len() - suffix.len())
}

/// `firstIndex(of:)` for a `Character`: the byte offset of the first grapheme equal to `g`.
pub fn find_grapheme(s: &str, g: &str) -> Option<usize> {
    s.grapheme_indices(true).find(|(_, x)| *x == g).map(|(i, _)| i)
}

/// The first `n` `Character`s and the rest.
pub fn split_at_grapheme(s: &str, n: usize) -> (&str, &str) {
    match s.grapheme_indices(true).nth(n) {
        Some((i, _)) => s.split_at(i),
        None => (s, ""),
    }
}

/// `dropLast(n)` over `Character`s.
pub fn drop_last_graphemes(s: &str, n: usize) -> &str {
    let total = count(s);
    split_at_grapheme(s, total.saturating_sub(n)).0
}

/// `CharacterSet.alphanumerics`: general categories L, M and N.
pub fn is_cs_alphanumeric(c: char) -> bool {
    matches!(c.general_category_group(), GeneralCategoryGroup::Letter | GeneralCategoryGroup::Mark | GeneralCategoryGroup::Number)
}

/// `trimmingCharacters(in: CharacterSet.alphanumerics.inverted)`.
pub fn trim_non_alphanumerics(s: &str) -> &str {
    s.trim_matches(|c: char| !is_cs_alphanumeric(c))
}

/// ICU's `\s`, `[\t\n\f\r\p{Z}]`, as the inside of a character class. Rust's `\s` also takes
/// U+000B and U+0085, which ICU does not.
pub const ICU_SPACE_CLASS: &str = r"\t\n\x0C\r\p{Z}";

/// A pattern written with `\s` the way NSRegularExpression reads it.
pub fn icu(pattern: &str) -> String {
    let mut out = String::with_capacity(pattern.len() + 32);
    let mut chars = pattern.chars().peekable();
    let mut in_class = false;
    while let Some(c) = chars.next() {
        if c == '\\' {
            let Some(&n) = chars.peek() else {
                out.push(c);
                break;
            };
            chars.next();
            if n == 's' {
                if in_class {
                    out.push_str(ICU_SPACE_CLASS);
                } else {
                    out.push('[');
                    out.push_str(ICU_SPACE_CLASS);
                    out.push(']');
                }
            } else {
                out.push('\\');
                out.push(n);
            }
            continue;
        }
        if c == '[' && !in_class {
            in_class = true;
        } else if c == ']' && in_class {
            in_class = false;
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tells_a_take_in_another_alphabet() {
        assert!(mostly_not_latin("Гей, раппак кир."));
        assert!(mostly_not_latin("Γεια σου"));
        assert!(!mostly_not_latin("Hey, wrap up here."));
        assert!(!mostly_not_latin("Café déjà vu, naïve résumé."));
        assert!(!mostly_not_latin("Call Влад about the 3 PM slot"));
        assert!(!mostly_not_latin("123 ... !"));
    }

    #[test]
    fn icu_space() {
        assert_eq!(icu(r"a\s+b"), r"a[\t\n\x0C\r\p{Z}]+b");
        assert_eq!(icu(r"[,.\s]+"), r"[,.\t\n\x0C\r\p{Z}]+");
        assert_eq!(icu(r"\\s"), r"\\s");
    }

    #[test]
    fn swift_character_rules() {
        assert!(is_lowercase("j"));
        assert!(!is_lowercase("J"));
        assert!(!is_lowercase("1"));
        assert!(is_punctuation("."));
        assert!(!is_punctuation("$"));
        assert_eq!(lowercased("ΣΑΣ"), "σασ");
        assert_eq!(count("e\u{301}x"), 2);
        assert_eq!(split_graphemes("  a b\r\nc  ", |g| g == " "), vec!["a", "b\r\nc"]);
        assert_eq!(split_graphemes("a\r\nb\nc", |g| g == "\n"), vec!["a\r\nb", "c"], "CRLF is one Character");
        assert!(has_prefix("tbd later", "tbd") && !has_prefix("e\u{301}", "e"));
        assert_eq!(trim_non_alphanumerics("(\"Ted's\")."), "Ted's");
        assert_eq!(drop_last_graphemes("18th", 2), "18");
    }
}
