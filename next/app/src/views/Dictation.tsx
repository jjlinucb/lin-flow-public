// Every dictation, newest first and grouped by day, with the totals on top. A row can be
// played, copied, fixed (which teaches the dictionary), run again through the current model,
// or deleted.

import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import { call, dayLabel, grouped, recordingUrl, timeOfDay, type HistoryEntry, type Stats } from "../api";
import { Copy, Pencil, Play, Retry, Stop, Trash } from "../icons";

export function Dictation({ history, stats, hotkeyLabel, onError }: { history: HistoryEntry[]; stats: Stats | null; hotkeyLabel: string; onError: (e: string) => void }) {
  const [search, setSearch] = useState("");
  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    return q ? history.filter((e) => e.text.toLowerCase().includes(q)) : history;
  }, [history, search]);
  const days = useMemo(() => {
    const out: [string, HistoryEntry[]][] = [];
    for (const e of shown) {
      const d = dayLabel(e.timestamp);
      const last = out[out.length - 1];
      if (last && last[0] === d) last[1].push(e);
      else out.push([d, [e]]);
    }
    return out;
  }, [shown]);

  return (
    <div class="section">
      <div class="section-head">
        <div class="stat">
          <b>{grouped(stats?.totalWords ?? 0)}</b> <span class="muted">total words</span>
        </div>
        <div class="stat">
          <b>{stats?.wordsPerMinute ?? 0}</b> <span class="muted">words per minute</span>
        </div>
        <div class="stat">
          <b>{stats?.streakDays ?? 0}</b> <span class="muted">day streak</span>
        </div>
        <span class="spacer" />
        <input type="search" placeholder="Search dictations" value={search} onInput={(e) => setSearch(e.currentTarget.value)} style={{ width: 240 }} />
      </div>
      {stats?.caption ? <div class="small muted" style={{ padding: "6px 20px" }}>{stats.caption}</div> : null}
      <div class="scroll">
        {shown.length === 0 ? (
          <div class="empty">
            <h2>{history.length === 0 ? "No dictations yet" : "No matches"}</h2>
            {history.length === 0 ? `Hold ${hotkeyLabel} and talk. Everything you dictate shows up here.` : `Nothing matches “${search}”.`}
          </div>
        ) : (
          days.map(([day, entries]) => (
            <div key={day}>
              <div class="day">{day}</div>
              {entries.map((e) => (
                <Row key={e.id} entry={e} onError={onError} />
              ))}
            </div>
          ))
        )}
      </div>
    </div>
  );
}

function Row({ entry, onError }: { entry: HistoryEntry; onError: (e: string) => void }) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(entry.text);
  const [retrying, setRetrying] = useState(false);
  const [playing, setPlaying] = useState(false);
  const audio = useRef<HTMLAudioElement | null>(null);

  useEffect(() => () => audio.current?.pause(), []);

  const save = async () => {
    setEditing(false);
    if (draft.trim() && draft !== entry.text) await call("edit_entry", { id: entry.id, text: draft }).catch((e) => onError(String(e)));
  };

  const togglePlay = async () => {
    if (playing) {
      audio.current?.pause();
      setPlaying(false);
      return;
    }
    const url = await recordingUrl(entry.id);
    if (!url) return onError("The audio for this dictation is gone.");
    const a = new Audio(url);
    a.onended = () => setPlaying(false);
    audio.current = a;
    setPlaying(true);
    a.play().catch(() => setPlaying(false));
  };

  return (
    <div class="entry">
      <div class="time">{timeOfDay(entry.timestamp)}</div>
      <div>
        {editing ? (
          <div>
            <textarea
              rows={Math.min(8, Math.max(2, Math.ceil(draft.length / 80)))}
              value={draft}
              onInput={(e) => setDraft(e.currentTarget.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  save();
                }
                if (e.key === "Escape") setEditing(false);
              }}
              autoFocus
            />
            <div class="row small" style={{ marginTop: 4 }}>
              <span class="muted">Fix a misheard word and Lin Flow remembers it.</span>
              <span class="spacer" />
              <button onClick={() => setEditing(false)}>Cancel</button>
              <button class="primary" onClick={save}>
                Save
              </button>
            </div>
          </div>
        ) : (
          <div class="text">{entry.text}</div>
        )}
      </div>
      <div class="actions">
        {entry.audioFile ? (
          <button class="icon" title={playing ? "Stop" : "Play the recording"} onClick={togglePlay}>
            {playing ? <Stop /> : <Play />}
          </button>
        ) : null}
        <button class="icon" title="Copy" onClick={() => call("copy_text", { text: entry.text })}>
          <Copy />
        </button>
        <button
          class="icon"
          title="Edit the text, and teach the dictionary"
          onClick={() => {
            setDraft(entry.text);
            setEditing(true);
          }}
        >
          <Pencil />
        </button>
        {entry.audioFile ? (
          <button
            class="icon"
            title="Transcribe again with the current model"
            disabled={retrying}
            onClick={async () => {
              setRetrying(true);
              await call("retry_entry", { id: entry.id }).catch((e) => onError(String(e)));
              setRetrying(false);
            }}
          >
            <Retry />
          </button>
        ) : null}
        <button class="icon" title="Delete" onClick={() => call("delete_entry", { id: entry.id }).catch((e) => onError(String(e)))}>
          <Trash />
        </button>
      </div>
    </div>
  );
}
