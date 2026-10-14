#!/usr/bin/env python3
"""The oracle: the installed apps' text pipeline is the definition of right, and the Rust core
has to agree with it on every input, or show each difference.

    python3 next/oracle/oracle.py              generated inputs, synthetic dictionary
    python3 next/oracle/oracle.py --history    also John's history.jsonl, with his dictionary

The Swift side is `.build/debug/LinFlow clean-batch` (build it first); the Rust side is
`next/target/release/linflow clean-batch`. Both read their dictionary from LINFLOW_DATA_DIR.

Generated inputs matter more than the history: in the NumberWords trial (2026-10-02) a planted
year bug passed all 482 numbered dictations and was caught only by generated ones. So this runs
every one-to-three-word run over a vocabulary of number, date and decimal words, and seeded
random sentences built from fragments that exercise each rule. John's dictation text never
leaves the temp folder: nothing it reads or writes is in the repo.
"""

import itertools
import json
import os
import random
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SWIFT = os.path.join(ROOT, ".build/debug/LinFlow")
RUST = os.path.join(ROOT, "next/target/release/linflow")
REAL_DATA = os.path.expanduser("~/Library/Application Support/Lin Flow")

VOCAB = """John Lin
Lin Flow
Wispr Flow
Parakeet
whisper.cpp
WORKBRAIN
Claude
Claude Code
GitHub
Northwind
Sunnyvale
Santa Cruz
Cambodia
kkwinedf
gws cli
Marisa Vuong
"""

RULES = """# synthetic rules for the oracle
wisper flow => Wispr Flow
K Wynn E D F => kkwinedf
GWS C L I => gws cli
Hasim => Hazim	# learned
Marissa vo => Marisa Vuong
quad => Claude
"""

NUMBER_WORDS = [
    "zero", "one", "two", "three", "five", "seven", "nine", "ten", "eleven", "thirteen", "nineteen", "twenty", "thirty",
    "ninety", "hundred", "thousand", "million", "and", "a", "point", "oh", "first", "second", "twenty-one", "the", "of",
    "September", "may", "hours", "people", "-", ",", "half",
]

FRAGMENTS = [
    "um", "uh", "Um,", "uh,", "er", "erm", "ah", "hmm", "mm-hmm", "mhm", "the ER, uh, was full", "you know,", "you know the answer",
    "I mean,", "like", "so", "new line", "new paragraph", "question mark", "exclamation mark", "exclamation point", "comma enter enter",
    "period enter", "enter enter", "press enter", "after the trial period, enter your card", "Comma, enter, enter.", "colon enter",
    "full stop enter enter", "Lend Flow", "Len Flow", "LinFlow", "linflow", "Linflow's", "Whisper Flow", "wisper flow", "work brain",
    "Workbrain", "git hub", "githubs", "Parakeets", "parakeet", "Claude's code", "Claude coded", "cloud", "clause", "Cloud Code",
    "John Lynn", "John Lee", "John Liu", "Johnson", "Sunny Veil", "Santa Cruise", "Cambodian", "Cambodians", "multi-team",
    "K Wynn E D F", "GWS C L I", "Hasim", "Marissa vo", "quad", "Quad", "twenty two", "one of the reasons", "no one knows", "one hour",
    "a hundred", "a hundred forty volts", "a few hundred", "thousands of them", "nineteen eighty four", "twenty twenty six",
    "twenty thirty", "panels one and two", "eight hundred and seven hundred", "two thousand five, three thousand", "one-on-one",
    "the twenty second", "September thirtieth", "September twenty first", "the thirtieth of September", "you may first check",
    "march on", "March fifth", "Opus five point five", "three point one four", "version two point oh", "five point five million",
    "one point five hours", "we made two points", "thanks a million", "one in a million", "3 45 p.m.", "7.15 am", "at 10 30 a.m.",
    "e.g.", "i.e.", "etc.", "Mr. Smith", "Dr. Who", "the U.S. team", "example.com", "whisper.cpp", "whisper.cpp. It",
    "https://x.com/a?b=c", "[BLANK_AUDIO]", "[MUSIC]", "(music)", "(laughs)", "(408) 555-1234", "(Parakeet)", "*laughs*", "♪", "♪♪",
    "Thank you.", "—", "–", " - ", ";", ":", "...", "!!", "??", ",,", "\"quoted\"", "'single'", "“curly”", "(aside)", "[1]",
    "café", "naïve", "Straße", "ß", "ﬁ", "日本語です", "中文", "ខ្មែរ", "é", "👍🏽", "İstanbul", "ΣΑΣ", "Ωmega", "über", "Ελλάδα",
    "", " ", "\t", "\n", "ok", "OK", "yes", "Yes", "i", "a", "the", "is", "it's", "don't", "rock 'n' roll",
]

SEPARATORS = [" ", " ", " ", ", ", ". ", "? ", "! ", "; ", " - ", " — ", "\n", "\n\n", "  ", ",", ":", " (", ") "]


def number_runs():
    for n in (1, 2, 3):
        for combo in itertools.product(NUMBER_WORDS, repeat=n):
            yield " ".join(combo).replace(" - ", "-").replace(" ,", ",")


def random_sentences(count, seed):
    rng = random.Random(seed)
    for _ in range(count):
        parts = []
        for _ in range(rng.randint(1, 12)):
            parts.append(rng.choice(FRAGMENTS))
            parts.append(rng.choice(SEPARATORS))
        text = "".join(parts)
        if rng.random() < 0.3:
            text = text.capitalize()
        yield text


def run(binary, inputs, data_dir):
    env = dict(os.environ, LINFLOW_DATA_DIR=data_dir)
    payload = "".join(json.dumps(s) + "\n" for s in inputs)
    out = subprocess.run([binary, "clean-batch"], input=payload, capture_output=True, text=True, env=env, check=True).stdout
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def compare(label, inputs, data_dir, show=8):
    inputs = [s for s in inputs if s.strip()]
    swift = run(SWIFT, inputs, data_dir)
    rust = run(RUST, inputs, data_dir)
    assert len(swift) == len(inputs) == len(rust), (len(swift), len(inputs), len(rust))
    diffs = [(i, s, r) for i, (s, r) in enumerate(zip(swift, rust)) if s != r]
    print(f"{label}: {len(inputs)} compared, {len(diffs)} differ")
    return diffs, inputs


def main():
    history = "--history" in sys.argv
    seed = 42
    total = 0
    failed = False
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "vocab.txt"), "w") as f:
            f.write(VOCAB)
        with open(os.path.join(tmp, "replacements.txt"), "w") as f:
            f.write(RULES)
        runs = list(number_runs())
        sentences = list(random_sentences(60_000, seed))
        for label, inputs in (("number runs of 1 to 3 words", runs), (f"random sentences (seed {seed})", sentences)):
            diffs, used = compare(label, inputs, tmp)
            total += len(used)
            for i, s, r in diffs[:8]:
                print(f"  in:    {json.dumps(used[i])}\n  swift: {json.dumps(s)}\n  rust:  {json.dumps(r)}")
            failed |= bool(diffs)
    if history:
        raws = []
        with open(os.path.join(REAL_DATA, "history.jsonl")) as f:
            for line in f:
                try:
                    raw = json.loads(line).get("raw")
                except ValueError:
                    continue
                if raw:
                    raws.append(raw)
        diffs, used = compare("John's dictations, his dictionary", raws, REAL_DATA)
        total += len(used)
        # Counts only: his dictation text stays out of anything this prints.
        failed |= bool(diffs)
    print(f"total {total} compared, {'DISAGREEMENTS' if failed else '0 disagreements'}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
