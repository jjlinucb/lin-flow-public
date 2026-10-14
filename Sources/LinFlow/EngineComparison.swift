import Foundation
import LinFlowCore

/// `LinFlow compare-engines`: John's own dictations through Parakeet and Whisper turbo, for a
/// person to judge. Whether long takes should go to Whisper is a question about his voice, his
/// vocabulary and his rooms, and no public benchmark answers it.
///
/// It picks the longest takes (where the question lives) plus a spread of the rest, copies their
/// audio into a benchmark folder so the 30-day recording expiry cannot take it, runs both engines
/// through the same cleanup a dictation gets, and writes label.html: every take where the two
/// disagree, blind (A and B in an order fixed per take), with the audio beside them.
enum EngineComparison {
    struct Take: Codable {
        var id: String
        var date: Date
        var seconds: Double
        /// What went out when it was dictated, for reference.
        var dictated: String
        var parakeet: String
        var whisper: String
        var parakeetSeconds: Double
        var whisperSeconds: Double
        /// True when Whisper is shown as A. Fixed per take so a reload never reshuffles.
        var whisperFirst: Bool
        var audio: String
    }

    static func run(count: Int, longest: Int) {
        let parakeetID = "parakeet-tdt-0.6b-v3-q8_0", whisperID = "large-v3-turbo-q5_0"
        guard let parakeetURL = ModelCatalog.locate(parakeetID), let whisperURL = ModelCatalog.locate(whisperID) else {
            fputs("both \(parakeetID) and \(whisperID) must be installed\n", stderr); exit(1)
        }
        let candidates = History.all().filter { $0.audioSeconds >= 1.5 && History.audioURL(for: $0) != nil }
        let picked = pick(candidates, count: count, longest: longest)
        guard !picked.isEmpty else { fputs("no saved recordings to compare\n", stderr); exit(1) }

        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let folder = ModelCatalog.appSupportDir.appendingPathComponent("benchmarks/engines-\(stamp)", isDirectory: true)
        let audioDir = folder.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let settings = Settings.shared
        let vocab = Glossary.load()
        let options = settings.transcriptionOptions(glossary: vocab)
        var cleaner = TextCleaner(glossary: vocab)
        cleaner.spokenCommands = settings.spokenCommands
        cleaner.numbersAsDigits = settings.numbersAsDigits
        let parakeet: SpeechEngine, whisper: SpeechEngine
        do { parakeet = try EngineFactory.load(modelURL: parakeetURL); whisper = try EngineFactory.load(modelURL: whisperURL) }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        // Warm both, or the first take pays for compiling Metal pipelines.
        let hush = [Float](repeating: 0, count: Int(AudioIO.sampleRate * 1.5))
        _ = try? parakeet.transcribe(hush, options: options)
        _ = try? whisper.transcribe(hush, options: options)

        var takes: [Take] = []
        for (i, entry) in picked.enumerated() {
            guard let source = History.audioURL(for: entry), let samples = try? AudioIO.loadSamples(from: source) else { continue }
            let copy = audioDir.appendingPathComponent(source.lastPathComponent)
            if !FileManager.default.fileExists(atPath: copy.path) { try? FileManager.default.copyItem(at: source, to: copy) }
            let p = try? parakeet.transcribe(samples, options: options)
            let w = try? whisper.transcribe(samples, options: options)
            let take = Take(id: entry.id, date: entry.timestamp, seconds: entry.audioSeconds, dictated: entry.text,
                            parakeet: cleaner.clean(p?.text ?? ""), whisper: cleaner.clean(w?.text ?? ""),
                            parakeetSeconds: p?.inferenceSeconds ?? 0, whisperSeconds: w?.inferenceSeconds ?? 0,
                            whisperFirst: entry.id.utf8.reduce(0) { $0 &+ Int($1) } % 2 == 0,
                            audio: "audio/" + source.lastPathComponent)
            takes.append(take)
            fputs(String(format: "  %2d/%d  %5.1fs  %@\n", i + 1, picked.count, entry.audioSeconds,
                         same(take.parakeet, take.whisper) ? "same" : "differ"), stderr)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let json = try? encoder.encode(takes) else { fputs("could not encode the results\n", stderr); exit(1) }
        try? json.write(to: folder.appendingPathComponent("takes.json"))
        let compact = JSONEncoder()
        compact.dateEncodingStrategy = .iso8601
        let embedded = String(decoding: (try? compact.encode(takes)) ?? Data(), as: UTF8.self)
        let page = labelPage.replacingOccurrences(of: "__TAKES__", with: embedded)
            .replacingOccurrences(of: "__STAMP__", with: stamp)
        try? page.write(to: folder.appendingPathComponent("label.html"), atomically: true, encoding: .utf8)

        let differ = takes.filter { !same($0.parakeet, $0.whisper) }.count
        let pTime = takes.reduce(0) { $0 + $1.parakeetSeconds }, wTime = takes.reduce(0) { $0 + $1.whisperSeconds }
        print(String(format: "%d takes, %d where the engines disagree. Parakeet %.1fs of inference in all, Whisper %.1fs.",
                     takes.count, differ, pTime, wTime))
        print("label them in: \(folder.appendingPathComponent("label.html").path)")
        fflush(stdout); Log.flush()
        _exit(0)   // two models loaded: a normal exit trips ggml's Metal teardown assertion
    }

    /// The `longest` longest takes, then the rest spread evenly through time, oldest first.
    static func pick(_ entries: [HistoryEntry], count: Int, longest: Int) -> [HistoryEntry] {
        let long = Array(entries.sorted { $0.audioSeconds > $1.audioSeconds }.prefix(min(longest, count)))
        let longIDs = Set(long.map(\.id))
        let rest = entries.filter { !longIDs.contains($0.id) }.sorted { $0.timestamp < $1.timestamp }
        let wanted = max(0, count - long.count)
        var spread: [HistoryEntry] = []
        if wanted > 0, !rest.isEmpty {
            let step = Double(rest.count) / Double(wanted)
            var seen = Set<Int>()
            for k in 0..<wanted {
                let i = min(rest.count - 1, Int(Double(k) * step + step / 2))
                if seen.insert(i).inserted { spread.append(rest[i]) }
            }
        }
        return (long + spread).sorted { $0.timestamp < $1.timestamp }
    }

    /// The same words, ignoring case and punctuation. Formatting alone is not worth a label.
    static func same(_ a: String, _ b: String) -> Bool { words(a) == words(b) }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    static let labelPage = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Engine Labels</title>
<style>
:root { --bg: #f6f5f2; --card: #ffffff; --ink: #1d1d1f; --muted: #6e6e73; --line: #e3e1dc; --accent: #2f6f4f;
        --del: #f6d6d3; --ins: #d6ecd9; --pick: #2f6f4f; --pick-ink: #ffffff; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #161617; --card: #202022; --ink: #f2f2f2; --muted: #9a9aa0; --line: #333336; --accent: #7cc49c;
          --del: #5a2a27; --ins: #1f4a2f; --pick: #7cc49c; --pick-ink: #101010; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
header { position: sticky; top: 0; z-index: 2; background: var(--bg); border-bottom: 1px solid var(--line); padding: 14px 16px; }
header h1 { margin: 0 0 4px; font-size: 18px; }
header p { margin: 0; color: var(--muted); font-size: 13px; }
#tally { margin-top: 10px; display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 8px; font-size: 13px; }
#tally div { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 8px 10px; }
#tally b { display: block; font-size: 15px; }
main { max-width: 860px; margin: 0 auto; padding: 16px; }
.take { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; margin-bottom: 14px; }
.take.current { outline: 2px solid var(--accent); }
.meta { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; color: var(--muted); font-size: 13px; margin-bottom: 10px; }
audio { width: 100%; max-width: 420px; height: 32px; }
.side { border-top: 1px solid var(--line); padding: 10px 0; }
.side h3 { margin: 0 0 4px; font-size: 13px; color: var(--muted); font-weight: 600; }
.side p { margin: 0; overflow-wrap: anywhere; }
.side span.x { background: var(--del); border-radius: 3px; padding: 0 2px; }
.side.b span.x { background: var(--ins); }
.choices { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
button { font: inherit; font-size: 14px; border: 1px solid var(--line); background: var(--bg); color: var(--ink); border-radius: 8px; padding: 6px 12px; cursor: pointer; }
button.on { background: var(--pick); color: var(--pick-ink); border-color: var(--pick); }
details { margin-top: 8px; color: var(--muted); font-size: 13px; }
.reveal { color: var(--muted); font-size: 13px; }
footer { color: var(--muted); font-size: 13px; padding: 8px 16px 40px; text-align: center; }
</style>
</head>
<body>
<header>
  <h1>Which engine got it right?</h1>
  <p>__STAMP__. Each take is shown twice, as A and B, in an order that does not tell you which engine wrote which. Listen, then pick.
     Keys: <b>space</b> play or pause, <b>1</b> A is right, <b>2</b> B is right, <b>3</b> both fine, <b>4</b> both wrong, <b>j</b>/<b>k</b> next or previous.</p>
  <div id="tally"></div>
</header>
<main id="takes"></main>
<footer>Labels are kept in this browser as you go. <button id="export">Save labels as a file</button></footer>
<script id="data" type="application/json">__TAKES__</script>
<script>
const takes = JSON.parse(document.getElementById('data').textContent);
const words = s => s.toLowerCase().split(/[^\p{L}\p{N}']+/u).filter(Boolean);
const same = (a, b) => words(a).join(' ') === words(b).join(' ');
const shown = takes.filter(t => !same(t.parakeet, t.whisper));
const agreed = takes.length - shown.length;
const key = 'linflow-engine-labels-__STAMP__';
let labels = {};
try { labels = JSON.parse(localStorage.getItem(key) || '{}'); } catch (e) {}
const save = () => { try { localStorage.setItem(key, JSON.stringify(labels)); } catch (e) {} };

// Word-level diff by longest common subsequence: the words only one side has are marked.
function marked(mine, other) {
  const a = mine.split(/\s+/).filter(Boolean), b = other.split(/\s+/).filter(Boolean);
  const norm = w => w.toLowerCase().replace(/[^\p{L}\p{N}']/gu, '');
  const n = a.length, m = b.length, L = Array.from({length: n + 1}, () => new Int16Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
    L[i][j] = norm(a[i]) === norm(b[j]) ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  const keep = new Set(); let i = 0, j = 0;
  while (i < n && j < m) {
    if (norm(a[i]) === norm(b[j])) { keep.add(i); i++; j++; }
    else if (L[i + 1][j] >= L[i][j + 1]) i++; else j++;
  }
  const esc = s => s.replace(/[&<>]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;'}[c]));
  return a.map((w, k) => keep.has(k) ? esc(w) : '<span class="x">' + esc(w) + '</span>').join(' ') || '<i>(nothing)</i>';
}

const bucket = s => s < 10 ? 'under 10 s' : s < 20 ? '10 to 20 s' : 'over 20 s';
function tally() {
  const rows = {};
  for (const t of shown) {
    const l = labels[t.id]; if (!l) continue;
    const b = bucket(t.seconds); rows[b] = rows[b] || {parakeet: 0, whisper: 0, fine: 0, wrong: 0};
    if (l === 'fine' || l === 'wrong') rows[b][l]++;
    else rows[b][(l === 'A') === t.whisperFirst ? 'whisper' : 'parakeet']++;
  }
  const done = shown.filter(t => labels[t.id]).length;
  let html = '<div><b>' + done + ' of ' + shown.length + '</b>labeled (' + agreed + ' more takes agreed word for word)</div>';
  for (const b of ['under 10 s', '10 to 20 s', 'over 20 s']) {
    const r = rows[b]; if (!r) continue;
    html += '<div><b>' + b + '</b>Parakeet ' + r.parakeet + ', Whisper ' + r.whisper + ', both fine ' + r.fine + ', both wrong ' + r.wrong + '</div>';
  }
  document.getElementById('tally').innerHTML = html;
}

const main = document.getElementById('takes');
shown.forEach((t, n) => {
  const [a, b] = t.whisperFirst ? [t.whisper, t.parakeet] : [t.parakeet, t.whisper];
  const el = document.createElement('section');
  el.className = 'take'; el.dataset.id = t.id;
  el.innerHTML =
    '<div class="meta"><b>' + (n + 1) + ' of ' + shown.length + '</b><span>' + t.seconds.toFixed(1) + ' s</span><span>' +
    new Date(t.date).toLocaleString() + '</span><audio controls preload="none" src="' + t.audio + '"></audio></div>' +
    '<div class="side a"><h3>A</h3><p>' + marked(a, b) + '</p></div>' +
    '<div class="side b"><h3>B</h3><p>' + marked(b, a) + '</p></div>' +
    '<div class="choices">' + [['A', 'A is right'], ['B', 'B is right'], ['fine', 'Both fine'], ['wrong', 'Both wrong']]
      .map(([v, label]) => '<button data-v="' + v + '">' + label + '</button>').join('') + '</div>' +
    '<p class="reveal"></p>';
  el.querySelectorAll('button').forEach(btn => btn.addEventListener('click', () => choose(n, btn.dataset.v)));
  el.addEventListener('click', ev => { if (!ev.target.closest('button')) focusTake(n, false); });
  main.appendChild(el);
  paint(n);
});

function paint(n) {
  const t = shown[n], el = main.children[n], l = labels[t.id];
  el.querySelectorAll('button').forEach(b => b.classList.toggle('on', b.dataset.v === l));
  el.querySelector('.reveal').textContent = l ? 'A was ' + (t.whisperFirst ? 'Whisper' : 'Parakeet') + ', B was ' +
    (t.whisperFirst ? 'Parakeet' : 'Whisper') + '. Whisper took ' + t.whisperSeconds.toFixed(2) + ' s, Parakeet ' +
    t.parakeetSeconds.toFixed(2) + ' s.' : '';
}

let current = 0;
function focusTake(n, scroll = true) {
  if (n < 0 || n >= shown.length) return;
  main.children[current]?.classList.remove('current');
  current = n; main.children[n].classList.add('current');
  if (scroll) main.children[n].scrollIntoView({block: 'center', behavior: 'smooth'});
}
function choose(n, v) {
  labels[shown[n].id] = v; save(); paint(n); tally();
  main.children[n].querySelector('audio').pause();
  if (n === current) focusTake(n + 1);
}
document.addEventListener('keydown', e => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const audio = main.children[current]?.querySelector('audio');
  if (e.key === ' ') { e.preventDefault(); if (audio) audio.paused ? audio.play() : audio.pause(); }
  else if (e.key === 'j') focusTake(current + 1);
  else if (e.key === 'k') focusTake(current - 1);
  else if ({'1': 'A', '2': 'B', '3': 'fine', '4': 'wrong'}[e.key]) choose(current, {'1': 'A', '2': 'B', '3': 'fine', '4': 'wrong'}[e.key]);
});
document.getElementById('export').addEventListener('click', () => {
  const out = shown.filter(t => labels[t.id]).map(t => {
    const l = labels[t.id];
    const winner = l === 'fine' || l === 'wrong' ? l : ((l === 'A') === t.whisperFirst ? 'whisper' : 'parakeet');
    return {id: t.id, seconds: t.seconds, label: winner};
  });
  const blob = new Blob([JSON.stringify(out, null, 2)], {type: 'application/json'});
  const link = document.createElement('a');
  link.href = URL.createObjectURL(blob); link.download = 'labels-__STAMP__.json'; link.click();
});
tally();
const firstOpen = shown.findIndex(t => !labels[t.id]);
if (shown.length) focusTake(firstOpen < 0 ? 0 : firstOpen, false);
</script>
</body>
</html>
"""#
}
