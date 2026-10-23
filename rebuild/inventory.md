# Inventory: everything Lin Flow does today

**Updated:** 2026-10-23. **Status:** reviewed. Written after the build started, since John said
to keep building. Every decision made without him was marked **Decide**, with the choice taken.
John approved all five on 2026-10-23 ("sure let's build all these"); each now says **Decided**.

This is the acceptance checklist for the rebuild. Each row is one thing the installed apps do.
**Where** says which app does it today: Mac for the Swift app, Win for the C# app, or Both. **Next** says where Lin
Flow Next stands:

- **Done**: built and checked without hardware, by the oracle, unit or property tests, or a
  headless run.
- **Built**: written and compiled for both systems, never run live. Needs a person at the
  computer: the talk key, the microphone, pasting, the call's audio, permission prompts.
- **Gap**: not built yet.
- **Out**: left out on purpose, with the reason.

Sources: `README.md`, `HISTORY.md`, `FLEET.md`, `SYNC-PLAN.md`, `windows/PLAN.md`,
`windows/NOTES.md`, and the code of both apps.

## Dictation

| Feature | Where | Next |
|---|---|---|
| Hold the talk key, speak, release: the text is pasted into the focused app | Both | Built |
| A space after each dictation, so the next one does not run into it | Both | Done |
| The clipboard put back 0.4 s later, images and files included | Both | Built |
| The dictation kept out of clipboard managers and Universal Clipboard | Mac | Built |
| The clipboard put back only if nothing else wrote to it since | Both | Built |
| Clips under 0.35 s and pure silence are dropped instead of pasted | Both | Done |
| A dead microphone named in a red toast instead of pasting nothing | Both | Built |
| A press while the model loads is ignored, not queued | Both | Done |
| Long dictations decoded in pieces cut at quiet points: 28 s Whisper, 45 s Parakeet | Both | Done |
| The other engine tried when one returns nothing | Mac | Done |
| The glossary recited back on silence is caught and dropped | Mac | Done |
| Stuck Mac audio: one retry, then a toast offering `killall coreaudiod` | Mac | Built, Windows form added |
| Every dictation saved to `history.jsonl`, with its audio kept 30 days by default | Both | Done |
| Sounds at ready, start, stop and error | Both | Built |
| `LINFLOW_TEST_AUDIO` and `LINFLOW_NO_PASTE` for tests | Win, Mac | Done |

## The talk key

| Feature | Where | Next |
|---|---|---|
| Any key, combination or extra mouse button as the talk key, recorded by pressing it | Both | Built |
| Escape cancels a recording of a new key | Both | Built |
| Fn as the talk key, with Fn's own events swallowed so the Globe action never fires | Mac | Built |
| A held mouse button talks without clicking, and a quick click still clicks | Both | Built |
| Shift, Control, Option and Command never swallowed | Both | Built |
| Default: Fn on the Mac, Left Ctrl + Left Alt on Windows | Both | Done. Next defaults to Right Option and Right Alt while it runs beside the installed app, and to the installed app's key from cut-over. **Decided** 10-23 |

## The text pipeline

| Feature | Where | Next |
|---|---|---|
| Fillers removed: "um", "uh", "you know" | Both | Done |
| Spoken commands: "new line", "new paragraph", "question mark", "exclamation mark" | Both | Done |
| "comma enter enter" and other runs of enter with punctuation words | Both | Done |
| Engine noise tags removed: [BLANK_AUDIO], (music), *laughs* | Both | Done |
| Phrases the engines invent on silence dropped: "Thank you.", "So." | Both | Done |
| Corrections from the dictionary, whole words, any case | Both | Done |
| Glossary near-misses snapped to the term's spelling, never an everyday word | Both | Done |
| A real name never turned into another name unless it sounds the same | Both | Done |
| Spoken numbers as digits, with "one" kept unless it counts | Both | Done |
| Dates and decimals: "September 30th", "the 30th of September", "5.5" | Both | Done |
| A year said as two numbers: "nineteen eighty four" is 1984 | Both | Done |
| Em dashes and semicolons replaced, times given their colon | Both | Done |
| Sentences capitalized | Both | Done |
| A lowercase dictionary term stays lowercase at a sentence start | Mac | Done on both. **Answered** 10-02: the Mac's way |
| Hand-edited lines in `replacements.txt` kept on save | Mac | Done on both |
| Cleanup level None or Light | Both | Done |
| Cleanup level Medium: an Apple Intelligence rewrite | Mac | Out. **Decided** 10-23. A Mac `medium` reads as Light |
| Snippets: a spoken phrase expands into saved text | Mac | Out. **Decided** 10-23. John's `snippets.json` is empty |
| Transforms and per-app rules: rewrites by an on-device model | Mac | Out. **Decided** 10-23. No transforms or app rules are set on the Mac |

