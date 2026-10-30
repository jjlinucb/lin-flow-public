//! Spoken commands. A take that starts with the wake word is handed to a program instead of
//! being pasted: "Zap, open my notes" runs `run` with "open my notes" as its last argument.
//!
//! It is off unless `command.json` sits in the data folder:
//!
//! ```json
//! {"word": "Zap", "run": ["/opt/homebrew/bin/python3.11", "-m", "zap", "do"], "cwd": "/some/folder", "env": {"KEY": "value"}}
//! ```
//!
//! `heard_as` lists what the engine writes when it mishears the word, such as `["ease app"]` for
//! "Zap" through AirPods; each counts as the word. `cwd`, `env` and `heard_as` are optional. Give `run` a full path: an app started at login has a short PATH.
//! The file is read on every take, so a change needs no restart.

use serde::Deserialize;
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};
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
    #[serde(default)]
    pub heard_as: Vec<String>,
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

    /// What follows the word, or one of its mishearings, at the start of the take.
    pub fn command_in(&self, text: &str) -> Option<String> {
        spoken_command(text, &self.word).or_else(|| self.heard_as.iter().find_map(|p| after_phrase(text, p)))
    }

    /// Starts the program with the command as its last argument and returns at once. Each line
    /// the program prints is passed to `show` as it comes, so John sees each step. When the
    /// program ends, `show` gets its last line again with `Done`, or `Failed` if it exited badly.
    pub fn start(&self, command: &str, show: impl Fn(&str, Progress) + Send + 'static) -> std::io::Result<()> {
        let mut c = Command::new(&self.run[0]);
        c.args(&self.run[1..]).arg(command).envs(&self.env);
        c.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
        if let Some(dir) = &self.cwd {
            c.current_dir(dir);
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = c.spawn()?;
        let out = child.stdout.take();
        // Read its lines, then reap it so it never lingers as a zombie, and log a failure.
        std::thread::spawn(move || {
            let mut last = String::new();
            if let Some(out) = out {
                for line in BufReader::new(out).lines().map_while(Result::ok) {
                    let line = line.trim();
                    if !line.is_empty() {
                        show(line, Progress::Working);
                        last = line.to_string();
                    }
                }
            }
            let ok = match child.wait() {
                Ok(status) if !status.success() => {
                    log::warn!("command: the program ended with {status}");
                    false
                }
                Err(e) => {
                    log::warn!("command: {e}");
                    false
                }
                Ok(_) => true,
            };
            if ok && !last.is_empty() {
                show(&last, Progress::Done);
            } else if !ok {
                let line = if last.is_empty() { "It stopped with an error.".to_string() } else { format!("{last} Then it stopped with an error.") };
                show(&line, Progress::Failed);
            }
        });
        Ok(())
    }
}

/// Where a command is when `Hook::start` shows a line.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Progress {
    Working,
    Done,
    Failed,
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

/// What follows `phrase` at the start of `text`, compared by letters word by word, after an
/// optional "Hey" or "OK".
fn after_phrase(text: &str, phrase: &str) -> Option<String> {
    let want: Vec<String> = phrase.split_whitespace().map(letters).filter(|w| !w.is_empty()).collect();
    if want.is_empty() {
        return None;
    }
    let mut starts = vec![text.trim_start()];
    let (first, after) = split_word(text.trim_start());
    if matches!(letters(first).as_str(), "hey" | "ok" | "okay" | "hi") {
        starts.push(after.trim_start_matches(|c: char| c.is_whitespace() || ",.".contains(c)));
    }
    for start in starts {
        let mut rest = start;
        let mut ok = true;
        for w in &want {
            let (got, after) = split_word(rest.trim_start());
            if letters(got) != *w {
                ok = false;
                break;
            }
            rest = after;
        }
        if ok {
            let command = rest.trim_start_matches(|c: char| c.is_whitespace() || ",.:;!?-".contains(c)).trim_end();
            return (!command.is_empty()).then(|| command.to_string());
        }
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
    fn a_known_mishearing_counts_as_the_word() {
        let hook = Hook { word: "Zap".into(), run: vec!["x".into()], cwd: None, env: BTreeMap::new(),
                          heard_as: vec!["ease app".into(), "is app".into()] };
        assert_eq!(hook.command_in("Ease app connect to my work laptop.").as_deref(), Some("connect to my work laptop."));
        assert_eq!(hook.command_in("Hey, is app, open Notes").as_deref(), Some("open Notes"));
        assert_eq!(hook.command_in("Zap, open Notes").as_deref(), Some("open Notes"));
        assert_eq!(hook.command_in("Ease application of the rule"), None);
        assert_eq!(hook.command_in("Please ease app pressure"), None);
        assert_eq!(hook.command_in("Ease app."), None, "the phrase alone is not a command");
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

    #[cfg(unix)]
    #[test]
    fn each_printed_line_is_shown_then_done() {
        let hook = Hook { word: "Zap".into(), run: vec!["/bin/sh".into(), "-c".into(), "echo one; echo; echo two; exit $0".into()],
                          cwd: None, env: BTreeMap::new(), heard_as: vec![] };
        for (code, last) in [("0", Progress::Done), ("3", Progress::Failed)] {
            let (tx, rx) = std::sync::mpsc::channel();
            hook.start(code, move |line, p| tx.send((line.to_string(), p)).unwrap()).unwrap();
            let got: Vec<_> = rx.iter().collect();
            assert_eq!(got, vec![("one".into(), Progress::Working), ("two".into(), Progress::Working), (if last == Progress::Done { "two".into() } else { "two Then it stopped with an error.".into() }, last)]);
        }
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
