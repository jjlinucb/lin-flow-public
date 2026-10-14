//! 16 kHz mono float samples, which is what both engines take, and the measurements made on
//! them: level, peak, a dead microphone, a rough signal-to-noise estimate, and where to cut a
//! long clip. Resampling is a band-limited sinc on both computers; the Windows app's linear
//! interpolation aliased a 48 kHz microphone into the speech band.

use rubato::{FftFixedIn, Resampler};
use std::path::Path;

pub const SAMPLE_RATE: u32 = 16_000;
pub const SAMPLE_RATE_F: f64 = 16_000.0;

/// Root-mean-square level, 0 to about 1. The silence gate and the pill's meter.
pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let acc: f32 = samples.iter().map(|s| s * s).sum();
    (acc / samples.len() as f32).sqrt()
}

pub fn peak(samples: &[f32]) -> f32 {
    samples.iter().fold(0.0f32, |m, s| m.max(s.abs()))
}

/// A dead input sends digital zeros. A quiet room never does, and a short tap is not a take.
pub fn is_dead_microphone(samples: &[f32]) -> bool {
    samples.len() >= (0.5 * SAMPLE_RATE_F) as usize && peak(samples) < 0.0001
}

/// A rough signal-to-noise estimate with no reference: the 10th percentile of 20 ms frame
/// levels is the floor, the 90th the speech. It tracks true SNR but reads high, and cannot tell
/// loud babble from someone talking without pausing, so it is for the log and a human reader.
pub fn snr_estimate(samples: &[f32], frame_ms: usize) -> (f64, f64) {
    let n = (SAMPLE_RATE as usize * frame_ms / 1000).max(1);
    if samples.len() < n * 8 {
        return (99.0, 0.0);
    }
    let mut levels: Vec<f64> = samples
        .chunks_exact(n)
        .map(|c| (c.iter().map(|&s| s as f64 * s as f64).sum::<f64>() / n as f64).sqrt())
        .collect();
    levels.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let pct = |p: f64| levels[((p * levels.len() as f64) as usize).min(levels.len() - 1)];
    let (floor, speech) = (pct(0.10), pct(0.90));
    if floor <= 1e-6 || speech <= floor {
        return (99.0, floor);
    }
    (20.0 * (speech / floor).log10(), floor)
}

/// Interleaved frames of `channels` channels, averaged to one.
pub fn mono_mix_interleaved(data: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return data.to_vec();
    }
    let scale = 1.0 / channels as f32;
    data.chunks_exact(channels).map(|f| f.iter().sum::<f32>() * scale).collect()
}

/// One buffer per channel, averaged to one, over the frames every buffer has. The layout comes
/// from the buffers themselves: on 2026-09-17 the Mac's system audio tap advertised one layout
/// and delivered the other, and trusting the advertised one cost every meeting half its audio.
pub fn mono_mix_planar(channels: &[&[f32]]) -> Vec<f32> {
    let Some(frames) = channels.iter().map(|c| c.len()).min() else { return vec![] };
    if frames == 0 {
        return vec![];
    }
    let mut out = vec![0.0f32; frames];
    for c in channels {
        for (o, s) in out.iter_mut().zip(c.iter()) {
            *o += s;
        }
    }
    let scale = 1.0 / channels.len() as f32;
    out.iter_mut().for_each(|o| *o *= scale);
    out
}

/// Cuts audio longer than `limit_seconds` into pieces, each ending at the quietest 200 ms found
/// between `search_from_seconds` and the limit, so no piece splits a word if it can be helped.
/// whisper.cpp drops speech that straddles its 30 s window and libparakeet drops sentences after
/// a pause past 60 s, so both engines decode long clips this way.
pub fn split_long(samples: &[f32], limit_seconds: f64, search_from_seconds: f64) -> Vec<Vec<f32>> {
    let limit = (limit_seconds * SAMPLE_RATE_F) as usize;
    if samples.len() <= limit {
        return vec![samples.to_vec()];
    }
    let mut pieces = Vec::new();
    let mut rest = samples;
    while rest.len() > limit {
        let cut = quietest_cut(rest, (search_from_seconds * SAMPLE_RATE_F) as usize, limit);
        pieces.push(rest[..cut].to_vec());
        rest = &rest[cut..];
    }
    if !rest.is_empty() {
        pieces.push(rest.to_vec());
    }
    pieces
}

