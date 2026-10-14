//! Core Audio on the Mac: which apps hold the microphone, the default devices' names, the
//! system-audio tap that records the other side of a call, and keeping the Mac awake while a
//! meeting records.

use core_foundation::base::{CFType, TCFType};
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::CFDictionary;
use core_foundation::string::{CFString, CFStringRef};
use core_foundation_sys::base::CFTypeRef;
use linflow_core::audio::{mono_mix_interleaved, mono_mix_planar, RateWatch, StreamingResampler};
use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject, Bool};
use objc2::msg_send;
use objc2_foundation::{NSArray, NSString, NSUUID};
use std::ffi::c_void;
use std::sync::Mutex;

#[repr(C)]
struct PropertyAddress {
    selector: u32,
    scope: u32,
    element: u32,
}

#[repr(C)]
#[derive(Default, Clone, Copy, Debug)]
struct StreamDescription {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
}

#[repr(C)]
struct AudioBuffer {
    channels: u32,
    bytes: u32,
    data: *mut c_void,
}

#[repr(C)]
struct AudioBufferList {
    count: u32,
    buffers: [AudioBuffer; 1],
}

type IOProcID = *mut c_void;
type IOProc = unsafe extern "C" fn(device: u32, now: *const c_void, input: *const AudioBufferList, input_time: *const c_void, output: *mut c_void, output_time: *const c_void, client: *mut c_void) -> i32;

#[link(name = "CoreAudio", kind = "framework")]
extern "C" {
    fn AudioObjectGetPropertyDataSize(id: u32, address: *const PropertyAddress, qualifier_size: u32, qualifier: *const c_void, size: *mut u32) -> i32;
    fn AudioObjectGetPropertyData(id: u32, address: *const PropertyAddress, qualifier_size: u32, qualifier: *const c_void, size: *mut u32, data: *mut c_void) -> i32;
    fn AudioHardwareCreateProcessTap(description: *mut AnyObject, tap: *mut u32) -> i32;
    fn AudioHardwareDestroyProcessTap(tap: u32) -> i32;
    fn AudioHardwareCreateAggregateDevice(description: *const c_void, device: *mut u32) -> i32;
    fn AudioHardwareDestroyAggregateDevice(device: u32) -> i32;
    fn AudioDeviceCreateIOProcID(device: u32, proc_: IOProc, client: *mut c_void, id: *mut IOProcID) -> i32;
    fn AudioDeviceDestroyIOProcID(device: u32, id: IOProcID) -> i32;
    fn AudioDeviceStart(device: u32, id: IOProcID) -> i32;
    fn AudioDeviceStop(device: u32, id: IOProcID) -> i32;
}

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOPMAssertionCreateWithName(kind: CFStringRef, level: u32, name: CFStringRef, id: *mut u32) -> i32;
    fn IOPMAssertionRelease(id: u32) -> i32;
}

const fn fourcc(s: &[u8; 4]) -> u32 {
    (s[0] as u32) << 24 | (s[1] as u32) << 16 | (s[2] as u32) << 8 | s[3] as u32
}

const SYSTEM_OBJECT: u32 = 1;
const SCOPE_GLOBAL: u32 = fourcc(b"glob");
const PROCESS_LIST: u32 = fourcc(b"prs#");
const PROCESS_RUNNING_INPUT: u32 = fourcc(b"piri");
const PROCESS_BUNDLE_ID: u32 = fourcc(b"pbid");
const PROCESS_PID: u32 = fourcc(b"ppid");
const DEFAULT_SYSTEM_OUTPUT: u32 = fourcc(b"sOut");
const OBJECT_NAME: u32 = fourcc(b"lnam");
const DEVICE_UID: u32 = fourcc(b"uid ");
const TAP_FORMAT: u32 = fourcc(b"tfmt");
const FORMAT_FLAG_FLOAT: u32 = 1;