The oracle compares Next with the Swift app on 97,003 generated inputs and agrees on all of them.
John's 1,219 real dictations are a further check that runs in place and is never committed.

## Learning from edits

| Feature | Where | Next |
|---|---|---|
| The pasted field watched for 15 s to see what John fixed | Both | Built |
| Accessibility on the Mac, UI Automation on Windows, password fields never read | Both | Built |
| A fix that sounds like the word becomes a correction, automatically or as a suggestion | Both | Done |
| An everyday word never bound by a learned rule | Both | Done, now a law |
| Suggestions waiting in `pending-corrections.json` | Both | Done |
| A toast for each learned or suggested correction, with Undo or Add | Both | Built |
| Editing a dictation in the window teaches the same way | Both | Done |
| Learning setting: off, ask, or automatic | Both | Done |

## The window

| Feature | Where | Next |
|---|---|---|
| Dictation: every dictation by day, total words, words a minute, day streak | Both | Done |
| Search, select text, play, copy, transcribe again, edit, delete | Both | Done, clicked through in a browser |
| Dictionary: words, corrections, learned labels, suggestions to accept or dismiss | Both | Done |
| Notetaker section | Both | Done |
| Settings | Both | Done |
| Snippets, Style and Transforms sections | Mac | Out. **Decided** 10-23 |
| Closing the window hides it, the app keeps running | Both | Built |
| The window opens at launch, unless turned off | Both | Built |
| The Mac look on Windows | Win | Done: one window for both |

## The pill, the menu and the app

| Feature | Where | Next |
|---|---|---|
| A floating pill: dot by state, level meter while recording | Both | Done in a browser, Built in the app |
| Drag the pill anywhere, the spot remembered | Both | Built |
| Hold-to-talk button on the pill | Both | Built |
| The pill and toasts never take focus | Both | Built |
| Menu bar or tray icon, red while recording | Both | Built |
| Recent Dictations in the menu: click one to copy it | Mac | Out. **Decided** 10-23: the window's copy button is enough |
| Show in Dock, off for menu bar only | Mac | Built |
| Launch at login | Both | Built |
| One copy running at a time | Both | Built |
| Quit frees the engine and exits without a crash report | Mac | Built |
| Logs: `app.log` on the Mac, rotated | Both | Done |

## Models

| Feature | Where | Next |
|---|---|---|
| Parakeet TDT 0.6B v3 by default | Both | Done |
| Whisper large-v3-turbo and other sizes | Mac | Done on both. **Answered** 10-02: both computers |
| Whisper language menu: English, auto, Khmer, Chinese and others | Mac | Built on both |
| Whisper primed with the glossary, VAD on, beam 5, no fallback | Mac | Done |
| Models downloaded with progress in the pill | Both | Built |
| whisper.cpp from Homebrew on the Mac, the release DLLs on Windows | Both | Done on the Mac, cross-checked for Windows |

## The notetaker

| Feature | Where | Next |
|---|---|---|
| One note per meeting, started and stopped by hand | Both | Built |
| The microphone as "You", the call's audio as "Others" | Both | Built |
| Core Audio process tap on the Mac, WASAPI loopback on Windows | Both | Built |
| Live transcript, a line a second after each pause | Both | Done for the segmenter, Built live |
| Crash-safe WAV per side, a valid header while recording | Both | Done |
| An unfinished note closed and transcribed at the next launch | Both | Done |
| Shared clock with padding for gaps, a watchdog that restarts a stalled side | Both | Built |
| Device changes mid-meeting followed | Both | Built |
| The whole recording transcribed again after the meeting, replacing the live lines | Both | Built |
| The microphone's echo of the other side dropped | Mac | Done on both. **Answered** 10-02 |
| Running notes every minute, checked against the transcript | Both | Built |
| Summary: summary, decisions, action items, open questions, merged in code | Both | Built |
| Recap of the last 5 minutes | Mac | Built |
| Ask Claude: three quick questions and a box | Mac | Built on both. **Answered** 10-02 |
| Typed notes beside the transcript | Both | Done |
| Copy or save as Markdown, open the folder | Both | Built |
| Transcribe again from the recording with the current model | Both | Built |
| No idle sleep while a meeting records | Both | Built |
| Low disk warning | Mac | Built on both |
| Offer to record when a call app takes the microphone | none | Built, new |
| Stop by itself when the call ends, with a countdown | none | Built, new |
| Live proof each side records: two meters | none | Done in a browser, new |
| An alarm when a side goes silent | none | Built, new |
| An end-of-call recap toast | none | Built, new |
| Rename a meeting, relabel a speaker | none | Done in a browser, new |

