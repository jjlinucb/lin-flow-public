//! Spoken commands. A take that starts with the wake word is handed to a program instead of
//! being pasted: "Zap, open my notes" runs `run` with "open my notes" as its last argument.
//!
//! It is off unless `command.json` sits in the data folder:
//!
//! ```json
//! {"word": "Zap", "run": ["/opt/homebrew/bin/python3.11", "-m", "zap", "do"], "cwd": "/some/folder", "env": {"KEY": "value"}}
//! ```
//!
//! `cwd` and `env` are optional. Give `run` a full path: an app started at login has a short PATH.
//! The file is read on every take, so a change needs no restart.

use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub const FILE: &str = "command.json";

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Hook {
    pub word: String,
    pub run: Vec<String>,
    #[serde(default)]
    pub cwd: Option<PathBuf>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
}

impl Hook {
    /// The hook in `data_dir`, or None when there is none or it cannot be read.
    pub fn load(data_dir: &Path) -> Option<Hook> {
        let text = std::fs::read_to_string(data_dir.join(FILE)).ok()?;
        match serde_json::from_str::<Hook>(&text) {
            Ok(h) if !h.word.trim().is_empty() && !h.run.is_empty() => Some(h),
            Ok(_) => None,
            Err(e) => {
                log::warn!("{FILE}: {e}");
                None
            }
        }
    }

    /// Starts the program with the command as its last argument and returns at once.
    pub fn start(&self, command: &str) -> std::io::Result<()> {
        let mut c = Command::new(&self.run[0]);
        c.args(&self.run[1..]).arg(command).envs(&self.env);
        c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        if let Some(dir) = &self.cwd {
            c.current_dir(dir);
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = c.spawn()?;
        // Reap it when it ends so it never lingers as a zombie, and log a failure.
        std::thread::spawn(move || match child.wait() {
            Ok(status) if !status.success() => log::warn!("command: the program ended with {status}"),
            Err(e) => log::warn!("command: {e}"),
            Ok(_) => {}
        });
        Ok(())
    }
}

/// What follows the wake word, or None when the take does not start with it. "Hey" or "OK" may
/// come first, and the engine's spellings with a doubled last letter ("Zapp") count.
pub fn spoken_command(text: &str, word: &str) -> Option<String> {
    let want = letters(word);
    if want.is_empty() {
        return None;
    }
    let mut rest = text.trim_start();
    for _ in 0..2 {
        let (first, after) = split_word(rest);
        let got = letters(first);
        let doubled = got.chars().count() == want.chars().count() + 1
            && got.starts_with(&want)
            && got.chars().last() == want.chars().last();
        if got == want || doubled {
            let command = after.trim_start_matches(|c: char| c.is_whitespace() || ",.:;!?-".contains(c)).trim_end();
            return (!command.is_empty()).then(|| command.to_string());
        }
        if !matches!(got.as_str(), "hey" | "ok" | "okay" | "hi") {
            return None;
        }
        rest = after.trim_start_matches(|c: char| c.is_whitespace() || ",.".contains(c));
    }
    None
}

fn split_word(s: &str) -> (&str, &str) {
    match s.find(char::is_whitespace) {
        Some(i) => (&s[..i], &s[i..]),
        None => (s, ""),
    }
}

fn letters(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_wake_word_starts_a_command() {
        assert_eq!(spoken_command("Zap, connect me to my work laptop.", "Zap").as_deref(), Some("connect me to my work laptop."));
        assert_eq!(spoken_command("zap open my notes", "Zap").as_deref(), Some("open my notes"));
        assert_eq!(spoken_command("Zapp. What's on today?", "Zap").as_deref(), Some("What's on today?"));
        assert_eq!(spoken_command("Hey Zap, do not disturb on", "Zap").as_deref(), Some("do not disturb on"));
        assert_eq!(spoken_command("Okay, Zap: quit Slack", "Zap").as_deref(), Some("quit Slack"));
    }

    #[test]
    fn other_takes_are_dictation() {
        assert_eq!(spoken_command("The zap went through the wire.", "Zap"), None);
        assert_eq!(spoken_command("Zapping the bugs today", "Zap"), None);
        assert_eq!(spoken_command("Hey team, Zap is down", "Zap"), None);
        assert_eq!(spoken_command("Zap.", "Zap"), None, "the word alone is not a command");
        assert_eq!(spoken_command("Zap open it", ""), None);
        assert_eq!(spoken_command("Caféé open it", "Café").as_deref(), Some("open it"), "letters, not bytes");
    }

    #[test]
    fn no_file_means_off() {
        let dir = std::env::temp_dir().join(format!("linflow-command-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        assert_eq!(Hook::load(&dir), None);
        std::fs::write(dir.join(FILE), r#"{"word": "Zap", "run": ["/bin/echo"]}"#).unwrap();
        assert_eq!(Hook::load(&dir).map(|h| h.word), Some("Zap".to_string()));
        std::fs::write(dir.join(FILE), r#"{"word": "", "run": ["/bin/echo"]}"#).unwrap();
        assert_eq!(Hook::load(&dir), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
