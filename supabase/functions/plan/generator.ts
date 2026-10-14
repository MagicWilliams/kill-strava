// Tempo plan generator — the deterministic half of /plan.
//
// Split out of index.ts (#63) for one reason: it is pure, and pure code can be pinned by a
// test. The week arithmetic here decides whether the athlete's plan actually reaches the
// race it was built for, and that is not a thing to verify by reading. index.ts keeps the
// HTTP handler, the Supabase reads and the Claude call; everything below is arithmetic.
//
// #104 widened it from "every plan is a marathon" to every distance from the mile up. What
// changes with distance — taper, long-run cap, volume band, workout mix — lives in one table
// (DISTANCES) rather than in prompt prose, because prose is a suggestion to the model and
// the table is a fact the tests can hold.

export const MARATHON_MI = 26.2188;

export const MI = 1609.34;

// ── Pace math (port of ios/Tempo/Engine/TrainingPaces.swift) ─────────────────
export function equivalentTime(t1: number, d1: number, d2: number): number {
  return t1 * Math.pow(d2 / d1, 1.06);
}
/// Training paces from a goal time over `raceMi` (default: the marathon, which is what every
/// plan was before #104). Threshold is the goal's 10-mile equivalent, as it always was; Riegel
/// is least trustworthy at the mile, so a mile goal gives the softest threshold estimate.
export function trainingPaces(goalSeconds: number, raceMi: number = MARATHON_MI) {
  const tenMile = equivalentTime(goalSeconds, raceMi, 10.0);
  const threshold = tenMile / 10.0;
  const marathon = equivalentTime(goalSeconds, raceMi, MARATHON_MI) / MARATHON_MI;
  return {
    easy: Math.round(threshold + 75),
    marathon: Math.round(marathon),
    threshold: Math.round(threshold),
    interval: Math.round(threshold - 20),
    repetition: Math.round(threshold - 40),
    /// Goal pace for the race actually being run. Equals `marathon` for a marathon goal.
    race: Math.round(goalSeconds / raceMi),
  };
}
export type Paces = ReturnType<typeof trainingPaces>;

