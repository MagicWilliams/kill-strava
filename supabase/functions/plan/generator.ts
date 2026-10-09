// Tempo plan generator — the deterministic half of /plan.
//
// Split out of index.ts (#63) for one reason: it is pure, and pure code can be pinned by a
// test. The week arithmetic here decides whether the athlete's plan actually reaches the
// race it was built for, and that is not a thing to verify by reading. index.ts keeps the
// HTTP handler, the Supabase reads and the Claude call; everything below is arithmetic.

export const MARATHON_MI = 26.2188;

export const MI = 1609.34;

// ── Pace math (port of ios/Tempo/Engine/TrainingPaces.swift) ─────────────────
export function equivalentTime(t1: number, d1: number, d2: number): number {
  return t1 * Math.pow(d2 / d1, 1.06);
}
export function trainingPaces(goalSeconds: number) {
  const marathonMi = 26.2188;
  const tenMile = equivalentTime(goalSeconds, marathonMi, 10.0);
  const threshold = tenMile / 10.0;
  const marathon = equivalentTime(goalSeconds, marathonMi, marathonMi) / marathonMi;
  return {
    easy: Math.round(threshold + 75),
    marathon: Math.round(marathon),
    threshold: Math.round(threshold),
    interval: Math.round(threshold - 20),
    repetition: Math.round(threshold - 40),
  };
}
export function fmtPace(sec: number): string {
  return `${Math.floor(sec / 60)}:${String(Math.round(sec) % 60).padStart(2, "0")}`;
}

export function mondayOf(d: Date): Date {
  const x = new Date(d);
  const day = (x.getUTCDay() + 6) % 7; // 0 = Monday
  x.setUTCDate(x.getUTCDate() - day);
  x.setUTCHours(0, 0, 0, 0);
  return x;
}

/// Where race day falls, in plan-week coordinates.
///
/// Plan weeks are Monday-based and counted from `startMonday`, so race day's week index is
/// the number of whole weeks between the two, and its day offset is race day's Monday-based
/// weekday. `raceDate` is read at noon UTC for the same reason the handler reads it that
/// way: a bare date parsed at midnight sits one timezone step away from landing on the
/// previous day.
export function racePlacement(startMonday: Date, raceDate: string): { weekIndex: number; dayOffset: number } {
  const raceDay = new Date(raceDate + "T12:00:00Z");
  const weekIndex = Math.floor((raceDay.getTime() - startMonday.getTime()) / (7 * 86400_000));
  return { weekIndex, dayOffset: (raceDay.getUTCDay() + 6) % 7 };
}

/// Calendar date of a session from its plan-week coordinates. Shared with the writer in
/// index.ts so a test asserts the same arithmetic that reaches the database, not a copy of it.
export function sessionDate(startMonday: Date, weekIndex: number, dayOffset: number): string {
  const d = new Date(startMonday);
  d.setUTCDate(d.getUTCDate() + weekIndex * 7 + dayOffset);
  return d.toISOString().slice(0, 10);
}

// ── Generator (deterministic) ─────────────────────────────────────────────────
export interface Shape {
  archetype: string;
  rationale: string;
  phases: { name: string; weeks: number; focus: string; quality_per_week: number }[];
  start_weekly_mi: number;
  peak_weekly_mi: number;
  long_run_start_mi: number;
  long_run_peak_mi: number;
}

function qualitySession(phase: string, paces: ReturnType<typeof trainingPaces>, weekInPhase: number) {
  const t = fmtPace(paces.threshold);
  const i = fmtPace(paces.interval);
  const mp = fmtPace(paces.marathon);
  switch (phase) {
    case "base":
      return weekInPhase % 2 === 0
        ? { type: "tempo", title: "Light tempo", detail: `15–20 min @ ${t} inside an easy run`, pace: paces.threshold }
        : { type: "interval", title: "Strides", detail: `8×20s fast, full recovery, inside an easy run`, pace: paces.repetition };
    case "build":
      return weekInPhase % 2 === 0
        ? { type: "threshold", title: "Threshold repeats", detail: `3×1 mi @ ${t} w/ 2:00 jog`, pace: paces.threshold }
        : { type: "tempo", title: "Steady tempo", detail: `2×15 min @ ${t} w/ 3:00 jog`, pace: paces.threshold };
    case "peak":
      return weekInPhase % 2 === 0
        ? { type: "tempo", title: "Marathon-pace blocks", detail: `2×3 mi @ ${mp} w/ 1 mi easy`, pace: paces.marathon }
        : { type: "interval", title: "VO₂ intervals", detail: `5×1000m @ ${i} w/ 2:30 jog`, pace: paces.interval };
    default: // taper
      return { type: "tempo", title: "Race-pace touch", detail: `4×half-mile @ ${mp}, feel springy`, pace: paces.marathon };
  }
}

