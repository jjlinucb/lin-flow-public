# Lin Flow for Windows

**Status:** M1-M3 built 2026-09-14, on the Mac rather than the laptop. Read `NOTES.md` first - it records what was actually built, where it departs from this plan and why, what is verified and what has never run. The zip is `scripts/package.sh`. Written 2026-09-10 on the Mac for John's work laptop: unsigned exes allowed, Claude Code installed, GPU present (vendor unknown until M0).

The Mac app is Apple end to end (Swift, Core Audio, CGEvent tap, Cmd+V, Accessibility, Apple Intelligence). The Windows app is a sibling in C# that shares the text logic, the models and the data files, and replaces every OS layer. `../Sources/LinFlowCore` is the spec: port behavior from it, and port its selftest cases as the tests.

## Decisions (settled, build on them)

- **Stack:** C# on .NET 8. WPF for the window, a tray icon for the menu, xUnit for tests. No admin rights to run, one folder to publish.
- **Engine:** P/Invoke straight into `whisper.dll` and `parakeet.dll` from the official whisper.cpp v1.9.1 release zip. Verified 2026-09-10: `whisper-bin-x64.zip` ships `whisper.dll`, `parakeet.dll`, `ggml.dll`, `ggml-base.dll`, the per-CPU `ggml-cpu-*.dll` backends, plus `parakeet-cli.exe` and `whisper-cli.exe` for sanity checks. No source build for the CPU path. An NVIDIA GPU takes `whisper-cublas-12.4.0-bin-x64.zip` instead. The whisper.net NuGet binding has no Parakeet, so it is out.
- **Models:** the same files and download URLs as `ModelCatalog.swift`. Parakeet tdt 0.6b v3 q8_0 is the default (English), large-v3-turbo q5_0 for other languages.
- **Data:** `%APPDATA%\Lin Flow\` with the Mac's file names and formats (history.jsonl, vocab.txt, replacements.txt with its `# learned` marker, snippets.json, transforms.json, pending-corrections.json, models\). A file copied from the Mac loads unchanged. Settings live in `settings.json` there, same keys as `Settings.swift`.
- **Repo:** this folder in the same private repo. The Mac app under `../Sources` is untouched by Windows work.
- **Order:** dictation first (M0 to M4). Notetaker and summaries are v2 (M5) because they need a local LLM in place of Apple Intelligence. Snippets, Style and Transforms are not planned (see "Not ported").

## Layout

```
windows/
  LinFlow.sln
  LinFlow.Core/     net8.0, no Windows APIs: cleanup, glossary, numbers, learner, snippets, settings, history, NotesMerge
  LinFlow.Engine/   net8.0-windows: P/Invoke bindings, model catalog, WASAPI capture, splitLong
  LinFlow.Cli/      console: bench, transcribe, clean, learn-test, focus-test (the Mac's CLI in main.swift)
  LinFlow.App/      WPF: tray, hotkey hook, recorder, paste, HUD, window, UIA read-back
  LinFlow.Tests/    xUnit: the Mac selftest cases, ported
  native/           the unzipped Release folder from the whisper.cpp zip (gitignored, fetched by scripts/fetch-native.ps1)
  NOTES.md          what the laptop turned out to have (M0 writes it, later milestones append measurements)
```

## Port map

