// The guard on create_plan.goal_time_s for "pr" and "unsure" goals (#239, rule 3 from #207).
//
// Pure, for the same reason history.ts is: index.ts does the I/O, this decides, and the
// failure it prevents is silent. goal_time_s is the pace basis for every training pace in the
// block. Until 2026-10-29 the intake told the coach to "propose a target from the data" for
// a PR, and whatever number it wrote became the athlete's paces for months.
//
// Now the app computes the suggestion (ios/Tempo/Engine/SuggestedGoal.swift) and sends it as
// <athlete_context>.suggested_goal: {target_s, range_s: [fastest, slowest], distance_m,
// race_date, basis}. The prompt tells the coach to offer only the target, a value in the
// range, or the athlete's own time. This is the part that does not rely on the prompt: a
// create_plan that breaks the rule is turned back to the model as a tool error, so it can
// re-propose in the same turn, and is never shown to the athlete as a card.
//
// Three things it deliberately does NOT do:
// - Guard anything when suggested_goal is absent. Every build installed before #239 sends
//   none, and those must keep working exactly as before. A new build with no projection
//   sends none either, and the prompt then has the coach propose no time at all.
// - Guard "time" or "finish" goals. A stated time goal is the athlete's number to own, and
//   the coach is meant to start from it and say if it is a reach.
// - Hold a different race to this race's range. suggested_goal names its race; a create_plan
//   for any other race gets no suggestion, so only the athlete's own time passes.

/// The goal types whose target the coach is asked to propose rather than take from the athlete.
const GUARDED_GOAL_TYPES = new Set(["pr", "unsure"]);

/// Race metres by create_plan label: a copy of plan/generator.ts `DISTANCES`, held equal by
/// goal_guard_test.ts, so the coach bundle does not pull in the plan generator (distances.ts
/// does the same with the labels).
export const DISTANCE_METERS: Record<string, number> = {
  "1mi": 1609,
  "5k": 5000,
  "10k": 10000,
  "15k": 15000,
  "10mi": 16093,
  half: 21097,
  marathon: 42195,
};

export interface SuggestedGoal {
  target_s: number;
  range_s: [number, number];
  distance_m: number | null;
  race_date: string | null;
}

const num = (v: unknown): number | null => {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : null;
};

const obj = (v: unknown): Record<string, unknown> | null =>
  v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;

/// `context.suggested_goal`, or null if it is missing or malformed. Malformed reads as missing:
/// a guard built on a half-read range would reject goals for no reason the coach can fix.
export function readSuggestedGoal(context: unknown): SuggestedGoal | null {
  const sg = obj(obj(context)?.suggested_goal);
  if (!sg) return null;
  const target = num(sg.target_s);
  const range = Array.isArray(sg.range_s) ? sg.range_s.map(num) : [];
  if (target === null || range.length !== 2) return null;
  const [lo, hi] = range;
  if (lo === null || hi === null || lo <= 0 || lo > hi) return null;
  const distance = num(sg.distance_m);
  return {
    target_s: target,
    range_s: [lo, hi],
    distance_m: distance !== null && distance > 0 ? distance : null,
    race_date: typeof sg.race_date === "string" && sg.race_date !== "" ? sg.race_date : null,
  };
}

