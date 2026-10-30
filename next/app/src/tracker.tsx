// The call tracker: a panel at the edge of the screen while a meeting records. What was asked of
// John, with an angle for answering; what people said they would do; the latest running notes.
// Click an item to tick it off. Its window never takes focus, so the call keeps the keyboard,
// and it is left out of screen shares. It stays up after the call ends until it is closed.

import { render } from "preact";
import { useEffect, useState } from "preact/hooks";
import { call, clock, onEvent, startDragging, type NoteDetail, type StatusView, type Tracker, type TrackerItem } from "./api";
import { Close } from "./icons";
import "./styles.css";

/** The running notes' last few bullets, each split into its "[m:ss]" stamp and its text. */
function lastNotes(markdown: string, n: number): [string, string][] {
  return markdown
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith("- ") || l.startsWith("* "))
    .map((l): [string, string] => {
      const m = /^\[([\d:]+)\]\s*(.*)$/.exec(l.slice(2));
      return m ? [m[1], m[2]] : ["", l.slice(2)];
    })
    .slice(-n);
}

function Panel() {
  const [id, setId] = useState<string | null>(null);
  const [recording, setRecording] = useState(false);
  const [title, setTitle] = useState("");
  const [tracker, setTracker] = useState<Tracker>({ items: [] });
  const [notes, setNotes] = useState("");
  const [showDone, setShowDone] = useState(false);

  const load = (note: string) => {
    setId(note);
    call<NoteDetail | null>("note", { id: note }).then((d) => {
      if (!d) return;
      setTitle(d.note.title);
      setNotes(d.runningNotes);
      setRecording(d.recording);
    });
    call<Tracker>("tracker", { id: note }).then(setTracker);
  };

  useEffect(() => {
    call<StatusView>("status").then((s) => s.recordingNote && load(s.recordingNote));
    const off = onEvent((e) => {
      if (e.type !== "note") return;
      const n = e.event;
      if (n.type === "recording") {
        setRecording(n.recording);
        if (n.recording) load(n.id);
      }
      if (n.type === "tracker") setId((cur) => (cur === n.id ? (setTracker(n.tracker), cur) : cur));
      if (n.type === "runningNotes") setId((cur) => (cur === n.id ? (setNotes(n.text), cur) : cur));
    });
    return () => {
      off.then((f) => f());
    };
  }, []);

  const toggle = (item: TrackerItem) => id && call<Tracker>("toggle_tracker", { id, item: item.id }).then(setTracker);
  const open = tracker.items.filter((i) => !i.done);
  const done = tracker.items.filter((i) => i.done);
  const questions = open.filter((i) => i.kind === "question").reverse();
  const actions = open.filter((i) => i.kind === "action");
  const recent = lastNotes(notes, 4);

  return (
    <div class="tracker-panel">
      <div class="tracker-head" title="Drag to move" onMouseDown={(e) => e.button === 0 && !(e.target as HTMLElement).closest("button") && startDragging()}>
        <span class={`tracker-dot ${recording ? "on" : ""}`} />
        <span class="tracker-title">{recording ? title || "Call" : "Call ended"}</span>
        {id ? (
          <button class="tracker-link" title="Open this meeting in Lin Flow" onClick={() => call("tracker_open_note", { id })}>
            Open
          </button>
        ) : null}
        <button class="icon" title="Hide the tracker. It comes back with the next recording." onClick={() => call("tracker_hide")}>
          <Close />
        </button>
      </div>
      <div class="tracker-body">
        <Section label="Asked of you" empty={recording ? "Questions put to you show up here." : "No open questions."}>
          {questions.map((q) => (
            <Row key={q.id} item={q} onToggle={toggle}>
              <div class="q">{q.text}</div>
              {q.detail ? <div class="angle">{q.detail}</div> : null}
            </Row>
          ))}
        </Section>
        <Section label="To do" empty="Promises made on the call show up here.">
          {actions.map((a) => (
            <Row key={a.id} item={a} onToggle={toggle}>
              <div>
                <span class={a.detail === "You" ? "who you" : "who"}>{a.detail}</span> {a.text}
              </div>
            </Row>
          ))}
        </Section>
        <Section label="Notes" empty="Notes come every minute or so.">
          {recent.map(([at, text]) => (
            <div class="tracker-note">
              <span>{text}</span>
              <span class="at">{at}</span>
            </div>
          ))}
        </Section>
        {done.length > 0 ? (
          <button class="tracker-done-toggle" onClick={() => setShowDone((s) => !s)}>
            {showDone ? "Hide" : "Show"} {done.length} ticked off
          </button>
        ) : null}
        {showDone
          ? done.map((i) => (
              <Row key={i.id} item={i} onToggle={toggle}>
                <div>{i.kind === "action" ? `${i.detail}: ${i.text}` : i.text}</div>
              </Row>
            ))
          : null}
      </div>
    </div>
  );
}

function Section({ label, empty, children }: { label: string; empty: string; children: preact.ComponentChildren }) {
  const has = Array.isArray(children) ? children.length > 0 : !!children;
  return (
    <div class="tracker-section">
      <div class="tracker-label">{label}</div>
      {has ? children : <div class="tracker-empty">{empty}</div>}
    </div>
  );
}

function Row({ item, onToggle, children }: { item: TrackerItem; onToggle: (i: TrackerItem) => void; children: preact.ComponentChildren }) {
  return (
    <div class={`tracker-row ${item.done ? "done" : ""}`} onClick={() => onToggle(item)} title={item.done ? "Click to bring it back" : "Click to tick it off"}>
      <span class="tick">{item.done ? "✓" : ""}</span>
      <div class="tracker-text">{children}</div>
      <span class="at">{clock(item.at)}</span>
    </div>
  );
}

render(<Panel />, document.getElementById("root")!);
