//! The talk key on Windows: low-level keyboard and mouse hooks. RegisterHotKey fires on a chord
//! press, never on hold and release of one bare key, which is the whole interaction.
//!
//! Both hooks live on a thread that does nothing but pump messages. A low-level hook is called
//! on the thread that installed it, the input waits for that call, and Windows silently removes
//! a hook that keeps it waiting too often: dictation that works for a while and then quietly
//! stops. So the callbacks decide in microseconds and hand the signal on.
//!
//! The mouse hook goes in only when the talk key uses a mouse button, since it runs for every
//! move of the pointer.

use crate::{OnRecord, OnSignal};
use linflow_core::hotkey::{Hotkey, HotkeyEvent, HotkeyMatcher, Modifier, Part, Signal};
use std::collections::HashSet;
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;
use windows::Win32::Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, MOUSEINPUT, MOUSE_EVENT_FLAGS};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, GetMessageW, PeekMessageW, PostThreadMessageW, SetWindowsHookExW, UnhookWindowsHookEx, KBDLLHOOKSTRUCT, MSG, MSLLHOOKSTRUCT, PM_NOREMOVE, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_KEYDOWN, WM_KEYUP, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_QUIT, WM_SYSKEYDOWN, WM_SYSKEYUP, WM_XBUTTONDOWN, WM_XBUTTONUP,
};

/// Stamped on the click this hook hands back, so it passes its own click on rather than
/// swallowing it again. Anything else counts as the button, injected or not, so a click from a
/// remote-control or mouse-sharing tool still dictates.
const CLICK_MARK: usize = 0x4C46_4D42; // "LFMB"

struct HookState {
    matcher: Mutex<HotkeyMatcher>,
    on_signal: OnSignal,
    recorder: Mutex<Option<OnRecord>>,
    /// Keys down right now, to tell a held key's repeats from a fresh press.
    keys_down: Mutex<HashSet<u32>>,
}

static STATE: Mutex<Option<Arc<HookState>>> = Mutex::new(None);

fn clock() -> f64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

fn current() -> Option<Arc<HookState>> {
    STATE.lock().ok()?.clone()
}

fn is_down(vk: u32) -> bool {
    (unsafe { GetAsyncKeyState(vk as i32) } as u16) & 0x8000 != 0
}

/// Runs one event through the matcher, or the recorder while Settings listens for a new key.
/// Returns whether to swallow it and whether to hand a click back.
fn handle(state: &HookState, event: &HotkeyEvent) -> (bool, bool) {
    if let Ok(mut rec) = state.recorder.lock() {
        if let Some(record) = rec.as_mut() {
            return (record(event), false);
        }
    }
    let out = match state.matcher.lock() {
        Ok(mut m) => m.handle(event, clock()),
        Err(_) => return (false, false),
    };
    if out.signal != Signal::None {
        (state.on_signal)(out.signal);
    }
    (out.swallow, out.replay_click)
}

fn key_event(state: &HookState, vk: u32, down: bool) -> HotkeyEvent {
    if let Some(changed) = Modifier::from_windows_vk(vk) {
        // The changing key from the event itself, every other modifier from the keyboard's state,
        // so a release this hook missed cannot leave one held forever.
        let held = Modifier::ALL
            .into_iter()
            .filter(|&m| if m == changed { down } else { is_down(m.windows_vk()) })
            .map(Part::Mod)
            .collect();
        return HotkeyEvent::Modifiers { down: held, changed: Some(Part::Mod(changed)) };
    }
    let repeat = match state.keys_down.lock() {
        Ok(mut keys) if down => !keys.insert(vk),
        Ok(mut keys) => {
            keys.remove(&vk);
            false
        }
        Err(_) => false,
    };
    HotkeyEvent::Key { code: vk, down, repeat }
}

