# Lin Flow for Windows

Hold Left Ctrl + Left Alt, talk, let go. The cleaned text is pasted where your cursor is. Everything runs
on this machine: no cloud, no account, no API bill.

## Setup, once

If you can see the `\\fileserver\share` share (it is `R:` on the laptop, but the letter differs
per machine, so this uses the path itself), the whole of this section is one command:

```
powershell -ExecutionPolicy Bypass -File \\fileserver\share\lin-flow\install-latest.ps1
```

That fetches the newest build, installs it under `%LOCALAPPDATA%\Programs\Lin Flow` and runs the
setup below for you. The same command updates it later. A Lin Flow that is running stays up while
the new build is fetched and checked, closes only while its files are replaced, and is started
again. The command changes nothing, and says why, while a meeting note is recording or when the new
build fails its check here. `-Force` installs a build that failed anyway, running setup, which
fetches a missing model or runtime, before Lin Flow starts again. Otherwise, from a zip:

1. Unzip anywhere you like (Documents is fine; it needs no admin rights and writes nothing to
   Program Files).
2. Right-click **install.ps1** and choose **Run with PowerShell**.
   It checks for the .NET 8 Desktop Runtime, offers to install it for your user only, verifies
   the speech engine loads, and downloads the model (about 640 MB, once).
3. Double-click **Lin Flow** on the desktop, which install.ps1 puts there. The tray icon is the
   Lin Flow mark with a dot in its corner: gray while it loads the model, green when it is ready.
   Right-click that desktop shortcut and choose **Pin to taskbar** to keep it to hand.

To start it at login, put a shortcut to `LinFlow.exe` into the folder that opens when you paste
`shell:startup` into the Run box (Win+R).

## Using it

- **Hold Left Ctrl + Left Alt**, speak, release. A pill appears near the bottom of the screen saying
  "Listening..." while you talk and "Transcribing..." while it works, so you can see it heard you
  without hunting for the tray icon. The text is then pasted.
- A tap with no speech is ignored, so resting on the key costs nothing.
- Right-click the tray icon for the window, the data folder and the log. Double-clicking it opens
  the window too.

## The window

**Open Lin Flow** any of three ways: double-click the desktop shortcut (or its taskbar pin),
double-click the tray icon, or choose **Open Lin Flow** from the tray menu. Running the exe while
Lin Flow is already going opens the window rather than starting a second copy, which is what makes
a taskbar pin behave like any other app's. Windows 11 hides a new tray icon behind the overflow
chevron, so do not count on finding it there.

It is a real window with a taskbar button, so it can be Alt-Tabbed to and pinned. Closing it only
hides it: Lin Flow keeps running and keeps listening, and **Quit** in the tray menu is what
actually ends it.

To put it on the taskbar, right-click the desktop shortcut and choose **Pin to taskbar**. Windows
blocks pinning from a script, so this is the one step nothing can do for you.

Four sections down the left:

- **Dictation** is everything you have said, newest first, with the time and how many times
  faster than real time it was transcribed. A new dictation shows up at the top as soon as it
  lands, with the window open or not. The copy button at the right of a row puts the whole
  dictation on the clipboard, which is how to rescue one whose paste missed; or select part of
  the text and press Ctrl+C. Right-clicking a row does either.
- **Dictionary** is the two files that fix what comes back. **Terms** on the left are spellings to
  snap near-misses onto, which is what turns "land flow" into "Lin Flow". **Corrections** on the
  right are outright "heard => meant" rules, and rules Lin Flow learned by itself are marked. Click
  a correction to change it: it fills the two fields, **Save** writes it back in place, and Esc or
  **Cancel** leaves it as it was. Rules
  it was not sure enough to add wait above them under **Suggested**, with **Add** and **No**. Both
  are still plain text files you can edit by hand; the window writes the same format, and keeps
  any line of yours it cannot read.
- **Notetaker** records a meeting: you and whatever the PC plays. Give it a title, press **Start
  recording**, and the transcript fills in as people pause. Pressing **Stop** transcribes the
  saved audio whole, which reads better than the live pass, and writes `note.md`. The pane below
  is the running notes while it runs and the summary once there is one; both need Ollama, and the
  meeting records and transcribes perfectly well without it. See **Meeting notes** below for what
  lands on disk.
