#!/usr/bin/env python3
"""Which checks a change needs: the suites to run, the areas to read, the live checks per computer.

    python3 scripts/test-plan.py                  # this branch against main
    python3 scripts/test-plan.py --base 6c32176 --head 8e8db23
    python3 scripts/test-plan.py --dry-run        # print what would be sent, send nothing
    python3 scripts/test-plan.py --json           # every probability, for tuning

Code finds the candidates: each selftest area, each Windows test class, each probe, and the live
checks in LIVE below, which exist only as John's hands on a real computer. Jev, TypeSafe's decision
model, then answers one yes/no question per candidate: could this diff change what it covers? Code
owns the policy. A whole suite runs whenever its sources changed, whatever Jev says, because the
Mac selftest takes seconds and the Windows tests about one. What Jev adds is the rest: which areas
to read or add cases to, which probes, and which live checks on which computer.

The key comes from TYPESAFE_API_KEY or ~/.config/typesafe/key. Only the diff leaves this computer,
and not all of it: the paths in PRIVATE are named but never sent, since clean-corpus.json is John's
real dictations and the notes carry internal paths. Python 3.9, standard library only.
"""
import argparse
import concurrent.futures
import fnmatch
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"
KEY_FILE = os.path.expanduser("~/.config/typesafe/key")

# Named in the plan, never sent.
PRIVATE = ["windows/LinFlow.Tests/Fixtures/*", "*.md", "*.jsonl", "*.wav", "*.env", "*.env.*"]
# Neither named nor sent.
IGNORED = ["*/bin/*", "*/obj/*", ".build/*", "dist/*", "*.lock", "Package.resolved"]

NEEDED = 0.5   # at or above: listed as needed
MAYBE = 0.2    # at or above: listed as worth a look
PER_FILE_LINES = 160
DIFF_CHARS = 40_000
BATCH = 12     # questions per request, to stay well under 32k tokens

PROJECT = ("Lin Flow is John's dictation app. The Mac app is Swift (Sources/LinFlowCore is the logic, "
           "Sources/LinFlow the app, its window and the selftest). The Windows app is a C# port in "
           "windows/, whose Core mirrors the Mac's cleanup, numbers, learning, notes and history formats "
           "case for case. Hold a talk key, speak, and the cleaned text is pasted where the cursor is. "
           "It also records meetings, learns from the fixes John makes after a paste, and sends daily "
           "word counts to a shared Supabase table. Three computers run it: John's Mac, and two Windows "
           "laptops, DESK-01 and LAPTOP-02.")