unsafe extern "system" fn keyboard_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let msg = wparam.0 as u32;
        let down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
        let up = msg == WM_KEYUP || msg == WM_SYSKEYUP;
        if down || up {
            if let Some(state) = current() {
                let info = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
                let event = key_event(&state, info.vkCode, down);
                if handle(&state, &event).0 {
                    return LRESULT(1);
                }
            }
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

unsafe extern "system" fn mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let msg = wparam.0 as u32;
        // Every move of the pointer comes through here, so anything but the three buttons a talk
        // key can use goes straight on.
        if matches!(msg, WM_MBUTTONDOWN | WM_MBUTTONUP | WM_XBUTTONDOWN | WM_XBUTTONUP) {
            let info = unsafe { &*(lparam.0 as *const MSLLHOOKSTRUCT) };
            let button = match msg {
                WM_MBUTTONDOWN | WM_MBUTTONUP => Some(2u8),
                _ => match (info.mouseData >> 16) & 0xFFFF {
                    1 => Some(3),
                    2 => Some(4),
                    _ => None,
                },
            };
            if let (Some(button), true) = (button, info.dwExtraInfo != CLICK_MARK) {
                if let Some(state) = current() {
                    let down = msg == WM_MBUTTONDOWN || msg == WM_XBUTTONDOWN;
                    let (swallow, replay) = handle(&state, &HotkeyEvent::Mouse { button, down });
                    if replay {
                        // A hook must return before the input it sends can be seen.
                        std::thread::spawn(move || click(button));
                    }
                    if swallow {
                        return LRESULT(1);
                    }
                }
            }
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

/// One click of the button, down and up, wherever the pointer is.
fn click(button: u8) {
    let (down, up, data) = match button {
        2 => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, 0),
        3 => (MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, 1),
        4 => (MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, 2),
        _ => return,
    };
    let input = |flags: MOUSE_EVENT_FLAGS| INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 { mi: MOUSEINPUT { dx: 0, dy: 0, mouseData: data, dwFlags: flags, time: 0, dwExtraInfo: CLICK_MARK } },
    };
    let inputs = [input(down), input(up)];
    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent as usize != inputs.len() {
        log::info!("could not pass a mouse button {button} click on");
    }
}

struct HookThread {
    thread_id: u32,
    thread: Option<std::thread::JoinHandle<()>>,
    keyboard: bool,
    mouse: bool,
}

impl HookThread {
    fn start(keyboard: bool, mouse: bool) -> Result<HookThread, String> {
        let (ready_tx, ready_rx) = mpsc::channel::<Result<u32, String>>();
        let thread = std::thread::Builder::new()
            .name("linflow.hotkey".into())
            .spawn(move || unsafe {
                let tid = GetCurrentThreadId();
                let mut msg = MSG::default();
                // Makes this thread's message queue now, so the stop message has somewhere to
                // land even if it comes before any input does.
                let _ = PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE);
                let module = GetModuleHandleW(None).ok().map(|m| HINSTANCE(m.0));
                let mut hooks = Vec::new();
                let mut failure = None;
                for (wanted, kind, proc_, what) in [(keyboard, WH_KEYBOARD_LL, keyboard_proc as unsafe extern "system" fn(i32, WPARAM, LPARAM) -> LRESULT, "keyboard"), (mouse, WH_MOUSE_LL, mouse_proc, "mouse")] {
                    if !wanted {
                        continue;
                    }
                    match SetWindowsHookExW(kind, Some(proc_), module, 0) {
                        Ok(h) => hooks.push(h),
                        Err(e) => {
                            failure = Some(format!("could not install the {what} hook ({e})"));
                            break;
                        }
                    }
                }
                let _ = ready_tx.send(match failure {
                    Some(f) => Err(f),
                    None => Ok(tid),
                });
                // The hooks are called from inside GetMessage. Nothing is posted here but WM_QUIT.
                while GetMessageW(&mut msg, None, 0, 0).0 > 0 {}
                for h in hooks {
                    let _ = UnhookWindowsHookEx(h);
                }
            })
            .map_err(|e| e.to_string())?;
        match ready_rx.recv() {
            Ok(Ok(thread_id)) => Ok(HookThread { thread_id, thread: Some(thread), keyboard, mouse }),
            Ok(Err(e)) => {
                let t = HookThread { thread_id: 0, thread: Some(thread), keyboard, mouse };
                drop(t);
                Err(e)
            }
            Err(_) => Err("the hotkey thread ended before it started".into()),
        }
    }
}

