// Words the engine is primed with and snaps to, and corrections from what was heard to what was
// meant, with the suggestions an edit left waiting for a click.

import { useState } from "preact/hooks";
import { call, type Dictionary as Dict, type LearnMode } from "../api";
import { Trash } from "../icons";

const MODES: [LearnMode, string][] = [
  ["auto", "Learn on its own, ask when unsure"],
  ["ask", "Always ask first"],
  ["off", "Don't learn"],
];

export function Dictionary({ dict, learn, onLearn, onError }: { dict: Dict | null; learn: LearnMode; onLearn: (m: LearnMode) => void; onError: (e: string) => void }) {
  const [term, setTerm] = useState("");
  const [heard, setHeard] = useState("");
  const [meant, setMeant] = useState("");
  const fail = (e: unknown) => onError(String(e));

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
                {dict.pending.map((r) => (
                  <div class="item" key={r.from}>
                    <span class="muted">{r.from}</span>
                    <span class="arrow">→</span>
                    <span>{r.to}</span>
                    <span class="spacer" />
                    <button onClick={() => call("accept_rule", { from: r.from, to: r.to }).catch(fail)}>Add</button>
                    <button onClick={() => call("dismiss_rule", { from: r.from }).catch(fail)}>No</button>
                  </div>
                ))}
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
              {(dict?.rules ?? []).map((r) => (
                <div class="item" key={r.from}>
                  <span class="muted">{r.from}</span>
                  <span class="arrow">→</span>
                  <span>{r.to}</span>
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
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
