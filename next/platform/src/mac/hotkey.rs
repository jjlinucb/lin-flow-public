//! The talk key on the Mac: a CGEventTap. Fn never reaches the normal key event APIs, so a tap is
//! the one way to see it, and the same tap covers every other key, combination and mouse button
//! a `Hotkey` can name. `HotkeyMatcher` (core) decides what fires and what is swallowed.
//!
//! The tap runs its own CFRunLoop on a thread of its own and calls back right there, so the
//! callback must be quick: hand the key to the audio side and return. A busy window must never
//! hold a key press back while the first words go unrecorded.

use core_foundation_sys::base::{CFRelease, CFTypeRef};
use core_foundation_sys::runloop::{kCFRunLoopCommonModes, CFRunLoopAddSource, CFRunLoopGetCurrent, CFRunLoopRef, CFRunLoopRun, CFRunLoopStop};
use linflow_core::hotkey::{Hotkey, HotkeyEvent, HotkeyMatcher, Signal};
use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::{Arc, Mutex};

type CGEventRef = *mut c_void;
type CFMachPortRef = *mut c_void;
type TapCallback = unsafe extern "C" fn(proxy: *mut c_void, kind: u32, event: CGEventRef, user: *mut c_void) -> CGEventRef;

#[repr(C)]
#[derive(Clone, Copy)]
struct CGPoint {
    x: f64,
    y: f64,
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventTapCreate(tap: u32, place: u32, options: u32, events: u64, callback: TapCallback, user: *mut c_void) -> CFMachPortRef;
    fn CGEventTapEnable(tap: CFMachPortRef, enable: bool);
    fn CGEventGetIntegerValueField(event: CGEventRef, field: u32) -> i64;
    fn CGEventSetIntegerValueField(event: CGEventRef, field: u32, value: i64);
    fn CGEventGetFlags(event: CGEventRef) -> u64;
    fn CGEventGetTimestamp(event: CGEventRef) -> u64;
    fn CGEventGetLocation(event: CGEventRef) -> CGPoint;
    fn CGEventCreateMouseEvent(source: *const c_void, kind: u32, at: CGPoint, button: u32) -> CGEventRef;
    fn CGEventPost(tap: u32, event: CGEventRef);
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFMachPortCreateRunLoopSource(allocator: *const c_void, port: CFMachPortRef, order: isize) -> *mut c_void;
}

const SESSION_TAP: u32 = 1;
const HEAD_INSERT: u32 = 0;
const DEFAULT_TAP: u32 = 0;
const KEY_DOWN: u32 = 10;
const KEY_UP: u32 = 11;
const FLAGS_CHANGED: u32 = 12;
const OTHER_MOUSE_DOWN: u32 = 25;
const OTHER_MOUSE_UP: u32 = 26;
const TAP_DISABLED_BY_TIMEOUT: u32 = 0xFFFF_FFFE;
const TAP_DISABLED_BY_USER_INPUT: u32 = 0xFFFF_FFFF;
const FIELD_MOUSE_CLICK_STATE: u32 = 1;
const FIELD_MOUSE_BUTTON_NUMBER: u32 = 3;
const FIELD_KEY_AUTOREPEAT: u32 = 8;
const FIELD_KEYCODE: u32 = 9;
const FIELD_SOURCE_USER_DATA: u32 = 42;
const MOUSE_BUTTON_CENTER: u32 = 2;

/// Marks the clicks this tap posts again, so it lets them through instead of catching them.
const REPLAY_MARKER: i64 = 0x4C_69_6E_46; // "LinF"

pub use crate::{OnRecord, OnSignal};

struct TapState {
    matcher: Mutex<HotkeyMatcher>,
    on_signal: OnSignal,
    recorder: Mutex<Option<OnRecord>>,
    tap: AtomicPtr<c_void>,
    run_loop: AtomicPtr<c_void>,
}