impl Drop for HookThread {
    fn drop(&mut self) {
        if self.thread_id != 0 {
            unsafe {
                let _ = PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
            }
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn hooks_for(hotkey: &Hotkey) -> (bool, bool) {
    let keyboard = hotkey.parts.iter().any(|p| !matches!(p, Part::Mouse(_)));
    (keyboard, hotkey.uses_mouse())
}

/// A running talk-key listener. Dropping it removes the hooks. One at a time.
pub struct HotkeyListener {
    state: Arc<HookState>,
    hooks: Mutex<Option<HookThread>>,
}

impl HotkeyListener {
    pub fn start(hotkey: Hotkey, on_signal: OnSignal) -> Result<HotkeyListener, String> {
        let (keyboard, mouse) = hooks_for(&hotkey);
        let state = Arc::new(HookState { matcher: Mutex::new(HotkeyMatcher::new(hotkey)), on_signal, recorder: Mutex::new(None), keys_down: Mutex::new(HashSet::new()) });
        *STATE.lock().map_err(|e| e.to_string())? = Some(state.clone());
        let hooks = HookThread::start(keyboard, mouse).inspect_err(|_| {
            if let Ok(mut s) = STATE.lock() {
                *s = None;
            }
        })?;
        log::info!("hotkey hooks running (keyboard {keyboard}, mouse {mouse})");
        Ok(HotkeyListener { state, hooks: Mutex::new(Some(hooks)) })
    }

    /// Changes the talk key. A take in progress ends first; the hooks change only when the new
    /// key needs a different set.
    pub fn set_hotkey(&self, hotkey: Hotkey) {
        let (keyboard, mouse) = hooks_for(&hotkey);
        let was_active = self.state.matcher.lock().map(|mut m| {
            let active = m.active;
            *m = HotkeyMatcher::new(hotkey);
            active
        });
        if was_active.unwrap_or(false) {
            (self.state.on_signal)(Signal::Release);
        }
        if let Ok(mut slot) = self.hooks.lock() {
            let same = slot.as_ref().is_some_and(|h| h.keyboard == keyboard && h.mouse == mouse);
            if !same {
                *slot = None;
                match HookThread::start(keyboard, mouse) {
                    Ok(h) => *slot = Some(h),
                    Err(e) => log::warn!("hotkey: {e}"),
                }
            }
        }
    }
}

impl HotkeyListener {
    /// Hands every event to `record` instead of the talk key until it is cleared with None. Both
    /// hooks go in while it listens, so any key or button can be recorded.
    pub fn set_recorder(&self, record: Option<OnRecord>) {
        let listening = record.is_some();
        if listening && self.state.matcher.lock().map(|mut m| std::mem::replace(&mut m.active, false)).unwrap_or(false) {
            (self.state.on_signal)(Signal::Release);
        }
        if let Ok(mut r) = self.state.recorder.lock() {
            *r = record;
        }
        let (keyboard, mouse) = if listening { (true, true) } else { self.state.matcher.lock().map(|m| hooks_for(&m.hotkey)).unwrap_or((true, false)) };
        if let Ok(mut slot) = self.hooks.lock() {
            if !slot.as_ref().is_some_and(|h| h.keyboard == keyboard && h.mouse == mouse) {
                *slot = None;
                match HookThread::start(keyboard, mouse) {
                    Ok(h) => *slot = Some(h),
                    Err(e) => log::warn!("hotkey: {e}"),
                }
            }
        }
    }
}

impl Drop for HotkeyListener {
    fn drop(&mut self) {
        if let Ok(mut slot) = self.hooks.lock() {
            *slot = None;
        }
        if self.state.matcher.lock().map(|m| m.active).unwrap_or(false) {
            (self.state.on_signal)(Signal::Release);
        }
        if let Ok(mut s) = STATE.lock() {
            if s.as_ref().is_some_and(|c| Arc::ptr_eq(c, &self.state)) {
                *s = None;
            }
        }
    }
}
