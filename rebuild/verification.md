# Verification: how an agent alone knows each area is right

**Updated:** 2026-10-02. **Status:** in use, for John's review. The laws at the end need his
verdict, one by one.

Three kinds of check, strongest first:

1. **The oracle.** The installed Swift app is the definition of right. Scripts in `next/oracle`
   feed both apps the same inputs and compare every answer. John's own dictations and meetings
   are read in place and never printed or committed.
2. **Laws.** Things that must hold for every input, checked on generated input every run
   in `next/core/tests/laws.rs`.
3. **Tests and headless runs.** Unit tests, the TypeScript tests, the app's service run on a WAV
   file, and a click-through of every page against made-up data.

What none of these can reach is listed at the end: the parts that need a person at the computer.

## Every area and its check

| Area | Check | Last result |
|---|---|---|
| Text pipeline | `python3 next/oracle/oracle.py --history` | 98,252 inputs, 0 disagreements: 37,059 number runs, 59,944 random sentences, 1,249 of John's dictations with his dictionary (10-02) |
| Laws of the text pipeline and sync | `cargo test -p linflow-core --test laws`, and after a change to either, the same with `PROPTEST_CASES=30000` and `--release` | 18 pass. Three deep sweeps of 30,000 cases a law, clean (10-02) |
| Learning from edits | `python3 next/oracle/notes_oracle.py` covers the learner's ops. Unit tests in `core/src/learn.rs` | 0 disagreements |
| Notes: regions, echo, segmenter, running-notes checks, summary merge | `python3 next/oracle/notes_oracle.py --real` | 3,000 generated and 568 from John's meetings, 0 disagreements (10-02) |
| Shared dictionary and totals | `python3 next/oracle/sync_oracle.py` and the sync law | 20,000 requests, 0 disagreements. Law: 2,000 random histories on three computers (10-02) |
| Speech engines | `python3 next/oracle/engine_oracle.py` | 22 of 22 clips identical, including a 48 s joined clip |
| Engine speed | `next/target/release/linflow bench scripts/testdata/test.wav` | 0.15 s Parakeet, about 1.3 s Whisper turbo on the M1 Pro |
| Dictation end to end, no hardware | `linflow service-test scripts/testdata/test.wav` | Transcribed in 0.17 s, one history row, in a temp folder |
| The system edge, read only | `linflow platform-check` | Trust, frontmost app, microphone users, devices read on the Mac |
| The Windows build | `bash next/scripts/check-windows.sh`, then clippy with the same target | Compiles and lints clean |
| The Linux build, as CI runs it | `bash next/scripts/check-linux.sh` | Lints clean. Its first run found the service calling the microphone module Linux lacked (10-02) |
| Everything else in Rust | `cargo test --workspace`, `cargo clippy --workspace --all-targets` | 113 tests pass, the 18 laws among them, no warnings |
| The window | `npm --prefix next/app test` and `npm --prefix next/app run build` | 16 tests pass, types check |
| The window, by eye | Start `next-ui` from `.claude/launch.json`, open each page, compare with the Swift app | Every page clicked through on 10-02. Fixed: panes stopping short of the window, labels wrapping, two buttons hiding their errors |

## The laws

Each law is in John's words where he gave them, and in plain English otherwise. **Verdict** is his
to fill in: approve, or correct. A law with exceptions holds everywhere else, and each exception
has a test that pins what the apps do today. Every exception happens in the Swift app too,
checked with its `clean-batch`.

| | Law | Holds | Verdict |
|---|---|---|---|
| N1 | A number said in words is written as its digits: "three hundred forty five thousand six" is 345006 | Yes | |
| N2 | "one" stays a word unless it is counting something: "no one knows" keeps it, "one dollar" is 1 | Yes | |
| N3 | A number never says the same place twice: "eight hundred seven hundred" is 800 and 700 | With exception E1 | |
| N4 | A year said as two numbers is one number: "nineteen eighty four" is 1984. "twenty thirty" stays two | Yes | |
| C1 | A correction replaces whole words only: "cloud => Claude" leaves "clouds" and "cloud's" alone | Yes | |
| G1 | An ordinary English word never becomes a name. Its letters never change | With exception E2 | |
| L1 | The learner never binds an everyday word by itself. A name spelled another way is the one exception | Yes | |
| I1 | Cleaning a text twice gives the same result as cleaning it once | With exceptions E3 | |
| S1 | Every computer ends with the same dictionary after a sync, deletions included | Yes, after fix F1 | |

