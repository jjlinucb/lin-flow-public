#!/usr/bin/env python3
"""Compares the sync's pure logic between the Swift app and the Rust rebuild.

The dictionary merge decides what every computer's vocab.txt and replacements.txt become, so it
gets the most cases: every combination of an entry being here, in the record, and in the table,
changed or not, deleted or not, with case variants, unreadable files and mass deletions. Also the
totals plan and combine, and sync.env parsing. Generated inputs only; nothing real is read.

    python3 next/oracle/sync_oracle.py [--n 20000] [--seed 3]
"""

import argparse
import json
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFT = ROOT / ".build/debug/LinFlow"
RUST = ROOT / "next/target/debug/linflow"

WORDS = ["Parakeet", "parakeet", "PARAKEET", "Lin Flow", "lin flow", "Claude Code", "claude code", "Café", "café", "CAFÉ", "Cafe\u0301", "CAFE\u0301",
         "İstanbul", "istanbul", "ΣΑΣ", "σας", "Northwind", "Supabase", "Ollama", "Zoom", "Wispr", "Jev", "ﬀ", "Straße",
         "STRASSE", "é", "é", " padded ", "Ted", "ted", "a", "B", "x y z", "Q&A", "C++", "Node.js"]
TARGETS = ["Claude", "Claude Code", "Parakeet", "Lin Flow", "", "Northwind", "Zoom", "café"]
STAMPS = ["2026-09-01T00:00:00.000Z", "2026-09-02T00:00:00.000Z", "2026-10-01T12:30:00.123Z", ""]


def entry(r, kind=None, text=None):
    kind = kind or r.choice(["term", "rule"])
    return {"kind": kind, "text": text or r.choice(WORDS), "target": r.choice(TARGETS) if kind == "rule" or r.random() < 0.05 else "",
            "learned": r.random() < 0.3, "deleted": r.random() < 0.2, "updated_at": r.choice(STAMPS)}


def variant(r, e):
    """The same entry, perhaps changed in one field."""
    v = dict(e)
    roll = r.random()
    if roll < 0.15:
        v["deleted"] = not v["deleted"]
    elif roll < 0.25:
        v["target"] = r.choice(TARGETS)
    elif roll < 0.32:
        v["learned"] = not v["learned"]
    elif roll < 0.4:
        v["text"] = v["text"].upper() if v["text"] != v["text"].upper() else v["text"].lower()
    if r.random() < 0.4:
        v["updated_at"] = r.choice(STAMPS)
    return v


def dict_merge(r):
    slots = [entry(r) for _ in range(r.randint(0, 12))]
    terms, rules, snapshot, remote = [], [], [], []
    for e in slots:
        here = r.random() < 0.6
        if here:
            local = variant(r, e) if r.random() < 0.3 else e
            if local["kind"] == "term":
                terms.append(local["text"])
                if r.random() < 0.1:
                    terms.append(local["text"].lower())
            else:
                rules.append({"from": local["text"], "to": local["target"], "learned": local["learned"]})
        if r.random() < 0.6:
            snapshot.append(e)
        if r.random() < 0.7:
            remote.append(variant(r, e) if r.random() < 0.4 else e)
    if r.random() < 0.15:
        # Many live terms in the record, few left here: the mass-deletion guard.
        many = [entry(r, "term", f"Word{i}") for i in range(r.randint(4, 10))]
        for e in many:
            e["deleted"] = False
        snapshot += many
        remote += [e for e in many if r.random() < 0.8]
        terms += [e["text"] for e in many if r.random() < 0.2]
    r.shuffle(terms)
    r.shuffle(rules)
    req = {"op": "dict-merge", "terms": terms, "rules": rules, "snapshot": snapshot, "remote": remote}
    if r.random() < 0.15:
        req["snapshot"] = None
    if r.random() < 0.08:
        req["terms"] = None
    if r.random() < 0.08:
        req["rules"] = None
    return req


def day(r, device):
    return {"device": device, "day": f"2026-{r.randint(9, 10):02d}-{r.randint(1, 30):02d}", "words": r.randint(0, 3000),
            "dictations": r.choice([0, r.randint(1, 80)]), "audio_seconds": round(r.uniform(0, 900), r.choice([0, 1, 2]))}


def totals_plan(r):
    local = {d["day"]: d for d in (day(r, "Mac") for _ in range(r.randint(0, 8)))}
    sent = {}
    for d in list(local.values()) + [day(r, "Mac") for _ in range(r.randint(0, 5))]:
        if r.random() < 0.6:
            s = dict(d)
            if r.random() < 0.3:
                s["words"] += 1
            sent[s["day"]] = s
    return {"op": "totals-plan", "local": sorted(local.values(), key=lambda d: d["day"]), "sent": list(sent.values())}


def totals_combine(r):
    devices = ["Mac", "DESK-01", "LAPTOP-02", "Zed", "A"]
    remote = [day(r, r.choice(devices)) for _ in range(r.randint(0, 20))]
    local = [day(r, "Mac") for _ in range(r.randint(0, 6))]
    return {"op": "totals-combine", "remote": remote, "local": local, "device": "Mac",
            "today": f"2026-10-{r.randint(1, 30):02d}"}


def sync_config(r):
    lines = []
    for _ in range(r.randint(0, 6)):
        k = r.choice(["SUPABASE_URL", "supabase_url", "SUPABASE_KEY", "DEVICE", "# comment", "", "=x", "OTHER"])
        v = r.choice(["https://abc.supabase.co", "https://abc.supabase.co/", "https://abc.supabase.co/rest/v1", "https://abc.supabase.co/REST/V1/",
                      "http://abc.co", "https://", "'sb_publishable_x'", "\"eyJhbGci\"", "sb_secret_abc", "DESK-01", "  Mac Book  ", "x" * 70, "\"", ""])
        lines.append(k if k.startswith("#") or k == "" else f"{k}{r.choice(['=', ' = ', '='])}{v}")
    return {"op": "sync-config", "text": r.choice(["\n", "\r\n", "\r"]).join(lines)}


def run(binary, reqs):
    payload = "".join(json.dumps(q, ensure_ascii=False) + "\n" for q in reqs)
    out = subprocess.run([str(binary), "sync-batch"], input=payload.encode(), capture_output=True, check=True).stdout.decode()
    return [json.loads(l)["out"] for l in out.splitlines() if l.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--show", type=int, default=4)
    args = ap.parse_args()
    r = random.Random(args.seed)
    makers = [dict_merge] * 6 + [totals_plan, totals_combine, sync_config]
    reqs = [r.choice(makers)(r) for _ in range(args.n)]
    a, b = run(SWIFT, reqs), run(RUST, reqs)
    assert len(a) == len(b) == len(reqs), (len(a), len(b), len(reqs))
    by_op, bad = {}, []
    for q, x, y in zip(reqs, a, b):
        ok = x == y
        by_op.setdefault(q["op"], [0, 0])[0 if ok else 1] += 1
        if not ok:
            bad.append((q, x, y))
    print(f"generated: {len(reqs)} requests, {len(bad)} disagreements")
    for op, (good, wrong) in sorted(by_op.items()):
        print(f"  {op:15s} {good:6d} agree {wrong:4d} differ")
    for q, x, y in bad[: args.show]:
        print("---", json.dumps(q, ensure_ascii=False)[:900])
        print("swift:", json.dumps(x, ensure_ascii=False)[:700])
        print("rust: ", json.dumps(y, ensure_ascii=False)[:700])
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
