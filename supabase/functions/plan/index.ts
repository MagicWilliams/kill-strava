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
import {
  equivalentTime, fmtPace, generate, MI, mondayOf, racePlacement,
  sessionDate, type Shape, trainingPaces,
} from "./generator.ts";

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

// ── Feature extraction ────────────────────────────────────────────────────────
interface RunRow {
  start_time: string;
  distance_m: number;
  duration_s: number;
  avg_hr: number | null;
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
    const weeksToRace = racePlacement(startMonday, race_date).weekIndex;
    if (weeksToRace < 2) return Response.json({ error: "race is too close for a plan" }, { status: 400 });
    // TRAINING weeks only — the shape excludes race week by contract, and generate()
    // appends it. Read this as "the plan is one week longer than the shape it came from".
    const planWeeks = weeksToRace;

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
    const generated = generate(shape, {
      startMonday, daysPerWeek, longRunDay, paces, wantsStrength,
      raceDate: race_date, raceName: race_name ?? null,
    });

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
      return {
        plan_id: plan.id, week_id: weekIdByIndex.get(s.week_index) ?? null, user_id: uid,
        date: sessionDate(startMonday, s.week_index, s.day_offset), type: s.type, title: s.title,
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
