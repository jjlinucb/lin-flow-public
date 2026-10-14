//! Windows: low-level hooks for the talk key, the clipboard and SendInput for paste, UI
//! Automation for the readback, WASAPI loopback for the call's audio, and the capability access
//! store for the apps holding the microphone.

pub mod audio;
pub mod hotkey;
pub mod paste;
pub mod uia;

use crate::App;
use windows::core::PWSTR;
use windows::Win32::Foundation::CloseHandle;
use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

pub use audio::{keep_awake, mic_users, AwakeGuard, SystemAudio};
pub use hotkey::HotkeyListener;
pub use paste::{clipboard_text, copy, paste};
pub use uia::{Field, FieldReader};

/// Windows asks nothing of a low-level hook or UI Automation, so there is nothing to grant.
pub fn trusted(_prompt: bool) -> bool {
    true
}

/// The executable behind a process, by its full path.
fn image_path(pid: u32) -> Option<String> {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(process);
        ok.then(|| String::from_utf16_lossy(&buf[..len as usize]))
    }
}

/// The app that owns the window in front, which is the one a paste goes to.
pub fn frontmost_app() -> Option<App> {
    let window = unsafe { GetForegroundWindow() };
    if window.is_invalid() {
        return None;
    }
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(window, Some(&mut pid)) };
    if pid == 0 {
        return None;
    }
    let path = image_path(pid).unwrap_or_default();
    let file = path.rsplit('\\').next().unwrap_or("").to_string();
    let name = file.rsplit_once('.').map(|(stem, _)| stem.to_string()).unwrap_or_else(|| file.clone());
    Some(App { pid, id: file.to_lowercase(), name })
}
