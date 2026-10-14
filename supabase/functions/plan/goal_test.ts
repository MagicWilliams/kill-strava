// #104 — /plan must work before AND after migration 0013, and must not forget the race.
//
// Two ways this goes wrong silently, both pinned here:
//
// 1. Deploy before 0013 (#102) is applied: an insert naming distance_m fails, plan
//    generation breaks for the only user, mid-block. The legacy row and the missing-column
//    detection are what keep today's behavior alive.
// 2. A days-per-week change regenerates the plan with only goal time, race name and race
//    date (ChatStore.applyPlanSettings). Without carry-over, a 5K athlete's first settings
//    tweak would rebuild their block as a marathon and drop every intake answer.

import { assert, assertEquals, assertThrows } from "jsr:@std/assert@^1";
import { advanceStartedWeek, goalInsertRow, isFinishGoal, isMissingColumnError, requiresTargetTime, resolveGoal } from "./goal.ts";

const NOW = new Date("2026-10-14T15:00:00Z"); // a Wednesday
const BODY = { goal_time_s: 1200, race_name: "Turkey Trot", race_date: "2026-11-26" };

/// What `select("*")` returns for an active goal after 0013, written two weeks before NOW.
const ACTIVE_5K = {
  id: "g1", race_date: "2026-11-26", distance: "5k", distance_m: 5000,
  course_type: "rolling", goal_type: "pr", started_week: 3,
  preferences: { v: 1, plan_style: "weekly", quality: ["intervals"] },
  created_at: "2026-09-30T09:00:00Z",
};

Deno.test("#104: a request with no intake fields is a marathon, exactly as before", () => {
  const g = resolveGoal({ ...BODY }, null, NOW);
  assertEquals(g.distance.label, "marathon");
  assertEquals(g.distance.meters, 42195);
  assertEquals([g.course_type, g.goal_type, g.started_week, g.preferences], [null, null, null, null]);
  assertEquals(g.inherited, false);
});

Deno.test("#104: intake fields in the request shape the goal", () => {
  const g = resolveGoal({
    ...BODY, distance: "1mi", distance_m: 1609, course_type: "flat", goal_type: "time",
    started_week: 5, preferences: { plan_style: "none" },
  }, null, NOW);
  assertEquals(g.distance.label, "1mi");
  assertEquals(g.course_type, "flat");
  assertEquals(g.started_week, 5);
  assertEquals(g.preferences, { plan_style: "none" });
});

Deno.test("#104: regenerating the same race carries the intake over (settings change)", () => {
  const g = resolveGoal({ ...BODY }, ACTIVE_5K, NOW);
  assert(g.inherited);
  assertEquals(g.distance.label, "5k", "not silently rebuilt as a marathon");
  assertEquals(g.distance.meters, 5000);
  assertEquals(g.course_type, "rolling");
  assertEquals(g.goal_type, "pr");
  assertEquals(g.preferences, ACTIVE_5K.preferences);
  assertEquals(g.started_week, 5, "week 3 two weeks ago is week 5 now");
});

Deno.test("#104: a different race date is a different race — nothing carries", () => {
  const g = resolveGoal({ ...BODY, race_date: "2027-04-20" }, ACTIVE_5K, NOW);
  assertEquals(g.inherited, false);
  assertEquals(g.distance.label, "marathon");
  assertEquals(g.preferences, null);
  assertEquals(g.started_week, null);
});

Deno.test("#104: the request outranks the carried-over goal, field by field", () => {
  const g = resolveGoal({ ...BODY, distance: "10k", preferences: { plan_style: "full" } }, ACTIVE_5K, NOW);
  // "10k" by label must not pick up the old goal's 5000 m and resolve back to a 5K.
  assertEquals(g.distance.label, "10k");
  assertEquals(g.distance.meters, 10000);
  assertEquals(g.preferences, { plan_style: "full" });
  assertEquals(g.course_type, "rolling", "unspecified fields still carry");
});

Deno.test("#104: a pre-0013 active goal (no new keys) carries nothing it doesn't have", () => {
  const legacy = { id: "g0", race_date: "2026-11-26", distance: "marathon", created_at: "2026-07-10T00:00:00Z" };
  const g = resolveGoal({ ...BODY }, legacy, NOW);
  assertEquals(g.distance.label, "marathon");
  assertEquals([g.course_type, g.started_week, g.preferences], [null, null, null]);
});

