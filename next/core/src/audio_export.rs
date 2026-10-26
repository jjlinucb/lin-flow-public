//! A meeting's recording as one file to keep or send: both sides leveled, mixed and encoded. A
//! port of the Swift `AudioExport`, which Save Audio used until the cut-over to Next.
//!
//! The two WAVs share one clock (the recorder pads whatever a track falls short), so sample n of
//! each is the same moment and the mix is a sum. Each side is first brought to one speech level.
//! In five of John's notes, measured 2026-10-07 as the 95th percentile of 20 ms frame levels, his
//! own side sat 4 to 7 dB under the call's, quiet enough to strain at in a plain mix. A soft
//! limiter then keeps the sum under full scale where both talk at once.
//!
//! MP3 is Homebrew's `lame` (or one on the PATH), fed raw samples on its standard input, so LAME
//! stays a separate program rather than linked in. Without it the mix is saved as a WAV, which
//! plays anywhere but is about four times the size.

use crate::wav;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

/// The speech level each side is brought to, as the 95th percentile of its frame levels, and how
/// far a side may move. The call measured -12 to -18 dB, John's side -19 to -24.
pub const TARGET_LEVEL: f32 = -16.0;
pub const GAIN_MIN: f32 = -6.0;
pub const GAIN_MAX: f32 = 12.0;
/// Quieter frames are silence or the recorder's padding, and don't count toward a level.
const LIVE_FLOOR: f32 = -70.0;
const SAMPLE_RATE: u32 = 16_000;
const FRAME: usize = 320; // 20 ms
const CHUNK: usize = 160_000; // 10 s, a whole number of frames
/// Constant 64 kbit/s, which is plenty for 16 kHz speech: about 29 MB an hour. Constant, so the
/// file needs no VBR header for players to know its length.
const MP3_KBPS: u32 = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Mp3,
    Wav,
}

impl Format {
    pub fn ext(self) -> &'static str {
        match self {
            Format::Mp3 => "mp3",
            Format::Wav => "wav",
        }
    }

    /// From a file's extension, for the CLI.
    pub fn from_ext(ext: &str) -> Option<Format> {
        match ext.to_ascii_lowercase().as_str() {
            "mp3" => Some(Format::Mp3),
            "wav" => Some(Format::Wav),
            _ => None,
        }
    }
}

/// MP3 when LAME is installed, else WAV.
pub fn preferred_format() -> Format {
    if lame().is_some() {
        Format::Mp3
    } else {
        Format::Wav
    }
}

/// The `lame` program: Homebrew's first, since an app opened from the Finder or at login gets a
/// PATH without /opt/homebrew/bin, then the PATH.
pub fn lame() -> Option<PathBuf> {
    let exe = if cfg!(windows) { "lame.exe" } else { "lame" };
    let fixed = ["/opt/homebrew/bin/lame", "/usr/local/bin/lame"].map(PathBuf::from);
    let on_path: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).map(|d| d.join(exe)).collect()).unwrap_or_default();
    fixed.into_iter().chain(on_path).find(|p| p.is_file())
}

/// How a note's two tracks relate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Coupling {
    /// Headphones: each track holds its own side.
    Separate,
    /// The mic hears the call from the speakers, a moment after it plays.
    Speakers,
    /// The people are in the room. The mic hears them first and the call carries them back later.
    Room,
}

