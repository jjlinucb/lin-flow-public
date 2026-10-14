// Toasts: what Lin Flow just learned, an offer to record a call, a countdown when a call ends,
// a warning when a side goes quiet. Each floats above the pill for a few seconds and goes by
// itself; clicking one does what it says. The window never takes focus: John is usually
// still typing.

import { render } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { call, onEvent, type Toast, type ToastAction } from "./api";
import "./styles.css";

const MAX = 3;

function Toasts() {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const box = useRef<HTMLDivElement>(null);
  const timers = useRef<Map<number, number>>(new Map());

  const dismiss = (id: number) => {
    window.clearTimeout(timers.current.get(id));
    timers.current.delete(id);
    setToasts((t) => t.filter((x) => x.id !== id));
  };

  useEffect(() => {
    const off = onEvent((e) => {
      if (e.type !== "toast") return;
      const t = e.toast;
      setToasts((list) => [...list.filter((x) => x.title !== t.title), t].slice(-MAX));
      timers.current.set(
        t.id,
        window.setTimeout(() => dismiss(t.id), t.seconds * 1000),
      );
    });
    return () => {
      off.then((f) => f());
    };
  }, []);

  // Fit the window to the stack, or hide it when the stack is empty.
  useLayoutEffect(() => {
    if (toasts.length === 0) {
      call("toast_hide");
      return;
    }
    const h = box.current?.getBoundingClientRect().height;
    if (h) call("toast_layout", { height: Math.ceil(h) });
  }, [toasts]);

  const act = (t: Toast, action?: ToastAction | null) => {
    dismiss(t.id);
    if (action) call("toast_action", { action });
  };

  return (
    <div class="toasts" ref={box}>
      {toasts.map((t) => (
        <div key={t.id} class={`toast-card ${t.warning ? "warning" : ""} ${t.action ? "clickable" : ""}`} onClick={() => act(t, t.action)}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div class="title">{t.title}</div>
            <div class="detail">{t.detail}</div>
          </div>
          {t.button ? (
            <button
              onClick={(e) => {
                e.stopPropagation();
                act(t, t.button![1]);
              }}
            >
              {t.button[0]}
            </button>
          ) : null}
        </div>
      ))}
    </div>
  );
}

render(<Toasts />, document.getElementById("root")!);