### Exceptions: John decides each

**E1. "two thousand two hundred one hundred" reads as 2000, 200 and 100.** It should be 2200 and
100. The reader looks ahead from the second "two", reads "two hundred one hundred" as 201
hundreds, and so starts a new number too early. Rare in speech. The fix is small: the look-ahead
should stop at its own repeated place. *Proposed: fix.*

**E2. "taurus" becomes "Tauris" when "Tauri" is in the dictionary.** A plural is matched by its
stem, and only the stem gets the English check: "tauru" is not a word and is one letter from
"Tauri". With John's real dictionary this changes 1 of the 25,915 English words ending in "s".
*Proposed: fix, by checking the whole word first.*

**E3. Five texts change when cleaned a second time.** Nothing in either app cleans a cleaned text
today, so none of these reach John unless that changes.

- A rule whose result contains its left side grows each time: "Lin => Lin Flow" turns "Lin Flow"
  into "Lin Flow Flow". *Proposed: the Dictionary warns when such a rule is added.*
- "um so" cleans to "So.", which is also what the engines write on silence, so a second pass
  removes it. *Proposed: leave.*
- "new um line" keeps its words, because removing the filler leaves two spaces inside the
  command. A second pass makes it a line break. *Proposed: fix, so the first pass does.*
- A month in lowercase at the start, as in "september thirtieth", keeps its words, and the capital added
  last makes a second pass write "September 30th". The engines write months capitalized.
  *Proposed: leave.*
- In "one a hundred dollars" the lone "one" stays a word. A second pass sees "One 100" and makes
  it 1. *Proposed: leave.*

### Fixed while writing the laws

**F1. A word deleted and added back in another spelling vanished.** "Café" typed, synced, deleted,
synced, then pasted back in its decomposed form went to a second row in the table, and the old
deletion won. Next now writes a change to the row the table already has for its entry. The
Swift and C# apps keep the old behavior until cut-over. The case is a test of its own,
`a_word_added_back_in_another_spelling_stays`.

## What only a person can check

These need someone at the computer: they press keys, speak, play a call, or answer a permission
prompt. Each is a box for whoever is there. On the Mac Next runs beside the installed app with
its own data folder and Right Option as its talk key, so the installed app keeps working
throughout.

**On the Mac, with John:**

- [ ] Launch Lin Flow Next. Grant Accessibility, Input Monitoring and the microphone
- [ ] Hold Right Option and dictate into TextEdit, Notes, Chrome, Slack and Terminal
- [ ] Copy an image first. After a dictation the image is still on the clipboard
- [ ] Fix a word in TextEdit within 15 s of a paste. A toast offers or learns the correction
- [ ] Drag the pill, quit, relaunch. It comes back where it was. It never takes focus
- [ ] Start a note during a Zoom call. Grant System Audio Recording. Both meters move
- [ ] Next offers to record when Zoom takes the microphone, and counts down when the call ends
- [ ] `kill -9` Next mid-meeting and relaunch. The note closes and its transcript is rebuilt
- [ ] Switch the output device mid-meeting. The call's side keeps recording

**On DESK-01 or LAPTOP-02:**

- [ ] Install from the NSIS build. WebView2 present or fetched
- [ ] Hold Right Alt and dictate into Notepad, Outlook, Teams and a browser
- [ ] Fix a word in Notepad within 15 s. UI Automation reads it back
- [ ] Record a Teams call with headphones. The loopback side records while nothing else plays
- [ ] The pill and toasts never take focus from the app being typed in