export function fmtPace(sec: number): string {
  return `${Math.floor(sec / 60)}:${String(Math.round(sec) % 60).padStart(2, "0")}`;
}
/// A finish time: H:MM:SS from an hour up, M:SS below.
export function fmtClock(sec: number): string {
  const s = Math.round(sec);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = String(s % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${r}` : `${m}:${r}`;
}

// ── Pace basis: what the paces are derived from ───────────────────────────────
// A "just finish" goal (#102 goal_type `finish`) has no target time, and every pace in the
// plan used to be derived from one. The answer is NOT to invent a time and store it — the
// goal row keeps goal_time_seconds null, because a made-up 4:30 on the goal would then be
// read back as the athlete's ambition by the coach, the projection and the race recap.
// Instead the paces get a basis of their own, and the rationale says what it was.

/// Riegel from the best recent effort is a best-case read: the run that produced it was the
/// athlete's fastest of eight weeks, not a typical one. 3% slower keeps a finish block honest.
export const FITNESS_MARGIN = 1.03;
/// With no runs to read at all, paces start from roughly a 5-hour-marathon effort (easy
/// ≈ 12:00/mi) scaled to the race distance — slow enough to be safe for a new runner, and
/// replaced the first time the plan is regenerated with real runs on file.
export const DEFAULT_BASIS_MARATHON_S = 5 * 3600;

export interface PaceBasis {
  /// The finish time training paces are derived from — never written to the goal.
  seconds: number;
  source: "goal" | "fitness" | "default";
  /// Athlete-facing sentence for the rationale; null when the athlete gave a target.
  note: string | null;
}

/// `currentRaceS` is features.riegel_current_race_s: the best ≥ 2.5 mi effort of the last 8
/// weeks, Riegel-projected to this race distance; null when there is no such run.
export function paceBasis(goalTimeS: number | null, raceMi: number, currentRaceS: number | null): PaceBasis {
  if (goalTimeS != null && goalTimeS > 0) return { seconds: goalTimeS, source: "goal", note: null };
  if (currentRaceS != null && currentRaceS > 0) {
    const seconds = Math.round(currentRaceS * FITNESS_MARGIN);
    return {
      seconds, source: "fitness",
      note: `No target time yet. Training paces come from your current fitness — your best recent run projects about ${fmtClock(currentRaceS)} for this distance — eased a few percent to stay conservative.`,
    };
  }
  const seconds = Math.round(equivalentTime(DEFAULT_BASIS_MARATHON_S, MARATHON_MI, raceMi));
  return {
    seconds, source: "default",
    note: `No target time, and no recent runs of 2.5 mi or more to read your fitness from, so training paces start from a conservative default (easy around ${fmtPace(trainingPaces(seconds, raceMi).easy)}/mi). Run by feel for now; once a few weeks of runs are logged, rebuilding the plan will base paces on them.`,
  };
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

// ── Distance table (#104) ─────────────────────────────────────────────────────
export type DistanceKey = "1mi" | "5k" | "10k" | "15k" | "10mi" | "half" | "marathon";
export type PhaseName = "base" | "build" | "peak" | "taper";
export type QualityKind =
  | "strides" | "speed" | "vo2" | "threshold" | "tempo" | "race_pace" | "race_touch" | "hills";

/// What an athlete can pick in the intake's "workouts I'll actually do" (#102).
export type QualityCategory = "intervals" | "tempo" | "hills" | "race_pace";

const CATEGORY: Record<QualityKind, QualityCategory> = {
  strides: "intervals", speed: "intervals", vo2: "intervals",
  threshold: "tempo", tempo: "tempo",
  race_pace: "race_pace", race_touch: "race_pace",
  hills: "hills",
};

export interface DistanceProfile {
  key: DistanceKey;
  meters: number;
  /// Training weeks in the taper phase. Race week is NOT counted: generate() appends it, and
  /// it holds nothing but the race, so it is itself ~a week of taper. Against a Sunday race
  /// the reduced-load window is therefore (taperWeeks + 1) × 7 days: 0 → 7, 1 → 14, 2 → 21.
  /// The 10K/15K row's single taper week is a light trim (0.85), which is how "~10 days"
  /// fits a plan that only knows whole weeks.
  taperWeeks: number;
  /// Taper for a block under 10 training weeks — only the marathon shortens (2 → 1), which
  /// is the rule the prompt carried before this table existed.
  shortBlockTaperWeeks: number;
  /// Each taper week's volume as a fraction of peak; the last entry repeats.
  taperScale: number[];
  /// Hard ceiling on any long run, whatever the shape asks for.
  longRunCapMi: number;
  /// Typical peak weekly volume. The top is enforced (never below the athlete's own current
  /// volume — a 60-mpw runner training for a 5K is not cut to 55); the bottom is guidance to
  /// the model only, because forcing volume UP over an unsafe ramp is worse than a light block.
  peakBandMi: [number, number];
  /// Quality session distance including warm-up and cool-down.
  qualityMi: number;
  /// Workout rotation per phase. Short races lean on speed and VO₂; long races on threshold
  /// and race pace. Each week takes kinds from here in turn, one per quality slot.
  mix: Record<PhaseName, QualityKind[]>;
  /// Race-pace workout prescription; `{pace}` is replaced with goal pace.
  racePace: { type: string; title: string; detail: string };
  /// Taper sharpener; `{pace}` is goal pace.
  raceTouch: { type: string; detail: string };
  /// Peak-phase long runs finish at race pace (half and marathon only).
  raceSpecificLongRuns: boolean;
  /// What counts as a "big" long run for the intake's long_runs_20plus question: 20 mi for the
  /// marathon, 12 for the half (#102's "distance-appropriate equivalent"); null elsewhere.
  bigLongRunMi: number | null;
}

const SHORT_TOUCH = { type: "interval", detail: "4×400m @ {pace}, feel springy" };
const LONG_TOUCH = { type: "tempo", detail: "4×half-mile @ {pace}, feel springy" };
const ENDURANCE_MIX: Record<PhaseName, QualityKind[]> = {
  base: ["tempo", "strides"],
  build: ["threshold", "tempo"],
  peak: ["race_pace", "threshold"],
  taper: ["race_touch"],
};

export const DISTANCES: Record<DistanceKey, DistanceProfile> = {
  "1mi": {
    key: "1mi", meters: 1609,
    taperWeeks: 0, shortBlockTaperWeeks: 0, taperScale: [0.8],
    longRunCapMi: 9, peakBandMi: [15, 45], qualityMi: 4.5,
    mix: { base: ["strides", "tempo"], build: ["speed", "vo2"], peak: ["race_pace", "speed"], taper: ["race_touch"] },
    racePace: { type: "interval", title: "Mile-pace 400s", detail: "6×400m @ {pace} w/ 400m walk-jog" },
    raceTouch: SHORT_TOUCH, raceSpecificLongRuns: false, bigLongRunMi: null,
  },
  "5k": {
    key: "5k", meters: 5000,
    taperWeeks: 0, shortBlockTaperWeeks: 0, taperScale: [0.8],
    longRunCapMi: 10, peakBandMi: [20, 55], qualityMi: 5,
    mix: { base: ["tempo", "strides"], build: ["vo2", "threshold"], peak: ["race_pace", "vo2"], taper: ["race_touch"] },
    racePace: { type: "interval", title: "5K-pace kilometres", detail: "5×1000m @ {pace} w/ 400m jog" },
    raceTouch: SHORT_TOUCH, raceSpecificLongRuns: false, bigLongRunMi: null,
  },
  "10k": {
    key: "10k", meters: 10000,
    taperWeeks: 1, shortBlockTaperWeeks: 1, taperScale: [0.85],
    longRunCapMi: 12, peakBandMi: [25, 60], qualityMi: 5.5,
    mix: { base: ["tempo", "strides"], build: ["threshold", "vo2"], peak: ["race_pace", "threshold"], taper: ["race_touch"] },
    racePace: { type: "interval", title: "10K-pace miles", detail: "4×1 mi @ {pace} w/ 400m jog" },
    raceTouch: SHORT_TOUCH, raceSpecificLongRuns: false, bigLongRunMi: null,
  },
  "15k": {
    key: "15k", meters: 15000,
    taperWeeks: 1, shortBlockTaperWeeks: 1, taperScale: [0.85],
    longRunCapMi: 13, peakBandMi: [28, 65], qualityMi: 5.5,
    mix: ENDURANCE_MIX,
    racePace: { type: "tempo", title: "Race-pace repeats", detail: "3×2 mi @ {pace} w/ 3:00 jog" },
    raceTouch: LONG_TOUCH, raceSpecificLongRuns: false, bigLongRunMi: null,
  },
  "10mi": {
    key: "10mi", meters: 16093,
    taperWeeks: 1, shortBlockTaperWeeks: 1, taperScale: [0.75],
    longRunCapMi: 14, peakBandMi: [30, 65], qualityMi: 5.5,
    mix: ENDURANCE_MIX,
    racePace: { type: "tempo", title: "Race-pace repeats", detail: "3×2 mi @ {pace} w/ 3:00 jog" },
    raceTouch: LONG_TOUCH, raceSpecificLongRuns: false, bigLongRunMi: null,
  },
  half: {
    key: "half", meters: 21097,
    taperWeeks: 1, shortBlockTaperWeeks: 1, taperScale: [0.7],
    longRunCapMi: 15, peakBandMi: [30, 70], qualityMi: 5.5,
    mix: ENDURANCE_MIX,
    racePace: { type: "tempo", title: "Half-pace blocks", detail: "3×2 mi @ {pace} w/ 3:00 jog" },
    raceTouch: LONG_TOUCH, raceSpecificLongRuns: true, bigLongRunMi: 12,
  },
  marathon: {
    key: "marathon", meters: 42195,
    // 2 taper weeks + race week ≈ 21 days on a 10+ week block, 14 on a shorter one — the
    // same "2 if total ≥ 10, else 1" rule the shape prompt has always given the model.
    taperWeeks: 2, shortBlockTaperWeeks: 1, taperScale: [0.72, 0.55, 0.4],
    longRunCapMi: 22, peakBandMi: [35, 85], qualityMi: 5.5,
    mix: { base: ["tempo", "strides"], build: ["threshold", "tempo"], peak: ["race_pace", "vo2"], taper: ["race_touch"] },
    racePace: { type: "tempo", title: "Marathon-pace blocks", detail: "2×3 mi @ {pace} w/ 1 mi easy" },
    raceTouch: { type: "tempo", detail: "4×half-mile @ {pace}, feel springy" },
    raceSpecificLongRuns: true, bigLongRunMi: 20,
  },
};

/// Labels the pre-#102 schema accepts in `goals.distance`; anything else needs migration 0013.
export const LEGACY_DISTANCE_LABELS = ["5k", "10k", "half", "marathon"];

export function taperWeeksFor(profile: DistanceProfile, blockTrainingWeeks: number): number {
  return blockTrainingWeeks >= 10 ? profile.taperWeeks : profile.shortBlockTaperWeeks;
}

export interface ResolvedDistance {
  /// The label written to `goals.distance` — one of the table keys, or "custom".
  label: DistanceKey | "custom";
  meters: number;
  /// The table row the plan is shaped by. For a custom distance, the nearest row, with the
  /// athlete's metres (so the race session is the race they are actually running).
  profile: DistanceProfile;
}

/// `goals.distance_m` is the source of truth (#102); the label is the fallback; and with
/// neither — every request that predates #102 — the answer is the marathon, as it always was.
export function resolveDistance(label: unknown, meters: unknown): ResolvedDistance {
  const m = typeof meters === "number" ? meters : typeof meters === "string" ? Number(meters) : NaN;
  if (Number.isFinite(m) && m >= 400 && m <= 100_000) {
    const nearest = (Object.values(DISTANCES) as DistanceProfile[]).reduce((best, p) =>
      Math.abs(Math.log(m / p.meters)) < Math.abs(Math.log(m / best.meters)) ? p : best
    );
    const exact = Math.abs(m - nearest.meters) / nearest.meters < 0.01;
    const given = typeof label === "string" && (label === "custom" || label in DISTANCES) ? label : null;
    return {
      label: (given as DistanceKey | "custom" | null) ?? (exact ? nearest.key : "custom"),
      meters: Math.round(m),
      profile: { ...nearest, meters: Math.round(m) },
    };
  }
  if (typeof label === "string" && label in DISTANCES) {
    const p = DISTANCES[label as DistanceKey];
    return { label: p.key, meters: p.meters, profile: p };
  }
  return { label: "marathon", meters: DISTANCES.marathon.meters, profile: DISTANCES.marathon };
}

// ── Preferences (goals.preferences, #102) ─────────────────────────────────────
export type PlanStyle = "full" | "weekly" | "none";
export type CourseType = "flat" | "rolling" | "hilly" | "trail";

export interface Preferences {
  planStyle: PlanStyle;
  /// How many long runs ≥ the distance's big-long-run mark the block must contain; null = no
  /// constraint (today's behavior). Ignored for distances without a mark.
  longRunsBig: number | null;
  courseType: CourseType | null;
  /// Empty means "no preference" → the distance's default mix.
  quality: QualityCategory[];
}

export const DEFAULT_PREFERENCES: Preferences = { planStyle: "full", longRunsBig: null, courseType: null, quality: [] };

const QUALITY_ALIASES: Record<string, QualityCategory> = {
  intervals: "intervals", interval: "intervals", vo2: "intervals", speed: "intervals", track: "intervals",
  tempo: "tempo", tempos: "tempo", threshold: "tempo",
  hills: "hills", hill: "hills", hill_repeats: "hills",
  race_pace: "race_pace", race_pace_long_runs: "race_pace", race_pace_long_run: "race_pace",
  race_pace_long: "race_pace", race_pace_runs: "race_pace", rp_long: "race_pace",
};
const COURSE_ALIASES: Record<string, CourseType> = {
  flat: "flat", flat_road: "flat", road: "flat",
  rolling: "rolling", hilly: "hilly", hills: "hilly", trail: "trail",
};
const slug = (v: unknown) => typeof v === "string" ? v.trim().toLowerCase().replace(/[^a-z0-9]+/g, "_") : "";

/// Read `goals.preferences` without trusting it. Before migration 0013 the column does not
/// exist (raw is undefined); after it, old goals carry null. Either way — and for any field
/// that is missing, misspelled or out of range — the answer is today's behavior.
/// `courseColumn` is `goals.course_type`, which outranks the copy inside the jsonb.
export function readPreferences(raw: unknown, courseColumn?: unknown): Preferences {
  const p = raw && typeof raw === "object" && !Array.isArray(raw) ? raw as Record<string, unknown> : {};
  const style = slug(p.plan_style);
  const planStyle: PlanStyle = style === "weekly" || style === "none" ? style : "full";
  const n = typeof p.long_runs_20plus === "number" ? p.long_runs_20plus : NaN;
  const longRunsBig = Number.isInteger(n) && n >= 0 && n <= 12 ? n : null;
  const courseType = COURSE_ALIASES[slug(courseColumn)] ?? COURSE_ALIASES[slug(p.course_type)] ?? null;
  const quality = Array.isArray(p.quality)
    ? [...new Set(p.quality.map((q) => QUALITY_ALIASES[slug(q)]).filter((q): q is QualityCategory => !!q))]
    : [];
  return { planStyle, longRunsBig, courseType, quality };
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

/// Make the model's shape obey the distance table. The model proposes; this decides.
///
/// - phases sum to exactly `trainingWeeks`, ending in exactly the table's taper (the model's
///   own taper phase lends its focus line and quality count, nothing else);
/// - peak volume ≤ the band's top, unless the athlete already runs more than that;
/// - long-run peak ≤ the distance's cap;
/// - mid-block (`anchorWeeklyMi` set): start volume IS the last 4 weeks' real average.
export function normalizeShape(shape: Shape, profile: DistanceProfile, ctx: {
  trainingWeeks: number; blockTrainingWeeks: number;
  currentWeeklyMi?: number | null; anchorWeeklyMi?: number | null;
}): Shape {
  const total = Math.max(ctx.trainingWeeks, 0);
  const taperWeeks = Math.min(taperWeeksFor(profile, ctx.blockTrainingWeeks), Math.max(total - 1, 0));
  const modelTaper = shape.phases.find((p) => p.name === "taper");
  const training = shape.phases
    .filter((p) => p.name !== "taper" && p.weeks > 0)
    .map((p) => ({ ...p, weeks: Math.round(p.weeks) }));
  const need = total - taperWeeks;
  let have = training.reduce((n, p) => n + p.weeks, 0);
  if (need > 0 && training.length === 0) {
    training.push({ name: "build", weeks: need, focus: "Build", quality_per_week: 2 });
    have = need;
  }
  if (have < need) training[training.length - 1].weeks += need - have; // extend the latest phase
  while (have > need && training.length > 0) {                         // trim from the front
    const cut = Math.min(training[0].weeks, have - need);
    training[0].weeks -= cut;
    have -= cut;
    if (training[0].weeks === 0) training.shift();
  }
  const phases = [...training];
  if (taperWeeks > 0) {
    phases.push({
      name: "taper", weeks: taperWeeks,
      focus: modelTaper?.focus ?? "Sharpen and freshen",
      quality_per_week: modelTaper?.quality_per_week ?? 1,
    });
  }

  const ceiling = Math.max(profile.peakBandMi[1], ctx.currentWeeklyMi ?? 0);
  const anchor = ctx.anchorWeeklyMi != null && ctx.anchorWeeklyMi > 0 ? ctx.anchorWeeklyMi : null;
  const start = anchor ?? shape.start_weekly_mi;
  const peak = Math.max(Math.min(shape.peak_weekly_mi, ceiling), start);
  const longPeak = Math.min(shape.long_run_peak_mi, profile.longRunCapMi);
  return {
    ...shape,
    phases,
    start_weekly_mi: +start.toFixed(1),
    peak_weekly_mi: +peak.toFixed(1),
    long_run_peak_mi: longPeak,
    long_run_start_mi: Math.min(shape.long_run_start_mi, longPeak),
  };
}

/// Which weeks carry the big long runs (20+ mi marathon, 12+ mi half). A hard constraint:
/// exactly `count` weeks, spread evenly across the peak phase, borrowing the latest build
/// (then base) weeks only when peak is too short to hold them all — and never a taper week.
export function bigLongRunWeeks(weeks: { index: number; phase: string }[], count: number): number[] {
  if (count <= 0) return [];
  const byPhase = (name: string) => weeks.filter((w) => w.phase === name).map((w) => w.index);
  const pool = byPhase("peak");
  for (const borrow of [byPhase("build").reverse(), byPhase("base").reverse()]) {
    for (const i of borrow) if (pool.length < count) pool.push(i);
  }
  pool.sort((a, b) => a - b);
  if (count >= pool.length) return pool;
  if (count === 1) return [pool[pool.length - 1]];
  const picks = new Set<number>();
  for (let k = 0; k < count; k++) picks.add(pool[Math.round((k * (pool.length - 1)) / (count - 1))]);
  // Rounding can collide when count is close to the pool size; fill from the back.
  for (let j = pool.length - 1; picks.size < count && j >= 0; j--) picks.add(pool[j]);
  return [...picks].sort((a, b) => a - b);
}

/// The workout kinds a phase rotates through for this athlete.
///
/// Hills join base and build when the course is rolling or hilly — unless the athlete named
/// the workouts they will do and hills are not among them (their word outranks the course).
/// An athlete who picks hills gets them on a flat course too. A pick list that empties a
/// phase falls back to that phase's flavor of each thing they did pick, never to nothing.
export function qualityRotation(profile: DistanceProfile, phase: PhaseName, prefs: Preferences): QualityKind[] {
  const allowed = prefs.quality.length ? new Set(prefs.quality) : null;
  const hillyCourse = prefs.courseType === "rolling" || prefs.courseType === "hilly";
  const hills = allowed ? allowed.has("hills") : hillyCourse;
  let rot: QualityKind[] = [...(profile.mix[phase] ?? profile.mix.build)];
  if (hills && (phase === "base" || phase === "build")) rot.push("hills");
  if (allowed) {
    rot = rot.filter((k) => allowed.has(CATEGORY[k]));
    if (rot.length === 0) {
      const flavor: Record<QualityCategory, QualityKind> = {
        intervals: phase === "base" || phase === "taper" ? "strides" : "vo2",
        tempo: phase === "base" || phase === "taper" ? "tempo" : "threshold",
        hills: "hills",
        race_pace: phase === "base" || phase === "taper" ? "race_touch" : "race_pace",
      };
      rot = prefs.quality.map((c) => flavor[c]);
    }
  }
  return rot;
}

function qualitySession(kind: QualityKind, phase: string, paces: Paces, profile: DistanceProfile) {
  const t = fmtPace(paces.threshold);
  const i = fmtPace(paces.interval);
  const r = fmtPace(paces.repetition);
  const race = fmtPace(paces.race);
  switch (kind) {
    case "strides":
      return { type: "interval", title: "Strides", detail: `8×20s fast, full recovery, inside an easy run`, pace: paces.repetition };
    case "speed":
      return { type: "interval", title: "Speed reps", detail: `8×200m @ ${r} w/ 200m jog`, pace: paces.repetition };
    case "vo2":
      return { type: "interval", title: "VO₂ intervals", detail: `5×1000m @ ${i} w/ 2:30 jog`, pace: paces.interval };
    case "threshold":
      return { type: "threshold", title: "Threshold repeats", detail: `3×1 mi @ ${t} w/ 2:00 jog`, pace: paces.threshold };
    case "tempo":
      return phase === "base"
        ? { type: "tempo", title: "Light tempo", detail: `15–20 min @ ${t} inside an easy run`, pace: paces.threshold }
        : { type: "tempo", title: "Steady tempo", detail: `2×15 min @ ${t} w/ 3:00 jog`, pace: paces.threshold };
    case "race_pace":
      return { type: profile.racePace.type, title: profile.racePace.title, detail: profile.racePace.detail.replace("{pace}", race), pace: paces.race };
    case "race_touch":
      return { type: profile.raceTouch.type, title: "Race-pace touch", detail: profile.raceTouch.detail.replace("{pace}", race), pace: paces.race };
    case "hills":
      return { type: "interval", title: "Hill repeats", detail: "8×60–90s uphill at 5K effort, jog down — climbing strength for the course", pace: null };
  }
}

export interface PlanWeek { index: number; phase: string; focus: string; target: number; quality: number }
export interface PlanSession {
  week_index: number; day_offset: number; type: string; title: string;
  target_distance_m: number | null; target_pace_sec: number | null; structure: unknown;
}

export function generate(shape: Shape, opts: {
  /// Monday of block week 0. Mid-block, this is in the past: week `firstWeekIndex` is the
  /// current week, and the weeks before it are never created.
  startMonday: Date;
  firstWeekIndex?: number;
  daysPerWeek: number; longRunDay: number; paces: Paces;
  wantsStrength: boolean; raceDate: string; raceName?: string | null;
  /// Default: the marathon, i.e. every plan before #104.
  distance?: DistanceProfile;
  prefs?: Preferences;
  /// Weekly volume of the athlete's last 4 real weeks — the "Today" every plan starts from.
  currentWeeklyMi?: number | null;
  /// Mid-block only: the first generated week runs at exactly this volume.
  anchorWeeklyMi?: number | null;
  /// Appended to the shape's rationale — PaceBasis.note, when paces did not come from a
  /// target time. The athlete reads the rationale; that is where "why these paces" belongs.
  rationaleNote?: string | null;
}) {
  const profile = opts.distance ?? DISTANCES.marathon;
  const prefs = opts.prefs ?? DEFAULT_PREFERENCES;
  const first = Math.max(opts.firstWeekIndex ?? 0, 0);
  const race = racePlacement(opts.startMonday, opts.raceDate);
  const trainingWeeks = Math.max(race.weekIndex - first, 0);
  const anchored = opts.anchorWeeklyMi != null && opts.anchorWeeklyMi > 0;
  const norm = normalizeShape(shape, profile, {
    trainingWeeks, blockTrainingWeeks: race.weekIndex,
    currentWeeklyMi: opts.currentWeeklyMi, anchorWeeklyMi: opts.anchorWeeklyMi,
  });
  if (opts.rationaleNote) norm.rationale = [norm.rationale, opts.rationaleNote].filter(Boolean).join(" ");
  const warnings: string[] = [];
  const notes: string[] = [];

  const buildWeeks = norm.phases.filter((p) => p.name !== "taper").reduce((n, p) => n + p.weeks, 0);
  const weeks: PlanWeek[] = [];
  let w = first;
  for (const phase of norm.phases) {
    for (let k = 0; k < phase.weeks; k++) {
      const rel = w - first;
      let target: number;
      if (phase.name === "taper") {
        const taperIdx = rel - buildWeeks;
        target = norm.peak_weekly_mi * profile.taperScale[Math.min(taperIdx, profile.taperScale.length - 1)];
      } else if (anchored && rel === 0) {
        target = norm.start_weekly_mi; // "begins there, at real volume" — no step-back either
      } else {
        const f = buildWeeks <= 1 ? 1 : rel / (buildWeeks - 1);
        target = norm.start_weekly_mi + (norm.peak_weekly_mi - norm.start_weekly_mi) * f;
        if ((w + 1) % 4 === 0) target *= 0.85; // step-back week, counted in block weeks
      }
      weeks.push({ index: w, phase: phase.name, focus: phase.focus, target: +target.toFixed(1), quality: phase.quality_per_week });
      w++;
    }
  }

  // Big long runs: only a constraint when the athlete answered and the distance has a mark.
  const bigMark = profile.bigLongRunMi;
  const bigCount = bigMark != null ? prefs.longRunsBig : null;
  const bigWeeks = new Set(bigCount != null ? bigLongRunWeeks(weeks, bigCount) : []);
  if (bigCount != null && bigWeeks.size < bigCount) {
    warnings.push(`asked for ${bigCount} long runs of ${bigMark}+ mi; only ${bigWeeks.size} non-taper weeks to hold them`);
  }
  const allowsRacePace = prefs.quality.length === 0 || prefs.quality.includes("race_pace");
  if (prefs.courseType === "trail") notes.push("Trail race: run long runs on trail when you can.");

  // Sessions per week. Weekday offsets are relative to the plan-week Monday (0=Mon…6=Sun).
  const longOffset = (opts.longRunDay + 6) % 7; // convert 0=Sun…6=Sat → 0=Mon…6=Sun
  const qualityOffsets = [1, 3].filter((o) => o !== longOffset); // Tue/Thu
  const easyPreference = [0, 2, 4, 5, 1, 3].filter((o) => o !== longOffset);
  const qualityMi = profile.qualityMi; // incl. warmup/cooldown
  const minEasyMi = 2.5;

  const sessions: PlanSession[] = [];

  for (const wk of weeks) {
    const rel = wk.index - first;
    const f = buildWeeks <= 1 ? 1 : Math.min(rel / (buildWeeks - 1), 1);
    let longMi = norm.long_run_start_mi + (norm.long_run_peak_mi - norm.long_run_start_mi) * f;
    longMi = Math.min(longMi, wk.target * 0.4);
    const qualityCount = Math.min(wk.quality, qualityOffsets.length);
    const easyCount = Math.max(opts.daysPerWeek - 1 - qualityCount, 0);
    if (bigMark != null && bigCount != null) {
      if (bigWeeks.has(wk.index)) {
        // The athlete's number is a hard constraint: it beats the 40%-of-week rule, so the
        // week's target grows to hold the run honestly rather than the run shrinking under it.
        longMi = Math.min(Math.max(longMi, bigMark), Math.max(profile.longRunCapMi, bigMark));
        wk.target = +Math.max(wk.target, longMi + qualityCount * qualityMi + easyCount * minEasyMi).toFixed(1);
      } else {
        longMi = Math.min(longMi, bigMark - 1);
      }
    }

    const easyTotal = Math.max(wk.target - longMi - qualityCount * qualityMi, easyCount * minEasyMi);
    const easyMi = easyCount > 0 ? easyTotal / easyCount : 0;

    let longDetail = `${longMi.toFixed(1)} mi steady @ ~${fmtPace(opts.paces.easy)}, conversational`;
    let longTitle = "Long run";
    if (profile.raceSpecificLongRuns && allowsRacePace && wk.phase === "peak" && wk.index % 2 === 1) {
      const finish = Math.max(2, Math.round(longMi * 0.3));
      longTitle = "Race-pace long run";
      longDetail = `${longMi.toFixed(1)} mi, the last ${finish} @ ${fmtPace(opts.paces.race)} — rehearse race day`;
    }
    if (prefs.courseType === "trail" && wk.phase !== "taper") longDetail += ". On trail if you can — the race is.";
    sessions.push({
      week_index: wk.index, day_offset: longOffset, type: "long", title: longTitle,
      target_distance_m: Math.round(longMi * MI), target_pace_sec: opts.paces.easy,
      structure: { detail: longDetail },
    });
    const rotation = qualityRotation(profile, wk.phase as PhaseName, prefs);
    for (let q = 0; q < qualityCount && rotation.length > 0; q++) {
      const s = qualitySession(rotation[(wk.index + q) % rotation.length], wk.phase, opts.paces, profile);
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
  const raceMi = profile.meters / MI;
  weeks.push({
    index: race.weekIndex,
    phase: "taper",   // plan_weeks.phase CHECK admits base|build|peak|taper only
    focus: "Race week — the training is done. Everything this week serves race day.",
    target: +raceMi.toFixed(1),
    quality: 0,
  });
  sessions.push({
    week_index: race.weekIndex, day_offset: race.dayOffset, type: "race",
    title: opts.raceName ?? "Race day",
    target_distance_m: profile.meters, target_pace_sec: opts.paces.race,
    structure: { detail: `${raceMi.toFixed(1)} mi @ ${fmtPace(opts.paces.race)} — goal pace.` },
  });

  return {
    weeks, sessions,
    /// Block length including race week — and, mid-block, the weeks before the athlete
    /// joined, so the app reads "Week 9 of 16" rather than "Week 1 of 8".
    totalWeeks: race.weekIndex + 1,
    raceWeekIndex: race.weekIndex,
    shape: norm,
    warnings,
    notes,
  };
}
export type Generated = ReturnType<typeof generate>;

/// What /plan writes besides the goal, by plan style (#102's "Do you want a plan?").
///
/// - `full`: everything generate() made — today's behavior.
/// - `weekly`: every week with its target and focus, but only the sessions that carry intent
///   (long runs, quality, the race). Easy days and strength are the athlete's to place.
/// - `none`: nothing. The goal is the whole commitment; the coach coaches from it.
export function planWrites(style: PlanStyle, generated: Generated | null): {
  plan: boolean; weeks: PlanWeek[]; sessions: PlanSession[];
} {
  if (style === "none" || !generated) return { plan: false, weeks: [], sessions: [] };
  if (style === "weekly") {
    return {
      plan: true,
      weeks: generated.weeks,
      sessions: generated.sessions.filter((s) => s.type !== "easy" && s.type !== "cross"),
    };
  }
  return { plan: true, weeks: generated.weeks, sessions: generated.sessions };
}
