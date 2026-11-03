// Settings, in the groups the Mac app uses: Dictation, Notetaker, Shared totals, App.

import { useEffect, useState } from "preact/hooks";
import { call, type Settings as S, type SettingsView, type UpdateView } from "../api";

export function Settings({ view, recorded, onChange, onError }: { view: SettingsView | null; recorded: { raw?: string | null; label?: string | null } | null; onChange: (s: S) => void; onError: (e: string) => void }) {
  const [recording, setRecording] = useState(false);
  useEffect(() => setRecording(false), [recorded]);
  if (!view) return <div class="section" />;
  const s = view.settings;
  const set = <K extends keyof S>(k: K, v: S[K]) => onChange({ ...s, [k]: v });
  const fail = (e: unknown) => onError(String(e));
  const isMac = view.platform === "mac";

  return (
    <div class="section">
      <div class="section-head">
        <h1>Settings</h1>
      </div>
      <div class="form">
        {!view.trusted ? (
          <div class="banner warning" style={{ borderRadius: 8, marginTop: 14 }}>
            Lin Flow needs Accessibility and Input Monitoring to hear the talk key and paste.
            <span class="spacer" />
            <button onClick={() => call("request_access")}>Open the request</button>
          </div>
        ) : null}

        <h2>Dictation</h2>
        <div class="group">
          <div class="field">
            <span class="label">
              Hold to talk
              <span class="help">Any key, combination or extra mouse button. Escape cancels a recording.</span>
            </span>
            {recording ? (
              <>
                <span class="muted">Press a key, keys or mouse button…</span>
                <button
                  onClick={() => {
                    call("cancel_record_hotkey");
                    setRecording(false);
                  }}
                >
                  Cancel
                </button>
              </>
            ) : (
              <>
                <select value={view.hotkey} onChange={(e) => call("set_hotkey", { raw: e.currentTarget.value }).catch(fail)}>
                  {view.hotkeyPresets.map(([raw, label]) => (
                    <option value={raw}>{label}</option>
                  ))}
                </select>
                <button
                  onClick={() => {
                    setRecording(true);
                    call("record_hotkey");
                  }}
                >
                  Record…
                </button>
              </>
            )}
          </div>
          <div class="field">
            <span class="label">
              Model
              <span class="help">{view.models.find((m) => m.id === s.modelID)?.note}</span>
            </span>
            <select value={s.modelID} onChange={(e) => set("modelID", e.currentTarget.value)}>
              {view.models.map((m) => (
                <option value={m.id}>
                  {m.label}
                  {m.installed ? "" : ` (download ${m.sizeMb} MB)`}
                </option>
              ))}
            </select>
          </div>
          <div class="field">
            <span class="label">
              Language
              <span class="help">Parakeet is English only. Whisper takes any two-letter code, or auto.</span>
            </span>
            <input value={s.language} style={{ width: 80 }} onChange={(e) => set("language", e.currentTarget.value.trim() || "en")} />
          </div>
          <div class="field">
            <span class="label">
              Cleanup
              <span class="help">None pastes the engine's words as they came. Light fixes fillers, dictionary spellings and punctuation instantly.</span>
            </span>
            <select value={s.cleanupLevel} onChange={(e) => set("cleanupLevel", e.currentTarget.value as S["cleanupLevel"])}>
              <option value="none">None</option>
              <option value="light">Light</option>
            </select>
          </div>
          <Toggle label="Spoken commands (“new line”, “question mark”)" value={s.spokenCommands} onChange={(v) => set("spokenCommands", v)} />
          <Toggle label="Numbers as digits (“twenty two” becomes 22)" value={s.numbersAsDigits} onChange={(v) => set("numbersAsDigits", v)} />
          <Toggle label="Add a space after each dictation" value={s.trailingSpace} onChange={(v) => set("trailingSpace", v)} />
          <div class="field">
            <span class="label">
              When you fix pasted text
              <span class="help">Lin Flow reads back the field it pasted into and turns a word you fix into a dictionary correction. Editing a dictation here does the same.</span>
            </span>
            <select value={s.learnCorrections} onChange={(e) => set("learnCorrections", e.currentTarget.value as S["learnCorrections"])}>
              <option value="auto">Learn on its own, ask when unsure</option>
              <option value="ask">Always ask first</option>
              <option value="off">Don't learn</option>
            </select>
          </div>
          <div class="field">
            <span class="label">Keep dictation audio for</span>
            <input type="number" min={0} max={365} step={5} value={s.audioRetentionDays} style={{ width: 70 }} onChange={(e) => set("audioRetentionDays", Math.max(0, Number(e.currentTarget.value) || 0))} />
            <span class="muted">days</span>
          </div>
        </div>

        <h2>Notetaker</h2>
        <div class="group">
          <Toggle label="Offer to record when a call starts" help="When Zoom, Teams, Meet in a browser or another call app picks up the microphone." value={s.offerMeetingNotes} onChange={(v) => set("offerMeetingNotes", v)} />
          <Toggle label="Keep meeting audio files" help="About 115 MB per hour per side. The transcript, notes and summary are always kept." value={s.keepMeetingAudio} onChange={(v) => set("keepMeetingAudio", v)} />
          <Toggle label="Transcribe the recording again when a meeting ends" help="The live transcript keeps up by cutting every few seconds. Afterwards the saved audio is transcribed whole and replaces it." value={s.transcribeAfterMeeting} onChange={(v) => set("transcribeAfterMeeting", v)} />
          <Toggle label="Write running notes during a meeting" help="Every minute or so, a few bullets on what was just said." value={s.runningNotes} onChange={(v) => set("runningNotes", v)} />
          <Toggle label="Show the call tracker during a meeting" help="A panel at the edge of the screen with questions put to you, promises made, and the latest notes. Share one window, not the whole screen, to keep it off the call. Reopen it from the pill's menu." value={s.callTracker} onChange={(v) => set("callTracker", v)} />
          <div class="field">
            <span class="label">
              Claude
              <span class="help">Meetings never use it: everything from a call stays on this computer. Only the command line's ask and summarize read this key.</span>
            </span>
            <span class={view.claudeReady ? "" : "muted"}>{view.claudeReady ? "Key saved" : "No key"}</span>
          </div>
          <div class="field">
            <span class="label">
              Local model
              <span class="help">Ollama, for running notes, the call tracker, summaries and Ask, without sending anything off this computer.</span>
            </span>
            <input value={s.notesModel} style={{ width: 120 }} onChange={(e) => set("notesModel", e.currentTarget.value.trim())} />
          </div>
        </div>

        <h2>Shared totals</h2>
        <div class="group">
          <div class="field">
            <span class="label">Status</span>
            <span class="muted" style={{ textAlign: "right", maxWidth: 420 }}>
              {view.syncStatus}
            </span>
          </div>
        </div>

        <h2>App</h2>
        <div class="group">
          <Toggle label="Show the floating pill" value={s.showHUD} onChange={(v) => set("showHUD", v)} />
          {isMac ? <Toggle label="Show in Dock" value={s.showInDock} onChange={(v) => set("showInDock", v)} /> : null}
          <Toggle label="Sounds" value={s.sounds} onChange={(v) => set("sounds", v)} />
          <Toggle label="Open this window when Lin Flow starts" value={s.openWindowAtLaunch} onChange={(v) => set("openWindowAtLaunch", v)} />
          <Toggle label="Start when you log in" value={s.launchAtLogin} onChange={(v) => set("launchAtLogin", v)} />
          <div class="field">
            <span class="label">
              Files
              <span class="help">{view.dataDir}</span>
            </span>
            <button onClick={() => call("open_data_folder")}>Open Data Folder</button>
            <button onClick={() => call("open_log")}>Open Log</button>
          </div>
          {isMac ? null : <Updates onError={onError} />}
        </div>
      </div>
    </div>
  );
}