fn address(selector: u32) -> PropertyAddress {
    PropertyAddress { selector, scope: SCOPE_GLOBAL, element: 0 }
}

fn get<T: Default + Copy>(object: u32, selector: u32) -> Result<T, i32> {
    let mut value = T::default();
    let mut size = std::mem::size_of::<T>() as u32;
    let err = unsafe { AudioObjectGetPropertyData(object, &address(selector), 0, std::ptr::null(), &mut size, &mut value as *mut T as *mut c_void) };
    if err == 0 {
        Ok(value)
    } else {
        Err(err)
    }
}

fn get_string(object: u32, selector: u32) -> Option<String> {
    let mut value: CFStringRef = std::ptr::null();
    let mut size = std::mem::size_of::<CFStringRef>() as u32;
    let err = unsafe { AudioObjectGetPropertyData(object, &address(selector), 0, std::ptr::null(), &mut size, &mut value as *mut CFStringRef as *mut c_void) };
    if err != 0 || value.is_null() {
        return None;
    }
    Some(unsafe { CFString::wrap_under_create_rule(value) }.to_string())
}

fn get_ids(object: u32, selector: u32) -> Vec<u32> {
    let mut size = 0u32;
    if unsafe { AudioObjectGetPropertyDataSize(object, &address(selector), 0, std::ptr::null(), &mut size) } != 0 || size == 0 {
        return vec![];
    }
    let mut ids = vec![0u32; size as usize / 4];
    let err = unsafe { AudioObjectGetPropertyData(object, &address(selector), 0, std::ptr::null(), &mut size, ids.as_mut_ptr() as *mut c_void) };
    if err != 0 {
        return vec![];
    }
    ids.truncate(size as usize / 4);
    ids
}

/// Apps holding the microphone right now, by bundle id (or "pid:N" when an app has none), not
/// counting this process. The signal meeting detection reads.
pub fn mic_users() -> Vec<String> {
    let me = std::process::id() as i32;
    get_ids(SYSTEM_OBJECT, PROCESS_LIST)
        .into_iter()
        .filter(|&p| get::<u32>(p, PROCESS_RUNNING_INPUT).map(|v| v != 0).unwrap_or(false))
        .filter(|&p| get::<i32>(p, PROCESS_PID).map(|pid| pid != me).unwrap_or(true))
        .map(|p| match get_string(p, PROCESS_BUNDLE_ID).filter(|s| !s.is_empty()) {
            Some(id) => id,
            None => format!("pid:{}", get::<i32>(p, PROCESS_PID).unwrap_or(0)),
        })
        .collect()
}

/// Keeps the Mac from idle sleep while it lives: a meeting recording must not stop because
/// nobody touched the keyboard for twenty minutes.
pub struct AwakeGuard(u32);

pub fn keep_awake(reason: &str) -> Option<AwakeGuard> {
    let mut id = 0u32;
    let kind = CFString::new("PreventUserIdleSystemSleep");
    let name = CFString::new(reason);
    let err = unsafe { IOPMAssertionCreateWithName(kind.as_concrete_TypeRef(), 255, name.as_concrete_TypeRef(), &mut id) };
    (err == 0).then_some(AwakeGuard(id))
}

impl Drop for AwakeGuard {
    fn drop(&mut self) {
        unsafe { IOPMAssertionRelease(self.0) };
    }
}

// MARK: system audio

use crate::OnChunk;

struct Sink {
    resampler: StreamingResampler,
    on_chunk: OnChunk,
    float32: bool,
    rate: RateWatch,
    clock: std::time::Instant,
}

/// Captures what every app is playing, the other people on a call, with a Core Audio process
/// tap (macOS 14.2+) wrapped in a private aggregate device, as 16 kHz mono like every other
/// source. macOS asks once for "System Audio Recording".
pub struct SystemAudio {
    tap: u32,
    aggregate: u32,
    proc_id: IOProcID,
    sink: *mut Mutex<Sink>,
    pub sample_rate: f64,
    pub output_name: String,
}

