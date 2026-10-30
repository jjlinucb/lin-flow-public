// The one door between the pages and the Rust service: typed commands and events. In a plain
// browser (no Tauri), the same calls go to an in-memory stand-in, so every page can be opened
// and clicked through without the real app, a microphone or John's data.

import { mock } from "./mock";

export type Phase = "loading" | "idle" | "recording" | "working" | "error";
export type LearnMode = "off" | "ask" | "auto";

export interface HistoryEntry {
  id: string;
  timestamp: string;
  raw: string;
  text: string;
  model: string;
  audioSeconds: number;
  inferenceSeconds: number;
  audioFile?: string;
  inputDevice?: string;
  firstAudioSeconds?: number;
  snrDB?: number;
  noiseFloor?: number;
  app?: string;
}

export interface Stats {
  count: number;
  totalWords: number;
  wordsPerMinute: number;
  streakDays: number;
  caption?: string | null;
}

export interface Replacement {
  from: string;
  to: string;
  learned: boolean;
}

/** A correction or suggestion opened for editing, under the left side it had when opened. */
export interface RuleEdit {
  kind: "rule" | "pending";
  original: string;
  from: string;
  to: string;
}

/** The command saving an edit sends, or null while either side is blank. A suggestion is added
 * as edited; a correction is rewritten in its place. */
export function saveEdit(e: RuleEdit): [string, Record<string, string>] | null {
  const from = e.from.trim();
  const to = e.to.trim();
  if (!from || !to) return null;
  return [e.kind === "pending" ? "accept_rule" : "edit_rule", { original: e.original, from, to }];
}

export interface Dictionary {
  terms: string[];
  rules: Replacement[];
  pending: Replacement[];
}

export interface Settings {
  modelID: string;
  hotkey: string;
  language: string;
  beamSize: number;
  temperatureFallback: boolean;
  useVAD: boolean;
  cleanupLevel: "none" | "light";
  learnCorrections: LearnMode;
  numbersAsDigits: boolean;
  spokenCommands: boolean;
  sounds: boolean;
  showHUD: boolean;
  showInDock: boolean;
  trailingSpace: boolean;
  audioRetentionDays: number;
  keepMeetingAudio: boolean;
  runningNotes: boolean;
  callTracker: boolean;
  transcribeAfterMeeting: boolean;
  meetingUsesMicrophone: boolean;
  meetingUsesSystemAudio: boolean;
  openWindowAtLaunch: boolean;
  launchAtLogin: boolean;
  offerMeetingNotes: boolean;
  hudX?: number;
  hudY?: number;
  notesModel: string;
  ollamaHost: string;
}

export interface ModelView {
  id: string;
  label: string;
  installed: boolean;
  sizeMb: number;
  note: string;
}

/** Check for updates on Windows: this build's commit against the newest release on GitHub. */
export interface UpdateView {
  current: string;
  latest: string | null;
  published: string | null;
  newer: boolean;
  error: string | null;
}

export interface SettingsView {
  settings: Settings;
  hotkey: string;
  hotkeyLabel: string;
  hotkeyPresets: [string, string][];
  models: ModelView[];
  claudeReady: boolean;
  syncStatus: string;
  dataDir: string;
  logPath: string;
  trusted: boolean;
  platform: "mac" | "windows";
}

export interface StatusView {
  phase: Phase;
  label: string;
  hotkeyLabel: string;
  model?: string | null;
  recordingNote?: string | null;
  elapsed?: number | null;
}

export interface MeetingNote {
  id: string;
  title: string;
  createdAt: string;
  endedAt?: string;
  durationSeconds: number;
  usedMicrophone: boolean;
  usedSystemAudio: boolean;
  summaryModel?: string;
  transcribedFromAudioAt?: string;
  transcriptModel?: string;
  recovered?: boolean;
  audioExports?: { path: string; title: string }[];
}

export interface Segment {
  id: string;
  start: number;
  end: number;
  speaker: string;
  text: string;
}

export interface QuestionTurn {
  question: string;
  answer: string;
  askedAt: string;
}

export interface NoteDetail {
  note: MeetingNote;
  segments: Segment[];
  myNotes: string;
  summary: string;
  runningNotes: string;
  tracker: Tracker;
  questions: QuestionTurn[];
  hasAudio: boolean;
  recording: boolean;
  elapsed: number;
  busy?: string | null;
  asking: boolean;
  speakers: string[];
  /** What Save Audio writes here: "mp3", or "wav" without LAME. */
  audioFormat: string;
}

