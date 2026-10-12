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

import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert@^1";
import {
  DEFAULT_BASIS_MARATHON_S,
  DEFAULT_PREFERENCES,
  equivalentTime,
  FITNESS_MARGIN,
  fmtClock,
  paceBasis,
  type DistanceKey,
  DISTANCES,
  generate,
  MARATHON_MI,
  MI,
  mondayOf,
  planWrites,
  type Preferences,
  racePlacement,
  readPreferences,
  resolveDistance,
  sessionDate,
  type Shape,
  trainingPaces,
} from "./generator.ts";

const PACES = { easy: 570, marathon: 495, threshold: 420, interval: 400, repetition: 380, race: 495 };

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

// ═════════════════════════════════════════════════════════════════════════════════════════
// #104 — every distance from the mile to the marathon (opened 2026-10-12).
//
// Before #104 the generator knew one race. A 5K athlete would have been handed 20-mile long
// runs, a three-week taper and a race-day session hardcoded at 26.2 mi. The intake (#102)
// now asks for any of seven distances and for what the athlete wants from the block; these
// tests pin the distance table and each preference as it actually reaches the plan.
// ═════════════════════════════════════════════════════════════════════════════════════════

const BLOCK_START = "2026-11-02"; // a Monday
const ALL_DISTANCES: DistanceKey[] = ["1mi", "5k", "10k", "15k", "10mi", "half", "marathon"];

/// A 16-week block: 15 training weeks + race week, race on the final Sunday.
const RACE_16 = sessionDate(new Date(BLOCK_START + "T00:00:00Z"), 15, 6);

/// What the model typically proposes, including its OWN guess at a taper — deliberately the
/// marathon's two weeks, so a passing test proves the table set the taper, not the model.
function modelShape(trainingWeeks: number, o: Partial<Shape> = {}): Shape {
  const rest = trainingWeeks - 2;
  const base = Math.floor(rest / 3), peak = Math.floor(rest / 3), build = rest - base - peak;
  return {
    archetype: "progressive_build",
    rationale: "fixture",
    phases: [
      { name: "base", weeks: base, focus: "Base", quality_per_week: 1 },
      { name: "build", weeks: build, focus: "Build", quality_per_week: 2 },
      { name: "peak", weeks: peak, focus: "Peak", quality_per_week: 2 },
      { name: "taper", weeks: 2, focus: "Taper", quality_per_week: 1 },
    ],
    start_weekly_mi: 40,
    peak_weekly_mi: 60,
    long_run_start_mi: 10,
    long_run_peak_mi: 20,
    ...o,
  };
}

function block(o: {
  distance?: DistanceKey; prefs?: Partial<Preferences>; shape?: Partial<Shape>; raceDate?: string;
  firstWeekIndex?: number; anchor?: number | null; current?: number | null; wantsStrength?: boolean;
} = {}) {
  const start = new Date(BLOCK_START + "T00:00:00Z");
  const raceDate = o.raceDate ?? RACE_16;
  const trainingWeeks = racePlacement(start, raceDate).weekIndex - (o.firstWeekIndex ?? 0);
  const g = generate(modelShape(trainingWeeks, o.shape), {
    startMonday: start,
    firstWeekIndex: o.firstWeekIndex,
    daysPerWeek: 6,
    longRunDay: 0,
    paces: PACES,
    wantsStrength: o.wantsStrength ?? false,
    raceDate,
    raceName: null,
    distance: DISTANCES[o.distance ?? "marathon"],
    prefs: { ...DEFAULT_PREFERENCES, ...o.prefs },
    currentWeeklyMi: o.current ?? null,
    anchorWeeklyMi: o.anchor ?? null,
  });
  const phaseOf = new Map(g.weeks.map((w) => [w.index, w.phase]));
  const longs = g.sessions.filter((s) => s.type === "long");
  const quality = g.sessions.filter((s) => ["tempo", "threshold", "interval"].includes(s.type));
  return { ...g, start, raceDate, phaseOf, longs, quality };
}

const miles = (m: number | null) => (m ?? 0) / MI;

// ── Distance table: taper, long-run cap, volume band ─────────────────────────