- **Settings** picks the hold-to-talk key, which can be any combination of keys and mouse buttons,
  recorded by pressing it, and what happens when you fix pasted text (below), and opens the data
  folder and the log. Saving the key rebinds it immediately, with no restart.

## Learning from your fixes

Fix a word in text Lin Flow has just pasted, within 15 seconds, and it becomes a correction, the
way the Mac does it. Dictate "Ask John Lynn about it.", change Lynn to Lin, and "Lynn => Lin" is
in the dictionary from then on. A note at the bottom left of the screen says what was learned.

It learns only what looks like a mishearing. Swapping one ordinary word for another ("late" for
"early") is a change of mind, and a rule for it would rewrite that word in every dictation after,
so it is never learned. A misheard name is too far from what was said to be sure of, so it is
offered instead: the note asks, and a click adds it. Anything offered also waits under
**Suggested** in the Dictionary.

**Settings > When you fix pasted text** chooses between **Add it automatically** (the default),
**Suggest it first** (nothing is added without a click) and **Do nothing**.

Lin Flow reads the field back through Windows accessibility, the same channel a screen reader
uses. It reads only the focused field, never the rest of the screen, only for those 15 seconds,
and never a password field. An app that does not expose its text teaches nothing, and the log
says so. To see whether
one does, run `linflow-cli.exe focus-test --wait 5` and click into its text field within the five
seconds.

### Changing the key

The default is **Left Ctrl + Left Alt**, held together. Both keys are on every keyboard, and the
chord does nothing else: Left Alt alone opens the menu bar and Left Ctrl alone is half of every
shortcut, but holding both is free. It was Right Alt until 2026-09-23. Right Ctrl was the original
default and is **gone from laptops shipping since 2024**, which replaced it with a Copilot key: on
one of those the old default was a key that did not physically exist, so nothing ever fired and
nothing reached the log to say why.

Any combination can be the talk key: any keys, a mouse button, or both. The easy way is
**Settings > Record the talk key**. Press **Record**, then press everything you want to hold,
together, and let go. The box shows what it recorded, and **Save** makes it the talk key. Esc on its
own cancels. The talk key is off while it records, so pressing the old one does not start a
dictation.

Or put it in `%APPDATA%\Lin Flow\settings.json`:

```json
{ "hotkey": "RightShift" }
```

Every ordinary key has a name: `A` to `Z`, the number row as `D0` to `D9`, `F1` to `F24`, `Space`,
`Enter`, `Tab`, `Esc`, `Backspace`, `Insert`, `Delete`, `Home`, `End`, `PageUp`, `PageDown`, the
arrows as `LeftArrow`, `RightArrow`, `UpArrow` and `DownArrow`, and `Numpad0` to `Numpad9`. The
modifiers are `LeftAlt`, `RightAlt` (also `AltGr`, and `rightOption`, which is what the Mac writes
for the same physical key), `LeftCtrl`, `RightCtrl`, `LeftShift`, `RightShift`, `LeftWin`,
`RightWin`, `Menu` and `CapsLock`. `Ctrl`, `Alt`, `Shift` and `Win` on their own mean the left one.
The mouse buttons are `MiddleMouse`, `MouseBack` and `MouseForward`. For anything else, give the
Windows virtual-key code directly, as `"0x5D"` or `"165"`.

Several joined by `+` make a chord that all have to be held:

```json
{ "hotkey": "LeftCtrl+LeftAlt" }
```

A chord is usually the right answer on the left of the keyboard, where every single key is already
busy. Left Alt on its own opens the menu bar in most apps, and Left Ctrl on its own starts a
recording on every `Ctrl+C` you type. Holding both does neither. Releasing any one key ends the
dictation. An unusable value falls back to the
default and says so in the log, rather than leaving you with no hotkey at all. Restart the app
after editing. The log line on startup names the key it bound, so it is worth a look if a press
does nothing.

Keys still reach the app you are in, so a letter or Space on its own would start a recording every
time you typed it. Pick keys you do not type with, or hold them with a modifier.