/// The middle of the quietest 200 ms between two sample offsets.
pub fn quietest_cut(samples: &[f32], lo: usize, hi: usize) -> usize {
    let win = (0.2 * SAMPLE_RATE_F) as usize;
    let mut best = hi;
    let mut best_energy = f32::MAX;
    let mut i = lo;
    while i + win <= hi {
        let e: f32 = samples[i..i + win].iter().map(|s| s * s).sum();
        if e < best_energy {
            best_energy = e;
            best = i + win / 2;
        }
        i += win / 2;
    }
    best
}

/// A live stream at any rate to 16 kHz, a buffer at a time, keeping the filter's state between
/// calls so the output is the same as converting the whole stream at once. The FFT filter's
/// delay is taken off the front and its padding off the end, so N input samples give
/// N x 16000 / rate output samples, as the Mac's converter does.
pub struct StreamingResampler {
    inner: Option<FftFixedIn<f32>>,
    pending: Vec<f32>,
    chunk: usize,
    ratio: f64,
    to_skip: usize,
    fed: u64,
    emitted: u64,
}

impl StreamingResampler {
    pub fn new(source_rate: u32) -> StreamingResampler {
        let chunk = 1024;
        let inner = if source_rate == SAMPLE_RATE || source_rate == 0 {
            None
        } else {
            FftFixedIn::<f32>::new(source_rate as usize, SAMPLE_RATE as usize, chunk, 2, 1).ok()
        };
        let to_skip = inner.as_ref().map_or(0, |r| r.output_delay());
        StreamingResampler { inner, pending: Vec::new(), chunk, ratio: SAMPLE_RATE_F / source_rate.max(1) as f64, to_skip, fed: 0, emitted: 0 }
    }

    fn take(&mut self, mut block: Vec<f32>) -> Vec<f32> {
        if self.to_skip > 0 {
            let n = self.to_skip.min(block.len());
            block.drain(..n);
            self.to_skip -= n;
        }
        self.emitted += block.len() as u64;
        block
    }

    pub fn feed(&mut self, input: &[f32]) -> Vec<f32> {
        self.fed += input.len() as u64;
        if self.inner.is_none() {
            self.emitted += input.len() as u64;
            return input.to_vec();
        }
        self.pending.extend_from_slice(input);
        let mut out = Vec::new();
        while self.pending.len() >= self.chunk {
            let block: Vec<f32> = self.pending.drain(..self.chunk).collect();
            let produced = self.inner.as_mut().unwrap().process(&[block], None).map(|mut o| o.remove(0)).unwrap_or_default();
            out.extend(self.take(produced));
        }
        out
    }

    /// Whatever is still buffered, at the end of a take, cut to the exact length.
    pub fn finish(&mut self) -> Vec<f32> {
        if self.inner.is_none() {
            return vec![];
        }
        let want = (self.fed as f64 * self.ratio).round() as u64;
        let mut out = Vec::new();
        let rest = std::mem::take(&mut self.pending);
        if !rest.is_empty() {
            let produced = self.inner.as_mut().unwrap().process_partial(Some(&[rest]), None).map(|mut o| o.remove(0)).unwrap_or_default();
            out.extend(self.take(produced));
        }
        // Flush the filter's tail until the output reaches its length.
        let mut guard = 0;
        while self.emitted < want && guard < 8 {
            let produced = self.inner.as_mut().unwrap().process_partial::<Vec<f32>>(None, None).map(|mut o| o.remove(0)).unwrap_or_default();
            if produced.is_empty() {
                break;
            }
            out.extend(self.take(produced));
            guard += 1;
        }
        if self.emitted > want {
            let extra = (self.emitted - want) as usize;
            out.truncate(out.len().saturating_sub(extra));
            self.emitted = want;
        }
        out
    }
}