Deno.test("#104: each distance tapers for its own length, whatever taper the model proposed", () => {
  // [taper-phase training weeks, reduced-load days to a Sunday race]. Race week holds the
  // race and nothing else, so it is a week of taper on its own.
  const expected: Record<DistanceKey, [number, number]> = {
    "1mi": [0, 7], "5k": [0, 7], "10k": [1, 14], "15k": [1, 14], "10mi": [1, 14], half: [1, 14], marathon: [2, 21],
  };
  for (const d of ALL_DISTANCES) {
    const p = block({ distance: d });
    const taper = p.weeks.filter((w) => w.phase === "taper" && w.index !== p.raceWeekIndex);
    assertEquals(taper.length, expected[d][0], `${d}: taper weeks (the model asked for 2)`);
    const firstTaperMonday = sessionDate(p.start, taper[0]?.index ?? p.raceWeekIndex, 0);
    const days = (Date.parse(p.raceDate) - Date.parse(firstTaperMonday)) / 86400_000 + 1;
    assertEquals(days, expected[d][1], `${d}: taper length in days`);
    assertEquals(p.totalWeeks, 16, `${d}: taper is carved out of the block, never appended`);
    assertEquals(p.weeks.map((w) => w.index), [...Array(16).keys()], `${d}: weeks stay contiguous`);
  }
});

Deno.test("#104: a 5K's last training week is full volume — race week is its whole taper", () => {
  const p = block({ distance: "5k" });
  const last = p.weeks.find((w) => w.index === p.raceWeekIndex - 1)!;
  assertEquals(last.phase, "peak");
  assert(last.target >= 50, `week before a 5K should be near peak, got ${last.target}`);
});

Deno.test("#104: a short marathon block keeps its one-week taper", () => {
  const raceDate = sessionDate(new Date(BLOCK_START + "T00:00:00Z"), 8, 6); // 8 training weeks
  const p = block({ distance: "marathon", raceDate });
  assertEquals(p.weeks.filter((w) => w.phase === "taper" && w.index !== p.raceWeekIndex).length, 1);
});

Deno.test("#104: each distance's long run stops at its cap, however big the model's ask", () => {
  // A huge ask on a big-volume athlete, so the 40%-of-week rule is not what binds.
  const caps: Record<DistanceKey, number> = {
    "1mi": 9, "5k": 10, "10k": 12, "15k": 13, "10mi": 14, half: 15, marathon: 22,
  };
  for (const d of ALL_DISTANCES) {
    const p = block({
      distance: d, current: 90,
      shape: { start_weekly_mi: 70, peak_weekly_mi: 90, long_run_start_mi: 18, long_run_peak_mi: 26 },
    });
    const longest = Math.max(...p.longs.map((s) => miles(s.target_distance_m)));
    assertAlmostEquals(longest, caps[d], 0.01, `${d}: longest long run`);
    assertEquals(p.shape.long_run_peak_mi, caps[d]);
  }
});

Deno.test("#104: a mile block's long run is 8–10 mi, not 20", () => {
  const p = block({ distance: "1mi", shape: { long_run_peak_mi: 20, peak_weekly_mi: 40 } });
  const longest = Math.max(...p.longs.map((s) => miles(s.target_distance_m)));
  assert(longest <= 9.01 && longest >= 8, `mile block longest run ${longest.toFixed(1)} mi`);
});

Deno.test("#104: peak volume is held to the distance's band, never below what they already run", () => {
  const ask = { start_weekly_mi: 40, peak_weekly_mi: 90 };
  const capped = block({ distance: "5k", current: 35, shape: ask });
  assertEquals(capped.shape.peak_weekly_mi, DISTANCES["5k"].peakBandMi[1]);
  assert(Math.max(...capped.weeks.map((w) => w.target)) <= 55);
  // A 62-mpw runner training for a 5K is not cut to 55.
  const high = block({ distance: "5k", current: 62, shape: ask });
  assertEquals(high.shape.peak_weekly_mi, 62);
  // The marathon band is wide enough that a 60-mile ask passes through untouched.
  assertEquals(block({ distance: "marathon", current: 45 }).shape.peak_weekly_mi, 60);
});

Deno.test("#104: race day is the race the athlete entered, at its goal pace", () => {
  for (const d of ALL_DISTANCES) {
    const p = block({ distance: d });
    const race = p.sessions.find((s) => s.type === "race")!;
    assertEquals(race.target_distance_m, DISTANCES[d].meters, `${d}: race distance`);
    assertEquals(race.target_pace_sec, PACES.race, `${d}: race pace`);
    assertEquals(p.weeks.at(-1)!.target, +(DISTANCES[d].meters / MI).toFixed(1));
  }
});

