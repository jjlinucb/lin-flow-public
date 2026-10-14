#!/usr/bin/env python3
"""Compares the notetaker's pure logic between the Swift app and the Rust rebuild.

Both CLIs answer the same JSON requests through `notes-batch`: speech regions, echo removal,
the running-notes filter, list tidying, the summary merge, transcript splitting. This makes
the requests: generated ones with a fixed seed, and with --real, ones built read-only from the
meetings in the Mac app's notes folder, whose text is never printed.

    python3 next/oracle/notes_oracle.py [--n 3000] [--seed 7] [--real]
"""

import argparse
import json
import os
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFT = ROOT / ".build/debug/LinFlow"
RUST = ROOT / "next/target/debug/linflow"

WORDS = """the county permit inspection we need to call about fee team build stable next week deadline
budget approved finance onboarding checklist overview overviewing overviewed forms send schedule
meeting minutes agreed decided pending unclear question whether should could would will might
yeah okay so um actually basically right good great thanks hello bye food safety hands wash
restroom surfaces doorknobs phones training permit's it's don't can't I'll we're they've""".split()
NAMES = ["Ted", "Anna", "Marcus", "John", "Sarah", "Kim", "Lee", "Maria", "Jose", "Claude", "Zoom", "Parakeet", "CNFA"]
NUMBERS = ["2", "18th", "40,000", "$40,000", "1st", "3rd", "22nd", "two", "five", "forty", "thousand", "first", "10:30",
           "١٢", "１２", "½", "2nd,", "5.", "(7)", "100%", "3,4,5", "0", "05"]
DATES = ["Monday", "Friday", "October", "May", "tomorrow", "tonight", "yesterday", "December"]
ODD = ["e\u0301te\u0301", "\u00e9t\u00e9", "Ame\u0301lie", "Am\u00e9lie", "cafe\u0301", "café", "ΣΑΣ", "İstanbul", "naïve", "👍", "👩‍💻", " ", "Mr.", "Dr.", "J.", "etc.", "U.S.", "vs.",
       "it’s", "“quoted”", "(aside)", "—", "–", "…", "\r\n", "\t", "ẍ"]
MARKERS = ["* ", "- ", "• ", "–", "—", "1. ", "2) ", "12. ", "123. ", "*", "-", "**", "", "", "", "   ", "_", "**Bold** "]
NONES = ["None", "None.", "N/A", "No decisions were made", "None mentioned", "no action items", "Nothing", "none yet!", "No."]


def word(r):
    roll = r.random()
    if roll < 0.55:
        return r.choice(WORDS)
    if roll < 0.68:
        return r.choice(NAMES)
    if roll < 0.80:
        return r.choice(NUMBERS)
    if roll < 0.88:
        return r.choice(DATES)
    return r.choice(ODD)


def sentence(r, lo=2, hi=14):
    words = [word(r) for _ in range(r.randint(lo, hi))]
    if words and r.random() < 0.7:
        words[0] = words[0][:1].upper() + words[0][1:]
    s = " ".join(words)
    return s + r.choice([".", ".", "?", "!", "", ":", "...", ".)"])


def bullet(r):
    roll = r.random()
    if roll < 0.12:
        return r.choice(MARKERS) + r.choice(NONES)
    if roll < 0.25:
        return r.choice(MARKERS) + r.choice(["Task", "Action item", "Name", "Next steps", "Q"]) + ": " + sentence(r, 0, 8)
    if roll < 0.35:
        return r.choice(MARKERS) + r.choice(["You: ", "Others: ", "You : "]) + " ".join(sentence(r) for _ in range(r.randint(1, 3)))
    if roll < 0.45:
        return r.choice(["**", "_", "*"]) + sentence(r) + r.choice(["**", "_", "*", ""])
    return r.choice(MARKERS) + " ".join(sentence(r) for _ in range(r.randint(1, 2)))


