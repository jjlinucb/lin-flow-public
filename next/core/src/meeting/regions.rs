//! The whole-file pass: transcribes a note's saved audio end to end after the meeting and
//! rewrites the transcript from it.
//!
//! The live transcript has to show something now, so it cuts wherever the speaker pauses or at
//! 10 s, and the model never sees more than that. This pass has the whole recording: it finds
//! the real pauses with hindsight, hands the model up to 28 s of context at a time, cuts a long
//! stretch at its quietest moment instead of mid-word, and never drops the words on either side
//! of a forced split. It is the transcript a summary should read, and it can be run again
//! whenever a better model is installed, which is the reason the audio is kept at all.

use super::{echo, Recognizer, SOURCES};
use crate::audio::{self, SAMPLE_RATE_F};
use crate::notes::{NotesStore, TranscriptSegment};
use crate::text::TextCleaner;
use crate::wav;
use std::path::Path;

/// A stretch of speech, in samples at 16 kHz, `end` exclusive.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Region {
    pub start: usize,
    pub end: usize,
}

/// Tunables, in seconds.
#[derive(Clone, Copy, Debug)]
pub struct Params {
    pub frame_seconds: f64,
    /// Both engines decode long clips in pieces past this (whisper.cpp at 28 s), so a region
    /// never exceeds it and the engine sees each region whole.
    pub max_region_seconds: f64,
    /// Two stretches of speech this close together are transcribed as one, for context.
    pub merge_gap_seconds: f64,
    /// Quiet inside a stretch that does not end it.
    pub close_gap_seconds: f64,
    pub pad_seconds: f64,
    /// Anything with less speech than this is a click or a cough, not a segment.
    pub min_speech_seconds: f64,
    /// Absolute floor for the speech threshold (RMS), the same as the live path's.
    pub minimum_threshold: f32,
}

impl Default for Params {
    fn default() -> Self {
        Params {
            frame_seconds: 0.1,
            max_region_seconds: 28.0,
            merge_gap_seconds: 2.0,
            close_gap_seconds: 0.8,
            pad_seconds: 0.3,
            min_speech_seconds: 0.4,
            minimum_threshold: 0.006,
        }
    }
}

fn frame_samples(frame_seconds: f64) -> usize {
    ((frame_seconds * SAMPLE_RATE_F) as usize).max(1)
}

/// Speech regions from the per-frame RMS levels of one track. The noise floor is the 10th
/// percentile of all frames, so an hour of hold music or fan noise lifts it and digital silence
/// does not drag it to zero. Speech is anything above max(0.006, 3 × floor).
pub fn regions(levels: &[f32], total_samples: usize, p: &Params) -> Vec<Region> {
    if levels.is_empty() || total_samples == 0 {
        return vec![];
    }
    let fs = frame_samples(p.frame_seconds) as i64;
    let mut sorted = levels.to_vec();
    sorted.sort_by(f32::total_cmp);
    // max and min rather than clamp: a NaN level from a broken device still gives a floor.
    #[allow(clippy::manual_clamp)]
    let floor = sorted[sorted.len() / 10].max(0.0005).min(0.05);
    let threshold = p.minimum_threshold.max(floor * 3.0);
    // Rounded, not truncated: 0.3 / 0.1 is 2.9999999999999996 in floating point.
    let frames = |seconds: f64| (seconds / p.frame_seconds).round() as i64;
    let close_gap = frames(p.close_gap_seconds).max(1);
    let merge_gap = frames(p.merge_gap_seconds).max(1);
    let max_len = frames(p.max_region_seconds).max(2);
    let pad = frames(p.pad_seconds);
    let min_speech = frames(p.min_speech_seconds).max(1);
    let total_frames = levels.len() as i64;

    // Runs of speech frames, a run tolerating up to `close_gap` quiet frames inside it.
    let mut runs: Vec<(i64, i64, i64)> = vec![];
    let mut open: Option<(i64, i64, i64)> = None;
    for (i, &level) in levels.iter().enumerate() {
        let i = i as i64;
        let speaking = level > threshold;
        match open {
            Some((start, last, speech)) => {
                if speaking {
                    open = Some((start, i, speech + 1));
                } else if i - last > close_gap {
                    runs.push((start, last + 1, speech));
                    open = None;
                }
            }
            None if speaking => open = Some((i, i, 1)),
            None => {}
        }
    }
    if let Some((start, last, speech)) = open {
        runs.push((start, last + 1, speech));
    }
    runs.retain(|r| r.2 >= min_speech);

    // Neighbours close together become one region, for context, while it stays short.
    let mut merged: Vec<(i64, i64)> = vec![];
    for r in runs {
        if let Some(last) = merged.last_mut() {
            if r.0 - last.1 <= merge_gap && r.1 - last.0 <= max_len {
                last.1 = r.1;
                continue;
            }
        }
        merged.push((r.0, r.1));
    }

    // Pad both sides, then split anything long at its quietest frame in the second half.
    let mut out = vec![];
    for (i, m) in merged.iter().enumerate() {
        let mut start = (m.0 - pad).max(0);
        let end = (m.1 + pad).min(total_frames);
        if i > 0 {
            start = start.max(merged[i - 1].1);
        }
        let mut pieces = vec![];
        let mut s = start;
        while end - s > max_len {
            let mut cut = s + max_len;
            let mut quietest = f32::MAX;
            for f in (s + max_len / 2)..(s + max_len) {
                if levels[f as usize] < quietest {
                    quietest = levels[f as usize];
                    cut = f;
                }
            }
            pieces.push((s, cut));
            s = cut;
        }
        pieces.push((s, end));
        for (a, b) in pieces {
            if b > a {
                out.push(Region { start: (a * fs) as usize, end: ((b * fs) as usize).min(total_samples) });
            }
        }
    }
    out.retain(|r| r.end > r.start);
    out
}