**A mouse button** works the other way: Lin Flow keeps it from the app under the pointer, so
holding it to talk does not also open a link or start autoscroll. That makes the middle button,
the wheel pressed down, a good talk key on a mouse with no button to spare. A quick click, under
0.3 s, still reaches the app as an ordinary click, so the middle button still opens a link in a
new tab and closes a tab, and Back still goes back. What it gives up is dragging with the button
held, which some CAD and 3D programs use to pan. The left and right buttons can never be the talk
key. Each quick click opens the microphone for that moment, and the log records it as a dropped
clip.

**Fn cannot be used**, on any layout. It is handled inside the keyboard firmware and never reaches
Windows as a key at all, so no application can bind it.

## Meeting notes

The **Notetaker** tab in the window is the way in. The same thing runs in a console as
`linflow-cli.exe meeting`, or from **Start a meeting note (console)** in the tray menu, and writes
the identical folder. Either way it records your microphone as "You" and whatever the PC
is playing (the other people on a Teams call) as "Others", prints each line a moment after the
speaker pauses, and stops when you press Enter or Ctrl+C. Then it transcribes the whole recording
again, at the real pauses and with more context than the live pass had, and writes `note.md`.

While it runs, running notes land every minute or so: a few bullets on what was just said,
each stamped with its time, printed in the console and saved to `running-notes.md` as they are
written. When it ends you also get `summary.md`. Both come from a local model behind
**Ollama**:

```
winget install --id Ollama.Ollama --scope user
ollama pull qwen2.5:3b
```

About 2 GB for the model, once. User scope needs no admin rights, and the installer puts a
shortcut in Startup, so the server is there after a reboot without anything else being done.
`linflow-cli.exe doctor` then shows a "notes model" line. Without Ollama the meeting still records
and transcribes; it just takes no notes. A different model or host goes in `settings.json` as
`notesModel` and `ollamaHost`.

The default host is `http://127.0.0.1:11434`, not `localhost`. Ollama listens on IPv4 only and
Windows resolves `localhost` to `::1` first, so the dead IPv6 connection has to time out before
the real one is tried: 2.14 s against 14 ms, measured. The check before a meeting gives up after
two seconds, so `localhost` made Lin Flow report Ollama missing while it was running.