# Checks that only a person at a real computer can make. `when` says what makes one necessary.
LIVE = [
    ("live:mac-dictation", "Mac", "Dictate into a real app with the installed Mac app and read what pasted",
     "the dictation path on the Mac: recording, the engines, cleanup, spoken commands, numbers, snippets, paste"),
    ("live:mac-talk-key", "Mac", "Hold the Mac talk key on the real keyboard and mouse",
     "the Mac's hotkey tap, HotkeyMatcher, Record in Settings, mouse buttons, what is swallowed or replayed"),
    ("live:mac-meeting-note", "Mac", "Record a meeting note on the Mac, then kill -9 and relaunch",
     "Mac meeting recording: MeetingRecorder, WAVWriter, the system audio tap, NotesStore recovery, NoteTranscriber"),
    ("live:mac-learning", "Mac", "Fix a pasted word on the Mac and watch for the learned-fix toast",
     "Mac learning from edits: PasteWatcher readback, LearnedCorrections, CorrectionLearning, ToastPanel"),
    ("live:mac-window", "Mac", "Open the Mac window's sections and look at what changed",
     "the Mac dashboard window, its SwiftUI views, Settings, the menu bar menu, the pill"),
    ("live:mac-install", "Mac", "Install on the Mac with build_app.sh --install and confirm the grants and the Fn tap survive",
     "the Mac build and install: build_app.sh, signing, Info.plist, entitlements, Package.swift"),
    ("live:win-dictation", "DESK-01 and LAPTOP-02", "Dictate on both Windows laptops and read what pasted",
     "the Windows dictation path: capture, engines, the C# cleanup, the talk-key chord, paste"),
    ("live:win-meeting-note", "DESK-01 and LAPTOP-02", "Record a meeting note on Windows, then kill it and run notes-repair",
     "Windows meeting recording, WavWriter, NotesStore, the Ollama running notes and summaries"),
    ("live:win-learning", "DESK-01 and LAPTOP-02", "Fix a pasted word on Windows and read the readback lines in app.log",
     "Windows learning from edits: FieldReader, UI Automation, ReadbackWatch, the learner"),
    ("live:win-install", "DESK-01 and LAPTOP-02", "Publish with release.ps1 and install with install-latest.ps1 on each laptop",
     "Windows packaging and install: release.ps1, install-latest.ps1, package.sh, the csproj files, doctor"),
    ("live:shared-totals", "all three", "Dictate, then look for this computer's row in the Supabase table",
     "the shared word totals: TotalsSync.swift, SharedTotals.cs, setup-sync.sh, sync-schema.sql, sync.env"),
    ("live:fleet", "each computer", "Run fleet.sh update, schedule on and status on the computer the change is for, and read fleet.log",
     "keeping all three computers on one build: fleet.sh, its schedule (launchd on the Mac, Task Scheduler on Windows), fleet-schema.sql, the devices table"),
    ("live:shared-dictionary", "two computers", "Add a word in the Dictionary on one computer, then look for it on another within ten minutes",
     "the shared dictionary: DictionarySync.swift, DictionarySync.cs, vocab.txt, replacements.txt, dictionary-sync.json, dictionary-schema.sql"),
]


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout


def matches(path, patterns):
    return any(fnmatch.fnmatch(path, p) or fnmatch.fnmatch(os.path.basename(path), p) for p in patterns)


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def doc_comment(text, prefixes):
    """The leading comment block of a file or a type, joined into one line."""
    out = []
    for line in text.splitlines():
        s = line.strip()
        hit = next((p for p in prefixes if s.startswith(p)), None)
        if hit:
            body = s[len(hit):].strip()
            if body and not body.startswith("Usage"):
                out.append(body)
        elif out:
            break
    return " ".join(out)[:600]


def candidates():
    """Every check the repo has, found from the files, so a new one is never missed."""
    found = []
    root = "Sources/LinFlow/SelfTest"
    for name in sorted(os.listdir(root)):
        m = re.match(r"SelfTest\+(\w+)\.swift$", name)
        if not m:
            continue
        text = read(os.path.join(root, name))
        labels = re.findall(r'"([^"\n]{6,})"\)\s*$', "\n".join(l for l in text.splitlines() if "expect(" in l), re.M)
        found.append({
            "id": "mac:" + m.group(1).lower(), "kind": "Mac selftest area", "where": f"{root}/{name}",
            "covers": doc_comment(text, ["///"]), "cases": labels[:30],
        })
    root = "windows/LinFlow.Tests"
    for name in sorted(os.listdir(root)):
        if not name.endswith("Tests.cs"):
            continue
        text = read(os.path.join(root, name))
        tests = re.findall(r"public (?:async Task|void) (\w+)\(", text)
        found.append({
            "id": "win:" + name[:-3], "kind": "Windows test class", "where": f"{root}/{name}",
            "covers": doc_comment(text, ["///"]) or name[:-8],
            "cases": [t.replace("_", " ") for t in tests[:30]],
        })
    for root, prefixes in [("scripts/probes", ["//"]), ("windows/scripts/probes", ["#", "//"])]:
        for name in sorted(os.listdir(root)):
            path = os.path.join(root, name)
            text = read(os.path.join(path, "Program.cs") if os.path.isdir(path) else path)
            found.append({
                "id": "probe:" + os.path.splitext(name)[0], "kind": "probe script", "where": path,
                "covers": doc_comment(text, prefixes + ["///"]) or name, "cases": [],
            })
    for cid, computers, action, covers in LIVE:
        found.append({"id": cid, "kind": f"live check on {computers}", "where": action, "covers": covers, "cases": []})
    return found


