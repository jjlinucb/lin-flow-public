//! When the operating system's audio service wedges, nothing on the machine can open a
//! microphone. On 2026-09-30 the Mac's coreaudiod did, after an input switch during a meeting
//! note: first 9 s of digital zeros from the built-in mic, then every press failed with
//! kAudioHardwareNotRunningError, and a fresh engine per take did not help. Restarting the
//! service fixed it at once. Lin Flow cannot do that itself, since it needs John's password, so
//! it recognises the state and hands him a script that does.

use std::path::{Path, PathBuf};

/// 'stop' on the Mac: the audio hardware is not running.
pub const MAC_NOT_RUNNING: i64 = 1_937_010_544;
/// AUDCLNT_E_SERVICE_NOT_RUNNING on Windows.
pub const WINDOWS_SERVICE_NOT_RUNNING: i64 = 0x8889_0010;

/// Whether an error code from opening the microphone means the audio service is stuck.
pub fn is_stuck(code: i64) -> bool {
    code == MAC_NOT_RUNNING || code == WINDOWS_SERVICE_NOT_RUNNING || code == WINDOWS_SERVICE_NOT_RUNNING - (1 << 32)
}

/// Counts takes in a row that came back as pure digital silence. One can be a muted headset;
/// two in a row, with the rest of the app working, is how the wedge began. Only takes long
/// enough to judge count: a tap of the key records nothing whatever the hardware does.
#[derive(Clone, Copy, Debug, Default)]
pub struct SilentStreak {
    pub count: u32,
}

impl SilentStreak {
    /// True on the take that makes the streak long enough to call it stuck.
    pub fn record(&mut self, dead: bool) -> bool {
        self.count = if dead { self.count + 1 } else { 0 };
        self.count == 2
    }
}

pub const MAC_SCRIPT: &str = "#!/bin/bash
echo \"Restarting the Mac's audio for Lin Flow.\"
echo \"Type your Mac password and press Enter. It stays hidden as you type.\"
if sudo killall coreaudiod; then
  echo \"Done. Press the talk key and try again. You can close this window.\"
else
  echo \"That did not work. Restarting the Mac fixes it too.\"
fi
";

pub const WINDOWS_SCRIPT: &str = "@echo off\r
echo Restarting Windows audio for Lin Flow. Choose Yes when Windows asks.\r
powershell -NoProfile -Command \"Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -Command Restart-Service -Name Audiosrv -Force'\"\r
echo Done. Press the talk key and try again. You can close this window.\r
pause\r
";

/// Writes the script where John can open it: `Restart Mac audio.command`, which Terminal runs,
/// or `Restart Windows audio.cmd`.
pub fn write_script(folder: &Path, windows: bool) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(folder)?;
    let (name, text) = if windows { ("Restart Windows audio.cmd", WINDOWS_SCRIPT) } else { ("Restart Mac audio.command", MAC_SCRIPT) };
    let path = folder.join(name);
    std::fs::write(&path, text)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))?;
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_dead_takes_in_a_row() {
        let mut s = SilentStreak::default();
        assert!(!s.record(true));
        assert!(s.record(true));
        assert!(!s.record(true), "said once per streak");
        assert!(!s.record(false));
        assert!(is_stuck(1_937_010_544) && is_stuck(0x8889_0010_i64 - (1 << 32)) && !is_stuck(-50));
    }

    #[test]
    fn the_script_is_runnable() {
        let dir = crate::history::tests::tempdir();
        let p = write_script(&dir, false).unwrap();
        assert!(std::fs::read_to_string(&p).unwrap().contains("killall coreaudiod"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o755);
        }
        let _ = std::fs::remove_dir_all(dir);
    }
}
