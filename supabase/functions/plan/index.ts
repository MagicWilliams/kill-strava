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
//
// Since #104 the request may also carry the intake's goal fields (#102): distance /
// distance_m, course_type, goal_type, started_week, preferences — the same names as the
// goals columns they land in. All optional: a request without them is a marathon plan,
// exactly as before. goal.ts decides how they resolve and carry across regenerations.

import { createClient } from "npm:@supabase/supabase-js@2";
import {
  equivalentTime, fmtClock, fmtPace, generate, type Generated, MI, mondayOf, paceBasis, planWrites,
  racePlacement, readPreferences, sessionDate, type Shape, taperWeeksFor, trainingPaces,
} from "./generator.ts";
import { goalInsertRow, isFinishGoal, isMissingColumnError, resolveGoal } from "./goal.ts";

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

function extractFeatures(runs: RunRow[], raceMi: number) {
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

/// The forced tool call, or the error Response the handler should return as-is.
async function proposeShape(apiKey: string, system: string): Promise<Shape | Response> {
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
  return shape;
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

    const body = (await req.json()) as Record<string, unknown>;
    // Null for a "just finish" goal — checked against goal_type once the goal is resolved.
    const goal_time_s = typeof body.goal_time_s === "number" && body.goal_time_s > 0 ? Math.round(body.goal_time_s) : null;
    const race_name = (body.race_name ?? null) as string | null;
    const race_date = body.race_date as string;
    if (!race_date) return Response.json({ error: "race_date required" }, { status: 400 });

    const { data: profile } = await supa.from("profiles")
      .select("days_per_week,long_run_day,risk_tolerance,wants_strength").eq("id", uid).single();
    const daysPerWeek = profile?.days_per_week ?? 6;
    const longRunDay = profile?.long_run_day ?? 0;
    const risk = profile?.risk_tolerance ?? "standard";
    const wantsStrength = profile?.wants_strength ?? false;

    // The active goal, carried into a regeneration of the same race (goal.ts). `select("*")`
    // rather than a column list: before migration 0013 a named distance_m would be an error,
    // whereas `*` just returns fewer keys and everything downstream reads them as absent.
    const { data: activeGoal } = await supa.from("goals").select("*")
      .eq("user_id", uid).eq("is_active", true)
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    const now = new Date();
    const goal = resolveGoal(body, (activeGoal ?? null) as Record<string, unknown> | null, now);
    if (goal_time_s == null && !isFinishGoal(goal.goal_type)) {
      return Response.json({ error: "goal_time_s required unless goal_type is finish" }, { status: 400 });
    }
    const prefs = readPreferences(goal.preferences, goal.course_type);
    const distance = goal.distance.profile;
    const raceMi = goal.distance.meters / MI;

    const since = new Date(Date.now() - 120 * 86400_000).toISOString();
    // `.is("superseded_by", null)` — duplicates retired by migration 0008 would otherwise
    // inflate every volume feature the plan shape is built from.
    const { data: runs } = await supa.from("runs")
      .select("start_time,distance_m,duration_s,avg_hr")
      .is("superseded_by", null)
      .gte("start_time", since).order("start_time", { ascending: true });
    const features = extractFeatures((runs ?? []) as RunRow[], raceMi);

    // Mid-block (#102): the athlete is in week `started_week` of a block already under way.
    // Block week 0 is backdated so plan-week coordinates — and "Week 9 of 16" in the app,
    // which counts from plans.start_date — stay true. The weeks before it are never created.
    const firstWeekIndex = goal.started_week ? goal.started_week - 1 : 0;
    const startMonday = mondayOf(now);
    startMonday.setUTCDate(startMonday.getUTCDate() - 7 * firstWeekIndex);
    const raceWeekIndex = racePlacement(startMonday, race_date).weekIndex;
    const weeksToRace = raceWeekIndex - firstWeekIndex;
    if (weeksToRace < 2) return Response.json({ error: "race is too close for a plan" }, { status: 400 });
    // TRAINING weeks only — the shape excludes race week by contract, and generate()
    // appends it. Read this as "the plan is one week longer than the shape it came from".
    const planWeeks = weeksToRace;
    const taperWeeks = Math.min(taperWeeksFor(distance, raceWeekIndex), planWeeks - 1);
    const anchorWeeklyMi = firstWeekIndex > 0 ? features.vol_4wk_avg_mi : null;
    // Paces come from the target time, or — for a finish goal — from current fitness, or a
    // conservative default. The basis is never stored as the goal's time.
    const basis = paceBasis(goal_time_s, raceMi, features.riegel_current_race_s);
    const paces = trainingPaces(basis.seconds, raceMi);
    // Projection: Riegel current fitness at the race distance, else a modest miss of goal.
    // No target and no runs → no projection; the app already omits the line when it's null.
    const projected = features.riegel_current_race_s ?? (goal_time_s != null ? Math.round(goal_time_s * 1.06) : null);
    const targetLine = goal_time_s != null
      ? `target ${fmtClock(goal_time_s)}`
      : `no target time — the goal is to finish. Training paces are derived from ${basis.source === "fitness" ? "current fitness" : "a conservative default (no usable recent runs)"}, not a goal; do not invent a target in the rationale`;

    const bigMark = distance.bigLongRunMi;
    const raceLines = [
      `- This is a ${goal.distance.label === "custom" ? `${raceMi.toFixed(1)}-mile` : goal.distance.label} race block. ${raceMi <= 6.3 ? "Short race: speed and VO₂ work matter more than long-run length." : "Endurance race: threshold work and long runs carry the block."}`,
      taperWeeks === 0
        ? `- No taper phase: race week itself is the taper for this distance. The last phase ends the week before race week.`
        : `- End with a taper of EXACTLY ${taperWeeks} week${taperWeeks === 1 ? "" : "s"} (race week excluded).`,
      `- peak_weekly_mi is typically ${distance.peakBandMi[0]}–${distance.peakBandMi[1]} for this distance; above ${distance.peakBandMi[1]} only if vol_4wk_avg_mi is already higher. long_run_peak_mi ≤ ${distance.longRunCapMi}.`,
      firstWeekIndex > 0
        ? `- The athlete is ALREADY in week ${firstWeekIndex + 1} of this block. Phases cover only the remaining ${planWeeks} weeks; start_weekly_mi = vol_4wk_avg_mi exactly (they are mid-block, not starting).`
        : null,
      bigMark != null && prefs.longRunsBig != null
        ? `- The athlete wants exactly ${prefs.longRunsBig} long run${prefs.longRunsBig === 1 ? "" : "s"} of ${bigMark}+ mi; the generator places them in the peak phase, so size peak to hold them.`
        : null,
      prefs.courseType === "rolling" || prefs.courseType === "hilly"
        ? `- Course is ${prefs.courseType}: the generator adds hill work to base/build.`
        : null,
    ].filter(Boolean).join("\n");

    // Claude proposes the shape (forced tool call).
    const system = `You design the SHAPE of a running plan for Tempo. The athlete's real data and constraints are below. Rules:
- Phases emerge from what the data says is missing. An already-fit athlete does NOT get sent back to base. A rebuilding athlete gets mostly aerobic work.
- phases[].weeks must sum to EXACTLY ${planWeeks}.
- Anchor start_weekly_mi on vol_4wk_avg_mi (at most ~15% above it; ambitious risk_tolerance may stretch to ~25%).
- Ramp start→peak must stay plausible for ${planWeeks} weeks (~10%/wk standard, ~15%/wk ambitious); the generator adds step-back weeks automatically.
${raceLines}
- long_run_peak_mi ≤ 35% of peak_weekly_mi and ≤ roughly double longest_run_8wk_mi.
- risk_tolerance: ${risk}. Honest, not reckless: the rationale must say what the data supports.

<athlete>
goal: ${race_name ?? "race"} (${goal.distance.label}, ${raceMi.toFixed(1)} mi) on ${race_date}, ${targetLine}
weeks_until_race: ${weeksToRace}
days_per_week: ${daysPerWeek}
features: ${JSON.stringify(features, null, 1)}
</athlete>`;

    // `none` is "no plan, just coaching": there is no shape to ask for, so no Claude call.
    let generated: Generated | null = null;
    if (prefs.planStyle !== "none") {
      const proposed = await proposeShape(apiKey, system);
      if (proposed instanceof Response) return proposed;
      // Phase arithmetic, the taper, the volume band and the long-run cap are no longer
      // trusted to the model: generate() fits the shape to the distance table (normalizeShape).
      generated = generate(proposed, {
        startMonday, firstWeekIndex, daysPerWeek, longRunDay, paces, wantsStrength,
        raceDate: race_date, raceName: race_name, distance, prefs,
        currentWeeklyMi: features.vol_4wk_avg_mi, anchorWeeklyMi, rationaleNote: basis.note,
      });
    }
    const writes = planWrites(prefs.planStyle, generated);

    // ── Write everything: CREATE first, retire old only after full success ──
    // (Retire-first once destroyed a plan when a later step failed mid-flight.)
    const goalBase = {
      user_id: uid, race_name, race_date, goal_time_seconds: goal_time_s,
      days_per_week: daysPerWeek, start_mileage: features.vol_4wk_avg_mi, is_active: true,
    };
    let inserted = await supa.from("goals").insert(goalInsertRow(goalBase, goal, false)).select("id").single();
    if (inserted.error && isMissingColumnError(inserted.error)) {
      // Migration 0013 isn't applied: write the row the old schema knows. The plan below is
      // still shaped by distance and preferences; only the goal row can't remember them yet.
      inserted = await supa.from("goals").insert(goalInsertRow(goalBase, goal, true)).select("id").single();
    }
    if (inserted.error) throw inserted.error;
    const goalId: string = inserted.data.id;

    const retireOthers = async (keepPlanId: string | null) => {
      const plans = supa.from("plans").update({ status: "done" }).eq("user_id", uid).eq("status", "active");
      await (keepPlanId ? plans.neq("id", keepPlanId) : plans);
      await supa.from("goals").update({ is_active: false })
        .eq("user_id", uid).eq("is_active", true).neq("id", goalId);
    };

    if (!writes.plan || !generated) {
      // No plan, just coaching: the goal is the commitment. Whatever plan was active belonged
      // to the previous goal, so it stands down with it.
      await retireOthers(null);
      return Response.json({
        plan_id: null, weeks: null, plan_style: prefs.planStyle,
        distance: goal.distance.label, projected_finish_s: projected,
        goal_time_s, pace_basis: basis.source, rationale: basis.note,
      });
    }
    const shape = generated.shape;

    const cleanup = async (planId?: string) => {
      if (planId) await supa.from("plans").delete().eq("id", planId);   // cascades weeks+sessions
      await supa.from("goals").delete().eq("id", goalId);
    };

    const { data: plan, error: pErr } = await supa.from("plans").insert({
      user_id: uid, goal_id: goalId,
      start_date: startMonday.toISOString().slice(0, 10),
      weeks: generated.totalWeeks, status: "active",
      assessment: {
        features, shape,
        distance: { label: goal.distance.label, meters: goal.distance.meters },
        preferences: prefs, started_week: goal.started_week,
        warnings: generated.warnings, notes: generated.notes,
        pace_basis: { source: basis.source, seconds: basis.seconds },
      },
      projected_finish_s: projected,
    }).select("id").single();
    if (pErr) { await cleanup(); throw pErr; }

    const weekRows = writes.weeks.map((w) => ({
      plan_id: plan.id, week_index: w.index, phase: w.phase,
      target_mileage: w.target, focus: w.focus,
    }));
    const { data: weekIds, error: wErr } = await supa.from("plan_weeks").insert(weekRows).select("id,week_index");
    if (wErr) { await cleanup(plan.id); throw wErr; }
    const weekIdByIndex = new Map((weekIds ?? []).map((w: { id: string; week_index: number }) => [w.week_index, w.id]));

    const sessionRows = writes.sessions.map((s) => {
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
    await retireOthers(plan.id);

    return Response.json({
      plan_id: plan.id,
      weeks: generated.totalWeeks,
      archetype: shape.archetype,
      rationale: shape.rationale,
      projected_finish_s: projected,
      start_weekly_mi: shape.start_weekly_mi,
      peak_weekly_mi: shape.peak_weekly_mi,
      plan_style: prefs.planStyle,
      distance: goal.distance.label,
      warnings: generated.warnings,
      goal_time_s,
      pace_basis: basis.source,
    });
  } catch (err) {
    console.error("plan error", err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});
