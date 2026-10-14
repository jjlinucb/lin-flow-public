//! Without headphones the microphone hears the speakers, so every sentence the other side says
//! comes back a second time as "You". On 2026-10-02, a 29-minute Zoom training, 80 of 87 "You"
//! segments were the presenter. A "You" segment goes when most of its word pairs are in "Others"
//! segments overlapping it in time: the system track is the clean copy. Pairs, not single words,
//! so "I think that is right" said over someone's long sentence stays. Segments under three
//! words stay too, since "yeah" and "okay" are too common to judge.

use super::{OTHERS, YOU};
use crate::notes::TranscriptSegment;
use crate::text::unicode::{is_letter, is_number, lowercased, split_graphemes, swift_key};
use std::collections::HashSet;

pub const SLACK_SECONDS: f64 = 1.0;
pub const SHARE: f64 = 0.5;

pub fn drop_echo(segments: &[TranscriptSegment], slack: f64, share: f64) -> Vec<TranscriptSegment> {
    let others: Vec<&TranscriptSegment> = segments.iter().filter(|s| s.speaker == OTHERS).collect();
    if others.is_empty() {
        return segments.to_vec();
    }
    segments
        .iter()
        .filter(|s| {
            if s.speaker != YOU || words(&s.text).len() < 3 {
                return true;
            }
            let mine = pairs(&s.text);
            let mut theirs = HashSet::new();
            for o in others.iter().filter(|o| o.start < s.end + slack && o.end > s.start - slack) {
                theirs.extend(pairs(&o.text));
            }
            let shared = mine.iter().filter(|p| theirs.contains(*p)).count();
            shared as f64 / mine.len() as f64 <= share
        })
        .cloned()
        .collect()
}

fn pairs(text: &str) -> Vec<String> {
    let w = words(text);
    if w.len() < 2 {
        return w;
    }
    (1..w.len()).map(|i| format!("{} {}", w[i - 1], w[i])).collect()
}

fn words(text: &str) -> Vec<String> {
    let lower = lowercased(text);
    split_graphemes(&lower, |g| !(is_letter(g) || is_number(g) || g == "'")).into_iter().map(swift_key).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(start: f64, end: f64, speaker: &str, text: &str) -> TranscriptSegment {
        TranscriptSegment::new(start, end, speaker, text)
    }

    #[test]
    fn drops_the_echo_and_keeps_johns_own_lines() {
        let segs = vec![
            seg(0.0, 6.0, OTHERS, "Wash your hands after using the restroom, every single time."),
            seg(0.4, 6.2, YOU, "wash your hands after using the restroom every single time"),
            seg(3.0, 5.0, YOU, "I think that is right"),
            seg(9.0, 10.0, YOU, "yeah okay"),
        ];
        let kept = drop_echo(&segs, SLACK_SECONDS, SHARE);
        let texts: Vec<&str> = kept.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(texts, vec!["Wash your hands after using the restroom, every single time.", "I think that is right", "yeah okay"]);
    }

    #[test]
    fn far_apart_in_time_is_not_an_echo() {
        let segs = vec![seg(0.0, 3.0, OTHERS, "the food permit is due friday"), seg(60.0, 63.0, YOU, "the food permit is due friday")];
        assert_eq!(drop_echo(&segs, SLACK_SECONDS, SHARE).len(), 2);
    }
}
