import { describe, expect, it } from "vitest";
import { clock, dayLabel, grouped, noteDate, timeOfDay, type MeetingNote } from "./api";

// Times are built in local time, so the results hold in any time zone. Newer ICU puts a narrow
// no-break space before AM and PM; the tests read it as a space.
const local = (y: number, mo: number, d: number, h = 12, mi = 0) => new Date(y, mo - 1, d, h, mi).toISOString();
const spaces = (s: string) => s.replace(/\s/g, " ");

describe("clock", () => {
  it("shows minutes and seconds, and hours once there are any", () => {
    expect(clock(0)).toBe("0:00");
    expect(clock(65)).toBe("1:05");
    expect(clock(599.9)).toBe("9:59");
    expect(clock(3600)).toBe("1:00:00");
    expect(clock(3725)).toBe("1:02:05");
  });

  it("never goes below zero", () => {
    expect(clock(-4)).toBe("0:00");
  });
});

describe("grouped", () => {
  it("separates thousands", () => {
    expect(grouped(0)).toBe("0");
    expect(grouped(1234567)).toBe("1,234,567");
  });
});

describe("dayLabel", () => {
  const now = new Date(2026, 9, 2, 9, 0);

  it("says Today and Yesterday by the calendar, not by 24 hours", () => {
    expect(dayLabel(local(2026, 10, 2, 0, 5), now)).toBe("Today");
    expect(dayLabel(local(2026, 10, 1, 23, 55), now)).toBe("Yesterday");
    expect(dayLabel(local(2026, 10, 1, 0, 5), now)).toBe("Yesterday");
  });

  it("names older days, with the year only when it differs", () => {
    expect(dayLabel(local(2026, 9, 28), now)).toBe("Monday, September 28");
    expect(dayLabel(local(2025, 12, 31), now)).toBe("Wednesday, December 31, 2025");
  });
});

describe("timeOfDay and noteDate", () => {
  const note = (durationSeconds: number): MeetingNote => ({
    id: "N",
    title: "T",
    createdAt: local(2026, 10, 2, 9, 30),
    durationSeconds,
    usedMicrophone: true,
    usedSystemAudio: true,
  });

  it("shows the hour without a leading zero", () => {
    expect(spaces(timeOfDay(local(2026, 10, 2, 9, 5)))).toBe("9:05 AM");
    expect(spaces(timeOfDay(local(2026, 10, 2, 15, 40)))).toBe("3:40 PM");
  });

  it("adds the length once a meeting has one, at least a minute", () => {
    expect(spaces(noteDate(note(0)))).toBe("Oct 2, 9:30 AM");
    expect(spaces(noteDate(note(20)))).toBe("Oct 2, 9:30 AM · 1 min");
    expect(spaces(noteDate(note(3540)))).toBe("Oct 2, 9:30 AM · 59 min");
  });
});
