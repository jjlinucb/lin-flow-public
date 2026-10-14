//! Cuts a continuous 16 kHz stream into pieces for the live transcript as people speak. A piece
//! opens when the level rises above an adaptive noise floor and closes after 0.8 s of quiet, or
//! at 10 s, cut at the quietest recent moment. The caller runs each piece through the engine and
//! the cleaner off the audio thread; this half has no clock, no thread and no engine, so a test
//! can feed it any stream.

use crate::audio::{self, SAMPLE_RATE_F};

/// A piece ready for the engine: its samples and where it starts in the stream.
#[derive(Clone, Debug, PartialEq)]
pub struct Cut {
    pub samples: Vec<f32>,
    pub start_sample: usize,
}

impl Cut {
    /// Seconds from the start of the note, given what the note had recorded before this stream.
    pub fn span(&self, time_offset: f64) -> (f64, f64) {
        let start = time_offset + self.start_sample as f64 / SAMPLE_RATE_F;
        (start, start + self.samples.len() as f64 / SAMPLE_RATE_F)
    }
}

pub struct LiveSegmenter {
    pub silence_to_close: f64,
    pub minimum_segment: f64,
    /// Someone on a call who does not pause is the normal case, not the edge case, and this is
    /// how long their words wait before anything appears. 20 s read as "nothing is being added"
    /// during a real Teams meeting on 2026-09-17; 10 s is still inside Parakeet's sweet spot and
    /// costs about 0.3 s of inference per cut.
    pub maximum_segment: f64,
    pub pre_padding: f64,
    /// Absolute floor for the speech threshold (RMS). Quiet rooms sit around 0.002.
    pub minimum_threshold: f32,
    /// Seconds of recent chunk levels the noise floor is estimated from.
    pub noise_window: f64,

    buffer: Vec<f32>,
    pre_buffer: Vec<f32>,
    buffer_start_sample: usize,
    samples_seen: usize,
    in_speech: bool,
    silent_samples: usize,
    noise_floor: f32,
    recent_levels: std::collections::VecDeque<(usize, f32)>,
    /// Where to split a piece that runs long: the quietest chunk of its last seconds.
    quiet_cut: Option<(usize, f32)>,
    /// The open piece is what was left after a forced split: emit it however short.
    after_forced_split: bool,
    last_level: f32,
}

impl Default for LiveSegmenter {
    fn default() -> Self {
        LiveSegmenter {
            silence_to_close: 0.8,
            minimum_segment: 0.8,
            maximum_segment: 10.0,
            pre_padding: 0.3,
            minimum_threshold: 0.006,
            noise_window: 5.0,
            buffer: vec![],
            pre_buffer: vec![],
            buffer_start_sample: 0,
            samples_seen: 0,
            in_speech: false,
            silent_samples: 0,
            noise_floor: 0.004,
            recent_levels: Default::default(),
            quiet_cut: None,
            after_forced_split: false,
            last_level: 0.0,
        }
    }
}

impl LiveSegmenter {
    pub fn new() -> Self {
        Self::default()
    }

    /// The level of the last chunk and the threshold it was judged against: what the window
    /// shows as live proof that a side is being heard.
    pub fn meter(&self) -> (f32, f32) {
        (self.last_level, self.minimum_threshold.max(self.noise_floor * 3.0))
    }

    pub fn in_speech(&self) -> bool {
        self.in_speech
    }

    /// Feeds one chunk, in order. Returns a piece when one closed.
    pub fn feed(&mut self, chunk: &[f32]) -> Option<Cut> {
        let level = audio::rms(chunk);
        self.last_level = level;
        self.samples_seen += chunk.len();
        self.update_noise_floor(level);
        let threshold = self.minimum_threshold.max(self.noise_floor * 3.0);
        let speaking = level > threshold;

        if !self.in_speech {
            self.pre_buffer.extend_from_slice(chunk);
            let keep = (self.pre_padding * SAMPLE_RATE_F) as usize;
            if self.pre_buffer.len() > keep {
                self.pre_buffer.drain(..self.pre_buffer.len() - keep);
            }
            if speaking {
                self.in_speech = true;
                self.buffer = std::mem::take(&mut self.pre_buffer);
                self.buffer_start_sample = self.samples_seen - self.buffer.len();
                self.silent_samples = 0;
                self.quiet_cut = None;
                self.after_forced_split = false;
            }
            return None;
        }

        self.buffer.extend_from_slice(chunk);
        self.silent_samples = if speaking { 0 } else { self.silent_samples + chunk.len() };
        let duration = self.buffer.len() as f64 / SAMPLE_RATE_F;
        // Once a piece runs long, remember its quietest recent chunk so a forced split lands
        // between words instead of through one.
        if duration >= self.maximum_segment - 4.0 {
            let offset = self.buffer.len() - chunk.len();
            if self.quiet_cut.is_none_or(|q| level < q.1) {
                self.quiet_cut = Some((offset, level));
            }
        }
        let silence = self.silent_samples as f64 / SAMPLE_RATE_F;
        let spoken = duration - silence;
        if silence >= self.silence_to_close {
            let mut out = None;
            if spoken >= self.minimum_segment || self.after_forced_split {
                let mut samples = std::mem::take(&mut self.buffer);
                let keep_silence = (0.25 * SAMPLE_RATE_F) as usize;
                let drop = self.silent_samples.saturating_sub(keep_silence);
                if drop < samples.len() {
                    samples.truncate(samples.len() - drop);
                }
                out = emit(samples, self.buffer_start_sample);
            }
            self.in_speech = false;
            self.buffer.clear();
            self.quiet_cut = None;
            self.after_forced_split = false;
            out
        } else if duration >= self.maximum_segment {
            // Still talking: cut at the quiet point, no overlap, so no word is transcribed twice.
            let cut = self.quiet_cut.map_or(self.buffer.len(), |q| q.0);
            let tail = self.buffer.split_off(cut);
            let head = std::mem::replace(&mut self.buffer, tail);
            let out = emit(head, self.buffer_start_sample);
            self.buffer_start_sample += cut;
            self.silent_samples = self.silent_samples.min(self.buffer.len());
            self.quiet_cut = None;
            self.after_forced_split = true;
            out
        } else {
            None
        }
    }

