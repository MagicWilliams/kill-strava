// Tempo plan features — what /plan reads out of the athlete's runs, and the projection it
// stores from them.
//
// Split out of index.ts (#205) so the projection could be pinned by a test. It used to fall
// back to `goal_time_s * 1.06` when no run qualified: a number measured from nothing, stored
// in plans.projected_finish_s and shown on Progress as if it were a reading of fitness. The
// app already has an honest empty state for "no qualifying effort"; the fallback hid it.

import { equivalentTime, fmtPace, MI, mondayOf } from "./generator.ts";

export interface RunRow {
  start_time: string;
  distance_m: number;
  duration_s: number;
  avg_hr: number | null;
}

/// The shortest run that counts as a sustained effort to extrapolate a race from.
export const QUALIFYING_MI = 2.5;

/// The slowest average pace (s/mi) that counts as a running effort. Slower is a walk, or a
/// watch left recording after the run: on 15 Oct 2026 an 8.1 mi workout with a 10h24m wall
/// clock (77:00/mi) was the only run in the window, and it set a 36-hour projection (#227).
/// Here it would also have set the plan's training paces. Mirrors
/// `ProjectionHistory.maxQualifyingPaceSecPerMile` in the app.
export const MAX_QUALIFYING_PACE_S = 1200;

export type Features = ReturnType<typeof extractFeatures>;

export function extractFeatures(runs: RunRow[], raceMi: number, now: Date = new Date()) {
  const weeks: Record<string, { mi: number; runs: number }> = {};
  for (const r of runs) {
    const wk = mondayOf(new Date(r.start_time)).toISOString().slice(0, 10);
    weeks[wk] ??= { mi: 0, runs: 0 };
    weeks[wk].mi += r.distance_m / MI;
    weeks[wk].runs += 1;
  }
  const lastNWeeks = (n: number) => {
    const out: { week: string; mi: number; runs: number }[] = [];
    for (let i = n - 1; i >= 0; i--) {
      const wk = new Date(mondayOf(now));
      wk.setUTCDate(wk.getUTCDate() - 7 * i);
      const key = wk.toISOString().slice(0, 10);
      out.push({ week: key, mi: +(weeks[key]?.mi ?? 0).toFixed(1), runs: weeks[key]?.runs ?? 0 });
    }
    return out;
  };
  const last12 = lastNWeeks(12);
  const last4 = last12.slice(-4);
  const prev4 = last12.slice(-8, -4);
  const avg = (a: number[]) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : 0);
  const vol4 = avg(last4.map((w) => w.mi));
  const vol4prev = avg(prev4.map((w) => w.mi));

  const eightWeeksAgo = new Date(now.getTime() - 56 * 86400_000);
  const recent = runs.filter((r) => new Date(r.start_time) >= eightWeeksAgo);
  const longestRecentMi = Math.max(0, ...recent.map((r) => r.distance_m / MI));

  // Best sustained effort (≥ 2.5 mi, no slower than 20:00/mi) in the last 8 weeks → Riegel current marathon fitness.
  let bestPace = Infinity;
  let bestMiles = 0;
  for (const r of recent) {
    const mi = r.distance_m / MI;
    if (mi >= QUALIFYING_MI) {
      const pace = r.duration_s / mi;
      if (pace > MAX_QUALIFYING_PACE_S) continue;
      if (pace < bestPace) {
        bestPace = pace;
        bestMiles = mi;
      }
    }
  }
  const currentMarathonS = bestPace < Infinity
    ? Math.round(equivalentTime(bestPace * bestMiles, bestMiles, 26.2188))
    : null;
  // Same Riegel, aimed at the race actually being run — a 5K goal projects a 5K time.
  const currentRaceS = bestPace < Infinity
    ? Math.round(equivalentTime(bestPace * bestMiles, bestMiles, raceMi))
    : null;

  return {
    weekly_last_12: last12,
    vol_4wk_avg_mi: +vol4.toFixed(1),
    vol_prev_4wk_avg_mi: +vol4prev.toFixed(1),
    consistency_weeks_with_runs_of_last_8: last12.slice(-8).filter((w) => w.runs > 0).length,
    longest_run_8wk_mi: +longestRecentMi.toFixed(1),
    best_effort: bestPace < Infinity
      ? { miles: +bestMiles.toFixed(1), pace_per_mile: fmtPace(bestPace) }
      : null,
    riegel_current_marathon: currentMarathonS
      ? `${Math.floor(currentMarathonS / 3600)}:${String(Math.floor((currentMarathonS % 3600) / 60)).padStart(2, "0")}:${String(currentMarathonS % 60).padStart(2, "0")}`
      : null,
    riegel_current_marathon_s: currentMarathonS,
    riegel_current_race_s: currentRaceS,
  };
}

/// What /plan stores as plans.projected_finish_s: Riegel from the best qualifying run, at the
/// race distance, or null.
///
/// Null is the honest answer when no run qualifies, and the goal time is deliberately not an
/// input. It used to be — `goal_time_s * 1.06`, "a modest miss of goal" — which put a number
/// on Progress that came from the athlete's own target rather than from any run. Every reader
/// of the column already handles null (Progress shows dashes, the detail screen says "No
/// qualifying effort…", the plan-is-live line drops its projection sentence).
export function projectedFinishS(features: Pick<Features, "riegel_current_race_s">): number | null {
  return features.riegel_current_race_s ?? null;
}