Deno.test("#104: short races lean on speed; long races on threshold and race-pace long runs", () => {
  const share = (d: DistanceKey) => {
    const p = block({ distance: d });
    const intervals = p.quality.filter((s) => s.type === "interval").length;
    return { intervals: intervals / p.quality.length, p };
  };
  const mile = share("1mi"), fiveK = share("5k"), marathon = share("marathon");
  assert(mile.intervals > 0.5, `mile: ${mile.intervals.toFixed(2)} of quality is speed/VO₂`);
  assert(fiveK.intervals > 0.5, `5K: ${fiveK.intervals.toFixed(2)} of quality is speed/VO₂`);
  assert(marathon.intervals < 0.35, `marathon: ${marathon.intervals.toFixed(2)} of quality is speed/VO₂`);
  assert(marathon.p.longs.some((s) => s.title === "Race-pace long run"), "marathon gets race-pace long runs");
  assert(!fiveK.p.longs.some((s) => s.title === "Race-pace long run"), "a 5K does not");
  assert(mile.p.quality.some((s) => s.title === "Speed reps"), "mile block has short speed reps");
});

// ── long_runs_20plus: a hard constraint ──────────────────────────────────────

Deno.test("#104: a 16-week marathon contains exactly the 20+ mi long runs asked for (0/3/5)", () => {
  const twenty = Math.round(20 * MI);
  for (const n of [0, 3, 5]) {
    // long_run_peak 21: unconstrained, the block would contain several 20+ runs by itself.
    const p = block({ distance: "marathon", prefs: { longRunsBig: n }, shape: { long_run_peak_mi: 21 } });
    const big = p.longs.filter((s) => s.target_distance_m! >= twenty);
    assertEquals(big.length, n, `asked for ${n}`);
    for (const s of big) {
      const phase = p.phaseOf.get(s.week_index);
      assert(phase !== "taper", `20-miler in a taper week (${s.week_index})`);
      const wk = p.weeks.find((w) => w.index === s.week_index)!;
      assert(wk.target >= miles(s.target_distance_m), "the week's target holds its long run");
    }
    assertEquals(p.warnings, []);
  }
});

Deno.test("#104: 20-milers sit in the peak phase, spread out, borrowing build weeks only if needed", () => {
  const twenty = Math.round(20 * MI);
  const three = block({ distance: "marathon", prefs: { longRunsBig: 3 } });
  const threeWeeks = three.longs.filter((s) => s.target_distance_m! >= twenty).map((s) => s.week_index);
  assert(threeWeeks.every((i) => three.phaseOf.get(i) === "peak"), `three in peak: ${threeWeeks}`);
  assert(threeWeeks.every((i, k) => k === 0 || i - threeWeeks[k - 1] >= 1));
  assertEquals(threeWeeks.at(-1), Math.max(...three.weeks.filter((w) => w.phase === "peak").map((w) => w.index)));

  const five = block({ distance: "marathon", prefs: { longRunsBig: 5 } });
  const fiveWeeks = five.longs.filter((s) => s.target_distance_m! >= twenty).map((s) => s.week_index);
  const phases = fiveWeeks.map((i) => five.phaseOf.get(i));
  assertEquals(phases.filter((p) => p === "peak").length, 4, "the whole 4-week peak");
  assertEquals(phases.filter((p) => p === "build").length, 1, "plus the latest build week");
});

Deno.test("#104: the half's mark is 12 mi, and a 5K ignores the question", () => {
  const twelve = Math.round(12 * MI);
  const half = block({ distance: "half", prefs: { longRunsBig: 2 }, shape: { long_run_peak_mi: 14 } });
  assertEquals(half.longs.filter((s) => s.target_distance_m! >= twelve).length, 2);
  // Not an error for a 5K, just inapplicable: same plan as without the answer.
  assertEquals(block({ distance: "5k", prefs: { longRunsBig: 4 } }).sessions, block({ distance: "5k" }).sessions);
});

// ── plan_style ───────────────────────────────────────────────────────────────

Deno.test("#104: plan_style none writes nothing but the goal", () => {
  const p = block();
  assertEquals(planWrites("none", p), { plan: false, weeks: [], sessions: [] });
  assertEquals(planWrites("none", null), { plan: false, weeks: [], sessions: [] });
});