export function generate(shape: Shape, opts: {
  startMonday: Date; daysPerWeek: number; longRunDay: number; paces: ReturnType<typeof trainingPaces>;
  wantsStrength: boolean; raceDate: string; raceName?: string | null;
}) {
  const totalWeeks = shape.phases.reduce((n, p) => n + p.weeks, 0);
  const buildWeeks = shape.phases.filter((p) => p.name !== "taper").reduce((n, p) => n + p.weeks, 0);
  const weeks: { index: number; phase: string; focus: string; target: number; quality: number }[] = [];
  let w = 0;
  for (const phase of shape.phases) {
    for (let k = 0; k < phase.weeks; k++) {
      let target: number;
      if (phase.name === "taper") {
        const taperIdx = w - buildWeeks;
        target = shape.peak_weekly_mi * [0.72, 0.55, 0.4][Math.min(taperIdx, 2)];
      } else {
        const f = buildWeeks <= 1 ? 1 : w / (buildWeeks - 1);
        target = shape.start_weekly_mi + (shape.peak_weekly_mi - shape.start_weekly_mi) * f;
        if ((w + 1) % 4 === 0) target *= 0.85; // step-back week
      }
      weeks.push({ index: w, phase: phase.name, focus: phase.focus, target: +target.toFixed(1), quality: phase.quality_per_week });
      w++;
    }
  }

  // Sessions per week. Weekday offsets are relative to the plan-week Monday (0=Mon…6=Sun).
  const longOffset = (opts.longRunDay + 6) % 7; // convert 0=Sun…6=Sat → 0=Mon…6=Sun
  const qualityOffsets = [1, 3].filter((o) => o !== longOffset); // Tue/Thu
  const easyPreference = [0, 2, 4, 5, 1, 3].filter((o) => o !== longOffset);

  const sessions: {
    week_index: number; day_offset: number; type: string; title: string;
    target_distance_m: number | null; target_pace_sec: number | null; structure: unknown;
  }[] = [];

  for (const wk of weeks) {
    const f = buildWeeks <= 1 ? 1 : Math.min(wk.index / (buildWeeks - 1), 1);
    let longMi = shape.long_run_start_mi + (shape.long_run_peak_mi - shape.long_run_start_mi) * f;
    if (wk.phase === "taper") longMi = Math.min(longMi, wk.target * 0.4);
    longMi = Math.min(longMi, wk.target * 0.4);

    const qualityCount = Math.min(wk.quality, qualityOffsets.length);
    const qualityMi = 5.5; // incl. warmup/cooldown
    const easyCount = Math.max(opts.daysPerWeek - 1 - qualityCount, 0);
    const easyTotal = Math.max(wk.target - longMi - qualityCount * qualityMi, easyCount * 2.5);
    const easyMi = easyCount > 0 ? easyTotal / easyCount : 0;

    sessions.push({
      week_index: wk.index, day_offset: longOffset, type: "long", title: "Long run",
      target_distance_m: Math.round(longMi * MI), target_pace_sec: opts.paces.easy,
      structure: { detail: `${longMi.toFixed(1)} mi steady @ ~${fmtPace(opts.paces.easy)}, conversational` },
    });
    for (let q = 0; q < qualityCount; q++) {
      const s = qualitySession(wk.phase, opts.paces, wk.index);
      sessions.push({
        week_index: wk.index, day_offset: qualityOffsets[q], type: s.type, title: s.title,
        target_distance_m: Math.round(qualityMi * MI), target_pace_sec: s.pace,
        structure: { detail: s.detail },
      });
    }
    let placed = 0;
    const usedOffsets = new Set<number>([longOffset, ...qualityOffsets.slice(0, qualityCount)]);
    for (const off of easyPreference) {
      if (placed >= easyCount) break;
      if (usedOffsets.has(off)) continue;
      usedOffsets.add(off);
      sessions.push({
        week_index: wk.index, day_offset: off, type: "easy", title: "Easy run",
        target_distance_m: Math.round(easyMi * MI), target_pace_sec: opts.paces.easy,
        structure: { detail: `${easyMi.toFixed(1)} mi relaxed @ ~${fmtPace(opts.paces.easy)}` },
      });
      placed++;
    }
    // Prescribed strength (athlete opted in): lands on a non-running day,
    // dialed back during taper.
    if (opts.wantsStrength && wk.phase !== "taper") {
      const free = [1, 4, 2, 5, 0, 3, 6].find((o) => !usedOffsets.has(o));
      if (free !== undefined) {
        sessions.push({
          week_index: wk.index, day_offset: free, type: "cross", title: "Strength",
          target_distance_m: null, target_pace_sec: null,
          structure: { detail: "30–40 min: squats, lunges, calf raises, hips, core — heavy enough to matter, light enough to run tomorrow." },
        });
      }
    }
  }
  // ── Race week ───────────────────────────────────────────────────────────────
  // The shape covers TRAINING weeks only. propose_plan_shape says so in as many words
  // ("taper included, race week excluded") and its phase enum has no `race` member, so
  // appending race week was always the generator's job — and until #63 nothing did it.
  // A 13-week shape became a 13-week plan, which ends on the Sunday BEFORE the race:
  // David's Chicago block tapered to 2026-10-04 for an 11 Oct marathon and contained no
  // race-day session at all. The one week of a block with the least margin for being
  // wrong was the one week the app had nothing for.
  //
  // What race week deliberately does NOT contain: shakeout runs, strides, rest days.
  // How the six days before a marathon should be prescribed is a coaching call, not
  // arithmetic, and this generator does not invent coaching. The race is the session.
  const race = racePlacement(opts.startMonday, opts.raceDate);
  weeks.push({
    index: race.weekIndex,
    phase: "taper",   // plan_weeks.phase CHECK admits base|build|peak|taper only
    focus: "Race week — the training is done. Everything this week serves race day.",
    target: +MARATHON_MI.toFixed(1),
    quality: 0,
  });
  sessions.push({
    week_index: race.weekIndex, day_offset: race.dayOffset, type: "race",
    title: opts.raceName ?? "Race day",
    target_distance_m: Math.round(MARATHON_MI * MI), target_pace_sec: opts.paces.marathon,
    structure: { detail: `${MARATHON_MI.toFixed(1)} mi @ ${fmtPace(opts.paces.marathon)} — goal pace.` },
  });

  return { weeks, sessions, totalWeeks: totalWeeks + 1, raceWeekIndex: race.weekIndex };
}
