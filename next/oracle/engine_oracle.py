#!/usr/bin/env python3
"""Compares speech-to-text output between the Swift app and the Rust rebuild, model by model.

Every clip in scripts/testdata/corpus, plus one long clip made by joining them with a second of
silence between, so the long-audio path (decoding in pieces cut at quiet points) runs too. Raw
engine text with a fixed prompt, so the dictionary cannot make a difference.

    python3 next/oracle/engine_oracle.py [--models parakeet-tdt-0.6b-v3-q8_0,large-v3-turbo-q5_0]
"""

import argparse
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFT = ROOT / ".build/debug/LinFlow"
RUST = ROOT / "next/target/debug/linflow"
CORPUS = ROOT / "scripts/testdata/corpus"


def joined(clips, out):
    with wave.open(str(out), "wb") as w:
        params = None
        for c in clips:
            with wave.open(str(c), "rb") as r:
                if params is None:
                    params = r.getparams()
                    w.setparams(params)
                w.writeframes(r.readframes(r.getnframes()))
                w.writeframes(b"\0" * params.sampwidth * params.nchannels * params.framerate)
    return out


def run(binary, clip, model):
    p = subprocess.run([str(binary), "transcribe", str(clip), "--model", model, "--raw", "--prompt", "Lin Flow"], capture_output=True, text=True)
    timing = p.stderr.strip().splitlines()[-1] if p.stderr.strip() else ""
    return p.stdout.strip(), timing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default="parakeet-tdt-0.6b-v3-q8_0,large-v3-turbo-q5_0")
    args = ap.parse_args()
    clips = sorted(CORPUS.glob("*.wav"))
    tmp = Path(tempfile.mkdtemp())
    long = joined(clips, tmp / "joined.wav")
    with wave.open(str(long)) as w:
        print(f"{len(clips)} clips, and one of {w.getnframes() / w.getframerate():.0f} s joined")
    bad = 0
    for model in args.models.split(","):
        same = 0
        for clip in clips + [long]:
            a, ta = run(SWIFT, clip, model)
            b, tb = run(RUST, clip, model)
            if a == b:
                same += 1
            else:
                bad += 1
                print(f"  DIFFERENT {model} {clip.name}\n    swift: {a}\n    rust:  {b}")
            if clip == long:
                print(f"  {model} joined clip: swift {ta}  rust {tb}  ({len(a.split())} words)")
        print(f"{model}: {same}/{len(clips) + 1} identical")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