/** Windows only: the Mac's app is signed on the Mac and updates from its build script. */
function Updates({ onError }: { onError: (e: string) => void }) {
  const [view, setView] = useState<UpdateView | null>(null);
  const [busy, setBusy] = useState<"" | "checking" | "updating">("");
  const check = () => {
    setBusy("checking");
    call<UpdateView>("check_update")
      .then(setView)
      .catch((e) => onError(String(e)))
      .finally(() => setBusy(""));
  };
  const update = () => {
    setBusy("updating");
    // Lin Flow quits here and opens again once the new copy is in place.
    call("install_update").catch((e) => {
      setBusy("");
      onError(String(e));
    });
  };
  const line = !view
    ? "Looks on GitHub for the newest Windows build. Nothing updates until you click Update."
    : view.error
      ? view.error
      : view.newer
        ? `A newer build is out: ${view.latest}, from ${view.published}. This one is ${view.current || "unknown"}.`
        : `Up to date: ${view.current}.`;
  return (
    <div class="field">
      <span class="label">
        Updates
        <span class="help">{busy === "updating" ? "Downloading. Lin Flow closes, updates and opens again." : line}</span>
      </span>
      {view?.newer ? (
        <button disabled={busy !== ""} onClick={update}>
          Update
        </button>
      ) : (
        <button disabled={busy !== ""} onClick={check}>
          {busy === "checking" ? "Checking…" : "Check for updates"}
        </button>
      )}
    </div>
  );
}

function Toggle({ label, help, value, onChange }: { label: string; help?: string; value: boolean; onChange: (v: boolean) => void }) {
  return (
    <label class="field">
      <span class="label">
        {label}
        {help ? <span class="help">{help}</span> : null}
      </span>
      <input type="checkbox" checked={value} onChange={(e) => onChange(e.currentTarget.checked)} />
    </label>
  );
}
