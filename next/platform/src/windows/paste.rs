//! Puts text into the focused field by way of the clipboard and Ctrl+V, then puts John's
//! clipboard back. Typing with SendInput a character at a time is slow for a long dictation,
//! loses characters in apps that throttle input and breaks on anything with an IME.
//!
//! The dictation is marked as something not to keep: Windows Clipboard History (Win+V), Cloud
//! Clipboard and clipboard managers each honour one of the three formats below, the same intent
//! as the Mac's current-host-only and transient markers. John's own clipboard goes back with
//! every format it held, images and files included, and unmarked, because it is his.

use std::time::Duration;
use windows::core::w;
use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL};
use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData, GetClipboardSequenceNumber, OpenClipboard, RegisterClipboardFormatW, SetClipboardData};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, VIRTUAL_KEY, VK_CONTROL, VK_V};

const CF_UNICODETEXT: u32 = 13;

/// Formats whose data is a GDI or private handle rather than memory, which cannot be copied
/// byte for byte. Windows makes CF_BITMAP again from the CF_DIB that is kept.
fn is_handle_format(format: u32) -> bool {
    matches!(format, 2 | 3 | 9 | 14 | 0x80 | 0x82 | 0x83 | 0x8E) || (0x200..=0x3FF).contains(&format)
}

/// The most of John's clipboard worth carrying back, past which only its text is.
const SNAPSHOT_LIMIT: usize = 64 << 20;

struct Clipboard;

impl Clipboard {
    /// Opens the clipboard, retrying while another app holds it.
    fn open() -> Option<Clipboard> {
        for _ in 0..10 {
            if unsafe { OpenClipboard(None) }.is_ok() {
                return Some(Clipboard);
            }
            std::thread::sleep(Duration::from_millis(15));
        }
        log::info!("paste: the clipboard stayed busy");
        None
    }
}

impl Drop for Clipboard {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseClipboard();
        }
    }
}

fn read_global(handle: HANDLE) -> Option<Vec<u8>> {
    let global = HGLOBAL(handle.0);
    unsafe {
        let size = GlobalSize(global);
        let ptr = GlobalLock(global) as *const u8;
        if ptr.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(ptr, size).to_vec();
        let _ = GlobalUnlock(global);
        Some(bytes)
    }
}

fn set_bytes(format: u32, bytes: &[u8]) -> bool {
    unsafe {
        let Ok(global) = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1)) else { return false };
        let ptr = GlobalLock(global) as *mut u8;
        if ptr.is_null() {
            let _ = GlobalFree(Some(global));
            return false;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
        let _ = GlobalUnlock(global);
        // Once set, the clipboard owns the memory; on failure it is still ours to free.
        if SetClipboardData(format, Some(HANDLE(global.0))).is_err() {
            let _ = GlobalFree(Some(global));
            return false;
        }
        true
    }
}

fn utf16z(text: &str) -> Vec<u8> {
    text.encode_utf16().chain(std::iter::once(0)).flat_map(|u| u.to_le_bytes()).collect()
}

type Snapshot = Vec<(u32, Vec<u8>)>;

/// Every format the clipboard holds that is memory, or only its text when the whole would be
/// too large to carry.
fn snapshot() -> Snapshot {
    let Some(_open) = Clipboard::open() else { return vec![] };
    let mut out = Vec::new();
    let mut total = 0usize;
    let mut format = 0u32;
    loop {
        format = unsafe { EnumClipboardFormats(format) };
        if format == 0 {
            break;
        }
        if is_handle_format(format) {
            continue;
        }
        let Ok(handle) = (unsafe { GetClipboardData(format) }) else { continue };
        if let Some(bytes) = read_global(handle) {
            total += bytes.len();
            out.push((format, bytes));
        }
        if total > SNAPSHOT_LIMIT {
            log::info!("paste: clipboard over {} MB, keeping its text only", SNAPSHOT_LIMIT >> 20);
            out.retain(|(f, _)| *f == CF_UNICODETEXT);
            break;
        }
    }
    out
}

