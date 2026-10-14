//! The microphone on both computers, through cpal: Core Audio on the Mac, WASAPI on Windows.
//! Every take opens a fresh stream on whatever the default input is right then, so AirPods that
//! connected a minute ago are the microphone for the next take without anything to restart.
//!
//! Audio arrives at the device's own rate and layout and leaves as 16 kHz mono, the one format
//! the rest of the app knows.

use crate::OnChunk;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use linflow_core::audio::{mono_mix_interleaved, StreamingResampler};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Default)]
struct Shared {
    first_audio: Mutex<Option<Duration>>,
    heard: AtomicBool,
    error: Mutex<Option<String>>,
}

/// Which side a capture records.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Source {
    /// The default input.
    Microphone,
    /// What the default output plays, through WASAPI loopback. Windows only: the Mac taps
    /// system audio through Core Audio instead.
    #[cfg_attr(not(windows), allow(dead_code))]
    Loopback,
}

/// An open microphone, or on Windows the loopback of the default output. Dropping it stops the
/// stream.
pub struct Microphone {
    pub device: String,
    pub sample_rate: u32,
    pub channels: u16,
    started: Instant,
    shared: Arc<Shared>,
    stop: Option<mpsc::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

fn to_f32_i16(data: &[i16]) -> Vec<f32> {
    data.iter().map(|&s| s as f32 / 32768.0).collect()
}

fn to_f32_u16(data: &[u16]) -> Vec<f32> {
    data.iter().map(|&s| (s as f32 - 32768.0) / 32768.0).collect()
}

fn to_f32_i32(data: &[i32]) -> Vec<f32> {
    data.iter().map(|&s| s as f32 / 2_147_483_648.0).collect()
}

struct Pipeline {
    channels: usize,
    resampler: StreamingResampler,
    on_chunk: OnChunk,
    shared: Arc<Shared>,
    started: Instant,
}

impl Pipeline {
    fn push(&mut self, interleaved: &[f32]) {
        if interleaved.is_empty() {
            return;
        }
        if let Ok(mut first) = self.shared.first_audio.try_lock() {
            if first.is_none() {
                *first = Some(self.started.elapsed());
            }
        }
        if !self.shared.heard.load(Ordering::Relaxed) && interleaved.iter().any(|&s| s != 0.0) {
            self.shared.heard.store(true, Ordering::Relaxed);
        }
        let mono = mono_mix_interleaved(interleaved, self.channels);
        let out = self.resampler.feed(&mono);
        if !out.is_empty() {
            (self.on_chunk)(&out);
        }
    }
}

impl Microphone {
    /// Opens the default input. Fails when there is none or the OS refuses it; on the Mac the
    /// first refusal is the microphone permission, which only John can grant.
    pub fn start(on_chunk: OnChunk) -> Result<Microphone, String> {
        Microphone::start_source(Source::Microphone, on_chunk)
    }

    pub(crate) fn start_source(source: Source, on_chunk: OnChunk) -> Result<Microphone, String> {
        let shared = Arc::new(Shared::default());
        let started = Instant::now();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(String, u32, u16), String>>();
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let thread_shared = shared.clone();
        // A cpal stream may not leave the thread that built it, so one thread owns it from
        // start to stop.
        let thread = std::thread::Builder::new()
            .name("linflow.capture".into())
            .spawn(move || {
                let streams = match open(source, on_chunk, thread_shared, started) {
                    Ok((streams, name, rate, channels)) => {
                        let _ = ready_tx.send(Ok((name, rate, channels)));
                        streams
                    }
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                        return;
                    }
                };
                let _ = stop_rx.recv();
                drop(streams);
            })
            .map_err(|e| e.to_string())?;
        match ready_rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok((device, sample_rate, channels))) => {
                log::info!("{source:?} open: {device} at {sample_rate} Hz, {channels} ch");
                Ok(Microphone { device, sample_rate, channels, started, shared, stop: Some(stop_tx), thread: Some(thread) })
            }
            Ok(Err(e)) => {
                let _ = thread.join();
                Err(e)
            }
            Err(_) => {
                // The thread is still stuck in the driver; let it go rather than wait on it.
                drop(stop_tx);
                Err("The audio device did not open within 5 seconds.".into())
            }
        }
    }

    /// How long the device took to deliver its first audio, once it has.
    pub fn first_audio(&self) -> Option<Duration> {
        *self.shared.first_audio.lock().ok()?
    }

    /// Whether anything but digital zeros has arrived. A muted or dead input sends zeros.
    pub fn heard_anything(&self) -> bool {
        self.shared.heard.load(Ordering::Relaxed)
    }

    /// What the stream reported going wrong, such as the device being unplugged.
    pub fn error(&self) -> Option<String> {
        self.shared.error.lock().ok()?.clone()
    }

    pub fn running_for(&self) -> Duration {
        self.started.elapsed()
    }
}

