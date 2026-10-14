//! A 16 kHz mono 16-bit WAV that stays readable if the process dies.
//!
//! A writer that fills in the RIFF and data sizes only on close leaves a recording cut short by a
//! crash, a force quit or a dead battery reading as 0 seconds in every player, with all of its
//! audio still in the file (verified 2026-09-17 on the Mac). This one brings the header up to
//! date about once a second, so a crash costs at most the last second, and `repair_header` fixes
//! any WAV from the file size. A port of the Swift `WAVWriter`, which the Windows app shares.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

pub struct WavWriter {
    pub path: PathBuf,
    /// Frames in the data chunk, including anything already in the file when appending.
    pub frames: u64,
    pub sample_rate: u32,
    /// How often the header is rewritten, in frames. One second by default.
    pub header_interval: u64,
    file: File,
    data_offset: u64,
    frames_at_last_header: u64,
    closed: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WavInfo {
    pub sample_rate: u32,
    pub channels: u16,
    pub bits: u16,
    /// Where the samples start.
    pub data_offset: u64,
    /// What the header claims. May be wrong after a crash; see `repair_header`.
    pub data_bytes: u64,
    pub file_size: u64,
}

impl WavInfo {
    pub fn seconds(&self) -> f64 {
        let per_second = self.channels as u64 * self.bits as u64 / 8 * self.sample_rate as u64;
        if per_second == 0 {
            0.0
        } else {
            self.data_bytes as f64 / per_second as f64
        }
    }
}

fn le32(v: u32) -> [u8; 4] {
    v.to_le_bytes()
}

fn clamp32(v: u64) -> u32 {
    v.min(u32::MAX as u64) as u32
}

pub fn header(data_bytes: u64, sample_rate: u32) -> Vec<u8> {
    let mut d = Vec::with_capacity(44);
    d.extend_from_slice(b"RIFF");
    d.extend_from_slice(&le32(clamp32(36 + data_bytes)));
    d.extend_from_slice(b"WAVE");
    d.extend_from_slice(b"fmt ");
    d.extend_from_slice(&le32(16));
    d.extend_from_slice(&1u16.to_le_bytes()); // PCM
    d.extend_from_slice(&1u16.to_le_bytes()); // mono
    d.extend_from_slice(&le32(sample_rate));
    d.extend_from_slice(&le32(sample_rate * 2));
    d.extend_from_slice(&2u16.to_le_bytes()); // block align
    d.extend_from_slice(&16u16.to_le_bytes()); // bits
    d.extend_from_slice(b"data");
    d.extend_from_slice(&le32(clamp32(data_bytes)));
    d
}

impl WavWriter {
    /// Creates the file, or with `append` continues one that already exists (repairing its
    /// header first if the last writer died). A file at the path in another format is moved
    /// aside rather than overwritten: nothing recorded is ever destroyed here.
    pub fn create(path: &Path, sample_rate: u32, append: bool) -> std::io::Result<WavWriter> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        if path.exists() {
            if append {
                let _ = repair_header(path);
                if let Some(info) = info(path) {
                    if info.sample_rate == sample_rate && info.channels == 1 && info.bits == 16 {
                        let mut file = OpenOptions::new().write(true).open(path)?;
                        file.seek(SeekFrom::Start(info.data_offset + info.data_bytes))?;
                        let frames = info.data_bytes / 2;
                        return Ok(WavWriter {
                            path: path.to_path_buf(),
                            frames,
                            sample_rate,
                            header_interval: sample_rate as u64,
                            file,
                            data_offset: info.data_offset,
                            frames_at_last_header: frames,
                            closed: false,
                        });
                    }
                }
            }
            let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
            let stem = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
            let aside = path.with_file_name(format!("{stem}.previous-{stamp}.wav"));
            fs::rename(path, &aside)?;
        }
        let mut file = OpenOptions::new().create_new(true).write(true).open(path)?;
        file.write_all(&header(0, sample_rate))?;
        Ok(WavWriter {
            path: path.to_path_buf(),
            frames: 0,
            sample_rate,
            header_interval: sample_rate as u64,
            file,
            data_offset: 44,
            frames_at_last_header: 0,
            closed: false,
        })
    }