    /// Closes whatever is open. Call when the recording stops.
    pub fn finish(&mut self) -> Option<Cut> {
        let out = if self.in_speech { emit(std::mem::take(&mut self.buffer), self.buffer_start_sample) } else { None };
        self.in_speech = false;
        self.buffer.clear();
        out
    }

    /// The floor is the quietest chunk of the last few seconds: it drops at once and rises
    /// slowly, so a fan or hold music that starts mid-meeting lifts the threshold within
    /// seconds, while continuous speech, which always has dips, cannot drag it up.
    fn update_noise_floor(&mut self, level: f32) {
        self.recent_levels.push_back((self.samples_seen, level));
        let horizon = self.samples_seen as i64 - (self.noise_window * SAMPLE_RATE_F) as i64;
        while self.recent_levels.front().is_some_and(|f| (f.0 as i64) < horizon) {
            self.recent_levels.pop_front();
        }
        let target = self.recent_levels.iter().map(|l| l.1).fold(None, |m: Option<f32>, l| Some(m.map_or(l, |m| m.min(l)))).unwrap_or(level);
        // Clamped from below and raised additively as well, so digital silence (an idle system
        // audio tap) does not drive the floor to zero where a multiplicative rise never recovers.
        if target < self.noise_floor {
            self.noise_floor = (self.noise_floor * 0.7 + target * 0.3).max(0.0005);
        } else {
            self.noise_floor = target.min((self.noise_floor * 1.04).max(self.noise_floor + 0.0005)).min(0.05);
        }
    }
}

fn emit(samples: Vec<f32>, start_sample: usize) -> Option<Cut> {
    if samples.is_empty() || audio::peak(&samples) <= 0.01 {
        return None;
    }
    Some(Cut { samples, start_sample })
}

#[cfg(test)]
mod tests {
    use super::*;

    const QUIET: f32 = 0.001;
    const SPEECH: f32 = 0.2;
    /// A breath between words: real speech always dips, which keeps the floor down.
    const BREATH: f32 = 0.04;

    /// 100 ms chunks of a tone at each amplitude.
    fn stream(pattern: &[(f32, usize)]) -> Vec<Vec<f32>> {
        let mut out = vec![];
        let mut t = 0usize;
        for &(amp, chunks) in pattern {
            for _ in 0..chunks {
                out.push((0..1600).map(|i| amp * (((t + i) as f32) * 0.05).sin()).collect());
                t += 1600;
            }
        }
        out
    }

    #[test]
    fn a_sentence_and_a_pause_make_one_piece() {
        let mut seg = LiveSegmenter::new();
        let cuts: Vec<Cut> = stream(&[(QUIET, 10), (SPEECH, 20), (QUIET, 10)]).iter().filter_map(|c| seg.feed(c)).collect();
        assert_eq!(cuts.len(), 1);
        let (start, end) = cuts[0].span(0.0);
        // The chunk that opens the piece is the last of the 0.3 s kept before it.
        assert!((start - 0.8).abs() < 1e-9, "starts 0.2 s before the speech: {start}");
        assert!((end - 3.25).abs() < 0.11, "keeps a quarter second of the pause: {end}");
        assert!(seg.finish().is_none());
    }

    #[test]
    fn nonstop_talk_is_cut_at_ten_seconds_without_losing_a_sample() {
        let mut seg = LiveSegmenter::new();
        let talk: Vec<(f32, usize)> = std::iter::once((QUIET, 5)).chain((0..25).flat_map(|_| [(SPEECH, 9), (BREATH, 1)])).collect();
        let chunks = stream(&talk);
        let mut cuts: Vec<Cut> = chunks.iter().filter_map(|c| seg.feed(c)).collect();
        cuts.extend(seg.finish());
        // The quietest chunk of a piece's last four seconds is its first breath after six.
        assert_eq!(cuts.len(), 4);
        for pair in cuts.windows(2) {
            assert_eq!(pair[0].start_sample + pair[0].samples.len(), pair[1].start_sample, "back to back, no gap, no overlap");
        }
        assert!(cuts.iter().all(|c| c.samples.len() as f64 / SAMPLE_RATE_F <= 10.0 + 1e-9));
        assert!(cuts[1..].iter().all(|c| c.start_sample % 16_000 == 6_400), "each cut lands on a breath");
        assert_eq!(cuts.last().unwrap().start_sample + cuts.last().unwrap().samples.len(), 255 * 1600);
    }

    #[test]
    fn a_click_is_not_a_piece() {
        let mut seg = LiveSegmenter::new();
        let cuts: Vec<Cut> = stream(&[(QUIET, 10), (SPEECH, 2), (QUIET, 20)]).iter().filter_map(|c| seg.feed(c)).collect();
        assert!(cuts.is_empty());
    }
}
