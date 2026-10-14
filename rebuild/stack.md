# Stack: Rust underneath, TypeScript on screen

**Updated:** 2026-10-02. **Status:** chosen and built, for John's review. The brief asked for a
recommendation and John's choice. John said to keep building, so this records the choice taken.

**Recommendation, as built:** Rust for everything below the window, and TypeScript for the window,
joined by Tauri 2. One codebase compiles into the Mac app and the Windows app. The parts that differ
per system are small Rust modules behind one interface.

## Why not the other two

| Option | What it would cost here |
|---|---|
| **TypeScript and Electron** | Node cannot hook the keyboard. The usual add-on sees keys but cannot swallow them, so Fn would open the emoji picker on every dictation. Pasting, reading text back, the meeting audio tap and whisper.cpp would all be native add-ons in C++ or Objective-C anyway. The app grows to about 150 MB. |
| **Rust with a native toolkit** (egui, Slint, iced) | Everything below the window is the same as the choice. The window is harder: selecting and copying text, the Mac's look on Windows, and Markdown summaries are each work these toolkits do poorly. |
| **Rust and Tauri** (chosen) | Rust does the system work directly on both. The window is HTML, CSS and TypeScript in the system's web view: WKWebView on the Mac, WebView2 on Windows, which Windows 10 and 11 already have. The app is a few MB plus the models. |

## The hard parts, system by system

### The global talk key, Fn and mouse buttons included

| | Mac | Windows |
|---|---|---|
| How | A Core Graphics event tap, called directly from Rust | Low-level keyboard and mouse hooks (`WH_KEYBOARD_LL`, `WH_MOUSE_LL`) on their own message thread |
| Fn | Seen as its own key, and its events swallowed so the Globe action never fires | Not possible. Fn is handled by the keyboard's firmware and never reaches Windows |
| Mouse buttons | Extra buttons seen and swallowed while held | The same |
| Needs | Accessibility and Input Monitoring grants, tied to the app's signature | Nothing |
| Cannot | Run before John grants access. Settings says so and opens the request | See Fn |

### Pasting, and reading the text back

| | Mac | Windows |
|---|---|---|
| Paste | The pasteboard, every type snapshotted, then a synthetic Cmd+V | The clipboard, every format snapshotted, then `SendInput` Ctrl+V |
| Restore | 0.4 s later, only if nothing else wrote to the clipboard | The same, by the clipboard's sequence number |
| Read back | Accessibility: the focused field's value | UI Automation: `ValuePattern` or `TextPattern` |
| Cannot | Read apps that expose nothing to Accessibility. Editing in the window teaches instead | The same. Password fields are never read on either |

### Recording both sides of a meeting

| | Mac | Windows |
|---|---|---|
| Microphone | Core Audio through `cpal`, a fresh stream per take | WASAPI through `cpal` |
| The call's audio | A Core Audio process tap on the output device, through an aggregate device. Rust calls it directly: `cpal` cannot | WASAPI loopback on the output device, plus a silent stream that keeps it delivering while nothing plays |
| Needs | macOS 14.2 or newer, and the System Audio Recording grant | Nothing |
| Cannot | Record a call routed to a device other than the default output | The same |

### The speech engines

| | Mac | Windows |
|---|---|---|
| How | whisper.cpp's `libwhisper` and `libparakeet` from Homebrew, loaded at run time | The official release DLLs, loaded at run time |
| Why at run time | Nothing in C is compiled into the app, so the Mac can build and check the Windows app, and a `brew upgrade` needs no rebuild | The same |
| Guard | The parameter structs are copied from the headers, and Parakeet's are read back and checked before the first decode | The same |
| Timing | 0.15 s Parakeet, 1.3 s Whisper turbo on the M1 Pro, the same as the Swift app | Not yet measured for Next. The C# app runs the same DLLs |

### Summaries and running notes

| | Mac | Windows |
|---|---|---|
| Apple Intelligence | Not reachable from Rust: its API is Swift only. A small Swift helper could bring it back | Not on Windows |
| Claude | HTTPS to the API with John's key. Summaries, recaps and Ask Claude | The same |
| Ollama | HTTP to `127.0.0.1:11434`. Running notes, and summaries when no key is saved | The same |

### Keeping the computers updated

`fleet.sh` builds each computer's app from `main`. For Next it becomes `npm run build` and
`cargo tauri build` on each computer, then the same install steps. Tauri's own updater is not used:
it ships one build to every computer, and John wants each computer to build its own.

### The shared dictionary and totals

Plain HTTPS to Supabase's REST API through `ureq`, with the system's own TLS, Security on the Mac and
SChannel on Windows, so nothing in C is compiled. The merge is pure Rust in the core, checked
against the Swift app's and by the sync law.

## What this stack costs

- **Two languages instead of one.** Rust below, TypeScript in the window. The line between them is
  one file of typed commands and events: `next/app/src/api.ts`.
- **Unsafe code at the system edges.** The event tap, Accessibility, the audio tap and the Windows
  hooks are foreign calls. They are kept in `next/platform`, small, and each wraps one system API.
- **The Windows app is built on the Mac but run only on Windows.** The Mac cross-checks it on every
  change. Hooks, paste, UI Automation and loopback can only be proven on DESK-01 or LAPTOP-02.
- **WebView2 on Windows.** Preinstalled on Windows 10 and 11. If a machine lacks it, the installer
  fetches it.