def transcript(r, lines=None):
    out = []
    t = 0
    for _ in range(lines or r.randint(1, 12)):
        t += r.randint(1, 40)
        out.append(f"[{t // 60}:{t % 60:02d}] {r.choice(['You', 'Others'])}: {sentence(r, 3, 20)}")
    return "\n".join(out)


def levels(r):
    out = []
    for _ in range(r.randint(0, 40)):
        speech = r.random() < 0.5
        n = r.randint(1, 60) if r.random() < 0.9 else r.randint(100, 400)
        for _ in range(n):
            if speech:
                out.append(round(r.uniform(0.005, 0.3), 6))
            else:
                out.append(round(r.uniform(0.0, 0.006), 6) if r.random() < 0.95 else 0.0)
    return out


def segments(r):
    segs = []
    t = 0.0
    for _ in range(r.randint(1, 14)):
        t += r.uniform(0, 8)
        dur = r.uniform(0.3, 9)
        text = sentence(r, 1, 18)
        segs.append({"start": round(t, 3), "end": round(t + dur, 3), "speaker": "Others", "text": text})
        if r.random() < 0.6:
            words = text.split()
            if r.random() < 0.5 and len(words) > 2:
                cut = r.randint(0, len(words) - 2)
                words = words[cut:cut + r.randint(2, len(words))]
            if r.random() < 0.4:
                words.insert(r.randint(0, len(words)), word(r))
            echo = " ".join(words).lower() if r.random() < 0.5 else " ".join(words)
            shift = r.uniform(-1.5, 1.5)
            segs.append({"start": round(t + shift, 3), "end": round(t + dur + shift, 3), "speaker": "You", "text": echo})
        if r.random() < 0.3:
            segs.append({"start": round(t + r.uniform(-3, 12), 3), "end": round(t + r.uniform(12, 20), 3), "speaker": r.choice(["You", "Others", "Someone"]), "text": sentence(r)})
    r.shuffle(segs)
    return segs


def notes_file(r):
    lines = []
    for _ in range(r.randint(0, 15)):
        roll = r.random()
        if roll < 0.6:
            lines.append(f"{r.choice(['- ', '* ', '  - ', '-', '• '])}[{r.randint(0, 59)}:{r.randint(0, 59):02d}] {sentence(r)}")
        elif roll < 0.8:
            lines.append(r.choice(["- ", "* "]) + sentence(r))
        else:
            lines.append(r.choice(["", "## Heading", "plain text", "- [1:00]", "- [broken", "\r"]))
    return r.choice(["\n", "\r\n", "\n\n"]).join(lines)


LEARN_NAMES = ["Siena", "Verona", "Marissa", "Marisa", "Wong", "Vuong", "Duarte", "Wort", "Claude", "cloud", "Lin Flow", "Linflow", "Brona",
               "Thursday", "Tuesday", "Parakeet", "parakeet", "Marcus", "Markus", "Kim", "Kym", "Zoom", "zoom", "Northwind", "north wind"]
PLACEHOLDERS = ["Type / for commands", "Message #general", "Reply...", "", "Write a comment", "Search"]


def edit(r, text):
    words = text.split()
    if not words:
        return text
    roll = r.random()
    if roll < 0.35:
        words[r.randrange(len(words))] = r.choice(LEARN_NAMES)
    elif roll < 0.55:
        i = r.randrange(len(words))
        w = words[i]
        if len(w) > 2:
            j = r.randrange(len(w))
            w = w[:j] + r.choice("aeiouyhnrst") + w[j + 1:]
        words[i] = w
    elif roll < 0.65:
        words.insert(r.randrange(len(words) + 1), r.choice(WORDS))
    elif roll < 0.72 and len(words) > 1:
        del words[r.randrange(len(words))]
    elif roll < 0.8:
        return r.choice(PLACEHOLDERS)
    elif roll < 0.86:
        return sentence(r)
    out = " ".join(words)
    if r.random() < 0.3:
        out = out.lower() if r.random() < 0.5 else out.capitalize()
    return out


