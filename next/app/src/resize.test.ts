import { describe, expect, it } from "vitest";
import { dragSize, fitSize, MAX_SIZE, MIN_SIZE, savedSize } from "./resize";

describe("the tracker's resize corner", () => {
  it("grows and shrinks with the pointer", () => {
    const start = { width: 320, height: 460, x: 1000, y: 500 };
    expect(dragSize(start, 1100, 650)).toEqual([420, 610]);
    expect(dragSize(start, 950, 400)).toEqual([270, 360]);
  });

  it("never gets too small to read or larger than the limits", () => {
    const start = { width: 320, height: 460, x: 0, y: 0 };
    expect(dragSize(start, -5000, -5000)).toEqual(MIN_SIZE);
    expect(dragSize(start, 5000, 5000)).toEqual(MAX_SIZE);
    expect(fitSize(Number.NaN, 300)).toEqual([MIN_SIZE[0], 300]);
  });

  it("brings back a saved size, and ignores anything that is not one", () => {
    expect(savedSize(JSON.stringify([500, 700]))).toEqual([500, 700]);
    expect(savedSize(JSON.stringify([10, 99999]))).toEqual([MIN_SIZE[0], MAX_SIZE[1]]);
    for (const bad of [null, "", "nope", "{}", "[1]", '["a","b"]']) expect(savedSize(bad)).toBeNull();
  });
});