/// A running talk-key listener. Dropping it stops the tap.
pub struct HotkeyListener {
    state: Arc<TapState>,
    thread: Option<std::thread::JoinHandle<()>>,
}

fn event_of(kind: u32, event: CGEventRef) -> Option<HotkeyEvent> {
    unsafe {
        match kind {
            FLAGS_CHANGED => Some(HotkeyEvent::from_mac_flags(CGEventGetFlags(event), CGEventGetIntegerValueField(event, FIELD_KEYCODE) as u32)),
            KEY_DOWN | KEY_UP => Some(HotkeyEvent::Key {
                code: CGEventGetIntegerValueField(event, FIELD_KEYCODE) as u32,
                down: kind == KEY_DOWN,
                repeat: CGEventGetIntegerValueField(event, FIELD_KEY_AUTOREPEAT) != 0,
            }),
            OTHER_MOUSE_DOWN | OTHER_MOUSE_UP => {
                Some(HotkeyEvent::Mouse { button: CGEventGetIntegerValueField(event, FIELD_MOUSE_BUTTON_NUMBER) as u8, down: kind == OTHER_MOUSE_DOWN })
            }
            _ => None,
        }
    }
}

unsafe extern "C" fn callback(_proxy: *mut c_void, kind: u32, event: CGEventRef, user: *mut c_void) -> CGEventRef {
    let state = unsafe { &*(user as *const TapState) };
    // macOS disables a tap it thinks is unresponsive; turn it back on.
    if kind == TAP_DISABLED_BY_TIMEOUT || kind == TAP_DISABLED_BY_USER_INPUT {
        let tap = state.tap.load(Ordering::Acquire);
        if !tap.is_null() {
            unsafe { CGEventTapEnable(tap, true) };
        }
        return event;
    }
    if unsafe { CGEventGetIntegerValueField(event, FIELD_SOURCE_USER_DATA) } == REPLAY_MARKER {
        return event;
    }
    let Some(e) = event_of(kind, event) else { return event };
    if let Ok(mut rec) = state.recorder.lock() {
        if let Some(record) = rec.as_mut() {
            return if record(&e) { std::ptr::null_mut() } else { event };
        }
    }
    let seconds = unsafe { CGEventGetTimestamp(event) } as f64 / 1e9;
    let out = match state.matcher.lock() {
        Ok(mut m) => m.handle(&e, seconds),
        Err(_) => return event,
    };
    if out.signal != Signal::None {
        (state.on_signal)(out.signal);
    }
    if out.replay_click {
        if let HotkeyEvent::Mouse { button, .. } = e {
            replay_click(button, unsafe { CGEventGetLocation(event) });
        }
    }
    if out.swallow {
        std::ptr::null_mut()
    } else {
        event
    }
}

/// Posts the click the tap swallowed, down and up, marked so this tap passes it on.
fn replay_click(button: u8, at: CGPoint) {
    for kind in [OTHER_MOUSE_DOWN, OTHER_MOUSE_UP] {
        unsafe {
            let e = CGEventCreateMouseEvent(std::ptr::null(), kind, at, MOUSE_BUTTON_CENTER);
            if e.is_null() {
                continue;
            }
            CGEventSetIntegerValueField(e, FIELD_MOUSE_BUTTON_NUMBER, button as i64);
            // A click count of 0 is not a click to a browser: it opens no link.
            CGEventSetIntegerValueField(e, FIELD_MOUSE_CLICK_STATE, 1);
            CGEventSetIntegerValueField(e, FIELD_SOURCE_USER_DATA, REPLAY_MARKER);
            CGEventPost(SESSION_TAP, e);
            CFRelease(e as CFTypeRef);
        }
    }
}

