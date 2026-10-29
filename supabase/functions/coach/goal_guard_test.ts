// #239 — a "pr" or "unsure" goal time comes from the app's suggested_goal, or from the athlete.
//
// The number this guards is the pace basis for every training pace in a block. What these pin:
// a model-invented target is turned back, every allowed number gets through, and a build
// installed before #239 (which sends no suggested_goal) sees no guard at all.

import { assert, assertEquals } from "jsr:@std/assert@^1";
import { DISTANCES } from "../plan/generator.ts";
import {
  DISTANCE_METERS,
  formatFinish,
  goalRejections,
  goalTimeRejection,
  readSuggestedGoal,
  timesIn,
} from "./goal_guard.ts";

// 3:30:00 projection, 12 weeks out: SuggestedGoal.swift's target and ±2% range.
const SUGGESTED = {
  target_s: 12222,
  range_s: [11978, 12466],
  distance_m: 42195,
  race_date: "2027-01-24",
  basis: "Current projection 3:30:00 for this race…",
};

const prIntake = { goal_type: "pr", distance: "marathon", distance_m: 42195, race_date: "2027-01-24" };
const ctx = (extra: Record<string, unknown> = {}) => ({ suggested_goal: SUGGESTED, intake: prIntake, ...extra });
const plan = (goal_time_s: unknown, extra: Record<string, unknown> = {}) => ({
  race_date: "2027-01-24",
  distance: "marathon",
  goal_type: "pr",
  goal_time_s,
  summary: "Build my plan",
  ...extra,
});

Deno.test("#239: an invented target outside the range is rejected, and the error names what is allowed", () => {
  const why = goalTimeRejection(plan(11100), ctx(), []); // 3:05:00, nowhere near the data
  assert(why !== null);
  assert(why.includes("3:05:00"), why);
  assert(why.includes("3:23:42"), "names the target");
  assert(why.includes("3:19:38") && why.includes("3:27:46"), "names the range");
  assert(why.includes("omit goal_time_s"), "says how to recover without a number");
});

Deno.test("#239: the target, both ends of the range, and anything between them pass", () => {
  for (const t of [12222, 11978, 12466, 12300 /* 3:25:00 */]) {
    assertEquals(goalTimeRejection(plan(t), ctx(), []), null, `${t}`);
  }
  assert(goalTimeRejection(plan(11977), ctx(), []) !== null, "one second past the fast end");
  assert(goalTimeRejection(plan(12467), ctx(), []) !== null, "one second past the slow end");
});

Deno.test("#239: the athlete's own stated time passes, wherever it sits", () => {
  // Said in chat, as h:mm or h:mm:ss.
  assertEquals(goalTimeRejection(plan(11700), ctx(), ["Honestly I want to go for 3:15."]), null);
  assertEquals(goalTimeRejection(plan(11700), ctx(), ["3:15:00 or bust"]), null);
  // Said on the intake form.
  assertEquals(
    goalTimeRejection(plan(11700), ctx({ intake: { ...prIntake, stated_goal_time: "3:15:00" } }), []),
    null,
  );
  // A different time from the one they said is still the coach's invention.
  assert(goalTimeRejection(plan(11400), ctx(), ["I want to go for 3:15."]) !== null);
});

Deno.test("#239: no suggested_goal means no guard: installed builds, and no projection", () => {
  for (const context of [undefined, null, {}, { intake: prIntake }, { suggested_goal: null }]) {
    assertEquals(goalTimeRejection(plan(11100), context, []), null, JSON.stringify(context));
  }
});

Deno.test("#239: a malformed suggested_goal reads as missing, not as a range to fail", () => {
  for (const bad of [
    { target_s: 12222 },
    { target_s: 12222, range_s: [12466] },
    { target_s: 12222, range_s: [12466, 11978] },
    { target_s: "x", range_s: [11978, 12466] },
    { target_s: 12222, range_s: [0, 12466] },
  ]) {
    assertEquals(readSuggestedGoal({ suggested_goal: bad }), null, JSON.stringify(bad));
    assertEquals(goalTimeRejection(plan(11100), { suggested_goal: bad, intake: prIntake }, []), null);
  }
});

