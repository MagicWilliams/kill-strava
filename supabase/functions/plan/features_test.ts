// #205 — /plan stored a projection it made up when no run qualified.
//
// The fallback was `goal_time_s * 1.06`, "a modest miss of goal". An athlete with a 3:30
// target and nothing longer than 2.5 mi in eight weeks got 3:42:36 written to
// plans.projected_finish_s, and Progress showed it as his projected finish — a number read
// off his own goal, not off any run. The app's "No qualifying effort" empty state never got
// a chance to appear. Pinned here: no qualifying run means null, whatever the goal says.

import { assertEquals, assertNotEquals } from "jsr:@std/assert@^1";
import { extractFeatures, projectedFinishS, type RunRow } from "./features.ts";
import { MARATHON_MI, MI, paceBasis } from "./generator.ts";

const NOW = new Date("2026-10-15T12:00:00Z");
const GOAL_3_30 = 3.5 * 3600;
const FIVE_K_MI = 5000 / MI;

const daysAgo = (d: number) => new Date(NOW.getTime() - d * 86400_000).toISOString();
const run = (d: number, miles: number, paceS: number): RunRow => ({
  start_time: daysAgo(d), distance_m: miles * MI, duration_s: miles * paceS, avg_hr: null,
});

Deno.test("#205: no qualifying run with a goal time set → projected is null, not goal × 1.06", () => {
  const runs = [
    run(3, 2.0, 540), run(6, 2.4, 530), run(10, 1.5, 600), // short, recent: don't qualify
    run(70, 14, 540), // long, but older than the 8-week window
  ];
  const features = extractFeatures(runs, MARATHON_MI, NOW);
  assertEquals(features.best_effort, null);
  assertEquals(features.riegel_current_race_s, null);

  // The goal is set, and it is what the paces come from — but it is not a projection.
  assertEquals(paceBasis(GOAL_3_30, MARATHON_MI, features.riegel_current_race_s).source, "goal");
  assertEquals(projectedFinishS(features), null);
  assertNotEquals(projectedFinishS(features), Math.round(GOAL_3_30 * 1.06));
});

Deno.test("#205: no runs at all → projected is null", () => {
  assertEquals(projectedFinishS(extractFeatures([], MARATHON_MI, NOW)), null);
});

Deno.test("#205: a qualifying run still projects — Riegel from the run, at the race distance", () => {
  const runs = [run(5, 2.0, 480), run(12, 6.0, 500)]; // the 6-miler at 8:20/mi qualifies
  const features = extractFeatures(runs, MARATHON_MI, NOW);
  const expected = Math.round(6.0 * 500 * Math.pow(MARATHON_MI / 6.0, 1.06));
  assertEquals(projectedFinishS(features), expected);
  assertEquals(projectedFinishS(features), features.riegel_current_race_s);
});

// #227 — a watch left recording for 10h24m over 8.1 mi (77:00/mi) was the only run in the
// window, and it set a 36-hour projection and would have set the plan's paces.
Deno.test("#227: a watch left running is not an effort → no projection, paces from the goal", () => {
  const leftRunning: RunRow = { start_time: daysAgo(9), distance_m: 13047, duration_s: 37459, avg_hr: null };
  const features = extractFeatures([leftRunning], MARATHON_MI, NOW);
  assertEquals(features.best_effort, null);
  assertEquals(projectedFinishS(features), null);
  assertEquals(paceBasis(GOAL_3_30, MARATHON_MI, features.riegel_current_race_s).source, "goal");
});

Deno.test("#227: the ceiling is inclusive at 20:00/mi, and a walk never outranks a real run", () => {
  assertNotEquals(extractFeatures([run(4, 3, 1200)], MARATHON_MI, NOW).best_effort, null);
  assertEquals(extractFeatures([run(4, 3, 1201)], MARATHON_MI, NOW).best_effort, null);

  const features = extractFeatures([run(2, 8, 1500), run(6, 5, 580)], FIVE_K_MI, NOW);
  assertEquals(features.riegel_current_race_s, Math.round(5 * 580 * Math.pow(FIVE_K_MI / 5, 1.06)));
});
