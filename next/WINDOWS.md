# Lin Flow on Windows

The Rust app in `next/` is Lin Flow on every computer John uses. The C# app in `windows/` and the
Swift app are retired, and "Lin Flow Next" was only its name while it ran beside them. On
2026-10-27 John asked for Windows to be Lin Flow too, and for each new build to arrive by clicking
Update, without a zip carried over by hand.

The Mac and Windows share this code and the same sync. They differ only in how a build is made and
installed:

| | Mac | Windows |
|---|---|---|
| Who builds | `next/scripts/mac-build.sh` on the Mac | CI, `windows-app` in `.github/workflows/next.yml`, on every green push to `main` |
| How | `LINFLOW_APP_FOLDER="Lin Flow" npx tauri build --config '{"productName":"Lin Flow"}'` | `LINFLOW_APP_FOLDER="Lin Flow" npx tauri build --no-bundle --config src-tauri/tauri.windows-lin-flow.json` |
| Installed at | `/Applications/Lin Flow.app` | `%LOCALAPPDATA%\Programs\Lin Flow\lin-flow.exe`, with `linflow.exe` and `native\` |
| Data | `~/Library/Application Support/Lin Flow` | `%APPDATA%\Lin Flow` |
| Updates | `mac-build.sh --install`, when John asks | Settings > App > Updates > Check for updates, then Update |
| Tray / menu bar | black template mic, tinted by macOS | the Lin Flow mark (`icons/windows/tray.png`), with a red dot while recording |
| App icon | `icons/icon.icns` | `icons/windows/lin-flow.ico`, the C# app's full-size mark |

## How an update reaches a Windows computer

1. A change lands on `main`, from the Mac or from a work PC, through a pull request.
2. `windows-app` builds Lin Flow, then **Check the app before anyone gets it** refuses the build
   unless the exe has its window inside it (`/assets/`), calls itself Lin Flow, and `linflow
   doctor` reads `%APPDATA%\Lin Flow`.
3. Only then does it replace the `windows-latest` release with `lin-flow-windows.zip`.
4. On each PC, John clicks Check for updates, then Update. Lin Flow downloads the zip, quits,
   `scripts/update-swap.ps1` swaps the install folder and opens it again. A copy that won't start
   is never swapped in. Nothing updates by itself, and never while a meeting records.

The data folder is never touched by an update, so history, dictionary, talk key and `sync.env`
carry on.

## Rules for any change, from either side

- **Build Windows only through the Tauri CLI.** A plain `cargo build -p lin-flow-next` leaves the
  window out (no `custom-protocol`), and the app opens to "localhost refused to connect". The
  release of `ea50382` on 2026-10-27 shipped that way, which is why the check in step 2 exists.
  Don't remove the check to get a build through.
- **Keep `LINFLOW_APP_FOLDER: Lin Flow` on the Windows build,** for both exes. Without it the app
  opens an empty `Lin Flow Next` folder: no history, no sync, the default talk key.
- **Keep the release name and asset,** `windows-latest` and `lin-flow-windows.zip`
  (`core/src/update.rs`). Every installed copy looks for exactly those. Renaming either strands
  every Windows PC on its current build.
- **Keep the exe name `lin-flow.exe`.** Shortcuts, the swap script and Startup point at it. The
  Cargo binary is still `lin-flow-next`, and the Windows package renames it, so the Mac is
  unaffected.
- **Update starts PowerShell with a hidden window only** (`powershell()` in
  `service/src/update.rs`). Adding DETACHED_PROCESS makes Windows PowerShell 5.1 exit without
  running the swap, so Lin Flow quits and doesn't come back. A Windows test starts it the same way.
- **Tray icons are per platform** (`TRAY_IDLE` and `TRAY_BUSY` in `app/src-tauri/src/main.rs`).
  A new Mac tray glyph doesn't change Windows, and the reverse.
- Mac-only and Windows-only code stays behind `cfg`. Anything shared runs on both, so CI's
  `windows` job (tests and clippy on Windows) has to pass before a merge.

## Per computer

| Computer | Talk key | Sync name |
|---|---|---|
| MBC253, Multibeam desktop | middle mouse button | MB Desktop MBC253 |
| MBC262, Multibeam laptop | Right Ctrl + Right Alt | its own `sync.env` |
| Mac | Fn | John Macbook |

The talk key lives in each computer's `settings.json` and survives updates. A cut-over build with
no key saved falls back to Left Ctrl + Left Alt on Windows (`context::default_hotkey`).

## First install on a Windows computer

Once per computer, with Lin Flow quit:

```
powershell -ExecutionPolicy Bypass -File next\scripts\windows.ps1 -Zip <path to lin-flow-windows.zip>
```

It installs to `%LOCALAPPDATA%\Programs\Lin Flow`. On a computer that ran Lin Flow Next, it also
moves `%APPDATA%\Lin Flow Next` to `%APPDATA%\Lin Flow`, renames anything the C# app left to
"(C# app)", and makes "Lin Flow" shortcuts in the Start menu and Startup. Re-pin the taskbar by
hand. After that, Update in Settings does the rest.

Don't save a Claude key on a work PC: meeting transcripts stay on the computer.