| Mac (Swift) | Windows (C#) | What changes |
|---|---|---|
| TextCleaner.swift (clean pipeline, Glossary, GlossaryMatcher, Replacement) | Core/TextCleaner.cs, Glossary.cs, GlossaryMatcher.cs | Straight port. The dictionary-word guard reads `/usr/share/dict/words` on the Mac, which is BSD web2 (235,976 words). Embed the same list as `Core/Resources/words.txt`, fetched from FreeBSD's `share/dict/web2`. |
| NumberWords.swift | Core/NumberWords.cs | Straight port. |
| LearnedCorrections.swift (LearnedCorrections, CorrectionLearning) | Core/LearnedCorrections.cs | Straight port. |
| Snippets.swift | not planned | See "Not ported" below. |
| Settings.swift | Core/Settings.cs | UserDefaults becomes settings.json. Same keys, same defaults. |
| History.swift | Core/History.cs | Same jsonl, ISO 8601 dates. |
| NotesMerge.swift | Core/NotesMerge.cs | Straight port, first used in M5. |
| Transforms.swift (Transform, Transforms) | not planned | See "Not ported" below. |
| ModelCatalog.swift | Engine/ModelCatalog.cs | Same ids, files, URLs. Search dir is the data dir's `models\`. |
| WhisperEngine.swift, ParakeetEngine.swift, SpeechEngine.swift, the CWhisper shim | Engine/Native.cs, WhisperEngine.cs, ParakeetEngine.cs | P/Invoke. Functions the Swift side uses today: `parakeet_context_default_params, parakeet_init_from_file_with_params, parakeet_full_default_params, parakeet_full, parakeet_full_n_segments, parakeet_full_get_segment_text, parakeet_free, parakeet_log_set` and `whisper_context_default_params, whisper_init_from_file_with_params, whisper_full_default_params, whisper_full, whisper_full_n_segments, whisper_full_get_segment_text, whisper_full_lang_id, whisper_is_multilingual, whisper_lang_id, whisper_lang_str, whisper_vad_default_params, whisper_version, whisper_log_set, whisper_free`. Struct layouts come from `include/whisper.h` and `include/parakeet.h` at the v1.9.1 tag. Same rule as the Mac: load the ggml backends (`ggml_backend_load_all`) before any model init or there are zero devices. Same decode parameters as the Swift engines, reasons in `../README.md`. |
| AudioIO.swift (resample, splitLong), Recorder.swift | Engine/AudioIO.cs, Recorder.cs | NAudio WasapiCapture on the default mic, resampled to 16 kHz mono float. Keep the 28 s (Whisper) and 45 s (Parakeet) split rules and the quietest-200 ms cut. |
| HotkeyMonitor.swift (CGEvent tap on Fn) | App/Hotkey.cs | `WH_KEYBOARD_LL` hook, since a bare modifier as hold-to-talk is exactly what `RegisterHotKey` cannot do. Return from the callback at once and do the work on a queue (a slow hook gets silently removed). Fn is firmware on most laptops and never reaches the hook, so the default is Right Ctrl, changeable in Settings. |
| TextInjector.swift (Cmd+V) | App/Paste.cs | Snapshot every clipboard format, set the text, `SendInput` Ctrl+V, and put the snapshot back after 0.4 s only if `GetClipboardSequenceNumber` has not moved (the Mac uses `changeCount` for the same check). |
| PasteWatcher.swift (Accessibility read-back) | App/PasteWatcher.cs | UI Automation: focused element, `ValuePattern` or `TextPattern`, the same 0.6 s guard then 5 s and 15 s reads, the same `editedVersion` anchor logic. Elements with `IsPassword` are never read. Chromium apps expose text once a UIA client connects, so the AXManualAccessibility step has no Windows counterpart. |
| DictationController.swift | App/DictationController.cs | Same states (idle, recording, transcribing) and the same pipeline without snippets or transforms: clean, paste, watch. |
| HUDPanel.swift, AppDelegate.swift | App/Tray.cs, Hud.xaml | Tray icon with the same menu, a small always-on-top HUD for state. |
| Dashboard/*.swift | App/Dashboard/*.xaml | Dictation, Dictionary, Notetaker, Settings. The Mac's Snippets, Style and Transforms sections are not planned. |
| main.swift (CLI) | Cli/Program.cs | `bench`, `transcribe`, `clean`, `learn-test`, `focus-test`. |
| SelfTest.swift | Tests/*.cs | Every case that needs neither audio hardware nor the Mac's Accessibility becomes an xUnit fact. |
| SystemAudioTap, MeetingRecorder, LiveTranscriber, NotesStore, Summarizer | M5 | `WasapiLoopbackCapture` replaces the Core Audio tap (simpler, no permission prompt). Summaries and transforms need a local LLM: LLamaSharp with a small instruct GGUF, or the Windows AI APIs on a Copilot+ PC. |

## Not ported

Snippets, Style and Transforms stay on the Mac until John uses them. On 2026-09-22 the Mac's
`snippets.json` was empty, there was no `transforms.json` and no per-app rule, and "transform" did
not appear once in 16 days of logs. They cost nothing on the Mac, so they stay there. On Windows
each would be work with no user. The data files keep the Mac's names (`Paths.SnippetsFile`,
`Paths.TransformsFile`), so a later port starts from the same formats.

## Milestones

Each milestone ends when its criterion holds and NOTES.md records what was measured.

### M0. Environment (on the laptop, first session)
1. Record in NOTES.md: GPU vendor and driver, Windows version, `dotnet --version` (install the .NET 8 SDK if absent), and whether Wispr Flow is installed there and which hotkey it binds.
2. Write `scripts/fetch-native.ps1` to fetch `whisper-bin-x64.zip` from the whisper.cpp v1.9.1 release into `native/`, and run it. NVIDIA: also fetch `whisper-cublas-12.4.0-bin-x64.zip` and note whether it loads without a separate CUDA runtime install.
3. Download `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` and `ggml-large-v3-turbo-q5_0.bin` (URLs in `ModelCatalog.swift`) into `%APPDATA%\Lin Flow\models\`.
4. Run `parakeet-cli.exe` and `whisper-cli.exe` on `../scripts/testdata/test.wav`.

Done when both CLIs print the test.wav transcript, the timings are in NOTES.md, and the GPU path (CPU only, cuBLAS, or a Vulkan source build) is decided there.

### M1. Core port and tests
Port the Core rows of the map, then every selftest case that touches them. Add the word list. Copy `replacements.txt`, `vocab.txt` and `snippets.json` from the Mac into the test fixtures.

Done when `dotnet test` is green, NOTES.md records how many Mac cases were ported and which were skipped and why, and the three Mac files load unchanged.

### M2. Engine and CLI
Port the Engine rows and `Cli/Program.cs`.

Done when `linflow bench ../scripts/testdata/test.wav` prints warmed timings for Parakeet and Whisper turbo, and `linflow transcribe` on test.wav matches the Mac transcript.

### M3. Dictation loop
Tray icon, hotkey hook, recorder, controller, paste, HUD, history.

Done when hold-to-talk dictation pastes cleaned text into Notepad, Outlook, Teams and a browser text box, each dictation lands in history.jsonl, and a 60 s dictation comes back whole (the split rule works).

### M4. Window and learning
Dashboard sections, then UIA read-back into the learner with the auto / ask / off setting.

Done when a word fixed in Notepad within 15 s of a paste appears in replacements.txt with the `# learned` marker and the Dictionary section shows it as learned.

### M5. v2: notetaker, transforms, summaries
The notetaker landed 2026-09-17 as `linflow meeting` (console; see NOTES.md), with WASAPI loopback in
place of the Core Audio tap as planned and the Mac's recording rules (crash-safe WAV, shared clock,
watchdog, full pass from the audio). Running notes and the meeting summary landed the same day on a
local model behind Ollama (`qwen2.5:3b` by default), which settles the local-LLM question for notes;
transforms could reuse the same client if they are ever ported. A window for the notetaker is still to come.

## Kick-off prompt for the laptop

> Read `windows/PLAN.md`, then do M0 and write `windows/NOTES.md`.

## Rules that carry over from the Mac

- Once M3 is installed, John dictates with it all day. Test instances run with `LINFLOW_NO_PASTE=1`, use their own hotkey, and are closed before a session ends. Only John closes the app he dictates with. The history behind this rule is in `../CLAUDE.md`.
- Engine parameters follow `../README.md`. Read it before changing one.
- Every guard in the fuzzy matcher, the number rules and the learner has a reason written beside the Swift code. Port the reasons as comments too.