unsafe impl Send for SystemAudio {}

unsafe extern "C" fn io_proc(_device: u32, _now: *const c_void, input: *const AudioBufferList, _t: *const c_void, _out: *mut c_void, _ot: *const c_void, client: *mut c_void) -> i32 {
    if input.is_null() || client.is_null() {
        return 0;
    }
    let sink = unsafe { &*(client as *const Mutex<Sink>) };
    let Ok(mut sink) = sink.try_lock() else { return 0 };
    if !sink.float32 {
        return 0;
    }
    // The layout is read off the buffer list itself, never off the format the tap advertised:
    // on 2026-09-17 the format said one layout and the HAL delivered the other, and trusting it
    // cost every meeting half its audio.
    let list = unsafe { &*input };
    let buffers = unsafe { std::slice::from_raw_parts(list.buffers.as_ptr(), list.count as usize) };
    let mono = if buffers.len() == 1 {
        let b = &buffers[0];
        let samples = unsafe { std::slice::from_raw_parts(b.data as *const f32, b.bytes as usize / 4) };
        mono_mix_interleaved(samples, b.channels.max(1) as usize)
    } else {
        let planes: Vec<&[f32]> = buffers.iter().map(|b| unsafe { std::slice::from_raw_parts(b.data as *const f32, b.bytes as usize / 4) }).collect();
        mono_mix_planar(&planes)
    };
    if mono.is_empty() {
        return 0;
    }
    let now = sink.clock.elapsed().as_secs_f64();
    if let Some(real) = sink.rate.add(mono.len(), now) {
        log::info!("system audio arrives at {real} Hz, not the rate the tap reports: resampling from {real}");
        sink.resampler = StreamingResampler::new(real as u32);
    }
    let chunk = sink.resampler.feed(&mono);
    if !chunk.is_empty() {
        (sink.on_chunk)(&chunk);
    }
    0
}

