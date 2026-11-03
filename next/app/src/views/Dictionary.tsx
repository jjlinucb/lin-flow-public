// Words the engine is primed with and snaps to, and corrections from what was heard to what was
// meant, with the suggestions an edit left waiting for a click. Click a correction or a
// suggestion to fix either side in place.

import { useEffect, useRef, useState } from "preact/hooks";
import { call, saveEdit, type Dictionary as Dict, type LearnMode, type Replacement, type RuleEdit } from "../api";
import { Trash } from "../icons";

/** One correction's two sides as inputs, saved on Enter and dropped on Escape. */
function EditRow({ edit, onChange, onSave, onCancel }: { edit: RuleEdit; onChange: (e: RuleEdit) => void; onSave: () => void; onCancel: () => void }) {
  const keys = (e: KeyboardEvent) => {
    if (e.key === "Enter") onSave();
    if (e.key === "Escape") onCancel();
  };
  const ok = saveEdit(edit) !== null;
  // The right side is the one usually wrong, so it opens selected.
  const meant = useRef<HTMLInputElement>(null);
  useEffect(() => meant.current?.select(), []);
  return (
    <div class="item">
      <input aria-label="Heard as" value={edit.from} onInput={(e) => onChange({ ...edit, from: e.currentTarget.value })} onKeyDown={keys} style={{ flex: 1, minWidth: 0 }} />
      <span class="arrow">→</span>
      <input aria-label="Should be" value={edit.to} onInput={(e) => onChange({ ...edit, to: e.currentTarget.value })} onKeyDown={keys} ref={meant} style={{ flex: 1, minWidth: 0 }} />
      <button class="primary" onClick={onSave} disabled={!ok}>
        {edit.kind === "pending" ? "Add" : "Save"}
      </button>
      <button onClick={onCancel}>Cancel</button>
    </div>
  );
}

/** A rule's two sides, as a button that opens it for editing. */
function Sides({ r, onEdit }: { r: Replacement; onEdit: () => void }) {
  return (
    <button class="sides" title="Click to edit" onClick={onEdit}>
      <span class="muted">{r.from}</span>
      <span class="arrow">→</span>
      <span>{r.to}</span>
    </button>
  );
}

const MODES: [LearnMode, string][] = [
  ["auto", "Learn on its own, ask when unsure"],
  ["ask", "Always ask first"],
  ["off", "Don't learn"],
];

export function Dictionary({ dict, learn, onLearn, onError }: { dict: Dict | null; learn: LearnMode; onLearn: (m: LearnMode) => void; onError: (e: string) => void }) {
  const [term, setTerm] = useState("");
  const [heard, setHeard] = useState("");
  const [meant, setMeant] = useState("");
  const [edit, setEdit] = useState<RuleEdit | null>(null);
  const fail = (e: unknown) => onError(String(e));

  const open = (kind: RuleEdit["kind"], r: Replacement) => setEdit({ kind, original: r.from, from: r.from, to: r.to });
  const save = async () => {
    const cmd = edit && saveEdit(edit);
    if (!cmd) return;
    await call(cmd[0], cmd[1])
      .then(() => setEdit(null))
      .catch(fail);
  };
  const editing = (kind: RuleEdit["kind"], r: Replacement) => edit?.kind === kind && edit.original === r.from;
  const editor = () => edit && <EditRow key={`edit-${edit.kind}-${edit.original}`} edit={edit} onChange={setEdit} onSave={save} onCancel={() => setEdit(null)} />;

  const addTerm = async () => {
    if (!term.trim()) return;
    await call("add_term", { term }).catch(fail);
    setTerm("");
  };
  const addRule = async () => {
    if (!heard.trim() || !meant.trim()) return;
    await call("add_rule", { from: heard, to: meant }).catch(fail);
    setHeard("");
    setMeant("");
  };

  return (
    <div class="section">
      <div class="section-head">
        <h1>Dictionary</h1>
      </div>
      <div class="columns">
        <div>
          <h2>Words</h2>
          <div class="muted small">Names, products, jargon. The engine is primed with these, and the cleanup snaps near misses to this exact spelling.</div>
          <div class="row" style={{ marginTop: 10 }}>
            <input placeholder="Add a word or name" value={term} onInput={(e) => setTerm(e.currentTarget.value)} onKeyDown={(e) => e.key === "Enter" && addTerm()} style={{ flex: 1 }} />
            <button onClick={addTerm} disabled={!term.trim()}>
              Add
            </button>
          </div>
          <div class="list">
            {(dict?.terms ?? []).map((t) => (
              <div class="item" key={t}>
                <span>{t}</span>
                <span class="spacer" />
                <button class="icon" title="Remove" onClick={() => call("remove_term", { term: t }).catch(fail)}>
                  <Trash />
                </button>
              </div>
            ))}
          </div>
        </div>
        <div>
          <h2>Corrections</h2>
          <div class="muted small">When Lin Flow hears the left, it writes the right. Whole words, any capitalization.</div>
          <div class="row" style={{ marginTop: 10 }}>
            <input placeholder="Heard as" value={heard} onInput={(e) => setHeard(e.currentTarget.value)} onKeyDown={(e) => e.key === "Enter" && addRule()} style={{ flex: 1, minWidth: 0 }} />
            <span class="arrow">→</span>
            <input placeholder="Should be" value={meant} onInput={(e) => setMeant(e.currentTarget.value)} onKeyDown={(e) => e.key === "Enter" && addRule()} style={{ flex: 1, minWidth: 0 }} />
            <button onClick={addRule} disabled={!heard.trim() || !meant.trim()}>
              Add
            </button>
          </div>
          <div class="row small" style={{ marginTop: 10 }}>
            <span class="muted">When you fix pasted text</span>
            <select value={learn} onChange={(e) => onLearn(e.currentTarget.value as LearnMode)}>
              {MODES.map(([m, label]) => (
                <option value={m}>{label}</option>
              ))}
            </select>
          </div>
          {dict && dict.pending.length > 0 ? (
            <>
              <h2 style={{ marginTop: 16 }}>Suggested</h2>
              <div class="list">
                {dict.pending.map((r) =>
                  editing("pending", r) ? (
                    editor()
                  ) : (
                    <div class="item" key={r.from}>
                      <Sides r={r} onEdit={() => open("pending", r)} />
                      <span class="spacer" />
                      <button onClick={() => call("accept_rule", { from: r.from, to: r.to }).catch(fail)}>Add</button>
                      <button onClick={() => call("dismiss_rule", { from: r.from }).catch(fail)}>No</button>
                    </div>
                  ),
                )}
              </div>
            </>
          ) : null}
          {dict && dict.rules.length === 0 ? (
            <div class="empty" style={{ margin: "40px auto" }}>
              <h2>No corrections yet</h2>
              Add one when a word keeps coming out wrong, for example “wisper flow” to “Wispr Flow”.
            </div>
          ) : (
            <div class="list" style={{ marginTop: 16 }}>
              {(dict?.rules ?? []).map((r) =>
                editing("rule", r) ? (
                  editor()
                ) : (
                  <div class="item" key={r.from}>
                    <Sides r={r} onEdit={() => open("rule", r)} />
                    {r.learned ? (
                      <span class="chip" title="Lin Flow added this from an edit you made">
                        learned
                      </span>
                    ) : null}
                    <span class="spacer" />
                    <button class="icon" title="Remove" onClick={() => call("remove_rule", { from: r.from }).catch(fail)}>
                      <Trash />
                    </button>
                  </div>
                ),
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
