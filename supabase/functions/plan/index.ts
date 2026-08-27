// Tempo plan engine — /plan
//
// Called after the athlete confirms the coach's goal proposal (create_plan card).
// Pipeline (spec: progress.md "Plan-engine spec"):
//   1. Read the athlete's real runs + settings via their JWT (RLS-scoped).
//   2. Deterministic feature extraction (volume, trend, consistency, long run, fitness).
//   3. Claude proposes the plan SHAPE inside a forced tool schema — phases emerge from
//      what's missing, never a fixed 4-phase template.
//   4. Deterministic generator turns the shape into weeks + sessions with real paces.
//   5. Write goal/plan/weeks/sessions; return a summary.
//
// The LLM never writes sessions or paces — it tunes shape within bounds; math is code.

import { createClient } from "npm:@supabase/supabase-js@2";

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const MODEL = "claude-sonnet-5";

// Same scar as coach/index.ts (#16): Sonnet 5 thinks by default, and thinking is drawn from
// the SAME max_tokens budget as the output. The old ceiling of 1500 was sized for a model
// that didn't think — one deliberation over phase math and there is nothing left to emit the
// tool call with, and this function's failure is a bare 502 "no shape proposed" with no plan
// built. Rarer than the coach bug only because plans are created rarely, not because it was
// any less broken.
//
// Forced tool_choice alongside thinking is fine here: that combination is restricted on
// Amazon Bedrock only, and this calls the Claude API directly.
const SAMPLING = {
  max_tokens: 16000,
  thinking: { type: "adaptive" },
  output_config: { effort: "medium" },
} as const;

const MI = 1609.34;

// ── Pace math (port of ios/Tempo/Engine/TrainingPaces.swift) ─────────────────
function equivalentTime(t1: number, d1: number, d2: number): number {
  return t1 * Math.pow(d2 / d1, 1.06);
}
function trainingPaces(goalSeconds: number) {
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
function fmtPace(sec: number): string {
  return `${Math.floor(sec / 60)}:${String(Math.round(sec) % 60).padStart(2, "0")}`;
}

// ── Feature extraction ────────────────────────────────────────────────────────
interface RunRow {
  start_time: string;
  distance_m: number;
  duration_s: number;
  avg_hr: number | null;
}

function mondayOf(d: Date): Date {
  const x = new Date(d);
  const day = (x.getUTCDay() + 6) % 7; // 0 = Monday
  x.setUTCDate(x.getUTCDate() - day);
  x.setUTCHours(0, 0, 0, 0);
  return x;
}

function extractFeatures(runs: RunRow[]) {
  const now = new Date();
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

  // Best sustained effort (≥ 2.5 mi) in the last 8 weeks → Riegel current marathon fitness.
  let bestPace = Infinity;
  let bestMiles = 0;
  for (const r of recent) {
    const mi = r.distance_m / MI;
    if (mi >= 2.5) {
      const pace = r.duration_s / mi;
      if (pace < bestPace) {
        bestPace = pace;
        bestMiles = mi;
      }
    }
  }
  const currentMarathonS = bestPace < Infinity
    ? Math.round(equivalentTime(bestPace * bestMiles, bestMiles, 26.2188))
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
  };
}

// ── Shape proposal (Claude, forced tool) ─────────────────────────────────────
const SHAPE_TOOL = {
  name: "propose_plan_shape",
  description: "Propose the training-plan shape for this athlete. Phases emerge from what the DATA says is missing — never force a fixed template. If the athlete is already aerobically fit, skip or shrink base. Anchor start volume on their real current volume.",
  input_schema: {
    type: "object",
    properties: {
      archetype: { type: "string", enum: ["rebuild_base", "progressive_build", "race_specific", "sharpen"] },
      rationale: { type: "string", description: "2-3 sentences, grounded in the features, written to the athlete." },
      phases: {
        type: "array",
        description: "In order, covering every training week (taper included, race week excluded).",
        items: {
          type: "object",
          properties: {
            name: { type: "string", enum: ["base", "build", "peak", "taper"] },
            weeks: { type: "integer", minimum: 1 },
            focus: { type: "string", description: "One line, athlete-facing." },
            quality_per_week: { type: "integer", minimum: 0, maximum: 3 },
          },
          required: ["name", "weeks", "focus", "quality_per_week"],
        },
      },
      start_weekly_mi: { type: "number", description: "Week-1 volume. Anchor on vol_4wk_avg_mi (max ~+15% unless risk_tolerance is ambitious)." },
      peak_weekly_mi: { type: "number" },
      long_run_start_mi: { type: "number" },
      long_run_peak_mi: { type: "number", description: "Cap ≈ 35% of peak weekly volume, and respect what history shows they can absorb." },
    },
    required: ["archetype", "rationale", "phases", "start_weekly_mi", "peak_weekly_mi", "long_run_start_mi", "long_run_peak_mi"],
  },
};