## Summaries and models for text

| Feature | Where | Next |
|---|---|---|
| Summaries and running notes by Apple Intelligence on the Mac | Mac | Out. **Decided** 10-23: Claude first for summaries, Ollama first for running notes |
| Ollama `qwen2.5:3b` on Windows | Win | Done on both |
| Claude with John's key, `scripts/setup-claude.sh` | Mac | Built on both |

## Sharing across computers

| Feature | Where | Next |
|---|---|---|
| Shared word totals in Supabase, counts only | Both | Done, oracle-checked |
| One dictionary on all three computers, deletions included | Both | Done, oracle-checked, now a law |
| Sync every 10 minutes and after a dictation | Both | Built |
| A mass deletion refused as an accident | Both | Done |
| `fleet.sh`: each computer builds its own app from `main` | Both | Gap. **Decided** 10-23: Next joins the fleet at cut-over, steps in `architecture.md` |

## Command line

| Command | Where | Next |
|---|---|---|
| `transcribe`, `bench`, `models`, `clean`, `summarize`, `ask` | Mac, some Win | Done |
| `download`, `learn-test` | Mac | Done |
| `focus-test`, `mic-test`, `paste` | Mac, some Win | Built. They touch the microphone or the focused app, so they run only when asked |
| `notes-test`, `notes-transcribe`, `notes-repair` | Mac | Done, on a made-up meeting in a temp folder |
| `running-notes-test` | Mac | Built. A run calls Ollama or Claude |
| `compare-engines` | Mac | Gap. The Swift one serves until cut-over |
| `selftest` | Mac | Replaced by `cargo test` and `npm test` |
| `doctor`, `version` | Win | Done |
| `meeting`, `notes` | Win | Replaced by the window |
| `expand`, `transform`, `transforms`, `toast-shot` | Mac | Out |
| `platform-check`, `service-test` | none | Done, new |

## Places the two apps differ

| Difference | Mac | Windows | Next |
|---|---|---|---|
| Lowercase term at a sentence start | stays lowercase | capitalized | the Mac's way, John 10-02 |
| Hand-edited lines in `replacements.txt` | kept | dropped on save | kept |
| Talk key default | Fn | Left Ctrl + Left Alt | Right Option and Right Alt until cut-over, then the installed app's |
| Summaries | Apple Intelligence, Claude | Ollama | Claude, then Ollama |
| Running notes | Apple Intelligence | Ollama | Ollama, then Claude |
| Whisper | yes | no | both |
| Echo removal, Ask Claude, stuck audio | yes | no | both |
| Window | SwiftUI | WinForms with the Mac's look | one TypeScript window |
| Data folder | `~/Library/Application Support/Lin Flow` | `%APPDATA%\Lin Flow` | the same names, `Lin Flow Next` until cut-over |

## Decisions for John

All five approved by John on 2026-10-23, as proposed.


1. **Snippets, Style and Transforms are out.** None is in use: `snippets.json` is empty and the
   Mac's settings hold no transform or app rule, as checked on 2026-10-02. A later port starts from the
   same file formats.
2. **No Apple Intelligence.** Its API is Swift only. Summaries go to Claude when a key is saved and
   to Ollama otherwise. Running notes go to Ollama first because they run every minute. A small
   Swift helper could bring the on-device model back on the Mac if John wants summaries that never
   leave it.
3. **Recent Dictations in the menu** is not built. The window's Dictation list has a copy button
   on every row.
4. **Next's talk key** is Right Option on the Mac and Right Alt on Windows while it runs beside the
   installed app, so the two never fight over Fn. At cut-over it takes the installed app's key.
5. **The fleet** builds the Swift and C# apps. Next joins it at cut-over, one computer at a time,
   Mac last.