Each meeting is a folder under `%APPDATA%\Lin Flow\notes\`: `audio-mic.wav` and `audio-system.wav`
(written as they arrive, with a header that stays valid, so a crash or a dead battery costs at most
the last second), `transcript.jsonl` (rebuilt from the audio; the live one is kept as
`transcript-live.jsonl`), `events.log` (every gap, restart and failure, with times), `note.json`
and `note.md`. The same layout as the Mac, so a folder copied over opens there too.

- `linflow-cli.exe notes` lists them.
- `linflow-cli.exe notes-transcribe <note id> --save` rebuilds a transcript from the audio, for
  example after installing a better model. Without `--save` it only prints.
- `linflow-cli.exe notes-repair` closes a note that a crash left open. `meeting` does this on its
  own before it starts.
- `--no-mic`, `--no-system`, `--no-live` (no live lines, just the recording and the pass at the
  end) and `--title "..."` are the options.

If a source dies mid-meeting (a headset unplugged, the output switched to a monitor) it is
restarted within a few seconds and the gap is filled with silence, so the two tracks stay
aligned; `events.log` says what happened and when.

## The dictionary

`%APPDATA%\Lin Flow\` holds the same files as the Mac, in the same formats:

| file | what it is |
|---|---|
| `vocab.txt` | names and terms to snap misheard words onto, one per line |
| `replacements.txt` | `heard => meant` corrections, one per line |
| `history.jsonl` | every dictation |
| `app.log` | what happened, one line per event - read this first when something is wrong |
| `sync.env` | only if shared totals are on: the project, its publishable key and this PC's name |

Copy `vocab.txt` and `replacements.txt` straight across from the Mac
(`~/Library/Application Support/Lin Flow/`) and they load unchanged. That is a hard requirement
of the port and it is covered by the tests. Do not copy `history.jsonl` once shared totals are on:
its words would count on both computers.

## Shared word totals

Optional, and off until this PC is set up. Turned on, the total over the Dictation list counts
every computer you dictate on and says how many of those words are this PC's.

Only counts leave this PC: for each day, its name, the date, and the words, dictations and seconds
of audio on it. They go to one table in a Supabase project you own. What you said, the audio, the
dictionary and app names never do. Create the table with `scripts/sync-schema.sql` in that
project's SQL editor, then write `%APPDATA%\Lin Flow\sync.env`:

```
SUPABASE_URL=https://<your project>.supabase.co
SUPABASE_KEY=<the project's publishable key>
DEVICE=<a name for this PC>
```

Lin Flow picks it up at the next dictation. It refuses a secret key, so use the publishable one.
**Settings > Shared totals** shows what it last did, and **Sync now** sends and reads straight
away. Delete `sync.env` to turn it off.

## If something is wrong

The first start after installing or updating can take most of a minute on a machine whose
antivirus examines new programs before letting them run. There is no tray icon until it
has, so give it that minute before starting it again.

Open a terminal in this folder and run:

```
.\linflow-cli.exe doctor
```

It checks, in order: the native DLLs are present, the hand-written struct layouts read back sane
values, a model is installed and complete, and the dictionary loads. Every failure prints what
to do next. Other commands:

```
.\linflow-cli.exe clean "some text"      run the cleanup pipeline, no audio or model needed
.\linflow-cli.exe transcribe clip.wav    transcribe a wav file
.\linflow-cli.exe bench clip.wav         warmed timings
.\linflow-cli.exe models                 what is installed
.\linflow-cli.exe mic-test               one second from the microphone: which device, how long until its first audio, whether it sent anything
.\linflow-cli.exe learn-test "<pasted>" "<fixed>"   what fixing one into the other would teach the dictionary (--apply adds it)
.\linflow-cli.exe focus-test --wait 5    whether the app you click into lets Lin Flow read its text field back
```

## Testing without a microphone

The Mac's two hooks work here too. `LINFLOW_TEST_AUDIO` points at a WAV that stands in for the
microphone, so the whole hotkey to engine to cleanup path runs with nobody talking, and
`LINFLOW_NO_PASTE` logs the text instead of pasting it, so a test can never type into whatever
window has focus.

```
set LINFLOW_TEST_AUDIO=C:\path\to\clip.wav
set LINFLOW_NO_PASTE=1
LinFlow.exe
```

Quit that instance before dictating for real: with either variable set, nothing pastes.

The clip behind the last real dictation is kept as `last-recording.wav` in the data folder, so a
transcript that came out wrong can be replayed with `linflow-cli.exe transcribe`.

## What is and is not here

**Here:** the full text pipeline (fillers, spoken commands, capitalization, the glossary
matcher with its name guards, spoken numbers into digits, the corrections dictionary), Parakeet
transcription, hold-to-talk, clipboard paste, the tray icon, history and logging.

**Here since 2026-09-17:** the meeting notetaker. It has the Mac's recording rules, its crash
safety, its pass from the saved audio, and its running notes and summary, with a local model
behind Ollama standing in for Apple Intelligence.

**Here since 2026-09-19:** the window, built to match the Mac's - four sections down the left
(Dictation, Notetaker, Dictionary, Settings), the dictionary editable in place, and the hotkey
changeable without touching a text file. One gap worth knowing: the sidebar sections are painted
rather than being real controls, so a screen reader cannot find them and there is no keyboard
path to a section.

**Here since 2026-09-23:** learning corrections from the fixes you type after a paste, with the
Mac's rules for what counts as a mishearing.

**Not here yet**, all of it Mac-only for now: snippets, transforms, and Whisper for non-English.
Parakeet is English-only, and it is the default on the Mac too.

**Read this before trusting it.** The whole Windows app was written and compiled on a Mac, so
the parts that touch Windows itself - the keyboard hook, WASAPI microphone capture, the WASAPI
loopback and device-change callbacks the notetaker uses, SendInput paste, the tray icon, and the
hand-written P/Invoke struct layouts - had never executed anywhere until you ran them. The text pipeline is a different story: it is checked against 346 real
dictations from the Mac and has to produce byte-identical output for every one of them, so that
part is as trustworthy as the Mac's. Start with `linflow-cli.exe doctor`, which is built
precisely to catch a native-layer problem in a console where you can read the error, rather than
in a tray app that silently does nothing.