fn restore(snap: &Snapshot) {
    let Some(_open) = Clipboard::open() else { return };
    unsafe {
        let _ = EmptyClipboard();
    }
    for (format, bytes) in snap {
        set_bytes(*format, bytes);
    }
}

/// Puts `text` on the clipboard marked for history, cloud sync and clipboard managers to skip.
/// Returns the sequence number it left behind.
fn write_transient(text: &str) -> Option<u32> {
    let _open = Clipboard::open()?;
    unsafe {
        let _ = EmptyClipboard();
        if !set_bytes(CF_UNICODETEXT, &utf16z(text)) {
            return None;
        }
        let exclude = RegisterClipboardFormatW(w!("ExcludeClipboardContentFromMonitorProcessing"));
        let history = RegisterClipboardFormatW(w!("CanIncludeInClipboardHistory"));
        let cloud = RegisterClipboardFormatW(w!("CanUploadToCloudClipboard"));
        if exclude != 0 {
            set_bytes(exclude, &[0]);
        }
        if history != 0 {
            set_bytes(history, &0u32.to_le_bytes());
        }
        if cloud != 0 {
            set_bytes(cloud, &0u32.to_le_bytes());
        }
    }
    drop(_open);
    Some(unsafe { GetClipboardSequenceNumber() })
}

fn key(vk: VIRTUAL_KEY, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) }, time: 0, dwExtraInfo: 0 } },
    }
}

/// With hold-to-talk the talk key is often still down when the paste goes out, and a held Alt
/// or Shift turns Ctrl+V into something else. Their key-ups go first.
fn release_modifiers() {
    for vk in [0x11u16, 0xA2, 0xA3, 0x12, 0xA4, 0xA5, 0x10, 0xA0, 0xA1] {
        if (unsafe { GetAsyncKeyState(vk as i32) } as u16) & 0x8000 != 0 {
            unsafe { SendInput(&[key(VIRTUAL_KEY(vk), true)], std::mem::size_of::<INPUT>() as i32) };
        }
    }
}

fn control_v() {
    let inputs = [key(VK_CONTROL, false), key(VK_V, false), key(VK_V, true), key(VK_CONTROL, true)];
    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent as usize != inputs.len() {
        log::info!("paste: SendInput sent {sent} of {} events", inputs.len());
    }
}

/// Pastes `text` and puts John's clipboard back after `how.restore_after`, unless something else
/// was copied in the meantime: clobbering that would be far worse than losing a restore. Windows
/// pastes with Ctrl+V everywhere, so only the timings of a remote app apply.
pub fn paste(text: &str, how: linflow_core::remote::Paste) {
    if text.is_empty() {
        return;
    }
    let snap = snapshot();
    let Some(ours) = write_transient(text) else {
        log::info!("paste abandoned: the clipboard could not be set");
        return;
    };
    if !how.wait.is_zero() {
        std::thread::sleep(how.wait);
    }
    release_modifiers();
    control_v();
    if snap.is_empty() {
        return;
    }
    let restore_after = how.restore_after;
    std::thread::spawn(move || {
        std::thread::sleep(restore_after);
        if unsafe { GetClipboardSequenceNumber() } == ours {
            restore(&snap);
        }
    });
}

/// Puts text on the clipboard the ordinary way: John asked to copy it, so it is his to keep.
pub fn copy(text: &str) {
    let Some(_open) = Clipboard::open() else { return };
    unsafe {
        let _ = EmptyClipboard();
    }
    set_bytes(CF_UNICODETEXT, &utf16z(text));
}

/// What the clipboard holds as text.
pub fn clipboard_text() -> Option<String> {
    let _open = Clipboard::open()?;
    let handle = unsafe { GetClipboardData(CF_UNICODETEXT) }.ok()?;
    let bytes = read_global(handle)?;
    let units: Vec<u16> = bytes.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).take_while(|&u| u != 0).collect();
    Some(String::from_utf16_lossy(&units))
}