impl Coupling {
    pub fn name(self) -> &'static str {
        match self {
            Coupling::Separate => "separate",
            Coupling::Speakers => "speakers",
            Coupling::Room => "room",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Exported {
    pub seconds: f64,
    /// The gain applied to each side, in dB, keyed "mic" and "system". A side left out has none.
    pub gains: BTreeMap<String, f32>,
    pub coupling: Coupling,
    /// How far the call trails the mic, in seconds, when they match. Negative: the mic trails.
    pub delay: f64,
}

/// The level a side's speech reaches: the 95th percentile of its live frames, in dB. None for a
/// side with nothing above the floor.
pub fn speech_level(frames: &[f32]) -> Option<f32> {
    let mut live: Vec<f32> = frames.iter().copied().filter(|&l| l > LIVE_FLOOR).collect();
    if live.is_empty() {
        return None;
    }
    live.sort_by(f32::total_cmp);
    Some(live[((live.len() - 1) as f32 * 0.95) as usize])
}

/// The gain, in dB, that brings a side's speech level to the target. A silent side stays as it is.
pub fn gain_for_level(level: Option<f32>) -> f32 {
    level.map_or(0.0, |l| (TARGET_LEVEL - l).clamp(GAIN_MIN, GAIN_MAX))
}

/// Untouched below 0.75, then bent smoothly toward 0.95 and never past it. The half decibel under
/// full scale is room for the encoder, whose decoded output overshoots its input.
pub fn limit(x: f32) -> f32 {
    let (knee, ceiling) = (0.75f32, 0.95f32);
    let m = x.abs();
    if m <= knee {
        return x;
    }
    let y = knee + (ceiling - knee) * ((m - knee) / (ceiling - knee)).tanh();
    if x < 0.0 {
        -y
    } else {
        y
    }
}

/// Matches the mic's loudness against the call's, ten seconds at a time wherever the call talks,
/// at every delay up to 1.2 s either way. Measured 2026-10-08 on six notes, as the share of
/// stretches that matched (r > 0.4): 0 to 2% in headphones. 88% through the speakers, the mic
/// 0.12 s behind the call (10-02). 100% in a shared room, the call 0.52 s behind the mic (10-08).
pub fn coupling(mic: &[f32], call: &[f32]) -> (Coupling, f64) {
    let n = mic.len().min(call.len());
    let (w, reach) = (500usize, 60usize); // 20 ms frames
    let mut windows = 0;
    let mut lags: Vec<i64> = Vec::new();
    let mut start = reach;
    while start + w + reach <= n {
        let at = start;
        start += w;
        let mut loud = call[at..at + w].to_vec();
        loud.sort_by(f32::total_cmp);
        if loud[w * 9 / 10] <= -45.0 {
            continue;
        }
        windows += 1;
        let a = &mic[at..at + w];
        let ma = a.iter().sum::<f32>() / w as f32;
        let va: f32 = a.iter().map(|x| (x - ma) * (x - ma)).sum();
        if va <= 0.0 {
            continue;
        }
        let mut best = (-1f32, 0i64);
        for lag in -(reach as i64)..=reach as i64 {
            let from = (at as i64 + lag) as usize;
            let b = &call[from..from + w];
            let mb = b.iter().sum::<f32>() / w as f32;
            let (mut cov, mut vb) = (0f32, 0f32);
            for (x, y) in a.iter().zip(b) {
                cov += (x - ma) * (y - mb);
                vb += (y - mb) * (y - mb);
            }
            if vb <= 0.0 {
                continue;
            }
            let r = cov / (va * vb).sqrt();
            if r > best.0 {
                best = (r, lag);
            }
        }
        if best.0 > 0.4 {
            lags.push(best.1);
        }
    }
    if windows == 0 || lags.len() * 2 <= windows {
        return (Coupling::Separate, 0.0);
    }
    lags.sort();
    let delay = lags[lags.len() / 2] as f64 * 0.02;
    (if delay >= 0.1 { Coupling::Room } else { Coupling::Speakers }, delay)
}

/// A 20 ms frame's level, in dB.
fn frame_level(frame: &[f32]) -> f32 {
    10.0 * (frame.iter().map(|x| x * x).sum::<f32>() / frame.len() as f32 + 1e-18).log10()
}

/// One side's WAV, checked to be a note's 16 kHz mono 16-bit audio.
struct Track {
    key: String,
    path: PathBuf,
    info: wav::WavInfo,
    frames: u64,
}

impl Track {
    fn open(key: &str, path: &Path) -> Result<Track, String> {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let info = wav::info(path).ok_or_else(|| format!("{name} is not a WAV file."))?;
        if info.sample_rate != SAMPLE_RATE || info.channels != 1 || info.bits != 16 {
            return Err(format!("{name} is {} Hz with {} channels, where a note's audio is 16 kHz mono.", info.sample_rate, info.channels));
        }
        let frames = info.data_bytes.min(info.file_size.saturating_sub(info.data_offset)) / 2;
        Ok(Track { key: key.into(), path: path.into(), info, frames })
    }

    fn read(&self, start: u64, count: usize) -> Result<Vec<f32>, String> {
        if start >= self.frames {
            return Ok(vec![]);
        }
        let count = count.min((self.frames - start) as usize);
        wav::read_pcm16_range(&self.path, &self.info, start, count).map_err(|e| e.to_string())
    }

    /// Every whole 20 ms frame's level, in dB.
    fn frame_levels(&self) -> Result<Vec<f32>, String> {
        let mut levels = Vec::with_capacity((self.frames / FRAME as u64) as usize);
        let mut at = 0;
        while at < self.frames {
            let s = self.read(at, CHUNK)?;
            if s.is_empty() {
                break;
            }
            levels.extend(s.as_chunks::<FRAME>().0.iter().map(|f| frame_level(f)));
            at += s.len() as u64;
        }
        Ok(levels)
    }
}

/// Exports a note's folder: `audio-mic.wav` and `audio-system.wav`, whichever it has.
pub fn export_note(folder: &Path, title: &str, to: &Path, format: Format, progress: &mut dyn FnMut(f64)) -> Result<Exported, String> {
    let mut tracks = Vec::new();
    for source in ["mic", "system"] {
        let p = folder.join(format!("audio-{source}.wav"));
        if p.exists() {
            let _ = wav::repair_header(&p);
            tracks.push((source.to_string(), p));
        }
    }
    if tracks.is_empty() {
        return Err("This meeting has no saved audio.".into());
    }
    export(&tracks, title, to, format, progress)
}

/// Mixes 16 kHz mono tracks, keyed "mic" and "system", into one file at `to`. The file appears
/// only once it is whole; one already there stays until the new one replaces it.
pub fn export(tracks: &[(String, PathBuf)], title: &str, to: &Path, format: Format, progress: &mut dyn FnMut(f64)) -> Result<Exported, String> {
    let tracks: Vec<Track> = tracks.iter().map(|(k, p)| Track::open(k, p)).collect::<Result<_, _>>()?;
    let mut levels = BTreeMap::new();
    for t in &tracks {
        levels.insert(t.key.clone(), t.frame_levels()?);
    }
    let (link, delay) = match (levels.get("mic"), levels.get("system")) {
        (Some(mic), Some(call)) => coupling(mic, call),
        _ => (Coupling::Separate, 0.0),
    };
    let mut gains: BTreeMap<String, f32> = levels.iter().map(|(k, l)| (k.clone(), gain_for_level(speech_level(l)))).collect();
    if link == Coupling::Speakers {
        // Raising the mic would raise the call's echo in it.
        if let Some(g) = gains.get_mut("mic") {
            *g = g.min(0.0);
        }
    }
    let linear: Vec<f32> = tracks.iter().map(|t| 10f32.powf(gains[&t.key] / 20.0)).collect();
    // In a shared room the call holds the room's voices again, late. Played as recorded each voice
    // would come twice, so the call starts that much earlier, its copies under the mic's, and
    // whoever is only on the call still comes through.
    let skip: Vec<u64> = tracks.iter().map(|t| if t.key == "system" && link == Coupling::Room { (delay * SAMPLE_RATE as f64) as u64 } else { 0 }).collect();
    let total = tracks.iter().zip(&skip).map(|(t, k)| t.frames.saturating_sub(*k)).max().unwrap_or(0);
    if total == 0 {
        return Err("This meeting's audio is empty.".into());
    }

    let name = to.file_name().ok_or("No file name to save to.")?.to_string_lossy().into_owned();
    let partial = to.with_file_name(format!(".{name}.partial-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut sink = Sink::open(&partial, title, format)?;
        let mut done = 0u64;
        while done < total {
            let n = (CHUNK as u64).min(total - done) as usize;
            let mut mix = vec![0f32; n];
            for ((t, k), g) in tracks.iter().zip(&skip).zip(&linear) {
                for (m, s) in mix.iter_mut().zip(t.read(k + done, n)?) {
                    *m += s * g;
                }
            }
            for m in mix.iter_mut() {
                *m = limit(*m);
            }
            sink.write(&mix)?;
            done += n as u64;
            progress(done as f64 / total as f64);
        }
        sink.finish()?;
        std::fs::rename(&partial, to).map_err(|e| format!("Could not save {name}: {e}"))
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&partial);
    }
    result?;
    Ok(Exported { seconds: total as f64 / SAMPLE_RATE as f64, gains, coupling: link, delay })
}

enum Sink {
    /// None once finished, so a sink dropped on an error stops LAME and reaps it.
    Mp3(Option<Child>),
    Wav(wav::WavWriter),
}

impl Sink {
    fn open(path: &Path, title: &str, format: Format) -> Result<Sink, String> {
        match format {
            Format::Wav => Ok(Sink::Wav(wav::WavWriter::create(path, SAMPLE_RATE, false).map_err(|e| e.to_string())?)),
            Format::Mp3 => {
                let lame = lame().ok_or("MP3 needs LAME. Install it with: brew install lame")?;
                let mut cmd = Command::new(lame);
                cmd.args(["--quiet", "-r", "-s", "16", "--bitwidth", "16", "--signed", "--little-endian", "-m", "m"])
                    .args(["-b", &MP3_KBPS.to_string(), "--cbr", "-q", "2", "-t", "--id3v2-utf16", "--tt", title, "--ta", "Lin Flow", "-"])
                    .arg(path)
                    .stdin(Stdio::piped())
                    .stdout(Stdio::null())
                    .stderr(Stdio::piped());
                #[cfg(windows)]
                {
                    use std::os::windows::process::CommandExt;
                    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
                }
                Ok(Sink::Mp3(Some(cmd.spawn().map_err(|e| format!("LAME did not start: {e}"))?)))
            }
        }
    }

    fn write(&mut self, samples: &[f32]) -> Result<(), String> {
        match self {
            Sink::Wav(w) => w.append(samples).map_err(|e| e.to_string()),
            Sink::Mp3(child) => {
                let bytes: Vec<u8> = samples.iter().flat_map(|s| ((s.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes()).collect();
                // A write that fails means LAME stopped; `finish` reports why.
                let _ = child.as_mut().and_then(|c| c.stdin.as_mut()).map(|i| i.write_all(&bytes));
                Ok(())
            }
        }
    }

    fn finish(mut self) -> Result<(), String> {
        match &mut self {
            Sink::Wav(w) => w.close().map_err(|e| e.to_string()),
            Sink::Mp3(child) => {
                let Some(child) = child.take() else { return Ok(()) };
                let out = child.wait_with_output().map_err(|e| e.to_string())?;
                if out.status.success() {
                    Ok(())
                } else {
                    Err(format!("LAME failed ({}): {}", out.status, String::from_utf8_lossy(&out.stderr).trim()))
                }
            }
        }
    }
}

impl Drop for Sink {
    fn drop(&mut self) {
        if let Sink::Mp3(Some(child)) = self {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_limiter_leaves_ordinary_levels_alone_and_caps_the_rest() {
        assert_eq!(limit(0.5), 0.5);
        assert_eq!(limit(-0.7), -0.7);
        assert!(limit(4.0) <= 0.95 && limit(-4.0) >= -0.95);
        assert!(limit(0.9) < limit(1.2), "it stays smooth past the knee");
    }

    #[test]
    fn a_quiet_side_is_raised_to_the_calls_level_within_the_range() {
        assert_eq!(gain_for_level(Some(-19.0)), 3.0);
        assert_eq!(gain_for_level(None), 0.0);
        assert_eq!(gain_for_level(Some(-60.0)), 12.0);
        assert_eq!(gain_for_level(Some(-2.0)), -6.0);
    }

    #[test]
    fn speech_level_ignores_silence() {
        assert_eq!(speech_level(&[-90.0, -80.0, -30.0, -20.0]), Some(-30.0));
        assert_eq!(speech_level(&[-90.0]), None);
    }

    /// Frame levels that rise and fall like speech, with a seed so two sides differ.
    fn speechy(n: usize, seed: u64) -> Vec<f32> {
        let mut x = seed;
        (0..n)
            .map(|_| {
                x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                -50.0 + 35.0 * ((x >> 33) as f32 / (1u64 << 31) as f32)
            })
            .collect()
    }

    fn shifted(v: &[f32], by: usize) -> Vec<f32> {
        let mut out = vec![-90.0; by];
        out.extend_from_slice(&v[..v.len() - by]);
        out
    }

    #[test]
    fn coupling_tells_headphones_speakers_and_a_shared_room_apart() {
        let call = speechy(6000, 1);
        let (c, d) = coupling(&shifted(&call, 6).iter().map(|l| l - 15.0).collect::<Vec<_>>(), &call);
        assert_eq!(c, Coupling::Speakers, "a mic 0.12 s behind the call hears the speakers");
        assert!((d + 0.12).abs() < 1e-9);
        let (c, d) = coupling(&call, &shifted(&call, 26));
        assert_eq!(c, Coupling::Room, "the call 0.52 s behind the mic carries the room");
        assert!((d - 0.52).abs() < 1e-9);
        assert_eq!(coupling(&speechy(6000, 2), &call).0, Coupling::Separate, "headphones keep the sides apart");
    }

    #[test]
    fn file_names_follow_finder() {
        assert_eq!(crate::notes::file_name("Meeting Oct 7, 2:09 PM", "mp3"), "Meeting Oct 7, 2.09 PM.mp3");
        assert_eq!(crate::notes::file_name("Plan a/b ", "md"), "Plan a-b.md");
        assert_eq!(crate::notes::file_name("", "mp3"), "Meeting.mp3");
    }

    /// Who talks at each 20 ms frame of a two-person call: the call (1), John (2) or nobody (0),
    /// in turns of 0.4 to 2 s picked at random, so neither side's loudness follows the other's at
    /// any delay, as on headphones.
    fn turns(seconds: usize) -> Vec<u8> {
        let (mut x, mut out) = (7u64, Vec::new());
        while out.len() < seconds * 50 {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            out.extend(std::iter::repeat_n((x >> 40) as u8 % 3, 20 + (x >> 33) as usize % 80));
        }
        out.truncate(seconds * 50);
        out
    }

    /// A tone at `amp` wherever `talks` says this side has the turn.
    fn side(turns: &[u8], talks: u8, amp: f32) -> Vec<f32> {
        (0..turns.len() * FRAME).map(|i| if turns[i / FRAME] == talks { amp * (i as f32 * 0.07).sin() } else { 0.0 }).collect()
    }

    fn level_db(samples: &[f32]) -> f32 {
        let levels: Vec<f32> = samples.as_chunks::<FRAME>().0.iter().map(|f| frame_level(f)).collect();
        speech_level(&levels).unwrap()
    }

    #[test]
    fn the_mix_brings_both_sides_to_one_level() {
        let dir = std::env::temp_dir().join(format!("linflow-export-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // John's side 8 dB under the call's, taking turns so each is heard alone.
        let who = turns(30);
        let call = side(&who, 1, 0.18);
        let mic = side(&who, 2, 0.18 * 10f32.powf(-8.0 / 20.0));
        wav::write(&dir.join("audio-system.wav"), &call, SAMPLE_RATE).unwrap();
        wav::write(&dir.join("audio-mic.wav"), &mic, SAMPLE_RATE).unwrap();
        let out = dir.join("Plan.wav");
        let mut last = 0.0;
        let r = export_note(&dir, "Plan", &out, Format::Wav, &mut |p| last = p).unwrap();
        assert_eq!(last, 1.0);
        assert!((r.seconds - 30.0).abs() < 0.01);
        assert_eq!(r.coupling, Coupling::Separate);
        assert!(r.gains["mic"] - r.gains["system"] > 7.0, "the quiet side gets more gain: {:?}", r.gains);
        let mix = wav::read_pcm16(&out).unwrap();
        let pick = |talks: u8| -> Vec<f32> { mix.chunks(FRAME).zip(&who).filter(|(_, w)| **w == talks).flat_map(|(f, _)| f.iter().copied()).collect() };
        let (mine, theirs) = (pick(2), pick(1));
        assert!((level_db(&mine) - level_db(&theirs)).abs() < 1.0, "mic {} dB, call {} dB", level_db(&mine), level_db(&theirs));
        assert!((level_db(&theirs) - TARGET_LEVEL).abs() < 1.0);
        assert!(!std::fs::read_dir(&dir).unwrap().flatten().any(|e| e.file_name().to_string_lossy().contains("partial")), "no partial file is left behind");
        if lame().is_some() {
            let mp3 = dir.join("Plan é.mp3");
            export_note(&dir, "Plan é", &mp3, Format::Mp3, &mut |_| {}).unwrap();
            let decoded = crate::audio::load_samples(&mp3).unwrap();
            assert!((decoded.len() as f64 / 16_000.0 - 30.0).abs() < 0.2, "{} samples", decoded.len());
        } else {
            eprintln!("no lame: MP3 export not checked");
        }
        assert!(export_note(&dir.join("nothing"), "x", &dir.join("x.wav"), Format::Wav, &mut |_| {}).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