/// RMS per frame over a whole track, read in 30 s blocks so an hour of audio never sits in
/// memory at once.
pub fn levels(read: &mut dyn FnMut(usize, usize) -> Vec<f32>, total_samples: usize, frame_seconds: f64) -> Vec<f32> {
    let fs = frame_samples(frame_seconds);
    let block = fs * 300;
    let mut out = Vec::with_capacity(total_samples / fs + 1);
    let mut pos = 0;
    while pos < total_samples {
        let n = block.min(total_samples - pos);
        let samples = read(pos, n);
        let mut i = 0;
        while i + fs <= samples.len() {
            out.push(audio::rms(&samples[i..i + fs]));
            i += fs;
        }
        if i < samples.len() && samples.len() - i >= fs / 2 {
            out.push(audio::rms(&samples[i..]));
        }
        pos += n;
    }
    out
}

/// One saved track. Our own files are 16 kHz mono 16-bit and are read from disk in pieces;
/// anything else is decoded whole first. `cleaner` should have spoken commands off: "question
/// mark" in a meeting is a phrase, not a command.
pub fn transcribe_track(
    path: &Path,
    speaker: &str,
    rec: &mut dyn Recognizer,
    cleaner: &TextCleaner,
    progress: &mut dyn FnMut(&str),
) -> Result<Vec<TranscriptSegment>, String> {
    let info = wav::info(path).filter(|i| i.sample_rate == audio::SAMPLE_RATE && i.channels == 1 && i.bits == 16);
    let whole = if info.is_none() { audio::load_samples(path)? } else { vec![] };
    let total = match &info {
        Some(i) => (i.data_bytes.min(i.file_size.saturating_sub(i.data_offset)) / 2) as usize,
        None => whole.len(),
    };
    let mut read = |start: usize, count: usize| -> Vec<f32> {
        match &info {
            Some(i) => wav::read_pcm16_range(path, i, start as u64, count).unwrap_or_default(),
            None => whole[start.min(whole.len())..(start + count).min(whole.len())].to_vec(),
        }
    };
    let p = Params::default();
    let lv = levels(&mut read, total, p.frame_seconds);
    let found = regions(&lv, total, &p);
    let mut segments = vec![];
    for (i, r) in found.iter().enumerate() {
        progress(&format!("{speaker} {}/{}", i + 1, found.len()));
        let samples = read(r.start, r.end - r.start);
        if audio::peak(&samples) <= 0.01 {
            continue;
        }
        let text = cleaner.clean(&rec.recognize(&samples)?);
        if text.is_empty() {
            continue;
        }
        segments.push(TranscriptSegment::new(r.start as f64 / SAMPLE_RATE_F, r.end as f64 / SAMPLE_RATE_F, speaker, &text));
    }
    Ok(segments)
}

/// Every saved track of a note, merged in time order, with the microphone's echo of the other
/// side dropped. Fails if the note has no audio.
pub fn transcribe_note(
    store: &NotesStore,
    id: &str,
    rec: &mut dyn Recognizer,
    cleaner: &TextCleaner,
    progress: &mut dyn FnMut(&str),
) -> Result<Vec<TranscriptSegment>, String> {
    let mut all = vec![];
    let mut found = false;
    for (file, speaker) in SOURCES {
        let path = store.audio_path(id, file);
        if !path.exists() {
            continue;
        }
        found = true;
        let _ = wav::repair_header(&path);
        all.extend(transcribe_track(&path, speaker, rec, cleaner, progress)?);
    }
    if !found {
        return Err("This meeting has no saved audio to transcribe.".into());
    }
    all.sort_by(|a, b| a.start.total_cmp(&b.start));
    Ok(echo::drop_echo(&all, echo::SLACK_SECONDS, echo::SHARE))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn levels_of(pattern: &[(f32, usize)]) -> Vec<f32> {
        pattern.iter().flat_map(|&(level, n)| std::iter::repeat_n(level, n)).collect()
    }

    #[test]
    fn finds_speech_pads_it_and_merges_close_neighbours() {
        // 2 s quiet, 3 s speech, 1 s quiet, 2 s speech, 10 s quiet.
        let lv = levels_of(&[(0.001, 20), (0.1, 30), (0.001, 10), (0.1, 20), (0.001, 100)]);
        let total = lv.len() * 1600;
        let r = regions(&lv, total, &Params::default());
        assert_eq!(r, vec![Region { start: 17 * 1600, end: 83 * 1600 }]);
    }

    #[test]
    fn a_cough_is_not_speech() {
        let lv = levels_of(&[(0.001, 50), (0.1, 3), (0.001, 50)]);
        assert!(regions(&lv, lv.len() * 1600, &Params::default()).is_empty());
    }

    #[test]
    fn long_speech_is_cut_at_its_quietest_frame() {
        let mut lv = levels_of(&[(0.001, 100), (0.1, 400), (0.001, 50)]);
        lv[300] = 0.02;
        let r = regions(&lv, lv.len() * 1600, &Params::default());
        assert_eq!(r, vec![Region { start: 97 * 1600, end: 300 * 1600 }, Region { start: 300 * 1600, end: 503 * 1600 }]);
    }

    #[test]
    fn levels_read_in_blocks_match_one_read() {
        let samples: Vec<f32> = (0..1_000_000).map(|i| ((i as f32) * 0.001).sin() * 0.2).collect();
        let mut read = |s: usize, n: usize| samples[s..s + n].to_vec();
        let lv = levels(&mut read, samples.len(), 0.1);
        assert_eq!(lv.len(), 625);
        assert_eq!(lv[3], audio::rms(&samples[4800..6400]));
    }
}