def change(base, head):
    files = []
    for line in git("diff", "--numstat", "--no-renames", f"{base}...{head}").splitlines():
        added, removed, path = line.split("\t", 2)
        if matches(path, IGNORED):
            continue
        files.append({"path": path, "added": added, "removed": removed, "sent": not matches(path, PRIVATE)})
    parts, total = [], 0
    for f in files:
        if not f["sent"]:
            continue
        body = git("diff", "-U2", f"{base}...{head}", "--", f["path"]).splitlines()
        body = [l for l in body if not l.startswith(("diff --git", "index ", "--- ", "+++ "))]
        if len(body) > PER_FILE_LINES:
            body = body[:PER_FILE_LINES] + [f"... {len(body) - PER_FILE_LINES} more lines"]
        chunk = f"### {f['path']}\n" + "\n".join(body)
        if total + len(chunk) > DIFF_CHARS:
            parts.append(f"### {f['path']}\n(left out: the diff is over its size limit)")
            continue
        parts.append(chunk)
        total += len(chunk)
    return files, "\n\n".join(parts)


def question(c):
    check = {"name": c["id"], "kind": c["kind"], "where": c["where"], "covers": c["covers"]}
    if c["cases"]:
        check["some_cases"] = c["cases"]
    return {
        "type": "noul",
        "instructions": {
            "check": check,
            "question": "Could the code change in `change` alter or break behavior that `check` covers, "
                        "so that `check` should be run or read closely before this change merges?",
        },
        "criteria": {
            "true": "The change touches code, data formats, scripts or settings that this check exercises, "
                    "or that the code under this check depends on.",
            "false": "The change has no path to what this check covers: other features, other platform, "
                     "or only comments, docs or notes.",
        },
    }


def api_key():
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if not key and os.path.exists(KEY_FILE):
        key = read(KEY_FILE).strip()
    return key


def ask(state, batch, key):
    body = json.dumps({"state": state, "model": MODEL, "questions": {c["id"]: question(c) for c in batch}}).encode()
    req = urllib.request.Request(API, data=body, headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            out = json.load(r)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"test-plan: TypeSafe answered {e.code}: {e.read().decode(errors='replace')[:300]}")
    except (urllib.error.URLError, TimeoutError) as e:
        raise SystemExit(f"test-plan: no answer from TypeSafe ({e}). Check the connection and run it again.")
    return {cid: a["noul"] for cid, a in out["answers"].items()}, out.get("usage", {})


def suites(files):
    """Whole suites, by path alone. Cheap enough that no judgment is needed."""
    paths = [f["path"] for f in files]
    run = []
    if any(p.startswith(("Sources/", "Package.swift")) for p in paths):
        run.append(("Mac selftest", "swift build --build-system native -Xswiftc -sdk -Xswiftc "
                    "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk && .build/debug/LinFlow selftest"))
    if any(p.startswith("windows/") and not p.endswith(".md") for p in paths):
        run.append(("Windows tests", "~/.dotnet/dotnet test windows/LinFlow.sln"))
    return run


def reachable(cid, files):
    """A platform's own checks cannot fail when none of its code changed, whatever Jev says.
    A Mac change that Windows mirrors is caught by `mirrored` instead."""
    code = [f["path"] for f in files if not f["path"].endswith(".md")]
    mac = any(p.startswith(("Sources/", "Package.swift", "scripts/build_app.sh", "scripts/probes/")) for p in code)
    win = any(p.startswith("windows/") for p in code)
    if cid.startswith(("mac:", "probe:axdrive", "probe:hotkeypost", "probe:winshot")):
        return mac
    if cid.startswith(("win:", "probe:installer-probe", "probe:uia-slots", "probe:readback-probe", "probe:window-probe")):
        return win
    if cid.startswith("live:mac-"):
        return any(not p.startswith("windows/") for p in code)
    if cid.startswith("live:win-"):
        return any(not p.startswith("Sources/") for p in code)
    return bool(code)