    /// Appends samples (clipped to ±1) as 16-bit little-endian PCM, and refreshes the header
    /// once `header_interval` frames have gone by since it was last written.
    pub fn append(&mut self, samples: &[f32]) -> std::io::Result<()> {
        if samples.is_empty() {
            return Ok(());
        }
        let mut bytes = Vec::with_capacity(samples.len() * 2);
        for s in samples {
            let v = (s.clamp(-1.0, 1.0) * 32767.0).round() as i16;
            bytes.extend_from_slice(&v.to_le_bytes());
        }
        self.file.write_all(&bytes)?;
        self.frames += samples.len() as u64;
        if self.frames - self.frames_at_last_header >= self.header_interval {
            self.update_header()?;
        }
        Ok(())
    }

    /// Writes the final header. Safe to call twice.
    pub fn close(&mut self) -> std::io::Result<()> {
        if self.closed {
            return Ok(());
        }
        self.closed = true;
        self.update_header()?;
        self.file.sync_all()
    }

    pub fn seconds(&self) -> f64 {
        self.frames as f64 / self.sample_rate as f64
    }

    fn update_header(&mut self) -> std::io::Result<()> {
        let data_bytes = self.frames * 2;
        let end = self.file.stream_position()?;
        self.file.seek(SeekFrom::Start(4))?;
        self.file.write_all(&le32(clamp32(self.data_offset - 8 + data_bytes)))?;
        self.file.seek(SeekFrom::Start(self.data_offset - 4))?;
        self.file.write_all(&le32(clamp32(data_bytes)))?;
        self.file.seek(SeekFrom::Start(end))?;
        self.frames_at_last_header = self.frames;
        Ok(())
    }
}

impl Drop for WavWriter {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

/// Walks the RIFF chunks (some writers put a JUNK chunk before "fmt ") to find the format and
/// the data chunk. None if the file is not a WAV.
pub fn info(path: &Path) -> Option<WavInfo> {
    let mut f = File::open(path).ok()?;
    let size = f.metadata().ok()?.len();
    let mut head = vec![0u8; 4096];
    let n = f.read(&mut head).ok()?;
    head.truncate(n);
    if head.len() < 12 {
        return None;
    }
    let tag = |o: usize| if o + 4 <= head.len() { &head[o..o + 4] } else { &[][..] };
    let u32_at = |o: usize| if o + 4 <= head.len() { u32::from_le_bytes([head[o], head[o + 1], head[o + 2], head[o + 3]]) as u64 } else { 0 };
    let u16_at = |o: usize| if o + 2 <= head.len() { u16::from_le_bytes([head[o], head[o + 1]]) } else { 0 };
    if tag(0) != b"RIFF" || tag(8) != b"WAVE" {
        return None;
    }
    let mut o = 12usize;
    let (mut rate, mut channels, mut bits) = (0u32, 0u16, 0u16);
    while o + 8 <= head.len() {
        let id = tag(o).to_vec();
        let len = u32_at(o + 4);
        if id == b"fmt " {
            channels = u16_at(o + 10);
            rate = u32_at(o + 12) as u32;
            bits = u16_at(o + 22);
        } else if id == b"data" {
            return Some(WavInfo { sample_rate: rate, channels, bits, data_offset: o as u64 + 8, data_bytes: len, file_size: size });
        }
        o += 8 + len as usize + (len as usize & 1);
    }
    None
}

pub fn duration(path: &Path) -> Option<f64> {
    info(path).map(|i| i.seconds())
}

/// Makes the header agree with the file's size when a writer died before closing it. Returns
/// true if it changed anything. A data chunk followed by another well-formed chunk is somebody
/// else's valid file and is left alone.
pub fn repair_header(path: &Path) -> std::io::Result<bool> {
    let Some(info) = info(path) else {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, format!("{} is not a WAV file", path.display())));
    };
    if info.file_size < info.data_offset {
        return Ok(false);
    }
    let actual = info.file_size - info.data_offset;
    if info.data_bytes == actual {
        return Ok(false);
    }
    if info.data_bytes > 0 && info.data_bytes < actual {
        // Something after the data chunk: a real trailing chunk means the header is right.
        let mut f = File::open(path)?;
        f.seek(SeekFrom::Start(info.data_offset + info.data_bytes + (info.data_bytes & 1)))?;
        let mut tail = [0u8; 8];
        if f.read_exact(&mut tail).is_ok() && tail[..4].iter().all(|b| b.is_ascii_alphanumeric() || *b == b' ') {
            return Ok(false);
        }
    }
    let mut f = OpenOptions::new().write(true).open(path)?;
    f.seek(SeekFrom::Start(4))?;
    f.write_all(&le32(clamp32(info.file_size - 8)))?;
    f.seek(SeekFrom::Start(info.data_offset - 4))?;
    f.write_all(&le32(clamp32(actual)))?;
    Ok(true)
}