def learning(r):
    wrote = " ".join(r.choice(LEARN_NAMES + WORDS[:40]) for _ in range(r.randint(1, 9))) + r.choice([".", "", "?", ","])
    now = edit(r, wrote)
    if r.random() < 0.25:
        now = edit(r, now)
    op = r.choice(["edited", "edited", "scored", "lone-pair", "word-checks", "merging"])
    if op == "edited":
        if r.random() < 0.3:
            # A long document around the phrase.
            now = " ".join(sentence(r) for _ in range(r.randint(10, 40))) + " " + now + " " + " ".join(sentence(r) for _ in range(r.randint(0, 30)))
        return {"op": op, "wrote": wrote, "now": now}
    if op in ("scored", "lone-pair"):
        existing = [{"from": r.choice(LEARN_NAMES), "to": r.choice(LEARN_NAMES), "learned": r.random() < 0.5} for _ in range(r.randint(0, 3))]
        return {"op": op, "wrote": wrote, "now": now, "existing": existing}
    if op == "word-checks":
        a = r.choice(LEARN_NAMES + WORDS)
        b = r.choice([edit(r, a), r.choice(LEARN_NAMES), a.upper(), a.capitalize(), a + "s"])
        return {"op": op, "from": a, "to": b}
    rep = lambda: {"from": r.choice(LEARN_NAMES), "to": r.choice(LEARN_NAMES), "learned": r.random() < 0.5}
    return {"op": op, "candidate": rep(), "waiting": [rep() for _ in range(r.randint(0, 4))], "accepted": [rep() for _ in range(r.randint(0, 3))]}


def generated(n, seed):
    r = random.Random(seed)
    reqs = []
    for _ in range(n):
        op = r.choice(["regions", "echo", "filter", "grounded", "worth", "repeats", "recent", "wordcount", "tidy", "merge", "split", "tail", "learn", "learn", "learn"])
        if op == "learn":
            reqs.append(learning(r))
        elif op == "regions":
            lv = levels(r)
            total = len(lv) * 1600 + r.choice([0, 0, -r.randint(0, 1599), r.randint(0, 3000)])
            reqs.append({"op": op, "levels": lv, "total": max(0, total)})
        elif op == "echo":
            reqs.append({"op": op, "segments": segments(r)})
        elif op == "filter":
            reqs.append({"op": op, "bullets": [bullet(r) for _ in range(r.randint(0, 5))], "previous": [sentence(r) for _ in range(r.randint(0, 4))], "transcript": transcript(r)})
        elif op == "grounded":
            reqs.append({"op": op, "bullet": sentence(r), "transcript": transcript(r), "previous": [sentence(r) for _ in range(r.randint(0, 3))]})
        elif op == "worth":
            reqs.append({"op": op, "bullet": bullet(r)})
        elif op == "repeats":
            base = [sentence(r) for _ in range(r.randint(0, 4))]
            near = [" ".join(r.sample(b.split(), max(1, len(b.split()) - r.randint(0, 2)))) for b in base if b.split()]
            reqs.append({"op": op, "bullets": near + [sentence(r) for _ in range(r.randint(0, 4))], "previous": base[: r.randint(0, len(base))]})
        elif op == "recent":
            reqs.append({"op": op, "notes": notes_file(r), "count": r.randint(0, 12)})
        elif op == "wordcount":
            reqs.append({"op": op, "text": r.choice(["", " ", "\n"]).join(sentence(r) for _ in range(r.randint(0, 4))) + r.choice(["", " ", " x", "\r\n"])})
        elif op == "tidy":
            reqs.append({"op": op, "items": [bullet(r) for _ in range(r.randint(0, 8))]})
        elif op == "merge":
            parts = [[[bullet(r) for _ in range(r.randint(0, 5))] for _ in range(4)] for _ in range(r.randint(0, 4))]
            # Near repeats across parts, to exercise the shorter-phrasing rule.
            if len(parts) > 1 and parts[0][0]:
                parts[1][0].append(parts[0][0][0] + " " + word(r))
            reqs.append({"op": op, "parts": parts})
        else:
            text = transcript(r, r.randint(0, 30))
            if r.random() < 0.2:
                text += "\n" + "x" * r.randint(50, 400)
            reqs.append({"op": op, "text": text, "max": r.randint(1, 600)})
    return reqs