Deno.test("#104: started_week advances by whole weeks, never backwards", () => {
  assertEquals(advanceStartedWeek(9, "2026-10-12T08:00:00Z", NOW), 9, "same week");
  assertEquals(advanceStartedWeek(9, "2026-10-11T23:00:00Z", NOW), 10, "Sunday → Wednesday crosses a week");
  assertEquals(advanceStartedWeek(9, "2026-12-01T00:00:00Z", NOW), 9, "a future timestamp doesn't rewind");
  assertEquals(advanceStartedWeek(9, null, NOW), 9);
  assertEquals(advanceStartedWeek(9, "garbage", NOW), 9);
});

Deno.test("#104: nonsense started_week is ignored, not trusted", () => {
  for (const bad of [0, -2, 3.5, 60, "nine", null]) {
    assertEquals(resolveGoal({ ...BODY, started_week: bad }, null, NOW).started_week, null, String(bad));
  }
});

// ── Writing the row ──────────────────────────────────────────────────────────

const BASE = { user_id: "u", race_name: "Turkey Trot", race_date: "2026-11-26", is_active: true };
const NEW_COLUMNS = ["distance_m", "course_type", "goal_type", "started_week", "preferences"];

Deno.test("#104: after 0013 the goal row records every intake field", () => {
  const row = goalInsertRow(BASE, resolveGoal({ ...BODY, distance: "5k", course_type: "hilly" }, null, NOW), false);
  for (const c of NEW_COLUMNS) assert(c in row, `missing ${c}`);
  assertEquals(row.distance, "5k");
  assertEquals(row.distance_m, 5000);
  assertEquals(row.course_type, "hilly");
});

Deno.test("#104: before 0013 the legacy row names no column the old schema lacks", () => {
  const row = goalInsertRow(BASE, resolveGoal({ ...BODY, distance: "half", course_type: "hilly" }, null, NOW), true);
  for (const c of NEW_COLUMNS) assert(!(c in row), `legacy row names ${c}`);
  assertEquals(row, { ...BASE, distance: "half" });
  // The default request — every request today — still writes exactly what it always did.
  assertEquals(goalInsertRow(BASE, resolveGoal({ ...BODY }, null, NOW), true).distance, "marathon");
});

Deno.test("#104: a mile goal refuses the legacy row rather than being saved as a marathon", () => {
  const mile = resolveGoal({ ...BODY, distance: "1mi" }, null, NOW);
  assertThrows(() => goalInsertRow(BASE, mile, true), Error, "0013");
});

Deno.test("#104: only a missing-column error triggers the legacy retry", () => {
  assert(isMissingColumnError({
    code: "PGRST204", message: "Could not find the 'distance_m' column of 'goals' in the schema cache",
  }));
  assert(isMissingColumnError({ code: "42703", message: 'column "distance_m" of relation "goals" does not exist' }));
  assert(isMissingColumnError({ message: "Could not find the 'preferences' column of 'goals' in the schema cache" }));
  assert(!isMissingColumnError({ code: "23514", message: "violates check constraint goals_distance_check" }));
  assert(!isMissingColumnError({ code: "42501", message: "new row violates row-level security policy" }));
  assert(!isMissingColumnError(null));
});

// ── "Just finish" ────────────────────────────────────────────────────────────

Deno.test("#104 finish: only a finish goal may come without a target time", () => {
  for (const t of ["finish", "Finish", "just_finish", "just finish"]) assert(isFinishGoal(t), t);
  for (const t of ["time", "pr", "not_sure", "", null, undefined]) assert(!isFinishGoal(t), String(t));
  // Carried over on a same-race regeneration like every other intake field.
  const regen = resolveGoal({ ...BODY, goal_time_s: null }, { ...ACTIVE_5K, goal_type: "finish" }, NOW);
  assert(isFinishGoal(regen.goal_type));
});

Deno.test("#104 finish: the goal row stores no invented time, before or after 0013", () => {
  const goal = resolveGoal({ ...BODY, goal_time_s: null, goal_type: "finish", distance: "marathon" }, null, NOW);
  const base = { ...BASE, goal_time_seconds: null };
  assertEquals(goalInsertRow(base, goal, false).goal_time_seconds, null);
  assertEquals(goalInsertRow(base, goal, false).goal_type, "finish");
  assertEquals(goalInsertRow(base, goal, true).goal_time_seconds, null);
});

Deno.test("only a time goal (or an untyped legacy goal) requires a target time", () => {
  for (const t of ["time", "Time", "", null, undefined]) assert(requiresTargetTime(t), String(t));
  // 2026-10-14: an "unsure" intake right after Chicago could never be confirmed.
  for (const t of ["finish", "just finish", "pr", "unsure", "Not sure"]) assert(!requiresTargetTime(t), String(t));
});
