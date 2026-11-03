// A stand-in for the Rust service when a page is opened in a plain browser: made-up dictations,
// a small dictionary and one meeting, enough to click through every section. Nothing here is
// John's; nothing here is saved.

import type { Dictionary, HistoryEntry, MeetingNote, NoteDetail, ServiceEvent, Settings, SettingsView, Stats, StatusView, Tracker } from "./api";

type Handler = (e: ServiceEvent) => void;

const now = Date.now();
const iso = (minutesAgo: number) => new Date(now - minutesAgo * 60_000).toISOString().replace(/\.\d+Z$/, "Z");

const history: HistoryEntry[] = [
  { id: "A1", timestamp: iso(3), raw: "send the draft to dana by friday", text: "Send the draft to Dana by Friday.", model: "parakeet-tdt-0.6b-v3-q8_0", audioSeconds: 2.4, inferenceSeconds: 0.14, app: "com.apple.mail" },
  { id: "A2", timestamp: iso(40), raw: "the build is green on all three computers", text: "The build is green on all three computers.", model: "parakeet-tdt-0.6b-v3-q8_0", audioSeconds: 3.1, inferenceSeconds: 0.16, audioFile: "A2.wav" },
  { id: "A3", timestamp: iso(60 * 26), raw: "remind me to call the dentist at twenty two hundred", text: "Remind me to call the dentist at 2200.", model: "parakeet-tdt-0.6b-v3-q8_0", audioSeconds: 2.9, inferenceSeconds: 0.15 },
];

const dictionary: Dictionary = {
  terms: ["Lin Flow", "Parakeet", "Supabase", "Tauri"],
  rules: [
    { from: "wisper flow", to: "Wispr Flow", learned: false },
    { from: "K Wynn E D F", to: "kkwinedf", learned: true },
  ],
  pending: [{ from: "Marisvo", to: "Marisa Vuong", learned: true }],
};

const settings: Settings = {
  modelID: "parakeet-tdt-0.6b-v3-q8_0",
  hotkey: "rightOption",
  language: "en",
  beamSize: 5,
  temperatureFallback: false,
  useVAD: true,
  cleanupLevel: "light",
  learnCorrections: "auto",
  numbersAsDigits: true,
  spokenCommands: true,
  sounds: true,
  showHUD: true,
  showInDock: true,
  trailingSpace: true,
  audioRetentionDays: 30,
  keepMeetingAudio: true,
  runningNotes: true,
  callTracker: true,
  transcribeAfterMeeting: true,
  meetingUsesMicrophone: true,
  meetingUsesSystemAudio: true,
  openWindowAtLaunch: true,
  launchAtLogin: false,
  offerMeetingNotes: true,
  notesModel: "qwen2.5:3b",
  ollamaHost: "http://127.0.0.1:11434",
};

const note: MeetingNote = { id: "N1", title: "Zoom Oct 2, 9:30 AM", createdAt: iso(300), endedAt: iso(240), durationSeconds: 3540, usedMicrophone: true, usedSystemAudio: true };

const tracker: Tracker = {
  items: [
    { id: "q-1", kind: "question", at: 130, text: "Can the parser rewrite land by Friday?", detail: "Give a range, and say what Friday depends on.", done: false },
    { id: "a-2", kind: "action", at: 140, text: "Label two thousand night images by Thursday", detail: "You", done: false },
    { id: "a-3", kind: "action", at: 150, text: "Get the GPU box ready by Wednesday", detail: "Kevin", done: false },
    { id: "q-4", kind: "question", at: 205, text: "What's the plan for showing confidence scores on the dashboard?", detail: "Say you'll propose a per-image score with a threshold, and confirm by Friday.", done: false },
    { id: "a-5", kind: "action", at: 260, text: "Walk through the results slide at the demo", detail: "You", done: true },
  ],
};

const detail: NoteDetail = {
  note,
  segments: [
    { id: "s1", start: 4, end: 9, speaker: "You", text: "Thanks for making the time. Where did we land on the rollout?" },
    { id: "s2", start: 10, end: 21, speaker: "Others", text: "We agreed to ship the Windows build first and the Mac last, one computer at a time." },
    { id: "s3", start: 22, end: 27, speaker: "You", text: "Good. I'll write up the checklist by Thursday." },
  ],
  myNotes: "",
  summary: "## Summary\n* The rollout goes Windows first, Mac last.\n## Decisions\n* One computer at a time.\n## Action items\n* John writes the checklist by Thursday.\n## Open questions\n* None",
  runningNotes: "- [0:10] Windows ships first, the Mac last.\n- [1:10] Night images get two thousand more labels before retraining.\n",
  tracker,
  questions: [],
  hasAudio: true,
  recording: false,
  elapsed: 3540,
  busy: null,
  asking: false,
  speakers: ["You", "Others"],
  audioFormat: "mp3",
};