impl HotkeyListener {
    /// Starts watching for `hotkey`. Fails when the process is not trusted for Accessibility
    /// and Input Monitoring, which only John can grant.
    pub fn start(hotkey: Hotkey, on_signal: OnSignal) -> Result<HotkeyListener, String> {
        // Every key and extra button, whatever the talk key is: a new key from Settings, or
        // its Record button, then needs no new tap. Everything but the talk key's own events
        // passes straight through.
        let mask: u64 = 1 << FLAGS_CHANGED | 1 << KEY_DOWN | 1 << KEY_UP | 1 << OTHER_MOUSE_DOWN | 1 << OTHER_MOUSE_UP;
        let state = Arc::new(TapState {
            matcher: Mutex::new(HotkeyMatcher::new(hotkey)),
            on_signal,
            recorder: Mutex::new(None),
            tap: AtomicPtr::new(std::ptr::null_mut()),
            run_loop: AtomicPtr::new(std::ptr::null_mut()),
        });
        let user = Arc::as_ptr(&state) as *mut c_void;
        let tap = unsafe { CGEventTapCreate(SESSION_TAP, HEAD_INSERT, DEFAULT_TAP, mask, callback, user) };
        if tap.is_null() {
            return Err("Couldn't watch the keyboard. Grant Lin Flow access under System Settings → Privacy & Security → Accessibility (and Input Monitoring), then relaunch.".into());
        }
        state.tap.store(tap, Ordering::Release);
        let thread_state = state.clone();
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let thread = std::thread::Builder::new()
            .name("linflow.hotkey".into())
            .spawn(move || unsafe {
                let tap = thread_state.tap.load(Ordering::Acquire);
                let source = CFMachPortCreateRunLoopSource(std::ptr::null(), tap, 0);
                let rl: CFRunLoopRef = CFRunLoopGetCurrent();
                thread_state.run_loop.store(rl as *mut c_void, Ordering::Release);
                CFRunLoopAddSource(rl, source as _, kCFRunLoopCommonModes);
                CGEventTapEnable(tap, true);
                let _ = ready_tx.send(());
                CFRunLoopRun();
                CFRelease(source as CFTypeRef);
            })
            .map_err(|e| e.to_string())?;
        let _ = ready_rx.recv_timeout(std::time::Duration::from_secs(2));
        log::info!("hotkey tap running");
        Ok(HotkeyListener { state, thread: Some(thread) })
    }

    /// Changes the talk key without a new tap. A take in progress ends first.
    pub fn set_hotkey(&self, hotkey: Hotkey) {
        let was_active = self.state.matcher.lock().map(|mut m| {
            let active = m.active;
            *m = HotkeyMatcher::new(hotkey);
            active
        });
        if was_active.unwrap_or(false) {
            (self.state.on_signal)(Signal::Release);
        }
    }
}

impl HotkeyListener {
    /// Hands every event to `record` instead of the talk key until it is cleared with None. A
    /// take in progress ends first.
    pub fn set_recorder(&self, record: Option<OnRecord>) {
        if record.is_some() && self.state.matcher.lock().map(|mut m| std::mem::replace(&mut m.active, false)).unwrap_or(false) {
            (self.state.on_signal)(Signal::Release);
        }
        if let Ok(mut r) = self.state.recorder.lock() {
            *r = record;
        }
    }
}

impl Drop for HotkeyListener {
    fn drop(&mut self) {
        let tap = self.state.tap.swap(std::ptr::null_mut(), Ordering::AcqRel);
        if !tap.is_null() {
            unsafe { CGEventTapEnable(tap, false) };
        }
        // A take in progress ends here rather than waiting for a release this tap will not see.
        if self.state.matcher.lock().map(|m| m.active).unwrap_or(false) {
            (self.state.on_signal)(Signal::Release);
        }
        let rl = self.state.run_loop.load(Ordering::Acquire);
        if !rl.is_null() {
            unsafe { CFRunLoopStop(rl as CFRunLoopRef) };
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        if !tap.is_null() {
            unsafe { CFRelease(tap as CFTypeRef) };
        }
    }
}