impl Drop for Microphone {
    fn drop(&mut self) {
        drop(self.stop.take());
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn open(source: Source, on_chunk: OnChunk, shared: Arc<Shared>, started: Instant) -> Result<(Vec<cpal::Stream>, String, u32, u16), String> {
    let host = cpal::default_host();
    let (device, config) = match source {
        Source::Microphone => {
            let device = host.default_input_device().ok_or("No microphone is connected.")?;
            let config = device.default_input_config().map_err(|e| format!("Couldn't read the microphone's format: {e}"))?;
            (device, config)
        }
        Source::Loopback => {
            let device = host.default_output_device().ok_or("No speaker or headphones are connected.")?;
            let config = device.default_output_config().map_err(|e| format!("Couldn't read the output's format: {e}"))?;
            (device, config)
        }
    };
    let name = device.name().unwrap_or_else(|_| "Audio device".into());
    let format = config.sample_format();
    let stream_config: cpal::StreamConfig = config.into();
    let rate = stream_config.sample_rate.0;
    let channels = stream_config.channels;
    let mut pipe = Pipeline { channels: channels.max(1) as usize, resampler: StreamingResampler::new(rate), on_chunk, shared: shared.clone(), started };
    let err_shared = shared.clone();
    let on_error = move |e: cpal::StreamError| {
        log::warn!("{source:?} stream: {e}");
        if let Ok(mut slot) = err_shared.error.lock() {
            *slot = Some(e.to_string());
        }
    };
    // On an output device, WASAPI opens an input stream as a loopback of what it plays.
    let stream = match format {
        cpal::SampleFormat::F32 => device.build_input_stream(&stream_config, move |d: &[f32], _: &cpal::InputCallbackInfo| pipe.push(d), on_error, None),
        cpal::SampleFormat::I16 => device.build_input_stream(&stream_config, move |d: &[i16], _: &cpal::InputCallbackInfo| pipe.push(&to_f32_i16(d)), on_error, None),
        cpal::SampleFormat::U16 => device.build_input_stream(&stream_config, move |d: &[u16], _: &cpal::InputCallbackInfo| pipe.push(&to_f32_u16(d)), on_error, None),
        cpal::SampleFormat::I32 => device.build_input_stream(&stream_config, move |d: &[i32], _: &cpal::InputCallbackInfo| pipe.push(&to_f32_i32(d)), on_error, None),
        other => return Err(format!("{name} sends {other:?} audio, which Lin Flow cannot read.")),
    }
    .map_err(|e| format!("Couldn't open {name}: {e}"))?;
    stream.play().map_err(|e| format!("Couldn't start {name}: {e}"))?;
    let mut streams = vec![stream];
    if source == Source::Loopback {
        // WASAPI loopback delivers buffers only while something plays on the device. A silent
        // stream of our own keeps it flowing, so a quiet stretch of a call is recorded as silence
        // at the right time rather than as a hole (the Windows app's KeepLoopbackAlive).
        match keep_alive(&device, &stream_config, format) {
            Ok(s) => streams.push(s),
            Err(e) => log::info!("loopback keep-alive: {e}"),
        }
    }
    Ok((streams, name, rate, channels))
}

fn keep_alive(device: &cpal::Device, config: &cpal::StreamConfig, format: cpal::SampleFormat) -> Result<cpal::Stream, String> {
    let on_error = |e: cpal::StreamError| log::warn!("loopback keep-alive: {e}");
    let stream = match format {
        cpal::SampleFormat::F32 => device.build_output_stream(config, |d: &mut [f32], _: &cpal::OutputCallbackInfo| d.fill(0.0), on_error, None),
        cpal::SampleFormat::I16 => device.build_output_stream(config, |d: &mut [i16], _: &cpal::OutputCallbackInfo| d.fill(0), on_error, None),
        other => return Err(format!("no silent stream for {other:?}")),
    }
    .map_err(|e| e.to_string())?;
    stream.play().map_err(|e| e.to_string())?;
    Ok(stream)
}

/// The default input's name.
pub fn default_input_name() -> Option<String> {
    cpal::default_host().default_input_device()?.name().ok()
}

/// The default output's name: where the call is playing.
pub fn default_output_name() -> Option<String> {
    cpal::default_host().default_output_device()?.name().ok()
}