def real():
    """Requests built from the Mac app's saved meetings, read in place. Nothing is printed."""
    base = Path(os.environ.get("LINFLOW_REAL_NOTES", Path.home() / "Library/Application Support/Lin Flow/notes"))
    reqs = []
    for folder in sorted(base.iterdir()) if base.exists() else []:
        segs = []
        for name in ["transcript.jsonl", "transcript-live.jsonl"]:
            p = folder / name
            if p.exists():
                for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
                    try:
                        d = json.loads(line)
                        segs.append({"start": d["start"], "end": d["end"], "speaker": d["speaker"], "text": d["text"]})
                    except (ValueError, KeyError):
                        pass
        if segs:
            reqs.append({"op": "echo", "segments": segs})
            text = "\n".join(f"[{int(s['start']) // 60}:{int(s['start']) % 60:02d}] {s['speaker']}: {s['text']}" for s in segs)
            for m in [400, 1500, 6500]:
                reqs.append({"op": "split", "text": text, "max": m})
                reqs.append({"op": "tail", "text": text, "max": m})
            for s in segs:
                reqs.append({"op": "wordcount", "text": s["text"]})
        for wav in sorted(folder.glob("audio-*.wav")):
            reqs.append({"op": "track", "path": str(wav)})
        running = folder / "running-notes.md"
        if running.exists():
            notes = running.read_text(encoding="utf-8", errors="replace")
            reqs.append({"op": "recent", "notes": notes, "count": 10})
            bullets = [l for l in notes.splitlines() if l.strip()]
            reqs.append({"op": "tidy", "items": bullets})
            if segs:
                text = "\n".join(s["text"] for s in segs)
                for i in range(0, len(bullets), 5):
                    reqs.append({"op": "filter", "bullets": bullets[i:i + 5], "previous": bullets[max(0, i - 10):i], "transcript": text})
        summary = folder / "summary.md"
        if summary.exists():
            lines = summary.read_text(encoding="utf-8", errors="replace").splitlines()
            reqs.append({"op": "tidy", "items": lines})
            reqs.append({"op": "merge", "parts": [[lines[:8], lines[8:12], lines[12:20], lines[20:26]]]})
    return reqs


def run(binary, reqs):
    payload = "".join(json.dumps(q, ensure_ascii=False) + "\n" for q in reqs)
    out = subprocess.run([str(binary), "notes-batch"], input=payload.encode(), capture_output=True, check=True).stdout.decode()
    return [json.loads(l)["out"] for l in out.splitlines() if l.strip()]


def compare(label, reqs, show):
    a, b = run(SWIFT, reqs), run(RUST, reqs)
    assert len(a) == len(b) == len(reqs), (len(a), len(b), len(reqs))
    by_op = {}
    bad = []
    for q, x, y in zip(reqs, a, b):
        ok = x == y
        by_op.setdefault(q["op"], [0, 0])[0 if ok else 1] += 1
        if not ok:
            bad.append((q, x, y))
    print(f"{label}: {len(reqs)} requests, {len(bad)} disagreements")
    for op, (good, wrong) in sorted(by_op.items()):
        print(f"  {op:10s} {good:6d} agree {wrong:4d} differ")
    for q, x, y in bad[:show]:
        print("---", json.dumps(q, ensure_ascii=False)[:600])
        print("swift:", json.dumps(x, ensure_ascii=False)[:400])
        print("rust: ", json.dumps(y, ensure_ascii=False)[:400])
    return len(bad)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=3000)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--real", action="store_true", help="also compare on the saved meetings (counts only)")
    ap.add_argument("--show", type=int, default=5)
    args = ap.parse_args()
    bad = compare("generated", generated(args.n, args.seed), args.show)
    if args.real:
        bad += compare("real meetings", real(), 0)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
