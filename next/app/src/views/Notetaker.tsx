// Meetings: the list, and one meeting at a time with its live transcript, John's own notes,
// running notes and the summary, and Ask Claude. While a meeting records, each side has a
// meter, the proof that both are being heard.

import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { call, clock, noteDate, type MeetingNote, type NoteDetail, type Segment, type Settings } from "../api";
import { More, NavNotes, Plus, Trash } from "../icons";
import { Markdown } from "../markdown";

const QUICK: [string, string][] = [
  ["Summarize so far", "Summarize the meeting so far: the main points, anything decided, and who owes what."],
  ["Last 5 minutes", "What did we talk about in the last 5 minutes?"],
  ["What should I ask?", "What are the best questions I could ask right now, given where the conversation is?"],
];

export interface LiveState {
  levels: { mic: number; system: number };
  status: Record<string, string | null>;
  recap: Record<string, string>;
  /// Why running notes are off during a note's recording, if they are.
  notesOff: Record<string, string>;
  /// Bumped when a note's files change, so the open one reloads.
  version: number;
}

export function Notetaker(props: {
  notes: MeetingNote[];
  selected: string | null;
  onSelect: (id: string | null) => void;
  recordingId: string | null;
  live: LiveState;
  segmentsAdded: Segment[];
  settings: Settings | null;
  onSettings: (s: Settings) => void;
  claudeReady: boolean;
  onError: (e: string) => void;
}) {
  const { notes, selected, onSelect, recordingId, onError } = props;
  const fail = (e: unknown) => onError(String(e));

  const create = async () => {
    const n = await call<MeetingNote>("create_note").catch(fail);
    if (n) onSelect(n.id);
  };

  return (
    <div class="section">
      <div class="notes">
        <div class="note-list">
          <div class="head">
            <b>Meetings</b>
            <span class="spacer" />
            <button onClick={create}>
              <span class="row" style={{ gap: 4 }}>
                <Plus /> New
              </span>
            </button>
          </div>
          <div class="scroll">
            {notes.map((n) => (
              <div key={n.id} class={`note-row ${selected === n.id ? "active" : ""}`} onClick={() => onSelect(n.id)}>
                <div style={{ minWidth: 0, flex: 1 }}>
                  <div class="row" style={{ gap: 6 }}>
                    <span class="title">{n.title}</span>
                    {recordingId === n.id ? <span class="rec-dot" /> : null}
                  </div>
                  <div class="small muted">{noteDate(n)}</div>
                </div>
                <button
                  class="icon"
                  title="Delete this meeting. It goes to the Trash."
                  onClick={async (e) => {
                    e.stopPropagation();
                    await call("delete_notes", { ids: [n.id] }).catch(fail);
                    if (selected === n.id) onSelect(null);
                  }}
                >
                  <Trash />
                </button>
              </div>
            ))}
          </div>
        </div>
        {selected ? (
          <NoteView key={selected} id={selected} {...props} />
        ) : (
          <div class="empty centered">
            <div class="glyph">
              <NavNotes />
            </div>
            <h2>No meeting selected</h2>
            Click New, then Start recording when the meeting begins. Lin Flow also offers to start one when a call app picks up the microphone.
          </div>
        )}
      </div>
    </div>
  );
}

