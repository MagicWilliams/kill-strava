// Regression suite for #63 — "the plan has no race week" (observed 2026-09-26).
//
// David's active Chicago block: 13 weeks from 2026-07-06, race 2026-10-11. The generator
// turned a 13-week shape into a 13-week plan, so the last session of any kind fell on
// 2026-10-04 and there were zero sessions on race day. He was eight days from a marathon
// the app had no entry for. The shape was never at fault — propose_plan_shape excludes
// race week by contract; nothing appended it.
//
// These tests pin the contract the fix establishes: a plan's last session lands on or
// after its race date, and race day itself is a `race` session.

import { assert, assertEquals } from "jsr:@std/assert@^1";
import {
  generate,
  MARATHON_MI,
  MI,
  mondayOf,
  racePlacement,
  sessionDate,
  type Shape,
} from "./generator.ts";

const PACES = { easy: 570, marathon: 495, threshold: 420, interval: 400, repetition: 380 };

/// A shape whose phases sum to `weeks`, the way the handler normalizes them before
/// calling generate(). Phase mix is irrelevant to week arithmetic; only the sum matters.
function shapeOf(weeks: number): Shape {
  const taper = weeks >= 10 ? 2 : 1;
  return {
    archetype: "race_specific",
    rationale: "fixture",
    phases: [
      { name: "build", weeks: weeks - taper, focus: "Build", quality_per_week: 2 },
      { name: "taper", weeks: taper, focus: "Sharpen and freshen", quality_per_week: 1 },
    ],
    start_weekly_mi: 40,
    peak_weekly_mi: 60,
    long_run_start_mi: 12,
    long_run_peak_mi: 20,
  };
}

function plan(startMonday: string, raceDate: string, opts?: { longRunDay?: number; raceName?: string }) {
  const start = new Date(startMonday + "T00:00:00Z");
  const trainingWeeks = racePlacement(start, raceDate).weekIndex;
  const generated = generate(shapeOf(trainingWeeks), {
    startMonday: start,
    daysPerWeek: 6,
    longRunDay: opts?.longRunDay ?? 0,
    paces: PACES,
    wantsStrength: false,
    raceDate,
    raceName: opts?.raceName ?? null,
  });
  const dated = generated.sessions
    .map((s) => ({ ...s, date: sessionDate(start, s.week_index, s.day_offset) }))
    .sort((a, b) => a.date.localeCompare(b.date));
  return { ...generated, trainingWeeks, dated };
}

// ── The incident ──────────────────────────────────────────────────────────────

Deno.test("#63: the Chicago block reaches race day instead of stopping on 4 Oct", () => {
  const p = plan("2026-07-06", "2026-10-11");
  assertEquals(p.trainingWeeks, 13, "13 whole weeks from 6 Jul to 11 Oct");
  assertEquals(
    p.dated.at(-1)?.date,
    "2026-10-11",
    "the last session must be race day — it used to be 2026-10-04",
  );
});

Deno.test("#63: race day is a race session, not a long run", () => {
  const p = plan("2026-07-06", "2026-10-11", { raceName: "Chicago Marathon" });
  const raceDay = p.dated.filter((s) => s.date === "2026-10-11");
  assertEquals(raceDay.length, 1, "exactly one session on race day");
  assertEquals(raceDay[0].type, "race");
  assertEquals(raceDay[0].title, "Chicago Marathon");
  assertEquals(raceDay[0].target_pace_sec, PACES.marathon, "race is prescribed at goal pace");
  assertEquals(raceDay[0].target_distance_m, Math.round(MARATHON_MI * MI));
});

Deno.test("#63: race week is appended, not carved out of training", () => {
  const p = plan("2026-07-06", "2026-10-11");
  // The 13 training weeks are untouched: they still end on the Sunday before race week.
  const training = p.dated.filter((s) => s.type !== "race");
  assertEquals(training.at(-1)?.date, "2026-10-04");
  assertEquals(p.totalWeeks, 14, "13 training weeks + race week");
  assertEquals(p.raceWeekIndex, 13);
});

// ── Week bookkeeping ──────────────────────────────────────────────────────────

Deno.test("week indices stay contiguous from 0 with race week last", () => {
  const p = plan("2026-07-06", "2026-10-11");
  const idx = p.weeks.map((w) => w.index);
  assertEquals(idx, [...Array(14).keys()], "no gap and no duplicate week_index");
  assertEquals(p.weeks.at(-1)?.phase, "taper", "plan_weeks.phase CHECK admits no 'race'");
  assertEquals(p.weeks.at(-1)?.target, +MARATHON_MI.toFixed(1));
  assertEquals(p.weeks.at(-1)?.quality, 0, "race week prescribes no quality session");
});

Deno.test("race week holds the race and nothing invented around it", () => {
  const p = plan("2026-07-06", "2026-10-11");
  const raceWeek = p.sessions.filter((s) => s.week_index === p.raceWeekIndex);
  assertEquals(raceWeek.length, 1, "shakeouts and rest days are a coaching call, not arithmetic");
});

// ── The property the issue asked for ──────────────────────────────────────────

Deno.test("a plan's last session is never before its race date", () => {
  const start = "2026-07-06";
  // Sweep five weeks of race dates: every weekday, either side of a month boundary.
  for (let d = 0; d < 35; d++) {
    const race = sessionDate(new Date("2026-09-14T00:00:00Z"), 0, d);
    const p = plan(start, race);
    const last = p.dated.at(-1)!;
    assert(last.date >= race, `race ${race}: last session ${last.date} falls before the race`);
    assertEquals(last.date, race, `race ${race}: race day must be the final session`);
    assertEquals(last.type, "race", `race ${race}: final session must be the race`);
  }
});

Deno.test("race day lands correctly whichever weekday it falls on", () => {
  // Mon 2026-10-05 through Sun 2026-10-11, each as its own race date.
  for (let d = 0; d < 7; d++) {
    const race = sessionDate(new Date("2026-10-05T00:00:00Z"), 0, d);
    const placement = racePlacement(new Date("2026-07-06T00:00:00Z"), race);
    assertEquals(placement.weekIndex, 13, `${race} sits in plan week 13`);
    assertEquals(placement.dayOffset, d, `${race} is day ${d} of that week`);
    assertEquals(sessionDate(new Date("2026-07-06T00:00:00Z"), 13, d), race);
  }
});

Deno.test("a race on the start Monday itself is week 0, day 0", () => {
  const p = racePlacement(new Date("2026-07-06T00:00:00Z"), "2026-07-06");
  assertEquals(p, { weekIndex: 0, dayOffset: 0 });
});

// ── Helpers the writer shares ─────────────────────────────────────────────────

Deno.test("sessionDate crosses month and year boundaries", () => {
  const start = new Date("2026-12-28T00:00:00Z"); // a Monday
  assertEquals(sessionDate(start, 0, 6), "2027-01-03");
  assertEquals(sessionDate(start, 1, 0), "2027-01-04");
  assertEquals(sessionDate(start, 5, 3), "2027-02-04");
});

Deno.test("mondayOf is idempotent and agrees with plan-week coordinates", () => {
  const monday = mondayOf(new Date("2026-10-11T12:00:00Z"));
  assertEquals(monday.toISOString().slice(0, 10), "2026-10-05");
  assertEquals(mondayOf(monday).getTime(), monday.getTime());
});
