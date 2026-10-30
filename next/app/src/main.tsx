// The main window: a sidebar of four sections, kept current by the service's events.

import { render, type JSX } from "preact";
import { useEffect, useState } from "preact/hooks";
import { call, onEvent, onNavigate, type Dictionary as Dict, type HistoryEntry, type MeetingNote, type Phase, type Segment, type ServiceEvent, type Settings as S, type SettingsView, type Stats, type StatusView } from "./api";
import "./styles.css";
import { NavDictation, NavDictionary, NavNotes, NavSettings } from "./icons";
import { Dictation } from "./views/Dictation";
import { Dictionary } from "./views/Dictionary";
import { Notetaker, type LiveState } from "./views/Notetaker";
import { Settings } from "./views/Settings";

type Section = "dictation" | "notes" | "dictionary" | "settings";

const SECTIONS: [Section, string, () => JSX.Element][] = [
  ["dictation", "Dictation", NavDictation],
  ["notes", "Notetaker", NavNotes],
  ["dictionary", "Dictionary", NavDictionary],
  ["settings", "Settings", NavSettings],
];

function App() {
  const [section, setSection] = useState<Section>("dictation");
  const [status, setStatus] = useState<StatusView | null>(null);
  const [history, setHistory] = useState<HistoryEntry[]>([]);
  const [stats, setStats] = useState<Stats | null>(null);
  const [dict, setDict] = useState<Dict | null>(null);
  const [view, setView] = useState<SettingsView | null>(null);
  const [notes, setNotes] = useState<MeetingNote[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [recordingId, setRecordingId] = useState<string | null>(null);
  const [live, setLive] = useState<LiveState>({ levels: { mic: 0, system: 0 }, status: {}, recap: {}, notesOff: {}, version: 0 });
  const [segments, setSegments] = useState<Segment[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [recorded, setRecorded] = useState<{ raw?: string | null; label?: string | null } | null>(null);

  const loadHistory = () => {
    call<HistoryEntry[]>("history").then(setHistory);
    call<Stats>("stats").then(setStats);
  };
  const loadDict = () => call<Dict>("dictionary").then(setDict);
  const loadView = () => call<SettingsView>("settings_view").then(setView);
  const loadNotes = () => call<MeetingNote[]>("notes").then(setNotes);
  const loadStatus = () =>
    call<StatusView>("status").then((s) => {
      setStatus(s);
      setRecordingId(s.recordingNote ?? null);
    });

  useEffect(() => {
    loadStatus();
    loadHistory();
    loadDict();
    loadView();
    loadNotes();
    const handle = (e: ServiceEvent) => {
      switch (e.type) {
        case "state":
          setStatus((s) => (s ? { ...s, phase: e.phase as Phase, label: e.label } : s));
          break;
        case "dictated":
        case "historyChanged":
          loadHistory();
          break;
        case "dictionaryChanged":
          loadDict();
          break;
        case "settingsChanged":
        case "sync":
          loadView();
          loadStatus();
          break;
        case "hotkeyRecorded":
          setRecorded({ raw: e.raw, label: e.label });
          loadView();
          loadStatus();
          break;
        case "note": {
          const n = e.event;
          switch (n.type) {
            case "listed":
              loadNotes();
              break;
            case "recording":
              setRecordingId(n.recording ? n.id : null);
              setSegments([]);
              loadNotes();
              setLive((l) => {
                // Cleared when a recording ends, not when one starts: the reason can arrive first.
                const notesOff = { ...l.notesOff };
                if (!n.recording) delete notesOff[n.id];
                return { ...l, levels: { mic: 0, system: 0 }, notesOff, version: l.version + 1 };
              });
              break;
            case "segment":
              setSegments((s) => [...s, n.segment]);
              break;
            case "levels":
              setLive((l) => ({ ...l, levels: { mic: n.mic, system: n.system } }));
              break;
            case "status":
              setLive((l) => ({ ...l, status: { ...l.status, [n.id]: n.text ?? null }, version: n.text ? l.version : l.version + 1 }));
              break;
            case "runningNotesOff":
              setLive((l) => ({ ...l, notesOff: { ...l.notesOff, [n.id]: n.why } }));
              break;
            case "recap":
              setLive((l) => ({ ...l, recap: { ...l.recap, [n.id]: n.sentence }, version: l.version + 1 }));
              break;
            case "transcript":
            case "summary":
            case "answer":
            case "runningNotes":
              setLive((l) => ({ ...l, version: l.version + 1 }));
              break;
            case "error":
              setError(n.text);
              break;
          }
          break;
        }
      }
    };
    const offs = [onEvent(handle), onNavigate((to) => go(to))];
    return () => offs.forEach((p) => p.then((off) => off()));
  }, []);

  const go = (to: string) => {
    if (to.startsWith("note:")) {
      setSection("notes");
      setSelected(to.slice(5));
      loadNotes();
    } else if (["dictation", "notes", "dictionary", "settings"].includes(to)) {
      setSection(to as Section);
    }
  };

  const saveSettings = (s: S) => {
    setView((v) => (v ? { ...v, settings: s } : v));
    call("set_settings", { settings: s }).catch((e) => setError(String(e)));
  };

  return (
    <div class="app">
      <nav class="sidebar">
        <div class="brand">
          Lin Flow
          <small>{SECTIONS.find(([id]) => id === section)?.[1]}</small>
        </div>
        {SECTIONS.map(([id, label, Icon]) => (
          <div key={id} class={`nav ${section === id ? "active" : ""}`} onClick={() => setSection(id)}>
            <span class="nav-icon">
              <Icon />
            </span>
            {label}
            {id === "notes" && recordingId ? <span class="dot" /> : null}
          </div>
        ))}
        <div class="status" title={status?.model ?? ""}>
          <span class={`phase-dot phase-${status?.phase ?? "loading"}`} />
          <span>{status ? (status.phase === "idle" ? `Hold ${status.hotkeyLabel} to talk` : status.label) : "Starting…"}</span>
        </div>
      </nav>
      <main class="section" style={{ minHeight: 0 }}>
        {section === "dictation" ? <Dictation history={history} stats={stats} hotkeyLabel={status?.hotkeyLabel ?? "the talk key"} onError={setError} /> : null}
        {section === "notes" ? (
          <Notetaker
            notes={notes}
            selected={selected}
            onSelect={setSelected}
            recordingId={recordingId}
            live={live}
            segmentsAdded={segments}
            settings={view?.settings ?? null}
            onSettings={saveSettings}
            claudeReady={view?.claudeReady ?? false}
            onError={setError}
          />
        ) : null}
        {section === "dictionary" ? <Dictionary dict={dict} learn={view?.settings.learnCorrections ?? "auto"} onLearn={(m) => view && saveSettings({ ...view.settings, learnCorrections: m })} onError={setError} /> : null}
        {section === "settings" ? <Settings view={view} recorded={recorded} onChange={saveSettings} onError={setError} /> : null}
        {error ? (
          <div class="banner warning">
            {error}
            <span class="spacer" />
            <button class="link" onClick={() => setError(null)}>
              Dismiss
            </button>
          </div>
        ) : null}
      </main>
    </div>
  );
}

render(<App />, document.getElementById("root")!);
