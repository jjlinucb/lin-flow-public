//! Remote desktop apps. A dictation pasted into Windows App (a remote session on a Windows
//! computer) has to arrive as Control+V pressed the long way, real Control key-down, V,
//! Control key-up, because the remote side follows modifier keys by their own events and a
//! V that only carries the Command flag reaches it as a bare "v". The remote clipboard also
//! syncs on its own timer and fetches the text only when the remote app pastes, so the paste
//! waits for the sync first and John's clipboard goes back later than for a local app.
//!
//! Windows App is built in. Others (Parsec, a VNC viewer, Jump Desktop) are added by bundle id
//! in `remote-apps.txt` in the data folder, one per line, with `#` comments. A number after the
//! id is the wait in milliseconds before the paste, for a slow connection:
//!
//! ```text
//! tv.parsec.www
//! com.realvnc.vncviewer 600
//! ```
//!
//! The file is read on every paste, so a change needs no restart.

use std::path::Path;
use std::time::Duration;

pub const FILE: &str = "remote-apps.txt";

/// Windows App, which was Microsoft Remote Desktop.
pub const BUILT_IN: [&str; 1] = ["com.microsoft.rdc.macos"];

/// How long a local paste leaves the dictation on the clipboard before John's own goes back.
pub const LOCAL_RESTORE: Duration = Duration::from_millis(400);
/// How long a remote app gets to notice the new clipboard and send it across before the paste.
pub const REMOTE_WAIT: Duration = Duration::from_millis(300);
/// A remote app reads the clipboard when the far side asks for it, a network round trip after
/// the paste, so the dictation stays this long.
pub const REMOTE_RESTORE: Duration = Duration::from_secs(3);

/// How to paste into the app in front.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Paste {
    /// A remote desktop: Control+V with real key events instead of Command+V.
    pub remote: bool,
    /// Between putting the text on the clipboard and pressing the paste key.
    pub wait: Duration,
    /// Between pressing the paste key and putting John's clipboard back.
    pub restore_after: Duration,
}

impl Paste {
    pub const LOCAL: Paste = Paste { remote: false, wait: Duration::ZERO, restore_after: LOCAL_RESTORE };
    pub const REMOTE: Paste = Paste { remote: true, wait: REMOTE_WAIT, restore_after: REMOTE_RESTORE };
}

/// The remote desktop apps: the built-in ones and those in `remote-apps.txt`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteApps {
    /// Lowercase bundle id, and its own wait if the file gave one.
    apps: Vec<(String, Option<Duration>)>,
}

impl RemoteApps {
    /// The built-in apps plus the lines of a `remote-apps.txt`.
    pub fn parse(text: &str) -> RemoteApps {
        let mut apps: Vec<(String, Option<Duration>)> = BUILT_IN.iter().map(|id| (id.to_string(), None)).collect();
        for line in text.lines() {
            let line = line.split('#').next().unwrap_or("").trim();
            let mut words = line.split_whitespace();
            let Some(id) = words.next() else { continue };
            let wait = words.next().and_then(|ms| ms.parse::<u64>().ok()).map(|ms| Duration::from_millis(ms.min(5000)));
            let id = id.to_lowercase();
            apps.retain(|(have, _)| *have != id);
            apps.push((id, wait));
        }
        RemoteApps { apps }
    }

    /// The remote apps for the data folder `data_dir`. A missing file leaves the built-in ones.
    pub fn load(data_dir: &Path) -> RemoteApps {
        RemoteApps::parse(&std::fs::read_to_string(data_dir.join(FILE)).unwrap_or_default())
    }

    /// How to paste into the app with bundle id `app_id`.
    pub fn paste_for(&self, app_id: Option<&str>) -> Paste {
        let Some(id) = app_id.map(str::to_lowercase) else { return Paste::LOCAL };
        match self.apps.iter().find(|(have, _)| *have == id) {
            Some((_, wait)) => Paste { wait: wait.unwrap_or(REMOTE_WAIT), ..Paste::REMOTE },
            None => Paste::LOCAL,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_app_is_remote_without_a_file() {
        let apps = RemoteApps::parse("");
        assert_eq!(apps.paste_for(Some("com.microsoft.rdc.macos")), Paste::REMOTE);
        assert_eq!(apps.paste_for(Some("COM.Microsoft.RDC.macos")), Paste::REMOTE);
    }

    #[test]
    fn every_other_app_keeps_the_local_paste() {
        let apps = RemoteApps::parse("");
        for id in ["com.apple.TextEdit", "com.google.Chrome", "com.microsoft.rdc.macos.helper", ""] {
            assert_eq!(apps.paste_for(Some(id)), Paste::LOCAL, "{id}");
        }
        assert_eq!(apps.paste_for(None), Paste::LOCAL);
    }

    #[test]
    fn the_file_adds_apps_with_their_own_wait() {
        let apps = RemoteApps::parse("# remote desktops\n\ntv.parsec.www\n  com.realvnc.vncviewer 600  # slow link\ncom.example.bad abc\n");
        assert_eq!(apps.paste_for(Some("tv.parsec.www")), Paste::REMOTE);
        assert_eq!(apps.paste_for(Some("com.realvnc.vncviewer")).wait, Duration::from_millis(600));
        assert!(apps.paste_for(Some("com.realvnc.vncviewer")).remote);
        // A wait that is not a number falls back to the default.
        assert_eq!(apps.paste_for(Some("com.example.bad")), Paste::REMOTE);
        assert_eq!(apps.paste_for(Some("com.microsoft.rdc.macos")), Paste::REMOTE);
    }

    #[test]
    fn the_file_can_change_a_built_in_wait_and_caps_it() {
        let apps = RemoteApps::parse("com.microsoft.rdc.macos 900\nslow.app 60000");
        assert_eq!(apps.paste_for(Some("com.microsoft.rdc.macos")).wait, Duration::from_millis(900));
        assert_eq!(apps.paste_for(Some("slow.app")).wait, Duration::from_secs(5));
    }

    #[test]
    fn load_reads_the_data_folder() {
        let dir = std::env::temp_dir().join(format!("linflow-remote-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(RemoteApps::load(&dir), RemoteApps::parse(""));
        std::fs::write(dir.join(FILE), "tv.parsec.www\n").unwrap();
        assert!(RemoteApps::load(&dir).paste_for(Some("tv.parsec.www")).remote);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