Deno.test("#104: plan_style weekly writes every week, but only the sessions that carry intent", () => {
  const p = block({ wantsStrength: true });
  const weekly = planWrites("weekly", p);
  assert(weekly.plan);
  assertEquals(weekly.weeks, p.weeks, "same weeks, same targets");
  assertEquals(weekly.sessions.filter((s) => s.type === "easy").length, 0, "no easy runs");
  assertEquals(weekly.sessions.filter((s) => s.type === "cross").length, 0, "no strength");
  assertEquals(weekly.sessions.filter((s) => s.type === "long").length, p.longs.length);
  assertEquals(weekly.sessions.filter((s) => s.type === "race").length, 1);
  assertEquals(
    weekly.sessions.filter((s) => ["tempo", "threshold", "interval"].includes(s.type)).length,
    p.quality.length,
  );
  // And full is today's behavior: everything.
  assertEquals(planWrites("full", p).sessions, p.sessions);
});

// ── Mid-block start ──────────────────────────────────────────────────────────

Deno.test("#104: a mid-block start at week 9 of 16 begins there, at real volume", () => {
  // Block week 0 is BLOCK_START; the athlete joins in week 9 (index 8) having run 42.3 mi/wk
  // over the last four weeks. The model's shape covers only the 7 weeks that remain.
  const p = block({ firstWeekIndex: 8, anchor: 42.3, shape: { start_weekly_mi: 30 } });
  assertEquals(p.totalWeeks, 16, "the app reads 'Week 9 of 16'");
  assertEquals(p.weeks[0].index, 8, "first created week is week 9");
  assertEquals(p.weeks[0].target, 42.3, "…at the athlete's real volume, not the model's 30");
  assertEquals(p.weeks.map((w) => w.index), [8, 9, 10, 11, 12, 13, 14, 15]);
  assertEquals(Math.min(...p.sessions.map((s) => s.week_index)), 8, "weeks 1–8 are never created");
  const first = p.sessions.map((s) => sessionDate(p.start, s.week_index, s.day_offset)).sort()[0];
  assert(first >= sessionDate(p.start, 8, 0), `first session ${first} predates the join week`);
  assertEquals(p.sessions.find((s) => s.type === "race")!.week_index, 15);
});

// ── Course type and quality picks ────────────────────────────────────────────

const hillsIn = (p: ReturnType<typeof block>) => p.quality.filter((s) => s.title === "Hill repeats");

Deno.test("#104: hill sessions appear only for rolling or hilly courses, and only in base/build", () => {
  assertEquals(hillsIn(block()).length, 0, "no course given");
  assertEquals(hillsIn(block({ prefs: { courseType: "flat" } })).length, 0, "flat");
  assertEquals(hillsIn(block({ prefs: { courseType: "trail" } })).length, 0, "trail is a note in v1");
  for (const course of ["rolling", "hilly"] as const) {
    const p = block({ prefs: { courseType: course } });
    assert(hillsIn(p).length > 0, `${course}: hills prescribed`);
    for (const s of hillsIn(p)) {
      assert(["base", "build"].includes(p.phaseOf.get(s.week_index)!), `${course}: hills outside base/build`);
    }
  }
});

Deno.test("#104: a trail course changes nothing but a note on the long runs", () => {
  const trail = block({ prefs: { courseType: "trail" } });
  const flat = block({ prefs: { courseType: "flat" } });
  assertEquals(trail.quality, flat.quality);
  assert(trail.notes.length === 1 && flat.notes.length === 0);
  assert((trail.longs[0].structure as { detail: string }).detail.includes("trail"));
});

Deno.test("#104: only the workout types the athlete picked are prescribed", () => {
  const tempoOnly = block({ distance: "5k", prefs: { quality: ["tempo"] } });
  assert(tempoOnly.quality.length > 0);
  for (const s of tempoOnly.quality) {
    assert(["tempo", "threshold"].includes(s.type), `${s.title} is not tempo work`);
  }
  // Picking workouts outranks the course: hilly, but they didn't pick hills.
  assertEquals(hillsIn(block({ prefs: { courseType: "hilly", quality: ["tempo", "intervals"] } })).length, 0);
  // …and an athlete who picks hills gets them on a flat course too.
  assert(hillsIn(block({ prefs: { courseType: "flat", quality: ["hills", "tempo"] } })).length > 0);
  // No race-pace pick → no race-pace long runs.
  assert(!block({ prefs: { quality: ["tempo"] } }).longs.some((s) => s.title === "Race-pace long run"));
});

