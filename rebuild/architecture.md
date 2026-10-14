# Architecture: one core, two thin shells

**Updated:** 2026-10-02. **Status:** built, for John's review.

Everything Lin Flow decides is written once, in a core with no system calls. What each system does
differently sits in one small module per system behind the same interface. The window is
TypeScript and holds no logic of its own.

```
next/
  core/       pure Rust. The text pipeline, learning, every file format, notes, sync, prompts
  engine/     whisper.cpp's Whisper and Parakeet, loaded at run time
  platform/   the system edge. mac/ and windows/ behind one interface, other/ for tests on Linux
  service/    Lin Flow running: the threads, the state, the events. No window
  cli/        the command line, over core, engine and service
  app/        Tauri: src-tauri/ in Rust (tray, windows, commands), src/ in TypeScript (the pages)
  oracle/     scripts comparing the core with the Swift app
```

## Where the core ends

**The core decides. The shells act.** A function belongs in `core` if it can be tested with
nothing but its inputs: no microphone, no keyboard, no network, no clock it did not get passed.
That is most of Lin Flow:

| Core module | What it decides |
|---|---|
| `text` | The cleanup pipeline: noise tags, corrections, fillers, spoken commands, glossary snapping, numbers, style rules, capitals. `glossary` reads and writes `vocab.txt` and `replacements.txt` |
| `learn`, `readback` | Whether an edit teaches a correction, and how sure. Where a dictation sits in a field read back |
| `history`, `settings`, `models`, `paths` | `history.jsonl` and its stats, `settings.json`, the model catalog, the data folder |
| `hotkey` | What the talk key is, what fires it and what is swallowed, and recording a new one |
| `audio`, `wav` | Resampling, levels, cutting long audio at quiet points, the crash-safe WAV and its repair |
| `notes`, `meeting` | Note folders, speech regions, echo removal, the live segmenter, running notes and their checks, the summary merge, the recap, call detection |
| `sync` | The shared dictionary's merge and the totals, as requests over a `Transport` |
| `llm`, `net` | Claude and Ollama clients and prompts, over the same `Transport` |
| `repair` | The stuck-audio fix scripts for each system |

The network goes through a `Transport` trait, so tests answer with a fake table and never reach
Supabase. The laws in `core/tests/laws.rs` run the real sync against such a fake.

## The shells

`platform` is the only crate that calls the operating system. Each function has a Mac body and a
Windows body, and `other/` stubs them so the rest builds and tests on Linux.

| Interface | Mac | Windows |
|---|---|---|
| `HotkeyListener` | Core Graphics event tap | Low-level keyboard and mouse hooks |
| `paste`, `copy`, `clipboard_text` | NSPasteboard and Cmd+V | The clipboard and `SendInput` Ctrl+V |
| `FieldReader` | Accessibility | UI Automation |
| `Microphone` | `cpal` on Core Audio | `cpal` on WASAPI |
| `SystemAudio` | Process tap and aggregate device | WASAPI loopback |
| `keep_awake` | IOKit power assertion | `PowerCreateRequest` |
| `mic_users` | Core Audio process list | The registry's microphone consent store |
| `frontmost_app`, `trusted` | NSWorkspace, Accessibility trust | Foreground window, always trusted |
| `play_sound` | NSSound | `PlaySoundW` |

`engine` loads whisper.cpp's libraries at run time from Homebrew on the Mac and from the release
DLLs on Windows, so no C is compiled into the app and the Mac can check the Windows build.

## The service

`service` runs Lin Flow without a window. The app and the CLI's `service-test` both start it. It
owns these threads:

| Thread | Job |
|---|---|
| `linflow.hotkey` | The event tap or hooks. Hands each press to the audio thread |
| `linflow.audio` | Opens the microphone for each take and collects it |
| `linflow.work` | Transcribe, clean, paste, save to history |
| `linflow.readback` | Reads pasted fields back on a schedule and hands edits to the learner |
| `linflow.meeting.io` | A meeting's audio: both sides, the WAVs, levels, the watchdog, device changes |
| `linflow.live` | The live transcript of a meeting |
| `linflow.running-notes` | Notes every minute while a meeting records |
| `linflow.transcribe`, `linflow.summary` | The whole-file pass after a meeting, summaries, recaps, questions |
| `linflow.detect` | Call apps on the microphone, a call ending, a silent side |
| `linflow.sync` | The shared dictionary and totals every 10 minutes |
| `linflow.model` | Loading and downloading speech models |

It reports through one stream of events: state, level, dictated, history changed, toasts, note
events. The app forwards each one to the pages as it comes.

## The window

The three pages, `main`, `pill` and `toast`, are Preact and TypeScript. They call the service through
typed commands and listen to its events, all declared in `app/src/api.ts`, which mirrors the
Rust types. Opened in a plain browser, `api.ts` answers from `mock.ts` instead, with made-up data,
so every page can be clicked through without the app or John's data.

`app/src-tauri` makes the windows. The pill and toasts never take focus: on the Mac they become a
non-activating panel class, and on Windows they get `WS_EX_NOACTIVATE`. Closing the main window
hides it. Quitting stops the service and exits at once, skipping the destructors that crash
ggml's Metal backend.

## Two paths through it

**A dictation.** The hook sees the talk key go down. The audio thread opens the microphone and
collects samples. On release the work thread transcribes, cleans with the current dictionary, and
pastes. It saves the entry and its audio, and asks the readback thread to find the field within
3 s and look at it every 0.8 s for 15 s. An edit found there goes to the learner, which may write
`replacements.txt` and show a toast.

**A meeting.** The detection thread sees Zoom take the microphone and offers to record. The io
thread opens the microphone and the call's audio, writes a WAV per side with a header kept valid,
and feeds both to the live transcriber. The running-notes thread writes bullets every minute.
When the call app lets go of the microphone, a countdown stops the note. The whole recording is
transcribed again with echo removed, then summarized, and a toast gives the recap.

## Data

Every file keeps the names and shapes of the Swift and C# apps, so a folder copied between them
opens in any of the three. Until cut-over Next keeps its own:

| | Installed app | Next |
|---|---|---|
| Data folder | `Lin Flow` | `Lin Flow Next` |
| App identifier | `com.johnlin.linflow` | `com.johnlin.linflow.next` |
| Talk key default | Fn, Right Alt | Right Option, Right Alt |
| `sync.env` | present on all three | never copied. Next would sync as the same computer |

## Cut-over

John says when, one computer at a time, Mac last. On each: install Next, point it at the real
data folder and talk key, check the live list in `verification.md` with John there, then remove
the old app. `fleet.sh` learns to build Next on that computer at the same time.
