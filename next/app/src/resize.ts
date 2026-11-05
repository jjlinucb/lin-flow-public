// Sizing a floating window by a corner the page draws itself. The tracker has no frame, so macOS
// gives it no edges to grab (John, 2026-11-05: "I can move it but not change the size").

/** The smallest size that still shows a heading and a few items, and the largest worth having. */
export const MIN_SIZE: [number, number] = [240, 200];
export const MAX_SIZE: [number, number] = [900, 1400];

/** A size kept inside the limits, in whole points. */
export function fitSize(width: number, height: number): [number, number] {
  const clamp = (v: number, lo: number, hi: number) => Math.round(Math.min(hi, Math.max(lo, Number.isFinite(v) ? v : lo)));
  return [clamp(width, MIN_SIZE[0], MAX_SIZE[0]), clamp(height, MIN_SIZE[1], MAX_SIZE[1])];
}

/** The size a corner drag gives: where it started, plus how far the pointer moved. */
export function dragSize(start: { width: number; height: number; x: number; y: number }, x: number, y: number): [number, number] {
  return fitSize(start.width + (x - start.x), start.height + (y - start.y));
}

/** A size saved by an earlier drag, or null when there is none or it is not a size. */
export function savedSize(raw: string | null): [number, number] | null {
  if (!raw) return null;
  try {
    const v = JSON.parse(raw);
    if (!Array.isArray(v) || v.length !== 2 || !v.every((n) => typeof n === "number" && Number.isFinite(n))) return null;
    return fitSize(v[0], v[1]);
  } catch {
    return null;
  }
}