Deno.test("#104: an empty pick list is the default mix, not an empty plan", () => {
  assertEquals(block({ prefs: { quality: [] } }).sessions, block().sessions);
  // A single pick that a phase has no default for still yields that kind, never nothing.
  const hillsOnly = block({ prefs: { quality: ["hills"] } });
  assertEquals(hillsIn(hillsOnly).length, hillsOnly.quality.length);
  assert(hillsOnly.quality.length > 0);
});

// ── Reading the request defensively ──────────────────────────────────────────

Deno.test("#104: distance_m outranks the label; neither means marathon, as before", () => {
  assertEquals(resolveDistance(undefined, undefined).profile.key, "marathon");
  assertEquals(resolveDistance(null, null).label, "marathon");
  assertEquals(resolveDistance("5k", null).meters, 5000);
  assertEquals(resolveDistance("1mi", undefined).meters, 1609);
  assertEquals(resolveDistance("10mi", undefined).meters, 16093);
  assertEquals(resolveDistance("marathon", 21097).profile.key, "half", "metres are the truth");
  assertEquals(resolveDistance(undefined, 10000).label, "10k");
  const odd = resolveDistance("custom", 8000); // 8K: nearest row is the 10K
  assertEquals(odd.label, "custom");
  assertEquals(odd.profile.key, "10k");
  assertEquals(odd.profile.meters, 8000, "the race session is the race they entered");
  assertEquals(resolveDistance("ultra", undefined).label, "marathon", "unknown label");
  assertEquals(resolveDistance(undefined, -3).label, "marathon", "nonsense metres");
});

Deno.test("#104: preferences tolerate a missing column, null, and junk", () => {
  assertEquals(readPreferences(undefined), DEFAULT_PREFERENCES, "pre-0013: no column");
  assertEquals(readPreferences(null), DEFAULT_PREFERENCES, "post-0013, old goal");
  assertEquals(readPreferences("weekly"), DEFAULT_PREFERENCES);
  assertEquals(readPreferences({ plan_style: "sometimes", long_runs_20plus: -1, quality: "tempo" }), DEFAULT_PREFERENCES);
  assertEquals(
    readPreferences({
      v: 1, plan_style: "Weekly", long_runs_20plus: 3, course_type: "rolling",
      quality: ["intervals", "Race-pace long runs", "hills", "yoga"],
    }),
    { planStyle: "weekly", longRunsBig: 3, courseType: "rolling", quality: ["intervals", "race_pace", "hills"] },
  );
  assertEquals(readPreferences({ course_type: "flat" }, "hilly").courseType, "hilly", "the column wins");
});

Deno.test("#104: pace math for a non-marathon goal", () => {
  const fiveK = trainingPaces(20 * 60, 5000 / MI); // 20:00 5K
  assertEquals(fiveK.race, Math.round(1200 / (5000 / MI)), "6:26/mi");
  assert(fiveK.threshold > fiveK.race, "threshold is slower than 5K pace");
  assert(fiveK.marathon > fiveK.threshold, "marathon pace is slower than threshold");
  const marathon = trainingPaces(11_700);
  assertEquals(marathon.race, marathon.marathon, "unchanged for the marathon");
});

// ── "Just finish": no target time ────────────────────────────────────────────
//
// #102's goal_type `finish` arrives with goal_time_s null, and every pace in a plan was
// derived from a goal time. The fix must not invent one (the goal row keeps null): paces get
// their own basis — current fitness, else a conservative default — and the rationale says so.

/// Best recent effort: 6 mi in 54:00 (9:00/mi), as features.riegel_current_race_s would
/// project it to `raceMi`.
const fitnessAt = (raceMi: number) => Math.round(equivalentTime(6 * 540, 6, raceMi));

/// A finish block for `d`, paced the way the handler paces it.
function finishBlock(d: DistanceKey, currentRaceS: number | null) {
  const raceMi = DISTANCES[d].meters / MI;
  const basis = paceBasis(null, raceMi, currentRaceS);
  const paces = trainingPaces(basis.seconds, raceMi);
  const start = new Date(BLOCK_START + "T00:00:00Z");
  const g = generate(modelShape(15), {
    startMonday: start, daysPerWeek: 5, longRunDay: 0, paces, wantsStrength: false,
    raceDate: RACE_16, raceName: null, distance: DISTANCES[d], prefs: DEFAULT_PREFERENCES,
    rationaleNote: basis.note,
  });
  return { basis, paces, g };
}