/// Any whole clip at `rate` to 16 kHz.
pub fn resample(samples: &[f32], rate: u32) -> Vec<f32> {
    let mut r = StreamingResampler::new(rate);
    let mut out = r.feed(samples);
    out.extend(r.finish());
    out
}

/// Decodes a WAV, MP3, M4A, FLAC or Ogg file to 16 kHz mono.
pub fn load_samples(path: &Path) -> Result<Vec<f32>, String> {
    use symphonia::core::audio::SampleBuffer;
    use symphonia::core::codecs::DecoderOptions;
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    let file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let mut format = probed.format;
    let track = format.default_track().ok_or("no audio track")?.clone();
    let mut decoder = symphonia::default::get_codecs().make(&track.codec_params, &DecoderOptions::default()).map_err(|e| e.to_string())?;
    let rate = track.codec_params.sample_rate.ok_or("no sample rate")?;
    let mut mono = Vec::new();
    while let Ok(packet) = format.next_packet() {
        if packet.track_id() != track.id {
            continue;
        }
        let Ok(decoded) = decoder.decode(&packet) else { continue };
        let channels = decoded.spec().channels.count();
        let mut buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, *decoded.spec());
        buf.copy_interleaved_ref(decoded);
        mono.extend(mono_mix_interleaved(buf.samples(), channels));
    }
    Ok(if rate == SAMPLE_RATE { mono } else { resample(&mono, rate) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn levels_and_dead_microphone() {
        let second = SAMPLE_RATE as usize;
        assert!(is_dead_microphone(&vec![0.0; second * 3]));
        assert!(!is_dead_microphone(&vec![0.0; second / 4]), "a quarter second is only a tap");
        let room: Vec<f32> = (0..second).map(|i| if i % 2 == 0 { 0.0009 } else { -0.0009 }).collect();
        assert!(!is_dead_microphone(&room), "a silent room's noise is not a dead microphone");
        assert_eq!(rms(&[0.0, 0.0]), 0.0);
        assert!((rms(&[0.5, -0.5]) - 0.5).abs() < 1e-6);
        assert_eq!(peak(&[0.1, -0.7, 0.3]), 0.7);
    }

    #[test]
    fn mono_mix_reads_either_layout() {
        let left = [0.2, 0.4, 0.6, 0.8];
        let right = [0.0, 0.0, 0.2, 0.0];
        let planar = mono_mix_planar(&[&left, &right]);
        let interleaved = mono_mix_interleaved(&[0.2, 0.0, 0.4, 0.0, 0.6, 0.2, 0.8, 0.0], 2);
        assert_eq!(planar.len(), 4);
        assert!((planar[2] - 0.4).abs() < 1e-6);
        assert_eq!(planar, interleaved);
    }

    #[test]
    fn long_clips_split_at_a_quiet_spot() {
        let sr = SAMPLE_RATE as usize;
        let mut s = vec![0.5f32; sr * 50];
        for x in &mut s[sr * 30..sr * 30 + sr / 2] {
            *x = 0.0;
        }
        let pieces = split_long(&s, 45.0, 20.0);
        assert_eq!(pieces.len(), 2);
        let cut = pieces[0].len() as f64 / SAMPLE_RATE_F;
        assert!((30.0..30.5).contains(&cut), "{cut}");
        assert_eq!(pieces.iter().map(Vec::len).sum::<usize>(), s.len());
    }

    #[test]
    fn resampling_keeps_length_and_pitch() {
        // One second of a 440 Hz tone at 48 kHz becomes one second at 16 kHz.
        let tone: Vec<f32> = (0..48_000).map(|i| (i as f32 * 440.0 * 2.0 * std::f32::consts::PI / 48_000.0).sin() * 0.5).collect();
        let mut r = StreamingResampler::new(48_000);
        let mut out = Vec::new();
        for chunk in tone.chunks(480) {
            out.extend(r.feed(chunk));
        }
        out.extend(r.finish());
        assert_eq!(out.len(), 16_000);
        // Zero crossings: 880 per second for 440 Hz.
        let crossings = out.windows(2).filter(|w| w[0] <= 0.0 && w[1] > 0.0).count();
        assert!((430..=450).contains(&crossings), "{crossings}");
    }
}

/// How fast a capture really delivers audio, against the clock, as `RateWatch.swift` does. On
/// 2026-10-06 a Teams call on AirPods came through the system tap at half the 48 kHz the tap
/// reported, so the other side was garbage. Returns a new rate once two three-second windows in
/// a row agree on a standard rate more than 15% from the one in use. A window with a pause longer
/// than a quarter second is thrown away, so a stall never reads as a slow rate.
pub struct RateWatch {
    pub rate: f64,
    start: Option<f64>,
    last: f64,
    frames: usize,
    candidate: Option<f64>,
}

impl RateWatch {
    const WINDOW: f64 = 3.0;
    const MAX_PAUSE: f64 = 0.25;
    const RATES: [f64; 10] = [8000.0, 11025.0, 16000.0, 22050.0, 24000.0, 32000.0, 44100.0, 48000.0, 88200.0, 96000.0];

    pub fn new(rate: f64) -> RateWatch {
        RateWatch { rate, start: None, last: 0.0, frames: 0, candidate: None }
    }

    pub fn add(&mut self, frames: usize, at: f64) -> Option<f64> {
        let Some(start) = self.start.filter(|_| at - self.last <= Self::MAX_PAUSE && at >= self.last) else {
            self.start = Some(at);
            self.last = at;
            self.frames = 0;
            return None;
        };
        self.last = at;
        self.frames += frames;
        if at - start < Self::WINDOW {
            return None;
        }
        let measured = self.frames as f64 / (at - start);
        self.start = Some(at);
        self.frames = 0;
        let snapped = Self::RATES.into_iter().min_by(|a, b| (a - measured).abs().total_cmp(&(b - measured).abs()))?;
        if (snapped - measured).abs() / snapped >= 0.1 || (snapped - self.rate).abs() / self.rate <= 0.15 {
            self.candidate = None;
            return None;
        }
        if self.candidate == Some(snapped) {
            self.candidate = None;
            self.rate = snapped;
            return Some(snapped);
        }
        self.candidate = Some(snapped);
        None
    }
}

#[cfg(test)]
mod rate_tests {
    use super::RateWatch;

    fn feed(w: &mut RateWatch, rate: f64, seconds: f64, from: f64, pause_at: Option<f64>) -> Vec<f64> {
        let mut got = vec![];
        let mut t = from;
        while t < from + seconds {
            t += 0.01;
            if pause_at.is_some_and(|p| t > p && t < p + 1.0) {
                continue;
            }
            if let Some(r) = w.add((rate / 100.0) as usize, t) {
                got.push(r);
            }
        }
        got
    }

    #[test]
    fn finds_the_rate_that_really_arrives() {
        let mut half = RateWatch::new(48000.0);
        assert_eq!(feed(&mut half, 24000.0, 10.0, 0.0, None), vec![24000.0]);
        assert!(feed(&mut RateWatch::new(48000.0), 48000.0, 20.0, 0.0, None).is_empty());
        assert!(feed(&mut RateWatch::new(48000.0), 48000.0, 20.0, 0.0, Some(5.0)).is_empty(), "a stall is not a slow rate");
        assert!(feed(&mut RateWatch::new(48000.0), 47000.0, 20.0, 0.0, None).is_empty(), "drift is not a new rate");
        assert_eq!(feed(&mut half, 48000.0, 10.0, 10.0, None), vec![48000.0], "back when the call ends");
    }
}
