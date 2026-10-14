//! Windows audio around the capture module: the call's side through WASAPI loopback, the apps
//! holding the microphone from the capability access store, and staying awake through a meeting.

use crate::mic::{Microphone, Source};
use crate::OnChunk;
use windows::core::{w, PCWSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, ERROR_SUCCESS, HANDLE};
use windows::Win32::System::Power::{PowerClearRequest, PowerCreateRequest, PowerRequestSystemRequired, PowerSetRequest};
use windows::Win32::System::Registry::{RegCloseKey, RegEnumKeyExW, RegGetValueW, RegOpenKeyExW, HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_READ, RRF_RT_REG_QWORD};
use windows::Win32::System::Threading::{POWER_REQUEST_CONTEXT_SIMPLE_STRING, REASON_CONTEXT, REASON_CONTEXT_0};

/// What the default output plays, the others on a call, as 16 kHz mono.
pub struct SystemAudio {
    _capture: Microphone,
    pub sample_rate: f64,
    pub output_name: String,
}

impl SystemAudio {
    pub fn start(on_chunk: OnChunk) -> Result<SystemAudio, String> {
        let capture = Microphone::start_source(Source::Loopback, on_chunk)?;
        Ok(SystemAudio { sample_rate: capture.sample_rate as f64, output_name: capture.device.clone(), _capture: capture })
    }

    /// What the stream reported going wrong, such as the output device going away.
    pub fn error(&self) -> Option<String> {
        self._capture.error()
    }
}

const MICROPHONE_STORE: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone");

struct Key(HKEY);

impl Key {
    fn open(parent: HKEY, path: PCWSTR) -> Option<Key> {
        let mut key = HKEY::default();
        let err = unsafe { RegOpenKeyExW(parent, path, None, KEY_READ, &mut key) };
        (err == ERROR_SUCCESS).then_some(Key(key))
    }

    fn subkeys(&self) -> Vec<String> {
        let mut out = Vec::new();
        for i in 0.. {
            let mut name = [0u16; 512];
            let mut len = name.len() as u32;
            let err = unsafe { RegEnumKeyExW(self.0, i, Some(PWSTR(name.as_mut_ptr())), &mut len, None, None, None, None) };
            if err != ERROR_SUCCESS {
                break;
            }
            out.push(String::from_utf16_lossy(&name[..len as usize]));
        }
        out
    }

    fn qword(&self, subkey: &str, value: PCWSTR) -> Option<u64> {
        let sub: Vec<u16> = subkey.encode_utf16().chain(std::iter::once(0)).collect();
        let mut data = 0u64;
        let mut size = 8u32;
        let err = unsafe { RegGetValueW(self.0, PCWSTR(sub.as_ptr()), value, RRF_RT_REG_QWORD, None, Some(&mut data as *mut u64 as *mut _), Some(&mut size)) };
        (err == ERROR_SUCCESS).then_some(data)
    }

    /// An app is on the microphone while its last use has a start and no stop.
    fn in_use(&self, subkey: &str) -> bool {
        self.qword(subkey, w!("LastUsedTimeStop")) == Some(0) && self.qword(subkey, w!("LastUsedTimeStart")).is_some_and(|t| t != 0)
    }
}

impl Drop for Key {
    fn drop(&mut self) {
        unsafe {
            let _ = RegCloseKey(self.0);
        }
    }
}

/// The id a store entry stands for: "C:#Program Files#Zoom#bin#Zoom.exe" is "zoom.exe", and a
/// packaged app's family name, "MSTeams_8wekyb3d8bbwe", is "msteams".
pub fn store_id(entry: &str, packaged: bool) -> String {
    let id = if packaged { entry.split('_').next().unwrap_or(entry) } else { entry.rsplit('#').next().unwrap_or(entry) };
    id.to_lowercase()
}

/// Apps holding the microphone right now, by lowercase executable name (or package name), not
/// counting this process.
pub fn mic_users() -> Vec<String> {
    let me = std::env::current_exe().ok().and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_lowercase()));
    let mut out: Vec<String> = Vec::new();
    for root in [HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE] {
        let Some(store) = Key::open(root, MICROPHONE_STORE) else { continue };
        for entry in store.subkeys() {
            if entry == "NonPackaged" {
                if let Some(non_packaged) = Key::open(store.0, w!("NonPackaged")) {
                    for app in non_packaged.subkeys() {
                        if non_packaged.in_use(&app) {
                            out.push(store_id(&app, false));
                        }
                    }
                }
            } else if store.in_use(&entry) {
                out.push(store_id(&entry, true));
            }
        }
    }
    out.retain(|id| Some(id) != me.as_ref());
    out.sort();
    out.dedup();
    out
}

/// Keeps the computer from sleeping while it lives: a meeting recording must not stop because
/// nobody touched the keyboard.
pub struct AwakeGuard(HANDLE);

unsafe impl Send for AwakeGuard {}

pub fn keep_awake(reason: &str) -> Option<AwakeGuard> {
    let mut text: Vec<u16> = reason.encode_utf16().chain(std::iter::once(0)).collect();
    let context = REASON_CONTEXT { Version: 0, Flags: POWER_REQUEST_CONTEXT_SIMPLE_STRING, Reason: REASON_CONTEXT_0 { SimpleReasonString: PWSTR(text.as_mut_ptr()) } };
    unsafe {
        let handle = PowerCreateRequest(&context).ok()?;
        if PowerSetRequest(handle, PowerRequestSystemRequired).is_err() {
            let _ = CloseHandle(handle);
            return None;
        }
        Some(AwakeGuard(handle))
    }
}

impl Drop for AwakeGuard {
    fn drop(&mut self) {
        unsafe {
            let _ = PowerClearRequest(self.0, PowerRequestSystemRequired);
            let _ = CloseHandle(self.0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::store_id;

    #[test]
    fn store_entries_name_the_app() {
        assert_eq!(store_id("C:#Program Files#Zoom#bin#Zoom.exe", false), "zoom.exe");
        assert_eq!(store_id("MSTeams_8wekyb3d8bbwe", true), "msteams");
    }
}
