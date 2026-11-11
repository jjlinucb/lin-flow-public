# Proved promises

Each promise below is proved in Lean 4, and the Lean kernel checks the proof. Lean proves a
model, not the Rust, so each one is tied back to the real code by a test that fails on any
difference.

`cargo test` runs it all. `core/tests/proofs.rs` has Lean check every proof and confirms
`vectors.json` is what the models answer today. CI's Linux job installs Lean for it. Where Lean
is missing (Windows, a cloud session) that test passes with a note, and the tie-in tests below
still run.

## The promises

1. **Spoken commands: Lin Flow runs a take as a command only when it starts with the wake word,
   or with one greeting (hey, ok, okay, hi) and then the wake word. What it hands to Zap is only
   the words said after the wake word, and there has to be at least one. Every other take is
   pasted as dictation.** `LinFlow/Command.lean`, `only_after_the_wake_word`. Code:
   `spoken_command` in `service/src/command.rs`. Tie-in: `service/tests/proofs.rs` runs it on
   the 3,000 takes in `vectors.json`, for the words "Zap" and "Zapdos".
2. **The dictionary file: saving keeps, word for word, every line that isn't a correction (no
   `=>` in it, or it starts with #). Reading the saved file back gives exactly the corrections
   that were saved, in the same order.** `LinFlow/Dictionary.lean`. Code: `replacements_file`
   and `parse_replacements` in `core/src/text/glossary.rs`. Tie-in: the `dictionary_save_*`
   laws in `core/tests/laws.rs`.

## What is not proved

- The command key and the `heard_as` mishearings (`Hook::command`), and letters outside ASCII.
- A line with `=>` that the parser cannot read, such as `=> Lin Flow` with nothing before the
  arrow, is dropped on save. `dictionary_save_drops_an_arrow_with_nothing_before_it` pins it.
  Whether to keep such a line is John's call.
- The vectors and laws are samples, not every input.

## Running it

Lean 4.35.0 through elan (`~/.elan/bin`). `cd next/proofs && lake build` checks only the proofs.