function NoteView({ id, recordingId, live, segmentsAdded, settings, onSettings, claudeReady, onError, onSelect }: Parameters<typeof Notetaker>[0] & { id: string }) {
  const [d, setD] = useState<NoteDetail | null>(null);
  const [title, setTitle] = useState("");
  const [myNotes, setMyNotes] = useState("");
  const [tab, setTab] = useState<"summary" | "running">("summary");
  const [menu, setMenu] = useState(false);
  const [question, setQuestion] = useState("");
  const [renaming, setRenaming] = useState<string | null>(null);
  const [newName, setNewName] = useState("");
  const [elapsed, setElapsed] = useState(0);
  // While the transcript or running notes grow, or an answer arrives, each box follows the
  // newest line, unless John has scrolled up to read.
  const transcriptBox = useStickToEnd(d?.segments.length, true);
  const notesBox = useStickToEnd(d?.runningNotes.length, !!d && (tab === "running" || d.summary.trim() === ""));
  const answersBox = useStickToEnd(d?.questions.length, true);
  const saveTimer = useRef<number | undefined>(undefined);
  const fail = (e: unknown) => onError(String(e));
  const recording = recordingId === id;

  const load = async () => {
    const detail = await call<NoteDetail | null>("note", { id });
    if (!detail) return;
    setD(detail);
    setTitle(detail.note.title);
    setElapsed(detail.elapsed);
  };

  useEffect(() => {
    load().then(() => call<NoteDetail | null>("note", { id }).then((x) => x && setMyNotes(x.myNotes)));
  }, [id, live.version]);

  // New lines while recording arrive as events, without reloading the whole note.
  useEffect(() => {
    if (!d) return;
    const mine = segmentsAdded.filter((s) => !d.segments.some((x) => x.id === s.id));
    if (mine.length) setD({ ...d, segments: [...d.segments, ...mine].sort((a, b) => a.start - b.start) });
  }, [segmentsAdded]);

  useEffect(() => {
    if (!recording) return;
    const started = Date.now() - elapsed * 1000;
    const t = window.setInterval(() => setElapsed((Date.now() - started) / 1000), 1000);
    return () => window.clearInterval(t);
  }, [recording]);

  if (!d) return <div />;

  const status = live.status[id] ?? d.busy ?? null;
  const hasBoth = d.summary.trim() !== "" && d.runningNotes.trim() !== "";
  const showRunning = hasBoth ? tab === "running" : d.summary.trim() === "" && d.runningNotes.trim() !== "";
  const otherRecording = recordingId !== null && !recording;

  const rename = () => {
    if (title.trim() && title !== d.note.title) call("rename_note", { id, title }).catch(fail);
  };
  const editNotes = (text: string) => {
    setMyNotes(text);
    window.clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(() => call("save_my_notes", { id, text }).catch(fail), 600);
  };
  const ask = (q: string) => {
    if (!q.trim()) return;
    call("ask", { id, question: q });
    setQuestion("");
    setD({ ...d, asking: true });
  };
  const toggle = async () => {
    if (recording) await call("stop_note").catch(fail);
    else await call("start_note", { id }).catch(fail);
  };

  return (
    <div class="note-detail" onClick={() => menu && setMenu(false)}>
      <div class="row">
        <input class="title-input" value={title} onInput={(e) => setTitle(e.currentTarget.value)} onBlur={rename} onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()} />
        <div class="menu">
          <button
            class="icon"
            onClick={(e) => {
              e.stopPropagation();
              setMenu(!menu);
            }}
          >
            <More />
          </button>
          {menu ? (
            <div class="items">
              <button onClick={() => call("copy_markdown", { id }).catch(fail)}>Copy as Markdown</button>
              <button onClick={() => call("save_markdown", { id }).catch(fail)}>Save as Markdown…</button>
              <button disabled={recording || !d.hasAudio || status !== null} onClick={() => call("save_audio", { id }).catch(fail)} title="Both sides of the meeting in one file, your side leveled to the call's. The file takes the note's new name when you rename it.">
                Save Audio as {d.audioFormat.toUpperCase()}…
              </button>
              <button onClick={() => call("reveal_note", { id })}>Show Files</button>
              <hr />
              <button disabled={recording || !d.hasAudio || status !== null} onClick={() => call("transcribe_again", { id }).catch(fail)} title="Rebuild the transcript from the saved audio with the current speech model. The live transcript is kept as transcript-live.jsonl.">
                Transcribe Again from the Recording
              </button>
              <hr />
              <button
                onClick={async () => {
                  await call("delete_notes", { ids: [id] }).catch(fail);
                  onSelect(null);
                }}
              >
                Delete Note
              </button>
            </div>
          ) : null}
        </div>
      </div>

      <div class="row" style={{ gap: 14, flexWrap: "wrap" }}>
        <button class={recording ? "danger" : "primary"} style={{ minWidth: 140 }} disabled={otherRecording} title={otherRecording ? "Another meeting is recording. Stop it first." : ""} onClick={toggle}>
          {recording ? "Stop" : d.note.durationSeconds > 0 ? "Resume recording" : "Start recording"}
        </button>
        <label class="row small">
          <input type="checkbox" disabled={recordingId !== null} checked={settings?.meetingUsesMicrophone ?? true} onChange={(e) => settings && onSettings({ ...settings, meetingUsesMicrophone: e.currentTarget.checked })} />
          Microphone
        </label>
        <label class="row small" title="The other people on the call, from what this computer plays">
          <input type="checkbox" disabled={recordingId !== null} checked={settings?.meetingUsesSystemAudio ?? true} onChange={(e) => settings && onSettings({ ...settings, meetingUsesSystemAudio: e.currentTarget.checked })} />
          System audio
        </label>
        <span class="muted" style={{ fontVariantNumeric: "tabular-nums" }}>
          {clock(recording ? elapsed : d.note.durationSeconds)}
        </span>
        <span class="spacer" />
        {recording ? (
          <>
            <Meter label="You" level={live.levels.mic} color="var(--you)" />
            <Meter label="Others" level={live.levels.system} color="var(--others)" />
          </>
        ) : null}
      </div>

      {live.recap[id] ? (
        <div class="banner" style={{ borderRadius: 8, border: "1px solid var(--line)" }}>
          <b>Recap</b> {live.recap[id]}
        </div>
      ) : null}

      <div class="panes">
        <div class="pane">
          <div class="row">
            <h3>Transcript</h3>
            {status ? (
              <span class="small muted">{status}</span>
            ) : d.note.transcribedFromAudioAt ? (
              <span class="small muted" title={`Rebuilt from the saved audio after the meeting${d.note.transcriptModel ? ` (${d.note.transcriptModel})` : ""}`}>
                from the recording
              </span>
            ) : d.segments.length > 0 && !recording ? (
              <span class="small muted" title="The live transcript is cut every 10 s to keep up. Once the meeting ends, the saved audio is transcribed whole and replaces it. The live one is kept as transcript-live.jsonl.">
                live
              </span>
            ) : null}
            <span class="spacer" />
            {d.speakers.map((s) =>
              renaming === s ? (
                <input
                  key={s}
                  autoFocus
                  value={newName}
                  style={{ width: 110 }}
                  onInput={(e) => setNewName(e.currentTarget.value)}
                  onBlur={() => setRenaming(null)}
                  onKeyDown={async (e) => {
                    if (e.key === "Escape") setRenaming(null);
                    if (e.key === "Enter") {
                      setRenaming(null);
                      await call("relabel_speaker", { id, from: s, to: newName }).catch(fail);
                    }
                  }}
                />
              ) : (
                <button
                  key={s}
                  class="chip"
                  style={{ border: "none", cursor: "pointer" }}
                  title={`Rename ${s} throughout this transcript`}
                  onClick={() => {
                    setNewName(s);
                    setRenaming(s);
                  }}
                >
                  {s}
                </button>
              ),
            )}
          </div>
          <div class="box" style={{ flex: 1 }} {...transcriptBox}>
            {d.segments.length === 0 ? (
              <div class="empty" style={{ margin: "40px auto" }}>
                <h2>{recording ? "Listening…" : "No transcript yet"}</h2>
                {recording ? "Lines appear a moment after each pause." : "Start recording to transcribe live."}
              </div>
            ) : (
              d.segments.map((s) => (
                <div class="segment" key={s.id}>
                  <div class="at">{clock(s.start)}</div>
                  <div>
                    <div class="who" style={{ color: s.speaker === "You" ? "var(--you)" : "var(--others)" }}>
                      {s.speaker}
                    </div>
                    <div class="said">{s.text}</div>
                  </div>
                </div>
              ))
            )}
          </div>
        </div>

        <div class="pane">
          <h3>My notes</h3>
          <textarea style={{ height: 110, flex: "none" }} value={myNotes} onInput={(e) => editNotes(e.currentTarget.value)} placeholder="Anything you want to remember. Claude reads these too." />
          <div class="row small" style={{ flexWrap: "wrap" }}>
            {hasBoth ? (
              <div class="tabs">
                <button class={tab === "summary" ? "on" : ""} onClick={() => setTab("summary")}>
                  Summary
                </button>
                <button class={tab === "running" ? "on" : ""} onClick={() => setTab("running")}>
                  Running notes
                </button>
              </div>
            ) : (
              <h3>{showRunning || (recording && !d.summary) ? "Running notes" : "Summary"}</h3>
            )}
            <span class="spacer" />
            <button disabled={d.segments.length === 0 || status !== null} title="What did I miss? A few bullets on the last five minutes." onClick={() => call("recap", { id, minutes: 5 }).catch(fail)}>
              Recap 5 min
            </button>
            <button disabled={d.segments.length === 0 || status !== null || recording} title="Summary, decisions, action items and open questions, from the whole transcript." onClick={() => call("summarize", { id }).catch(fail)}>
              Summarize
            </button>
          </div>
          <div class="box" style={{ flex: 1 }} {...notesBox}>
            {showRunning ? (
              <Markdown text={d.runningNotes} />
            ) : d.summary ? (
              <Markdown text={d.summary} />
            ) : (
              <span class="muted">
                {recording
                  ? live.notesOff[id]
                    ? `Running notes are off: ${live.notesOff[id]}`
                    : "Notes appear here every minute or so while the meeting runs. Summarize once it ends."
                  : "Press Summarize to get the summary, decisions and action items."}
              </span>
            )}
          </div>
          <div class="row">
            <h3>Ask Claude</h3>
            {d.asking ? <span class="small muted">Thinking…</span> : null}
          </div>
          {!claudeReady ? (
            <div class="small muted">Run scripts/setup-claude.sh once to save a Claude key, then reopen Lin Flow.</div>
          ) : (
            <>
              <div class="row small" style={{ flexWrap: "wrap" }}>
                {QUICK.map(([label, q]) => (
                  <button disabled={d.asking || d.segments.length === 0} onClick={() => ask(q)}>
                    {label}
                  </button>
                ))}
              </div>
              {d.questions.length > 0 ? (
                <div class="box" style={{ maxHeight: 180 }} {...answersBox}>
                  {d.questions.map((t) => (
                    <div style={{ marginBottom: 10 }}>
                      <b>{t.question}</b>
                      <Markdown text={t.answer} />
                    </div>
                  ))}
                </div>
              ) : null}
              <input placeholder="Ask about this meeting…" value={question} disabled={d.asking} onInput={(e) => setQuestion(e.currentTarget.value)} onKeyDown={(e) => e.key === "Enter" && ask(question)} />
            </>
          )}
        </div>
      </div>
    </div>
  );
}

/** Pins a scrolling box to its end when `size` grows, as long as it was at the end before. */
function useStickToEnd(size: number | undefined, enabled: boolean) {
  const ref = useRef<HTMLDivElement>(null);
  const atEnd = useRef(true);
  useLayoutEffect(() => {
    const b = ref.current;
    if (b && enabled && atEnd.current) b.scrollTop = b.scrollHeight;
  }, [size, enabled]);
  const onScroll = () => {
    const b = ref.current;
    if (b) atEnd.current = b.scrollHeight - b.scrollTop - b.clientHeight < 40;
  };
  return { ref, onScroll };
}

function Meter({ label, level, color }: { label: string; level: number; color: string }) {
  return (
    <div class="meter" title={level > 0.006 ? `${label}: being heard` : `${label}: quiet`}>
      {label}
      <div class="bar">
        <div class="fill" style={{ width: `${Math.min(100, level * 600)}%`, background: color }} />
      </div>
    </div>
  );
}