/// Paces a human could run, in the order physiology puts them.
function assertSanePaces(p: ReturnType<typeof trainingPaces>, label: string) {
  for (const [k, v] of Object.entries(p)) {
    assert(Number.isInteger(v) && v >= 240 && v <= 1080, `${label}: ${k} ${v}s/mi is not a human pace`);
  }
  assert(p.repetition < p.interval && p.interval < p.threshold && p.threshold < p.easy, `${label}: pace order`);
  assert(p.easy - p.marathon >= 30, `${label}: easy must be clearly slower than marathon pace`);
}

Deno.test("#104 finish: a null-time 5K paces from current fitness, a touch conservative", () => {
  const raceMi = DISTANCES["5k"].meters / MI;
  const { basis, paces, g } = finishBlock("5k", fitnessAt(raceMi));
  assertEquals(basis.source, "fitness");
  assertEquals(basis.seconds, Math.round(fitnessAt(raceMi) * FITNESS_MARGIN));
  assert(basis.seconds > fitnessAt(raceMi), "eased, never faster than the best effort says");
  assertSanePaces(paces, "5K");
  // 9:00/mi over 6 mi projects 26:53 for a 5K; 3% easier is 27:41 → 8:55/mi race pace.
  assert(paces.race > 8.5 * 60 && paces.race < 9.5 * 60, `5K race pace ${paces.race}`);
  const race = g.sessions.find((s) => s.type === "race")!;
  assertEquals(race.target_pace_sec, paces.race);
  assert(g.sessions.every((s) => s.target_pace_sec == null || Number.isFinite(s.target_pace_sec)), "no NaN paces");
  assert(g.shape.rationale.includes("No target time"), "the rationale says why these paces");
  assert(g.shape.rationale.includes(fmtClock(fitnessAt(raceMi))), "…and what fitness they came from");
});

Deno.test("#104 finish: a null-time marathon paces from current fitness", () => {
  const raceMi = DISTANCES.marathon.meters / MI;
  const { basis, paces, g } = finishBlock("marathon", fitnessAt(raceMi));
  assertEquals(basis.source, "fitness");
  assertSanePaces(paces, "marathon");
  // 9:00/mi over 6 mi projects a 4:17:48 marathon; 3% easier is 4:25:32 → 10:08/mi.
  assert(paces.race > 9.5 * 60 && paces.race < 10.75 * 60, `marathon race pace ${paces.race}`);
  assertEquals(paces.race, paces.marathon);
  assertEquals(g.sessions.find((s) => s.type === "race")!.target_pace_sec, paces.race);
  assert(g.shape.rationale.startsWith("fixture "), "the model's rationale is kept, the note appended");
});

Deno.test("#104 finish: no target and no usable runs falls back to a conservative default, and says so", () => {
  for (const d of ["5k", "marathon"] as DistanceKey[]) {
    const raceMi = DISTANCES[d].meters / MI;
    const { basis, paces, g } = finishBlock(d, null);
    assertEquals(basis.source, "default", d);
    assertEquals(basis.seconds, Math.round(equivalentTime(DEFAULT_BASIS_MARATHON_S, MARATHON_MI, raceMi)));
    assertSanePaces(paces, `${d} default`);
    assert(paces.easy >= 11 * 60, `${d}: default easy pace ${paces.easy}s/mi should be gentle`);
    assert(g.shape.rationale.includes("conservative default"), `${d}: rationale names the fallback`);
    assert(g.shape.rationale.includes("no recent runs"), `${d}: …and why`);
  }
});

Deno.test("#104 finish: a target time is still the basis, and the rationale is untouched", () => {
  const raceMi = DISTANCES.marathon.meters / MI;
  const basis = paceBasis(11_700, raceMi, fitnessAt(raceMi));
  assertEquals(basis, { seconds: 11_700, source: "goal", note: null }, "fitness never overrides a target");
  const p = block();
  assertEquals(p.shape.rationale, "fixture");
});

Deno.test("fmtClock reads like a finish time", () => {
  assertEquals(fmtClock(11_700), "3:15:00");
  assertEquals(fmtClock(1_565), "26:05");
  assertEquals(fmtClock(3_600), "1:00:00");
});