class Mock {
  private handlers: Handler[] = [];
  private navigators: ((to: string) => void)[] = [];
  private state: StatusView = { phase: "idle", label: "Lin Flow", hotkeyLabel: "Right Option", model: settings.modelID };
  private meter: number | undefined;

  constructor() {
    // The toast page has nothing to show until the service speaks, so the mock speaks first.
    if (typeof document !== "undefined" && document.body.classList.contains("toast")) {
      setTimeout(() => {
        this.emit({ type: "toast", toast: { id: 1, title: "Learned: “dana” → “Dana”", detail: "Used from now on. Click to change it in the Dictionary.", warning: false, seconds: 60, action: { type: "openDictionary" } } });
        this.emit({ type: "toast", toast: { id: 2, title: "The call ended", detail: "Stopping the note in 30 seconds.", warning: true, seconds: 60, action: { type: "stopNote" }, button: ["Keep recording", { type: "keepRecording" }] } });
      }, 300);
    }
  }

  listen(h: Handler): () => void {
    this.handlers.push(h);
    return () => (this.handlers = this.handlers.filter((x) => x !== h));
  }

  onNavigate(h: (to: string) => void): () => void {
    this.navigators.push(h);
    return () => (this.navigators = this.navigators.filter((x) => x !== h));
  }

  private emit(e: ServiceEvent) {
    for (const h of this.handlers) h(e);
  }

  private setState(phase: StatusView["phase"], label: string) {
    this.state = { ...this.state, phase, label };
    this.emit({ type: "state", phase, label });
  }