impl SystemAudio {
    pub fn start(on_chunk: OnChunk) -> Result<SystemAudio, String> {
        let fail = |what: &str, code: i32| format!("{what} failed ({code}). If macOS asked about System Audio Recording, allow it and try again.");
        // Everything, excluding nothing: a stereo mix of every process's output, left audible.
        let cls = AnyClass::get(c"CATapDescription").ok_or("This Mac's macOS has no system audio taps (14.2 or later is needed).")?;
        let uuid = NSUUID::new();
        let description: Retained<AnyObject> = unsafe {
            let empty = NSArray::<AnyObject>::new();
            let allocated: *mut AnyObject = msg_send![cls, alloc];
            let d: *mut AnyObject = msg_send![allocated, initStereoGlobalTapButExcludeProcesses: &*empty];
            Retained::from_raw(d).ok_or("could not describe the system audio tap")?
        };
        unsafe {
            let _: () = msg_send![&*description, setUUID: &*uuid];
            let _: () = msg_send![&*description, setMuteBehavior: 0isize];
            let _: () = msg_send![&*description, setPrivate: Bool::YES];
        }
        let mut tap = 0u32;
        let err = unsafe { AudioHardwareCreateProcessTap(Retained::as_ptr(&description) as *mut AnyObject, &mut tap) };
        if err != 0 || tap == 0 {
            return Err(fail("Creating the system audio tap", err));
        }
        let mut me = SystemAudio { tap, aggregate: 0, proc_id: std::ptr::null_mut(), sink: std::ptr::null_mut(), sample_rate: 0.0, output_name: String::new() };
        let format: StreamDescription = get(tap, TAP_FORMAT).map_err(|e| fail("Reading the system audio format", e))?;
        me.sample_rate = format.sample_rate;
        let output: u32 = get(SYSTEM_OBJECT, DEFAULT_SYSTEM_OUTPUT).map_err(|e| fail("Finding the output device", e))?;
        let output_uid = get_string(output, DEVICE_UID).ok_or_else(|| fail("Reading the output device", -1))?;
        me.output_name = get_string(output, OBJECT_NAME).unwrap_or_else(|| output_uid.clone());

        let tap_uid = uuid.UUIDString().to_string();
        let sub_device = CFDictionary::from_CFType_pairs(&[(CFString::new("uid").as_CFType(), CFString::new(&output_uid).as_CFType())]);
        let sub_tap = CFDictionary::from_CFType_pairs(&[
            (CFString::new("drift").as_CFType(), CFBoolean::true_value().as_CFType()),
            (CFString::new("uid").as_CFType(), CFString::new(&tap_uid).as_CFType()),
        ]);
        let array = |d: CFDictionary<CFType, CFType>| core_foundation::array::CFArray::from_CFTypes(&[d]).as_CFType();
        let aggregate = CFDictionary::from_CFType_pairs(&[
            (CFString::new("name").as_CFType(), CFString::new("Lin Flow Next System Audio").as_CFType()),
            (CFString::new("uid").as_CFType(), CFString::new(&NSUUID::new().UUIDString().to_string()).as_CFType()),
            (CFString::new("master").as_CFType(), CFString::new(&output_uid).as_CFType()),
            (CFString::new("private").as_CFType(), CFBoolean::true_value().as_CFType()),
            (CFString::new("stacked").as_CFType(), CFBoolean::false_value().as_CFType()),
            (CFString::new("tapautostart").as_CFType(), CFBoolean::true_value().as_CFType()),
            (CFString::new("subdevices").as_CFType(), array(sub_device)),
            (CFString::new("taps").as_CFType(), array(sub_tap)),
        ]);
        let mut agg = 0u32;
        let err = unsafe { AudioHardwareCreateAggregateDevice(aggregate.as_concrete_TypeRef() as *const c_void, &mut agg) };
        if err != 0 {
            return Err(fail("Creating the capture device", err));
        }
        me.aggregate = agg;
        let float32 = format.format_flags & FORMAT_FLAG_FLOAT != 0 && format.bits_per_channel == 32;
        if !float32 {
            return Err(format!("The system audio arrived as {} bit, not 32-bit float; Lin Flow cannot read it yet.", format.bits_per_channel));
        }
        let sink = Box::new(Mutex::new(Sink { resampler: StreamingResampler::new(format.sample_rate.round() as u32), on_chunk, float32, rate: RateWatch::new(format.sample_rate), clock: std::time::Instant::now() }));
        me.sink = Box::into_raw(sink);
        let mut proc_id: IOProcID = std::ptr::null_mut();
        let err = unsafe { AudioDeviceCreateIOProcID(agg, io_proc, me.sink as *mut c_void, &mut proc_id) };
        if err != 0 {
            return Err(fail("Attaching to the capture device", err));
        }
        me.proc_id = proc_id;
        let err = unsafe { AudioDeviceStart(agg, proc_id) };
        if err != 0 {
            return Err(fail("Starting system audio capture", err));
        }
        log::info!("system audio tap running ({} Hz, {} ch, output: {})", format.sample_rate, format.channels_per_frame, me.output_name);
        Ok(me)
    }
}

impl Drop for SystemAudio {
    fn drop(&mut self) {
        unsafe {
            if self.aggregate != 0 {
                if !self.proc_id.is_null() {
                    AudioDeviceStop(self.aggregate, self.proc_id);
                    AudioDeviceDestroyIOProcID(self.aggregate, self.proc_id);
                }
                AudioHardwareDestroyAggregateDevice(self.aggregate);
            }
            if self.tap != 0 {
                AudioHardwareDestroyProcessTap(self.tap);
            }
            if !self.sink.is_null() {
                drop(Box::from_raw(self.sink));
            }
        }
        log::info!("system audio tap stopped");
    }
}

#[allow(dead_code)]
fn _types(_: CFTypeRef, _: &NSString) {}