/// The samples of a 16-bit mono WAV as floats, read straight from its data chunk. Divided by
/// 32768 as Core Audio and the Windows app read them, though both write with 32767.
pub fn read_pcm16(path: &Path) -> std::io::Result<Vec<f32>> {
    let info = info(path).ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "not a WAV"))?;
    if info.bits != 16 || info.channels != 1 {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "not 16-bit mono"));
    }
    let mut f = File::open(path)?;
    f.seek(SeekFrom::Start(info.data_offset))?;
    let available = info.file_size.saturating_sub(info.data_offset);
    let mut bytes = vec![0u8; info.data_bytes.min(available) as usize];
    f.read_exact(&mut bytes)?;
    Ok(bytes.as_chunks::<2>().0.iter().map(|b| i16::from_le_bytes(*b) as f32 / 32768.0).collect())
}

/// Reads `count` frames starting at frame `start` of a 16-bit mono WAV, for walking a long
/// recording without holding it all in memory.
pub fn read_pcm16_range(path: &Path, info: &WavInfo, start: u64, count: usize) -> std::io::Result<Vec<f32>> {
    let mut f = File::open(path)?;
    f.seek(SeekFrom::Start(info.data_offset + start * 2))?;
    let mut bytes = vec![0u8; count * 2];
    let mut read = 0;
    while read < bytes.len() {
        let n = f.read(&mut bytes[read..])?;
        if n == 0 {
            break;
        }
        read += n;
    }
    bytes.truncate(read - read % 2);
    Ok(bytes.as_chunks::<2>().0.iter().map(|b| i16::from_le_bytes(*b) as f32 / 32768.0).collect())
}

/// Writes samples as a whole 16-bit WAV in one go (a dictation's recording).
pub fn write(path: &Path, samples: &[f32], sample_rate: u32) -> std::io::Result<()> {
    let mut bytes = header(samples.len() as u64 * 2, sample_rate);
    for s in samples {
        bytes.extend_from_slice(&((s.clamp(-1.0, 1.0) * 32767.0).round() as i16).to_le_bytes());
    }
    crate::fsutil::write_atomic(path, &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_crash_costs_at_most_the_last_second() {
        let dir = crate::history::tests::tempdir();
        let path = dir.join("audio-mic.wav");
        let mut w = WavWriter::create(&path, 16_000, false).unwrap();
        for _ in 0..40 {
            w.append(&vec![0.25; 1_000]).unwrap();
        }
        // Simulate the process dying: forget the writer without closing it.
        std::mem::forget(w);
        let before = info(&path).unwrap();
        assert!(before.seconds() >= 2.0 && before.seconds() < 2.5, "{}", before.seconds());
        assert!(repair_header(&path).unwrap());
        assert_eq!(info(&path).unwrap().seconds(), 2.5);
        assert!(!repair_header(&path).unwrap(), "a second repair changes nothing");
        // Appending continues the same file.
        let mut w = WavWriter::create(&path, 16_000, true).unwrap();
        w.append(&vec![0.5; 16_000]).unwrap();
        w.close().unwrap();
        assert_eq!(info(&path).unwrap().seconds(), 3.5);
        let samples = read_pcm16(&path).unwrap();
        assert_eq!(samples.len(), 56_000);
        assert!((samples[0] - 0.25).abs() < 0.001);
        // A fresh writer never overwrites what is there.
        let w = WavWriter::create(&path, 16_000, false).unwrap();
        drop(w);
        let asides = fs::read_dir(&dir).unwrap().filter(|e| e.as_ref().unwrap().file_name().to_string_lossy().contains("previous")).count();
        assert_eq!(asides, 1);
        let _ = fs::remove_dir_all(dir);
    }
}