// ── Generator (deterministic) ─────────────────────────────────────────────────
interface Shape {
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

function generate(shape: Shape, opts: {
  startMonday: Date; daysPerWeek: number; longRunDay: number; paces: ReturnType<typeof trainingPaces>;
  wantsStrength: boolean;
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
  return { weeks, sessions, totalWeeks };
}

// ── HTTP handler ──────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (req.method !== "POST") return Response.json({ error: "POST only" }, { status: 405 });
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return Response.json({ error: "ANTHROPIC_API_KEY not configured" }, { status: 500 });

  try {
    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
    );
    const { data: userData, error: userErr } = await supa.auth.getUser();
    if (userErr || !userData?.user) return Response.json({ error: "unauthorized" }, { status: 401 });
    const uid = userData.user.id;

    const { goal_time_s, race_name, race_date } = await req.json();
    if (!goal_time_s || !race_date) return Response.json({ error: "goal_time_s and race_date required" }, { status: 400 });

    const { data: profile } = await supa.from("profiles")
      .select("days_per_week,long_run_day,risk_tolerance,wants_strength").eq("id", uid).single();
    const daysPerWeek = profile?.days_per_week ?? 6;
    const longRunDay = profile?.long_run_day ?? 0;
    const risk = profile?.risk_tolerance ?? "standard";
    const wantsStrength = profile?.wants_strength ?? false;

    const since = new Date(Date.now() - 120 * 86400_000).toISOString();
    // `.is("superseded_by", null)` — duplicates retired by migration 0008 would otherwise
    // inflate every volume feature the plan shape is built from.
    const { data: runs } = await supa.from("runs")
      .select("start_time,distance_m,duration_s,avg_hr")
      .is("superseded_by", null)
      .gte("start_time", since).order("start_time", { ascending: true });
    const features = extractFeatures((runs ?? []) as RunRow[]);

    const startMonday = mondayOf(new Date());
    const raceDay = new Date(race_date + "T12:00:00Z");
    const weeksToRace = Math.floor((raceDay.getTime() - startMonday.getTime()) / (7 * 86400_000));
    if (weeksToRace < 2) return Response.json({ error: "race is too close for a plan" }, { status: 400 });
    const planWeeks = weeksToRace; // race week's partial days ride in the final taper week

    // Claude proposes the shape (forced tool call).
    const system = `You design the SHAPE of a running plan for Tempo. The athlete's real data and constraints are below. Rules:
- Phases emerge from what the data says is missing. An already-fit athlete does NOT get sent back to base. A rebuilding athlete gets mostly aerobic work.
- phases[].weeks must sum to EXACTLY ${planWeeks}.
- Anchor start_weekly_mi on vol_4wk_avg_mi (at most ~15% above it; ambitious risk_tolerance may stretch to ~25%).
- Ramp start→peak must stay plausible for ${planWeeks} weeks (~10%/wk standard, ~15%/wk ambitious); the generator adds step-back weeks automatically.
- Always end with a taper (2 weeks if total ≥ 10, else 1).
- long_run_peak_mi ≤ 35% of peak_weekly_mi and ≤ roughly double longest_run_8wk_mi.
- risk_tolerance: ${risk}. Honest, not reckless: the rationale must say what the data supports.

<athlete>
goal: ${race_name ?? "race"} on ${race_date}, target ${Math.floor(goal_time_s / 3600)}:${String(Math.floor((goal_time_s % 3600) / 60)).padStart(2, "0")}:${String(goal_time_s % 60).padStart(2, "0")}
weeks_until_race: ${weeksToRace}
days_per_week: ${daysPerWeek}
features: ${JSON.stringify(features, null, 1)}
</athlete>`;

    const resp = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL, ...SAMPLING, system,
        tools: [SHAPE_TOOL], tool_choice: { type: "tool", name: "propose_plan_shape" },
        messages: [{ role: "user", content: "Propose the plan shape." }],
      }),
    });
    if (!resp.ok) {
      console.error("anthropic error", resp.status, await resp.text());
      return Response.json({ error: `anthropic ${resp.status}` }, { status: 502 });
    }
    const ai = await resp.json();
    const shape = ai.content?.find((b: { type: string }) => b.type === "tool_use")?.input as Shape | undefined;
    if (!shape) {
      // The one line that turns "the plan button did nothing" into a diagnosis. Its twin in
      // coach/index.ts is what identified the thinking-budget bug from a single log query.
      console.error("no shape proposed", JSON.stringify({ stop_reason: ai.stop_reason, usage: ai.usage }));
      return Response.json({ error: "no shape proposed" }, { status: 502 });
    }

    // Normalize phase weeks to exactly planWeeks (guard against model arithmetic).
    const sum = shape.phases.reduce((n, p) => n + p.weeks, 0);
    if (sum !== planWeeks && shape.phases.length > 0) {
      shape.phases[0].weeks += planWeeks - sum;
      if (shape.phases[0].weeks < 1) return Response.json({ error: "invalid phase math" }, { status: 502 });
    }

    const paces = trainingPaces(goal_time_s);
    const generated = generate(shape, { startMonday, daysPerWeek, longRunDay, paces, wantsStrength });

    // Projection: Riegel current fitness, nudged toward goal by volume adequacy.
    const projected = features.riegel_current_marathon_s ?? Math.round(goal_time_s * 1.06);

    // ── Write everything: CREATE first, retire old only after full success ──
    // (Retire-first once destroyed a plan when a later step failed mid-flight.)
    const { data: goal, error: gErr } = await supa.from("goals").insert({
      user_id: uid, race_name: race_name ?? null, race_date,
      distance: "marathon", goal_time_seconds: goal_time_s,
      days_per_week: daysPerWeek, start_mileage: features.vol_4wk_avg_mi, is_active: true,
    }).select("id").single();
    if (gErr) throw gErr;

    const cleanup = async (planId?: string) => {
      if (planId) await supa.from("plans").delete().eq("id", planId);   // cascades weeks+sessions
      await supa.from("goals").delete().eq("id", goal.id);
    };

    const { data: plan, error: pErr } = await supa.from("plans").insert({
      user_id: uid, goal_id: goal.id,
      start_date: startMonday.toISOString().slice(0, 10),
      weeks: generated.totalWeeks, status: "active",
      assessment: { features, shape },
      projected_finish_s: projected,
    }).select("id").single();
    if (pErr) { await cleanup(); throw pErr; }

    const weekRows = generated.weeks.map((w) => ({
      plan_id: plan.id, week_index: w.index, phase: w.phase,
      target_mileage: w.target, focus: w.focus,
    }));
    const { data: weekIds, error: wErr } = await supa.from("plan_weeks").insert(weekRows).select("id,week_index");
    if (wErr) { await cleanup(plan.id); throw wErr; }
    const weekIdByIndex = new Map((weekIds ?? []).map((w: { id: string; week_index: number }) => [w.week_index, w.id]));

    const sessionRows = generated.sessions.map((s) => {
      const date = new Date(startMonday);
      date.setUTCDate(date.getUTCDate() + s.week_index * 7 + s.day_offset);
      return {
        plan_id: plan.id, week_id: weekIdByIndex.get(s.week_index) ?? null, user_id: uid,
        date: date.toISOString().slice(0, 10), type: s.type, title: s.title,
        target_distance_m: s.target_distance_m, target_pace_sec: s.target_pace_sec,
        structure: s.structure, status: "planned",
      };
    });
    const { error: sErr } = await supa.from("sessions").insert(sessionRows);
    if (sErr) { await cleanup(plan.id); throw sErr; }

    // New plan fully exists — NOW retire everything that isn't it.
    await supa.from("plans").update({ status: "done" })
      .eq("user_id", uid).eq("status", "active").neq("id", plan.id);
    await supa.from("goals").update({ is_active: false })
      .eq("user_id", uid).eq("is_active", true).neq("id", goal.id);

    return Response.json({
      plan_id: plan.id,
      weeks: generated.totalWeeks,
      archetype: shape.archetype,
      rationale: shape.rationale,
      projected_finish_s: projected,
      start_weekly_mi: shape.start_weekly_mi,
      peak_weekly_mi: shape.peak_weekly_mi,
    });
  } catch (err) {
    console.error("plan error", err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});
