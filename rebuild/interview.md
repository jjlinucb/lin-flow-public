# Rebuild interview log

The answers John gives in the interview `REBUILD-PROMPT.md` asks for, one per question, in order.
Each phase's document is written from this log. No dictation text goes in this file.

## Phase 1: inventory

Sources read so far: `README.md` (Using it, The window), `windows/PLAN.md` (port map, not ported),
`windows/NOTES.md` (decisions that differ from the plan, known divergences, the hotkey default).

Divergences found before the first question:

- Mac only: Snippets, Style (None, Light, Medium with an Apple Intelligence rewrite), Transforms and
  per-app rules, the Whisper engine and its language menu, asking Claude about a meeting (PR #35),
  dropping the mic's echo of the other side (PR #34), the stuck-audio repair (PR #33), Recent
  Dictations in the menu, Show in Dock.
- Different by platform: talk key default (Fn on the Mac, Right Alt on Windows, after Right Ctrl
  turned out to be a Copilot key on LAPTOP-02); summaries (Apple Intelligence or Claude on the Mac,
  Ollama `qwen2.5:3b` on Windows); system audio (Core Audio tap, WASAPI loopback); window (SwiftUI,
  WinForms with a Mac look).
- Known text differences recorded 2026-09-15: hand-edited lines in `replacements.txt` kept on the
  Mac and dropped on Windows; lowercase dictionary terms protected from sentence capitalization on
  the Mac only. To check whether either has since been ported.
- CLI: Mac has `models download selftest toast-shot notes-test summarize ask running-notes-test
  paste mic-test learn-test focus-test bench transcribe clean`; Windows has `doctor meeting notes
  version` that the Mac lacks.

## Answers

1. **Mac-only features (2026-10-02).** On both computers: Ask Claude, echo removal, the stuck-audio
   repair (its Windows form to be worked out), Whisper with the language menu. Not chosen: Snippets,
   Style and Transforms. Read as out of the rebuild; confirm at the inventory review.
2. **Lowercase dictionary terms at a sentence start (2026-10-02).** Stay lowercase, the Mac's way.
   Windows capitalizes them today (`CapitalizeSentences` has no protected set).

## Phases 2 to 4

Not interviewed. On 2026-10-02 John said to keep building until Lin Flow is done in Rust and
TypeScript, so the review gates gave way to building, and every choice made without him is
written down for him to correct:

- `inventory.md`, "Decisions for John": Snippets, Style and Transforms out, no Apple
  Intelligence, no Recent Dictations menu, Next's talk key beside the installed app, and the fleet
  at cut-over.
- `stack.md`: Rust under a TypeScript window, joined by Tauri.
- `architecture.md`: the core, the shells, and the cut-over steps.
- `verification.md`: nine laws awaiting his verdict, with five proposed fixes or leaves.