  async call<T>(command: string, args: Record<string, unknown>): Promise<T> {
    const a = args as Record<string, any>;
    const r = (v: unknown) => v as T;
    switch (command) {
      case "status":
        // The tracker page opens on the meeting being recorded.
        return r(location.pathname.includes("tracker") ? { ...this.state, recordingNote: note.id } : this.state);
      case "tracker":
        return r(structuredClone(tracker));
      case "toggle_tracker": {
        const i = tracker.items.find((x) => x.id === a.item);
        if (i) i.done = !i.done;
        return r(structuredClone(tracker));
      }
      case "check_update":
        return r({ current: "caafe1d", latest: "b0168ec", published: "2026-10-27", newer: true, error: null });
      case "install_update":
        throw "The browser preview cannot update.";
      case "press": {
        this.setState("recording", "Recording…");
        const t0 = Date.now();
        this.meter = window.setInterval(() => this.emit({ type: "level", level: 0.01 + 0.08 * Math.abs(Math.sin((Date.now() - t0) / 180)) }), 100);
        return r(undefined);
      }
      case "release":
        window.clearInterval(this.meter);
        this.setState("working", "Transcribing…");
        setTimeout(() => {
          const entry: HistoryEntry = { id: `M${Date.now()}`, timestamp: new Date().toISOString(), raw: "a made up dictation", text: "A made-up dictation.", model: settings.modelID, audioSeconds: 1.2, inferenceSeconds: 0.12 };
          history.unshift(entry);
          this.emit({ type: "dictated", entry });
          this.setState("idle", "Lin Flow");
        }, 400);
        return r(undefined);
      case "history":
        return r([...history]);
      case "stats": {
        const words = history.reduce((n, e) => n + e.text.split(/\s+/).length, 0);
        return r({ count: history.length, totalWords: words, wordsPerMinute: 142, streakDays: 2, caption: null } satisfies Stats);
      }
      case "delete_entry":
        history.splice(history.findIndex((e) => e.id === a.id), 1);
        this.emit({ type: "historyChanged" });
        return r(undefined);
      case "edit_entry": {
        const e = history.find((x) => x.id === a.id);
        if (e) e.text = a.text;
        this.emit({ type: "historyChanged" });
        this.emit({ type: "toast", toast: { id: Date.now(), title: "Learned: “dana” → “Dana”", detail: "Used from now on. Click to change it in the Dictionary.", warning: false, seconds: 6, action: { type: "openDictionary" } } });
        return r(undefined);
      }
      case "retry_entry":
        return r(history.find((x) => x.id === a.id));
      case "recording_path":
        return r(null);
      case "dictionary":
        return r(structuredClone(dictionary));
      case "add_term":
        dictionary.terms.push(a.term);
        this.emit({ type: "dictionaryChanged" });
        return r(undefined);
      case "remove_term":
        dictionary.terms = dictionary.terms.filter((t) => t !== a.term);
        this.emit({ type: "dictionaryChanged" });
        return r(undefined);
      case "add_rule":
        dictionary.rules.push({ from: a.from, to: a.to, learned: false });
        this.emit({ type: "dictionaryChanged" });
        return r(undefined);
      case "remove_rule":
        dictionary.rules = dictionary.rules.filter((x) => x.from !== a.from);
        this.emit({ type: "dictionaryChanged" });
        return r(undefined);
      case "edit_rule":
        dictionary.rules = dictionary.rules.map((x) => (x.from === a.original ? { ...x, from: a.from, to: a.to } : x));
        this.emit({ type: "dictionaryChanged" });
        return r(undefined);
      case "accept_rule":
        dictionary.rules.push({ from: a.from, to: a.to, learned: true });
        dictionary.pending = dictionary.pending.filter((x) => x.from !== (a.original ?? a.from));
        this.emit({ type: "dictionaryChanged" });
        return r(undefined);
      case "dismiss_rule":
        dictionary.pending = dictionary.pending.filter((x) => x.from !== a.from);
        this.emit({ type: "dictionaryChanged" });
        return r(undefined);
      case "settings_view":
        return r({
          settings: { ...settings },
          hotkey: settings.hotkey,
          hotkeyLabel: "Right Option",
          hotkeyPresets: [["fn", "Fn"], ["rightOption", "Right Option"], ["rightCommand", "Right Command"], ["middleMouse", "Middle Mouse Button"]],
          models: [
            { id: "parakeet-tdt-0.6b-v3-q8_0", label: "Parakeet · parakeet-tdt-0.6b-v3-q8_0", installed: true, sizeMb: 669, note: "Default. Top English accuracy." },
            { id: "large-v3-turbo-q5_0", label: "Whisper · large-v3-turbo-q5_0", installed: false, sizeMb: 574, note: "Use for Khmer and other languages." },
          ],
          claudeReady: true,
          syncStatus: "Off: no sync.env in the data folder.",
          dataDir: "~/Library/Application Support/Lin Flow Next",
          logPath: "~/Library/Logs/Lin Flow/lin-flow.log",
          trusted: true,
          // ?platform=windows previews the Windows-only rows, such as Updates.
          platform: new URLSearchParams(location.search).get("platform") === "windows" ? "windows" : "mac",
        } satisfies SettingsView);
      case "set_settings":
        Object.assign(settings, a.settings);
        this.emit({ type: "settingsChanged" });
        return r(undefined);
      case "set_hotkey":
        settings.hotkey = a.raw;
        this.emit({ type: "settingsChanged" });
        return r(undefined);
      case "record_hotkey":
        setTimeout(() => this.emit({ type: "hotkeyRecorded", raw: "rightCommand", label: "Right Command" }), 1200);
        return r(undefined);
      case "notes":
        return r([note]);
      case "note":
        return r(a.id === note.id ? structuredClone({ ...detail, tracker }) : null);
      case "create_note":
        return r(note);
      case "start_note":
        detail.recording = true;
        this.emit({ type: "note", event: { type: "recording", id: note.id, recording: true } });
        return r(note.id);
      case "stop_note":
        detail.recording = false;
        this.emit({ type: "note", event: { type: "recording", id: note.id, recording: false } });
        this.emit({ type: "note", event: { type: "recap", id: note.id, sentence: "59 min. You spoke 1 min, the others 3. 1 action item, 1 decision." } });
        return r(note.id);
      case "rename_note":
        note.title = a.title;
        this.emit({ type: "note", event: { type: "listed" } });
        return r(note);
      case "relabel_speaker":
        for (const s of detail.segments) if (s.speaker === a.from) s.speaker = a.to;
        detail.speakers = [...new Set(detail.segments.map((s) => s.speaker))];
        this.emit({ type: "note", event: { type: "transcript", id: note.id } });
        return r(undefined);
      case "ask":
        setTimeout(() => {
          detail.questions.push({ question: a.question, answer: "Windows ships first and the Mac goes last, one computer at a time.", askedAt: new Date().toISOString() });
          this.emit({ type: "note", event: { type: "answer", id: note.id } });
        }, 600);
        return r(undefined);
      default:
        return r(undefined);
    }
  }
}

export const mock = new Mock();