def mirrored(files):
    """Mac logic that Windows ports case for case: a change there usually needs its twin."""
    twins = {"TextCleaner", "NumberWords", "GlossaryMatcher", "LearnedCorrections", "PasteWatcher",
             "RunningNotes", "NotesStore", "History", "WAVWriter", "TotalsSync", "Snippets"}
    mac = {os.path.splitext(os.path.basename(f["path"]))[0] for f in files if f["path"].startswith("Sources/LinFlowCore/")}
    win = {f["path"] for f in files if f["path"].startswith("windows/") and not f["path"].endswith(".md")}
    return sorted(mac & twins) if not win else []


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", default="main")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    files, diff = change(a.base, a.head)
    if not files:
        print("test-plan: no changes between", a.base, "and", a.head)
        return
    checks = candidates()
    state = {"project": PROJECT, "change": {"files": [
        {k: f[k] for k in ("path", "added", "removed")} | ({} if f["sent"] else {"note": "content not sent"})
        for f in files], "diff": diff}}
    batches = [checks[i:i + BATCH] for i in range(0, len(checks), BATCH)]

    if a.dry_run:
        print(json.dumps({"state": state, "questions": {c["id"]: question(c) for c in checks}}, indent=1))
        print(f"test-plan: {len(checks)} checks in {len(batches)} requests, {len(json.dumps(state))} chars of state",
              file=sys.stderr)
        return
    key = api_key()
    if not key:
        raise SystemExit(f"test-plan: no key. Set TYPESAFE_API_KEY or save it to {KEY_FILE}")

    probs, tokens = {}, 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(batches)) as pool:
        for got, usage in pool.map(lambda b: ask(state, b, key), batches):
            probs.update(got)
            tokens += usage.get("input_tokens", 0)

    if a.json:
        print(json.dumps({"base": a.base, "head": a.head, "input_tokens": tokens,
                          "checks": {c["id"]: round(probs[c["id"]], 3) for c in checks},
                          "unreachable": [c["id"] for c in checks if not reachable(c["id"], files)]}, indent=1))
        return

    by = {c["id"]: c for c in checks}
    probs = {i: p for i, p in probs.items() if reachable(i, files)}
    ranked = sorted(probs, key=probs.get, reverse=True)
    def group(prefix, lo, hi=1.01):
        return [i for i in ranked if i.startswith(prefix) and lo <= probs[i] < hi]

    print("## Test plan\n")
    print(f"From `{a.base}` to `{a.head}`, {len(files)} files. Suggested by Jev (`scripts/test-plan.py`).\n")
    for name, cmd in suites(files):
        print(f"- [ ] **{name}**, in full: `{cmd}`")
    for twin in mirrored(files):
        print(f"- [ ] **Windows port:** `{twin}` changed on the Mac and nothing under `windows/` did.")
    sections = [("Mac selftest areas", "mac:"), ("Windows test classes", "win:"), ("Probes", "probe:")]
    for title, prefix in sections:
        need, maybe = group(prefix, NEEDED), group(prefix, MAYBE, NEEDED)
        if need or maybe:
            print(f"\n**{title}**")
            for i in need:
                print(f"- [ ] `{by[i]['where']}` ({probs[i]:.2f})")
            for i in maybe:
                print(f"- maybe `{by[i]['where']}` ({probs[i]:.2f})")
    need, maybe = group("live:", NEEDED), group("live:", MAYBE, NEEDED)
    if need or maybe:
        print("\n**Live checks** (John, on the computer named)")
        for i in need:
            print(f"- [ ] {by[i]['where']}, on {by[i]['kind'].split(' on ', 1)[1]} ({probs[i]:.2f})")
        for i in maybe:
            print(f"- maybe: {by[i]['where']} ({probs[i]:.2f})")
    held = [f["path"] for f in files if not f["sent"]]
    if held:
        print(f"\nNot sent to Jev: {', '.join(held[:8])}{' and more' if len(held) > 8 else ''}.")


if __name__ == "__main__":
    main()