/// h:mm:ss, or m:ss under an hour: how the app writes times (`IntakeAnswers.finishTime`).
export function formatFinish(seconds: number): string {
  const s = Math.round(seconds);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(sec)}` : `${m}:${pad(sec)}`;
}

/// Every finish time, in seconds, written in `text` as h:mm:ss, h:mm or m:ss.
///
/// "3:15" could be 3 h 15 min or 3 min 15 s, and both readings go in: either is a time the
/// athlete wrote, and the one that is not a plausible finish never matches a goal_time_s.
/// Spellings without a colon ("sub-3", "under 20 minutes") are not read. The coach then
/// cannot propose that time as the athlete's until they put it as a time, which is the safe
/// way round for a number they will train on.
export function timesIn(text: string): Set<number> {
  const found = new Set<number>();
  for (const m of text.matchAll(/(?<![\d:])(\d{1,2}):(\d{2})(?::(\d{2}))?(?![\d:])/g)) {
    const a = Number(m[1]), b = Number(m[2]);
    if (b > 59) continue;
    if (m[3] !== undefined) {
      const c = Number(m[3]);
      if (c <= 59) found.add(a * 3600 + b * 60 + c);
    } else {
      found.add(a * 3600 + b * 60);
      found.add(a * 60 + b);
    }
  }
  return found;
}

/// The times the athlete has stated: the intake's stated_goal_time, and any time in their
/// own turns of this conversation.
export function statedTimes(context: unknown, athleteTurns: readonly string[]): Set<number> {
  const stated = new Set<number>();
  const fromIntake = obj(obj(context)?.intake)?.stated_goal_time;
  for (const text of [typeof fromIntake === "string" ? fromIntake : "", ...athleteTurns]) {
    for (const t of timesIn(text)) stated.add(t);
  }
  return stated;
}

/// The race distance a create_plan names, in metres, or null when it names none (then it is
/// the race already being talked about: the active goal's, or the intake's).
function plannedMeters(input: Record<string, unknown>): number | null {
  const m = num(input.distance_m);
  if (m !== null && m > 0) return m;
  return typeof input.distance === "string" ? DISTANCE_METERS[input.distance] ?? null : null;
}

/// Whether a create_plan is for the race the suggestion was computed for. Within 1% on
/// distance, because a half is 21,097 m in the plan engine and 21,098 m in the intake.
export function isSuggestedRace(input: Record<string, unknown>, sg: SuggestedGoal): boolean {
  if (sg.race_date && typeof input.race_date === "string" && input.race_date !== sg.race_date) return false;
  const meters = plannedMeters(input);
  if (meters === null || sg.distance_m === null) return true;
  return Math.abs(meters - sg.distance_m) / sg.distance_m < 0.01;
}

/// Why this create_plan must not reach the athlete, as the tool error the coach reads, or null
/// when it may.
///
/// The goal type is the intake's when there is one, not the card's: the app saves the intake's
/// goal_type whatever the card says (`PlanRequest.fromIntake`), so a "pr" intake cannot be
/// talked out of the guard by a card that calls itself a "time" goal.
export function goalTimeRejection(
  input: Record<string, unknown>,
  context: unknown,
  athleteTurns: readonly string[],
): string | null {
  const sg = readSuggestedGoal(context);
  if (!sg) return null;
  const goalTime = num(input.goal_time_s);
  if (goalTime === null) return null;

  const intakeType = obj(obj(context)?.intake)?.goal_type;
  const goalType = typeof intakeType === "string" ? intakeType : input.goal_type;
  if (typeof goalType !== "string" || !GUARDED_GOAL_TYPES.has(goalType)) return null;

  const t = Math.round(goalTime);
  if (statedTimes(context, athleteTurns).has(t)) return null;

  const [lo, hi] = sg.range_s;
  const recover =
    "No card was shown. The athlete has not seen your previous message: write your reply again from the start, and either call create_plan again with an allowed goal_time_s or omit goal_time_s. Do not mention this check.";
  if (!isSuggestedRace(input, sg)) {
    return `create_plan rejected: goal_time_s ${formatFinish(t)} has no basis. suggested_goal is for a different race (${sg.distance_m ?? "?"} m on ${sg.race_date ?? "?"}), so for a "${goalType}" goal at this race there is no suggested time: omit goal_time_s, unless the athlete stated a time themselves. ${recover}`;
  }
  if (t >= lo && t <= hi) return null;
  return `create_plan rejected: goal_time_s ${formatFinish(t)} is outside suggested_goal.range_s. For a "${goalType}" goal, goal_time_s must be suggested_goal.target_s (${formatFinish(sg.target_s)}), a value from ${formatFinish(lo)} to ${formatFinish(hi)}, or a time the athlete stated themselves. ${recover}`;
}

/// Tool-use blocks the guard turns back, by tool_use id, with the error the coach is shown.
export function goalRejections(
  blocks: ReadonlyArray<{ type: string; name?: string; id?: string; input?: Record<string, unknown> }>,
  context: unknown,
  athleteTurns: readonly string[],
): Map<string, string> {
  const rejected = new Map<string, string>();
  for (const b of blocks) {
    if (b.type !== "tool_use" || b.name !== "create_plan" || !b.id) continue;
    const why = goalTimeRejection(b.input ?? {}, context, athleteTurns);
    if (why) rejected.set(b.id, why);
  }
  return rejected;
}

/// Said in place of a card the coach could not get right on its second try.
export const HELD_BACK_PLAN =
  "I held back the plan card: the target I had does not match what your data supports. Ask me again and I'll propose one that does.";