Deno.test("#239: time and finish goals are the athlete's, and are not guarded", () => {
  const timeIntake = { ...prIntake, goal_type: "time" };
  assertEquals(goalTimeRejection(plan(11100, { goal_type: "time" }), ctx({ intake: timeIntake }), []), null);
  // No intake: the card's own type decides. An ordinary chat time goal arrives with none.
  assertEquals(goalTimeRejection(plan(11100, { goal_type: undefined }), { suggested_goal: SUGGESTED }, []), null);
  assertEquals(goalTimeRejection(plan(11100, { goal_type: "time" }), { suggested_goal: SUGGESTED }, []), null);
  // But a chat "pr" card with no intake is guarded on its own type.
  assert(goalTimeRejection(plan(11100), { suggested_goal: SUGGESTED }, []) !== null);
});

Deno.test("#239: a pr intake cannot slip a number past the guard by calling the card a time goal", () => {
  // The app saves the intake's goal_type, not the card's (PlanRequest.fromIntake).
  assert(goalTimeRejection(plan(11100, { goal_type: "time" }), ctx(), []) !== null);
  assert(goalTimeRejection(plan(11100, { goal_type: undefined }), ctx(), []) !== null);
});

Deno.test("#239: no goal_time_s is always allowed: that is the no-target path", () => {
  assertEquals(goalTimeRejection(plan(undefined), ctx(), []), null);
  assertEquals(goalTimeRejection(plan(null), ctx(), []), null);
});

Deno.test("#239: the range is held to its own race only", () => {
  // Omitted distance: the race already under discussion, so the range applies.
  assert(goalTimeRejection(plan(11100, { distance: undefined }), ctx(), []) !== null);
  assertEquals(goalTimeRejection(plan(12222, { distance: undefined }), ctx(), []), null);
  // The intake's half and the plan engine's half differ by a metre; still the same race.
  const half = { ...SUGGESTED, distance_m: 21098, target_s: 5900, range_s: [5782, 6018] };
  assertEquals(goalTimeRejection(plan(5900, { distance: "half" }), ctx({ suggested_goal: half }), []), null);

  // A different distance or date has no suggestion: only the athlete's time passes, so a
  // marathon-shaped range is never used to approve (or refuse) a half time.
  const halfCard = plan(12222, { distance: "half" });
  const why = goalTimeRejection(halfCard, ctx(), []);
  assert(why !== null && why.includes("different race"), why ?? "");
  assert(goalTimeRejection(plan(12222, { race_date: "2027-03-01" }), ctx(), []) !== null);
  assertEquals(goalTimeRejection(plan(5700, { distance: "half" }), ctx(), ["Let's do the half, 1:35."]), null);
});

Deno.test("#239: goalRejections returns only the create_plan blocks that fail, by tool_use id", () => {
  const blocks = [
    { type: "text", text: "Here is the plan." },
    { type: "tool_use", id: "a", name: "create_plan", input: plan(11100) },
    { type: "tool_use", id: "b", name: "create_plan", input: plan(12222) },
    { type: "tool_use", id: "c", name: "remember", input: { goal_time_s: 1, fact: "x" } },
  ];
  const rejected = goalRejections(blocks, ctx(), []);
  assertEquals([...rejected.keys()], ["a"]);
});

Deno.test("#239: times are read from the athlete's words as h:mm:ss, h:mm and m:ss", () => {
  assert(timesIn("sub 3:15:00").has(11700));
  assert(timesIn("maybe 3:15?").has(11700));
  assert(timesIn("19:30 for the 5K").has(1170));
  assertEquals(timesIn("12:75").size, 0, "not a time");
  assertEquals(timesIn("sub-3, under 20 minutes").size, 0, "no colon, not read");
  assertEquals([...timesIn("3:15:00")], [11700], "the tail of h:mm:ss is not a second time");
});

Deno.test("#239: formatFinish writes times the way the app does", () => {
  assertEquals(formatFinish(12222), "3:23:42");
  assertEquals(formatFinish(1164), "19:24");
  assertEquals(formatFinish(3600), "1:00:00");
});

Deno.test("#239: the guard's distance table is the plan engine's", () => {
  assertEquals(
    DISTANCE_METERS,
    Object.fromEntries(Object.entries(DISTANCES).map(([k, p]) => [k, p.meters])),
  );
});
