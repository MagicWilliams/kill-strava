// What goal /plan is building for — resolved from the request and the athlete's current goal.
//
// Pure, for the same reason generator.ts is: this decides which race a plan is shaped for,
// and the failure is silent (a 5K athlete quietly handed a marathon block). index.ts does
// the reads and writes; this file decides.
//
// Two facts shape it:
//
// 1. Migration 0013 (#102) adds goals.distance_m, course_type, goal_type, started_week and
//    preferences — and it may not be applied when this deploys. Every read here tolerates
//    the columns being absent or null, and every write has a legacy shape that names none
//    of them, so plan generation behaves exactly as before 0013 until 0013 exists.
//
// 2. The app regenerates a plan (ChatStore.applyPlanSettings, after a days-per-week change)
//    by sending only goal time, race name and race date. If /plan took the distance and
//    preferences from the request alone, the first settings change after a 5K intake would
//    rebuild the block as a marathon and drop every preference. So when the request names
//    the SAME race date as the active goal, whatever the request leaves out is carried over
//    from that goal. A different race date is a different race: nothing carries.

import { LEGACY_DISTANCE_LABELS, mondayOf, resolveDistance, type ResolvedDistance } from "./generator.ts";

export interface GoalFields {
  distance_m: unknown;
  distance: unknown;
  course_type: string | null;
  goal_type: string | null;
  /// 1-based block week the athlete was in when THIS goal row was written.
  started_week: number | null;
  preferences: Record<string, unknown> | null;
}

export interface ResolvedGoal {
  distance: ResolvedDistance;
  course_type: string | null;
  goal_type: string | null;
  started_week: number | null;
  preferences: Record<string, unknown> | null;
  /// True when fields were carried over from the active goal (a regeneration).
  inherited: boolean;
}

const str = (v: unknown) => typeof v === "string" && v.trim() !== "" ? v.trim() : null;
const obj = (v: unknown) =>
  v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;
const weekNo = (v: unknown) => {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isInteger(n) && n >= 1 && n <= 52 ? n : null;
};
const given = (v: unknown) => v !== undefined && v !== null;

/// `started_week` means "the block week I was in when I said so". Carried onto a new goal
/// row weeks later, it must move forward by the whole weeks that have passed, or a
/// regeneration would rewind the athlete to the week they first imported.
export function advanceStartedWeek(startedWeek: number, since: string | null | undefined, now: Date): number {
  if (!since) return startedWeek;
  const then = new Date(since);
  if (Number.isNaN(then.getTime())) return startedWeek;
  const elapsed = Math.round((mondayOf(now).getTime() - mondayOf(then).getTime()) / (7 * 86400_000));
  return startedWeek + Math.max(elapsed, 0);
}

export function resolveGoal(
  body: Record<string, unknown>,
  active: Record<string, unknown> | null,
  now: Date,
): ResolvedGoal {
  const inherit = !!active && typeof body.race_date === "string" && active.race_date === body.race_date;
  const pick = (key: string) => given(body[key]) ? body[key] : inherit ? active![key] : undefined;

  // A request that names a distance by label alone must not inherit the old goal's metres —
  // "5k" with a carried-over 42195 would resolve to a marathon.
  const bodyNamesDistance = given(body.distance) || given(body.distance_m);
  const distance = bodyNamesDistance
    ? resolveDistance(body.distance, body.distance_m)
    : resolveDistance(pick("distance"), pick("distance_m"));

  let started_week = weekNo(body.started_week);
  if (started_week === null && inherit) {
    const carried = weekNo(active!.started_week);
    started_week = carried === null ? null : advanceStartedWeek(carried, str(active!.created_at), now);
  }

  return {
    distance,
    course_type: str(pick("course_type")),
    goal_type: str(pick("goal_type")),
    started_week,
    preferences: obj(pick("preferences")),
    inherited: inherit,
  };
}

/// "Just finish" (#102 goal_type). The one goal type a plan may be built without a target
/// time for: every other type is about a time, and a missing one there is a bad request,
/// not a choice.
export function isFinishGoal(goalType: string | null | undefined): boolean {
  const t = (goalType ?? "").trim().toLowerCase().replace(/[^a-z]+/g, "_");
  return t === "finish" || t === "just_finish";
}

/// The goals row to insert. `legacy` is the pre-0013 shape: the columns that existed before
/// #102 and nothing else. A distance the old CHECK constraint rejects cannot be stored there,
/// and this says so rather than quietly writing "marathon" over a mile goal.
export function goalInsertRow(
  base: Record<string, unknown>,
  goal: ResolvedGoal,
  legacy: boolean,
): Record<string, unknown> {
  if (legacy) {
    if (!LEGACY_DISTANCE_LABELS.includes(goal.distance.label)) {
      throw new Error(`goals.distance '${goal.distance.label}' needs migration 0013 (#102)`);
    }
    return { ...base, distance: goal.distance.label };
  }
  return {
    ...base,
    distance: goal.distance.label,
    distance_m: goal.distance.meters,
    course_type: goal.course_type,
    goal_type: goal.goal_type,
    started_week: goal.started_week,
    preferences: goal.preferences,
  };
}

/// PostgREST's answer to a column that is not in the schema (PGRST204), or Postgres's own
/// (42703). Either means 0013 is not applied yet and the legacy row is the one to write.
export function isMissingColumnError(err: unknown): boolean {
  const e = obj(err);
  if (!e) return false;
  if (e.code === "PGRST204" || e.code === "42703") return true;
  const msg = typeof e.message === "string" ? e.message : "";
  return /could not find the '.*' column|column .* does not exist/i.test(msg);
}
