// The floating pill: a dot or a level meter, the state, a hold-to-talk button and a close
// button. Drag it anywhere; the spot is remembered. Its window never takes focus, so the text
// still lands in the app being typed into.

import { render } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { call, onEvent, startDragging, type Phase, type StatusView } from "./api";
import { Close, Mic } from "./icons";
import "./styles.css";

const COLORS: Record<Phase, string> = {
  loading: "rgb(140, 140, 148)",
  idle: "rgb(77, 199, 107)",
  recording: "rgb(242, 59, 59)",
  error: "rgb(242, 59, 59)",
  working: "rgb(250, 179, 51)",
};

const SHAPE = [0.45, 0.75, 1.0, 0.75, 0.45];

function Pill() {
  const [phase, setPhase] = useState<Phase>("loading");
  const [label, setLabel] = useState("Starting…");
  const [level, setLevel] = useState(0);
  const [holding, setHolding] = useState(false);
  const [menu, setMenu] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);
  const moved = useRef(false);

  useEffect(() => {
    call<StatusView>("status").then((s) => {
      setPhase(s.phase);
      setLabel(s.label);
    });
    const off = onEvent((e) => {
      if (e.type === "state") {
        setPhase(e.phase);
        setLabel(e.label);
        if (e.phase !== "recording") setLevel(0);
      }
      // Fast attack, slow decay, so the meter reads as speech rather than noise.
      if (e.type === "level") setLevel((l) => Math.max(e.level, l * 0.75));
    });
    return () => {
      off.then((f) => f());
    };
  }, []);

  // The window fits the pill, so no invisible margin catches clicks meant for the app below.
  useLayoutEffect(() => {
    const w = wrap.current?.getBoundingClientRect().width;
    if (w) call("pill_layout", { width: Math.ceil(w) });
  }, [label, phase, menu]);

  const recording = phase === "recording";
  const amp = Math.min(1, level * 6);

  return (
    <div class="pill-wrap" ref={wrap}>
      <div
        class="pill-body"
        title="Drag to move. Click for the menu."
        onMouseDown={(e) => {
          if (e.button !== 0) return;
          moved.current = false;
          const start = { x: e.screenX, y: e.screenY };
          const onMove = (m: MouseEvent) => {
            if (!moved.current && Math.hypot(m.screenX - start.x, m.screenY - start.y) > 3) {
              moved.current = true;
              startDragging().then(() => call("pill_moved"));
            }
          };
          const onUp = () => {
            window.removeEventListener("mousemove", onMove);
            window.removeEventListener("mouseup", onUp);
            if (!moved.current) setMenu((m) => !m);
            else call("pill_moved");
          };
          window.addEventListener("mousemove", onMove);
          window.addEventListener("mouseup", onUp);
        }}
      >
        <div class="pill-meter">
          {recording ? (
            SHAPE.map((s) => <i style={{ height: `${Math.max(3, (4 + 12 * amp) * s)}px`, background: COLORS[phase] }} />)
          ) : (
            <i style={{ width: "9px", height: "9px", borderRadius: "50%", background: COLORS[phase] }} />
          )}
        </div>
        <span>{label}</span>
      </div>
      {menu ? (
        <>
          {[
            ["dictation", "Dictations"],
            ["note", "Meeting note"],
            ["dictionary", "Dictionary"],
            ["settings", "Settings"],
          ].map(([item, text]) => (
            <button
              class="pill-button"
              style={{ width: "auto", padding: "0 10px", borderRadius: "14px", color: "#fff", fontSize: "12.5px" }}
              onClick={() => {
                setMenu(false);
                call("pill_menu", { item });
              }}
            >
              {text}
            </button>
          ))}
        </>
      ) : (
        <>
          <button
            class={`pill-button ${recording || holding ? "on" : ""}`}
            title="Click and hold to dictate"
            onMouseDown={(e) => {
              e.preventDefault();
              setHolding(true);
              call("press");
            }}
            onMouseUp={() => {
              setHolding(false);
              call("release");
            }}
            onMouseLeave={() => {
              if (holding) {
                setHolding(false);
                call("release");
              }
            }}
          >
            <Mic size={15} color="#fff" />
          </button>
          <button class="pill-button pill-close" title="Hide the pill" onClick={() => call("hide_pill")}>
            <Close color="#fff" />
          </button>
        </>
      )}
    </div>
  );
}

render(<Pill />, document.getElementById("root")!);
