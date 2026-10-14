# Lin Flow

Local, on-device dictation for macOS. Hold a key, talk, release, and the text lands in whatever app has focus. Nothing leaves the machine: no cloud, no account, no API bill. A self-built replacement for Wispr Flow, including its window: a searchable dictation history you can replay and copy from, a personal dictionary, and a meeting notetaker that transcribes both sides of a call live and summarizes it with Apple Intelligence.

Version 2 is a native Swift menu bar app built on [whisper.cpp](https://github.com/ggml-org/whisper.cpp). The same library runs two speech models, and you can switch between them from the menu:

| Engine | Model | 7.6 s test clip | Notes |
|---|---|---|---|
| Parakeet (default) | NVIDIA Parakeet TDT 0.6B v3, q8_0, 669 MB | 0.15 s | Top English accuracy, near-instant. Also handles 25 European languages. |
| Whisper | OpenAI large-v3-turbo, q5_0, 574 MB | 1.3 s | Use for Khmer, Chinese, Japanese and anything Parakeet does not cover. Primed with your glossary. |

Both numbers are steady-state inference on an M1 Pro, measured through the app's own engine wrapper. The old Python version (Parakeet via MLX plus a 3B Llama cleanup pass) took a similar time to transcribe but then spent several seconds in the LLM.

## What is in this repository

The repo holds three versions of the same app. They share file formats and most test cases.

| Folder | What it is | Status |
|---|---|---|
| `Package.swift`, `Sources/` | The macOS app in Swift. Everything below describes it. | The one in daily use |
| `windows/` | A C# port for Windows, built on the same whisper.cpp libraries | Works. See `windows/README-WINDOWS.md` |
| `next/` | A rebuild in Rust with a Tauri window, meant to replace both | In progress. The plan is in `rebuild/` |

A dictionary, history or notes folder written by one loads unchanged in the other two.

## Install

Built and run on **macOS 27**. Requirements: an Apple Silicon Mac on **macOS 26 or newer**, Homebrew, and either Xcode or the Command Line Tools. macOS 26 is a hard floor, not a preference: the app links Homebrew's whisper.cpp libraries in place, and those are built for macOS 26. Meeting summaries and transforms need Apple Intelligence turned on; everything else works without it.

```bash
brew install whisper-cpp
scripts/build_app.sh --install
```

That builds `dist/Lin Flow.app` and puts it in `/Applications`, quitting the copy already there and reopening the new one. The first build takes about a minute. Then:

1. Quit Wispr Flow if it is running. Both apps listen for the Fn key.
2. Launch Lin Flow from `/Applications`. macOS asks for Accessibility (to see the hotkey and to paste) and Microphone. Grant both, then relaunch if the pill still says it cannot see the keyboard. If you had version 1 installed, the grants carry over because the app is signed with the same identity.
3. On first launch the pill says "Loading parakeet..." for a few seconds. When it turns green and you hear the Glass sound, hold Fn and talk.

Lin Flow swallows the Fn key's own press and release, so the system Globe-key action (emoji picker, dictation) does not fire on every dictation and you can leave that setting alone. Fn combos such as Fn+arrow still work.

The default model is already on disk if you ran the build from this repo; otherwise the app downloads it (669 MB) on first launch and shows progress in the pill.

## Using it

Hold **Fn**, speak, release. The transcript is cleaned up and pasted into the focused app, followed by a space so the next dictation does not run into it. Your clipboard is put back the way it was, including images and files.

While it runs you see it in three places: the Dock (the L icon with the running dot, like Wispr Flow), the menu bar (a mic icon that turns red while recording), and the floating pill. The pill shows state (gray loading, green ready, red recording with a level meter, orange transcribing). Drag it anywhere; it remembers the spot. The mic button next to it is a click-and-hold alternative to the hotkey, and the X hides the pill (Show Floating Pill in the menu brings it back). If the microphone sends pure digital silence, a red toast names the device instead of pasting nothing. Clicking the pill, the menu bar mic, or right-clicking the Dock icon opens the menu:

- **Model**: switch between Parakeet and Whisper, or download other sizes.
- **Hold to Talk Key**: Fn (the default), Right Option, Right Command, Right Control or the middle mouse button. Record Another Key opens Settings, where Record takes any key, combination or extra mouse button: press it, let go, and that is the talk key. Escape cancels. A held mouse button talks without also clicking, and a quick click of it still clicks.
- **Language**: Whisper only. English, auto-detect, Khmer, Chinese, Spanish, French, German, Japanese, Korean.
- **Cleanup**: None, Light or Medium. Medium adds an Apple Intelligence rewrite for clarity, which takes several seconds. Light removes "um" and "uh", writes spoken numbers as digits ("twenty two" becomes 22, "a hundred forty" becomes 140, "nineteen eighty four" becomes 1984, and a run like "one two three" becomes "1 2 3"), snaps glossary near-misses to the right spelling, replaces em dashes and semicolons, fixes capitalization, puts the colon back in times the models write as "3 45 p.m.". It never rewrites an ordinary English word into a name ("cloud" stays "cloud" even though it is one letter from "Claude"); when the recognizer keeps producing a real word for a name you say, add a correction in the Dictionary.
- **Spoken Commands**: "new line", "new paragraph", "question mark", "exclamation mark". "Period" and "comma" are deliberately not commands since both models punctuate on their own and both words show up in real sentences.
- **Recent Dictations**: the last ten, click one to copy it. Useful when a paste landed in the wrong window.
- **Dictionary…**: opens the Dictionary section of the window. Its names live in `~/Library/Application Support/Lin Flow/vocab.txt`, one per line, and an edit made there by hand applies to the next dictation. Whisper is primed with the list so it spells names right the first time, and the cleanup pass fixes near-misses for both engines ("Linflow" and "Lend Flow" both become "Lin Flow").
- **Show in Dock**: off makes it a menu-bar-only app.
- **Launch at Login**.

Everything the app writes lives in `~/Library/Application Support/Lin Flow/` (models, `vocab.txt`, `replacements.txt`, `history.jsonl`, `recordings/`, `notes/`) and `~/Library/Logs/Lin Flow/app.log`.

## The window

Lin Flow opens its window at launch (turn that off in Settings). Closing the window hides it; the app keeps running in the Dock and menu bar, and clicking the Dock icon, the pill's menu, or "Open Lin Flow Window" brings it back. Four sections in the sidebar:

- **Dictation**: every dictation, grouped by day, with total words, words per minute and your day streak at the top. Search, select text straight off the page, or use the buttons on each row: play the recording, copy, transcribe again with the current model (handy after switching engines or fixing the dictionary), delete. Audio is kept for 30 days by default.
- **Dictionary**: the words list (names, products, jargon) that primes Whisper and drives the fuzzy fix-ups, plus corrections: "heard as" on the left, "should be" on the right, applied whole-word and case-insensitively to every dictation and meeting transcript.
- **Learning from your edits**: fix a word in the text Lin Flow pasted and it remembers. It reads the field back through Accessibility, works out whether the change was a mishearing rather than a change of mind, and adds the correction. Either automatically or as a suggestion you confirm, per the setting. Editing a dictation with the pencil in the Dictation list does the same and works in every app, including ones that expose nothing to Accessibility.
- **Snippets**: a phrase you say that expands into saved text. Say “my address” or “insert my address” and the address is what gets pasted, several lines if need be. Whole words, any capitalization, and a single token such as an email address sheds the sentence period so it lands clean in a form.
- **Style**: the cleanup level for every dictation, None, Light or Medium, shown as three cards with the same sample sentence run through each. Light is the instant rule-based pass. Medium adds Apple Intelligence's Clarity rewrite on this Mac, about ten seconds per dictation, so it is a choice, not the default. Below that, per-app rules: give Claude Code or a terminal the Agent prompt transform, give Slack none, and each dictation is rewritten for the app it lands in. The original text is kept and one click on the dictation undoes the rewrite.
- **Transforms**: the rewrite library. Six built in (Agent prompt, Clarity, Bullet list, Email, Formal, Casual), all editable, plus your own. Each has a Try it box so you can see what the model does with a sentence and how long it takes. Any past dictation can be rewritten with a transform from its row, with Undo.
- **Notetaker**: one note per meeting. Start recording when the call begins. Your microphone is transcribed as "You" and whatever your Mac is playing (the other people on the call) as "Others", each line timestamped, appearing a moment after each pause. Type your own notes alongside. When the meeting ends, Summarize writes a summary, decisions, action items and open questions on-device with Apple Intelligence; "Recap 5 min" gives you a few bullets on what you missed while it is still going. Copy the whole note as Markdown, save it, or open its folder. Each note is a folder under `notes/` with `transcript.jsonl`, `notes.md`, `summary.md`, `events.log` and the audio as WAV. The audio is the record: it is written as it arrives with a header that stays valid, so a crash or a force quit costs at most the last second, and the next launch closes the note and rebuilds its transcript. While the meeting runs, running notes appear in the pane every minute or so: a few bullets on what was just said, each stamped with its time, saved to `running-notes.md` as they are written. When a meeting ends the saved audio is transcribed whole, at the real pauses and with up to 28 s of context at a time, and that transcript replaces the live one (kept as `transcript-live.jsonl`); "Transcribe Again from the Recording" in the note's menu redoes it with whatever model is current, which is why the audio is kept. The Mac does not idle-sleep while a meeting records; the rest of the time Lin Flow lets it sleep as usual. Save Audio as MP3 in a note's menu mixes both sides into one file, your side leveled to the call's, and the file follows when you rename the note. When the call ends Lin Flow offers to stop, and stops by itself a minute later. Meetings go to the Trash after 14 days. In a shared room, or on a call through the speakers, both tracks hold every voice, so Lin Flow tells your voice from the others' with a speaker model (WeSpeaker's ResNet34, trained on VoxCeleb, CC BY 4.0, downloaded once from Hugging Face) and a voiceprint learned from your own dictations, kept in `voiceprint.json`. With headphones the tracks already say who spoke.
- **Settings**: hotkey, model, cleanup toggles, audio retention, whether to keep meeting audio, pill, Dock, sounds, open-at-launch.

The first time you record a meeting with system audio on, macOS asks for "System Audio Recording". No screen recording permission is involved; only audio is captured.

## Shared word totals

Optional and off by default. Turned on, the Dictation total counts every computer you dictate on instead of each one keeping its own. The day streak counts a day dictated anywhere, and words per minute stays per computer.

Only counts leave the machine: for each day, the computer's name, the date, and the words, dictations and seconds of audio on it. What you said, the audio, the dictionary and app names stay local. The counts go to one table in a Supabase project you own. Create it by running `scripts/sync-schema.sql` in that project's SQL editor, then put a `sync.env` file in the data folder:

```
SUPABASE_URL=https://<your project>.supabase.co
SUPABASE_KEY=<the project's publishable key>
DEVICE=<a name for this computer>
```

The app reads it at the next dictation. A secret key is refused. Settings > Shared totals shows what it last did, and Sync now sends and reads straight away. Delete `sync.env` to turn it off.

## Command line

The app binary doubles as a CLI. Alias it once:

```bash
alias linflow="/Applications/Lin Flow.app/Contents/MacOS/LinFlow"
```

```bash
linflow transcribe recording.m4a                # any format AVFoundation reads, cleaned output
linflow transcribe recording.wav --raw --model large-v3-turbo-q5_0 --lang km
linflow bench scripts/testdata/test.wav         # every installed model, warmed timings
linflow models                                  # installed and downloadable models
linflow download large-v3-turbo-q8_0
linflow clean "um so lend flow should uh work"  # cleanup pass only
linflow paste "text"                            # paste into the focused app the way dictation does
linflow selftest                                # 528 checks: cleanup, matcher, learning, notes, audio helpers, shared totals
linflow notes-test recording.wav                # stream a file through the live meeting transcriber
linflow notes-transcribe <note id> --save       # rebuild a note's transcript from its saved audio
linflow notes-repair [file.wav]                 # fix a WAV cut short by a crash, or close unfinished notes
linflow summarize notes/<id>/transcript.jsonl   # Apple Intelligence summary of a transcript (or any .txt)
linflow running-notes-test notes/<id>/transcript.jsonl   # replay a meeting through the running-notes pass, a minute at a time
linflow transform agent "look at the dashboard model and fix the summary painting under the wrong note"   # rewrite with a transform
linflow transforms                              # the transforms and which apps use them
linflow expand "insert my address"              # cleanup pass plus snippet expansion
linflow learn-test "K Wynn E D F" "kkwinedf"     # what an edit would teach the dictionary
linflow focus-test                              # whether the app you are typing in can be read back
linflow mic-test                                # one second from the default input: device, delay to first audio, dead or live
linflow compare-engines                         # your saved takes through both engines, and a blind page to label them
```

## How it works

```
Sources/
  CWhisper/          module map over Homebrew's whisper.h, parakeet.h, ggml-backend.h
  LinFlowCore/
    WhisperEngine    libwhisper wrapper: beam search, VAD, glossary prompt, no timestamps
    ParakeetEngine   libparakeet wrapper, same interface
    SpeechEngine     protocol + factory (picks the engine from the model file name), long audio in pieces
    Recorder         AVAudioEngine tap, resampled to 16 kHz mono float, timed from the key press
    AudioIO          resampling, mixdown, levels, cutting long audio at its quietest points
    Hotkey           the talk key: parts, storage, HotkeyMatcher (what fires, what is swallowed), HotkeyRecorder
    HotkeyMonitor    CGEventTap for the talk key (swallows Fn's own events), own run loop thread
    TextInjector     clipboard snapshot, Cmd+V, restore; the dictation is marked transient and this-Mac-only
    TextCleaner      fillers, spoken commands, glossary fuzzy match, style rules
    NumberWords      spoken numbers as digits
    Snippets, Transforms   text expansion, and on-device rewrites per app
    PasteWatcher     reads the field back after a paste to see what you fixed
    LearnedCorrections     decides what a fix teaches the dictionary
    DictationController    the state machine tying it together
    FileBacked       a file's contents, read again only when the file changes
    ModelCatalog     model list, the models folder, downloads
    History          dictation log (JSON lines) plus one WAV per dictation, stats
    NotesStore       meeting notes on disk: note.json, transcript.jsonl (+ transcript-live.jsonl), running-notes.md, notes.md, summary.md, events.log
    WAVWriter        crash-safe 16 kHz WAV: header refreshed every second, repair from file size
    NoteTranscriber  the full pass over a note's saved audio after the meeting
    SystemAudioTap   Core Audio process tap on the default output device
    LiveTranscriber  turns a stream of audio into timestamped segments on pauses
    MeetingRecorder  mic + system tap, two LiveTranscribers, WAV writers on a shared clock, watchdog and device-change restarts
    RunningNotes     the notes written each minute of a meeting, and the checks every bullet must pass
    Summarizer, NotesMerge   Apple FoundationModels notes per part, merged heading by heading in code
    Settings, Sounds, Log
  LinFlow/
    AppDelegate      Dock, menu bar item and menu, window lifecycle
    HUDPanel         the floating pill
    ToastPanel       the notice above the pill: a learned correction, a dead mic, a hidden pill
    Dashboard/       the window: DashboardWindow (NSWindow, close hides), DashboardModel (state), DashboardView (all SwiftUI views)
    EngineComparison the compare-engines command and its labeling page
    SelfTest/        the selftest, one file per area
    main             CLI entry point; no arguments means run the app
```

Decisions worth knowing about:

- **Parakeet is the default** because it is about ten times faster than Whisper turbo for the same accuracy on English, and it returns nothing on silence instead of hallucinating. Whisper stays one click away for languages Parakeet does not speak.
- **Whisper runs with VAD on, beam size 5, temperature fallback off.** Without Silero VAD, silent or noisy clips came back as the glossary recited word by word. Fallback retries made a 0.9 s clip take 3 s and never changed the text on clean speech.
- **Cleanup is rule-based, not an LLM.** Apple's on-device Foundation Model was tested for the job and took 4 to 11 seconds per call on this machine while still missing the glossary fixes. Whisper and Parakeet already produce cased, punctuated text, so the rules only handle what is left.
- **Text goes in via paste**, not synthetic keystrokes. Browser and Electron editors drop fast synthetic typing but always accept a real paste. The whole clipboard is snapshotted and restored 0.4 s later. The dictation itself is marked transient and this-Mac-only, so clipboard managers skip it and Universal Clipboard never sends it to your phone.
- **whisper.cpp comes from Homebrew** rather than being vendored. The Command Line Tools have no cmake and no Metal shader compiler, and brew's build already has Metal on. The binary links the version-stable `/opt/homebrew/opt/...` paths, so `brew upgrade whisper-cpp` keeps working unless the library major version changes.
- **No test target.** The Command Line Tools ship neither XCTest nor swift-testing. `linflow selftest` covers the pure logic instead: 528 checks in `Sources/LinFlow/SelfTest/`, run against a temporary data folder and settings domain so your own dictionary never changes a result.
- **System audio comes from a Core Audio process tap**, not ScreenCaptureKit. The tap needs only the "System Audio Recording" permission, not Screen Recording, and hands over raw PCM from the default output device that the same resampler used for the mic turns into 16 kHz mono. AVAudioEngine cannot read a tap, so the recorder drives an aggregate device with an IOProc directly.
- **Live transcription is segment based.** Neither model streams, so each source is watched for speech against an adaptive noise floor (the quietest moment of the last five seconds, so a fan or hold music that starts mid-meeting is absorbed within a few seconds); a segment closes after 0.8 s of silence or at 10 s, cut at the quietest recent moment so no word is transcribed twice, and goes through the normal engine and cleanup pass. Lines show up about a second after you stop talking, and Parakeet keeps up with two sources at once. That is the transcript you watch; the one you keep is rebuilt from the saved audio when the meeting ends (see Notetaker above).
- **Long clips are decoded in pieces.** whisper.cpp works in 30 s windows and, with timestamps off, silently skips speech that straddles a window edge. Parakeet has no window but starts dropping sentences after a pause once a clip runs past about a minute. So anything over 28 s (Whisper) or 45 s (Parakeet) is cut at the quietest 200 ms before the limit and each piece decoded on its own; a 5-minute file comes back complete (963 words against Parakeet's 968 on the same recording), and a 95 s clip with two-second pauses keeps all 23 sentences.
- **Summaries use Apple Intelligence on-device.** The model has a 4096-token window, so long transcripts are split on line boundaries and each part is turned into notes: four lists (key points, decisions, action items, open questions) generated against a schema that caps each list, so the model cannot ramble past its token budget. The parts are then merged heading by heading in code, not by the model: asked to reorganize all the notes at once it copied one list under every heading, lost the start and end of the meeting, and drifted numbers while rewriting 50 bullets. A section only goes back to the model to be shortened when it runs long, again against a capped schema. The model still misreads the odd number in a figure-dense meeting (99.6 became 98.6 once in testing), so check anything that matters against the transcript, which sits right next to the summary. A short meeting takes about 15 s on the M1 Pro, a 25-minute one about 4 minutes. It was too slow for dictation cleanup but is fine here.
- **Transforms are opt-in per app** because the on-device model takes 8 to 13 s to rewrite a dictation on the M1 Pro, far too slow for a chat message but nothing next to typing a long prompt into Claude Code. The pill shows “Rewriting…” meanwhile, the untouched text is kept for Undo, and if the model declines or takes over 30 s the plain text is pasted instead. Greedy decoding, no sampling, because rewriting is close to extraction and sampling only adds ways to misread a number.
- **"One" is left alone unless it is counting.** Every other number word becomes digits, but "one" is a pronoun as often as a number ("one of the reasons", "the one that works", "no one knows"), so it only converts inside a larger number, inside a run of digits, or in front of a unit. An ordinal after a number ("the twenty second") and hyphenated compounds ("one-on-one") are left as spoken.
- **A learned correction has to sound like the word it replaces.** The test is the same consonant skeleton the fuzzy matcher uses, which is why "K Wynn E D F" to "kkwinedf" is learned and "Thursday" to "Friday" is not. Single short or everyday words are never bound to a rule, at most three rules come from one dictation, and every learned rule is labeled in the Dictionary so it can be removed.
- **Storage is plain files.** JSON lines, Markdown and WAV in Application Support, plus snippets.json, transforms.json and pending-corrections.json. You can read a note with `cat`, back it up with Time Machine, or point another tool at it.

## Rebuilding and permissions

macOS ties the Accessibility and Microphone grants to the app's code signature. `scripts/build_app.sh` signs with the self-signed "Lin Flow" identity in your keychain when it can (the first time, the keychain asks you to allow codesign; choose Always Allow). Signed that way, every rebuild keeps its permissions. `--adhoc` skips the identity and you re-grant Accessibility after each rebuild (toggle Lin Flow off and on in System Settings, or `tccutil reset Accessibility com.johnlin.linflow`).

Environment variables for unattended testing: `LINFLOW_TEST_AUDIO=/path/to.wav` feeds that file instead of the microphone and never requests mic access, `LINFLOW_NO_PASTE=1` logs the result instead of pasting it, `LINFLOW_OPEN_DASHBOARD=1` opens the window regardless of the setting, and `LINFLOW_SECTION=notetaker` (or `dictation`, `dictionary`, `settings`) picks the section. `LINFLOW_DATA_DIR=<folder>` and `LINFLOW_DEFAULTS_SUITE=<domain>` point a test at its own data folder and settings, away from your real ones.

## Working on the design

Xcode is optional, though it makes the build command shorter. Clone, `brew install whisper-cpp`, then:

```bash
swift build          # with Xcode; about a minute the first time
swift build --build-system native -Xswiftc -sdk -Xswiftc /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk   # Command Line Tools only
LINFLOW_OPEN_DASHBOARD=1 LINFLOW_NO_PASTE=1 .build/debug/LinFlow
```

The Command Line Tools 27 need the second form: their default build system does not start without Xcode, and their macOS 27 SDK turns SwiftUI's `@State` into a macro only Xcode can expand. `scripts/build_app.sh` picks the right one by itself.

The last line runs the app straight from the build folder with the window open. Quit the installed Lin Flow first: only one copy runs at a time, and a second launch just brings the running one forward. The debug binary is unsigned, so the hotkey and pasting may not work until you grant it Accessibility, but the window, history, dictionary and notetaker all do. Quit with Cmd+Q and rerun after each change.

Everything visual lives in a handful of files:

- `Sources/LinFlow/Dashboard/DashboardView.swift`: every screen of the window, in plain SwiftUI. Sidebar, Dictation, Notetaker, Dictionary, Snippets, Style (the three cleanup cards and the per-app rules), Transforms, Settings, plus small pieces such as the stat tiles, level meters, level cards and the error bar.
- `Sources/LinFlow/Dashboard/DashboardWindow.swift`: window size, minimum size, title.
- `Sources/LinFlow/Dashboard/DashboardModel.swift`: the data the views show. Change this only when a screen needs new information.
- `Sources/LinFlow/HUDPanel.swift`: the floating pill, drawn by hand in AppKit.
- `assets/`: the app icon and `Info.plist`.

### Your data stays out of the repo

Dictation history, the dictionary and notes live in `~/Library/Application Support/Lin Flow`, outside the repo, so nothing you push can touch them. The same goes for test data made from real dictation: the Windows port's `CleanCorpusTests` read `test-corpus/clean-corpus.json` from that folder and skip every case when it isn't there. A fresh clone runs zero corpus cases, and that's correct.

After pulling changes, rebuild to run them as the real app:

```bash
git pull && scripts/build_app.sh --install && open "/Applications/Lin Flow.app"
```

A `git pull` on its own changes nothing about the installed app. The rebuild replaces `/Applications/Lin Flow.app` and signs it with the "Lin Flow" keychain identity, so the Accessibility, microphone and system-audio grants survive. If the code does not compile, the script stops before touching `/Applications`.

`scripts/probes/` holds small Swift tools for checking the UI without a human: `winshot` screenshots the window of a running Lin Flow, `axdrive` clicks buttons, selects rows, focuses fields and types into them through Accessibility (`axdrive dump <pid>`, `press <pid> Add AXButton`, `select <pid> Snippets`, `focus <pid> @AXTextField:0`, `type <pid> "hello"`). Build one with `swiftc -O scripts/probes/axdrive.swift -o /tmp/axdrive`. Keystrokes from `type` go to the Lin Flow process only.

## Tests

| Suite | Command | Runs on |
|---|---|---|
| Swift selftest | `swift build && .build/debug/LinFlow selftest` | macOS only |
| Windows port | `dotnet test windows/LinFlow.Tests` | Any OS with the .NET 8 SDK |
| Rust rebuild | `cd next && cargo test --workspace --exclude lin-flow-next` | macOS, Linux, Windows |
| Rebuild's window | `cd next/app && npm ci && npm test` | Anywhere with Node 22 |

The Swift app has no XCTest target because the Command Line Tools ship without XCTest, so `linflow selftest` is the test suite. The Rust app crate is left out on Linux because it needs WebKitGTK. Everything under it builds against the platform crate's stand-ins. `.github/workflows/` runs all of these.

## History

Version 1 was a Python app (rumps, mlx-audio Parakeet, mlx-lm Llama cleanup). This repository starts from the Swift version. `assets/AppIcon.icns` is a hand-drawn L in sand on a dark plum squircle, and `assets/AppIcon-1024.png` is the master it was built from.