export interface TrackerItem {
  id: string;
  kind: "question" | "action";
  /** Seconds into the meeting. */
  at: number;
  text: string;
  /** A question's angle for answering; an action's owner. */
  detail: string;
  done: boolean;
}

export interface Tracker {
  items: TrackerItem[];
}

export type ToastAction =
  | { type: "openDictionary" }
  | { type: "addRule"; from: string; to: string }
  | { type: "recordMeeting"; app: string; name: string }
  | { type: "keepRecording" }
  | { type: "stopNote" }
  | { type: "repairAudio" }
  | { type: "openNote"; id: string };

export interface Toast {
  id: number;
  title: string;
  detail: string;
  warning: boolean;
  seconds: number;
  action?: ToastAction | null;
  button?: [string, ToastAction] | null;
}

export type NoteEvent =
  | { type: "listed" }
  | { type: "recording"; id: string; recording: boolean }
  | { type: "segment"; id: string; segment: Segment }
  | { type: "transcript"; id: string }
  | { type: "levels"; mic: number; system: number }
  | { type: "runningNotes"; id: string; text: string }
  | { type: "runningNotesOff"; id: string; why: string }
  | { type: "tracker"; id: string; tracker: Tracker }
  | { type: "status"; id: string; text?: string | null }
  | { type: "summary"; id: string; text: string }
  | { type: "recap"; id: string; sentence: string }
  | { type: "answer"; id: string }
  | { type: "error"; text: string };

export type ServiceEvent =
  | { type: "state"; phase: Phase; label: string }
  | { type: "level"; level: number }
  | { type: "dictated"; entry: HistoryEntry }
  | { type: "historyChanged" }
  | { type: "dictionaryChanged" }
  | { type: "settingsChanged" }
  | { type: "toast"; toast: Toast }
  | { type: "note"; event: NoteEvent }
  | { type: "sync"; status: string }
  | { type: "hotkeyRecorded"; raw?: string | null; label?: string | null };

declare global {
  interface Window {
    __TAURI_INTERNALS__?: unknown;
  }
}

export const inTauri = typeof window !== "undefined" && window.__TAURI_INTERNALS__ !== undefined;

/** Calls one Rust command. Errors come back as the sentence the service wrote. */
export async function call<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
  if (!inTauri) return mock.call<T>(command, args);
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>(command, args);
}

/** Every service event, for as long as the page lives. */
export async function onEvent(handler: (e: ServiceEvent) => void): Promise<() => void> {
  if (!inTauri) return mock.listen(handler);
  const { listen } = await import("@tauri-apps/api/event");
  return listen<ServiceEvent>("linflow", (e) => handler(e.payload));
}

/** Requests from the app to show a section: "dictionary", "notes", "note:<id>". */
export async function onNavigate(handler: (to: string) => void): Promise<() => void> {
  if (!inTauri) return mock.onNavigate(handler);
  const { getCurrentWebviewWindow } = await import("@tauri-apps/api/webviewWindow");
  return getCurrentWebviewWindow().listen<{ to: string }>("navigate", (e) => handler(e.payload.to));
}

/** A dictation's recording as a URL the page can play. */
export async function recordingUrl(id: string): Promise<string | null> {
  const path = await call<string | null>("recording_path", { id });
  if (!path) return null;
  if (!inTauri) return path;
  const { convertFileSrc } = await import("@tauri-apps/api/core");
  return convertFileSrc(path);
}

/** Starts dragging the current window, for the pill. */
export async function startDragging(): Promise<void> {
  if (!inTauri) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  await getCurrentWindow().startDragging();
}

// Formatting shared by the pages.

export function clock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

export function grouped(n: number): string {
  return n.toLocaleString("en-US");
}

export function timeOfDay(iso: string): string {
  return new Date(iso).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
}

/** "Today", "Yesterday", or "Monday, September 29". */
export function dayLabel(iso: string, now = new Date()): string {
  const d = new Date(iso);
  const start = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const days = Math.round((start(now) - start(d)) / 86_400_000);
  if (days === 0) return "Today";
  if (days === 1) return "Yesterday";
  return d.toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", year: d.getFullYear() === now.getFullYear() ? undefined : "numeric" });
}

export function noteDate(n: MeetingNote): string {
  const d = new Date(n.createdAt);
  const when = d.toLocaleDateString("en-US", { month: "short", day: "numeric" }) + ", " + d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
  return n.durationSeconds > 0 ? `${when} · ${Math.max(1, Math.round(n.durationSeconds / 60))} min` : when;
}
