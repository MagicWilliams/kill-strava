// Everything the plan model is told, and the tool it answers in (#265).
//
// In its own file for the same reason as coach/prompts.ts: index.ts starts the server on
// import, so a test cannot load it. The model copies how its prompt is written, and the two
// fields it writes are both read by the athlete: the rationale shown beside the projection,
// and each phase's focus line, which the generator copies onto every week that phase covers.
// An em dash or a catchphrase in the text below comes back out in a stored plan, which is
// why prompts_test.ts holds this file to the rules it gives the model.

import { type DistanceProfile, fmtClock, type PaceBasis, type Preferences } from "./generator.ts";
import { type Features, QUALIFYING_MI } from "./features.ts";

/// How the model writes the two fields an athlete reads. Shorter than the coach's VOICE
/// because this model writes two lines, not a conversation, and the words listed are the ones
/// that mark text as machine-written.
///
/// The dash rule is repeated here and enforced afterwards by stripDashes(): telling a model
/// not to use em dashes helps but does not hold (see _shared/plain_text.ts). The banned WORDS
/// have only this lever, because swapping a word in a finished sentence produces garbage.
export const PLAN_VOICE = `How to write the rationale and the focus lines:
- Plain, everyday words and short sentences, the way a good coach talks at the track. No hype, no exclamation marks, no emoji.
- Never use an em dash. Use a period or a comma. Do not use a hyphen or en dash in its place between clauses. Number ranges are fine.
- Do not announce your candor. Never write frankly, truly, or "to be clear". Just say the thing.
- Do not use these words or phrases: worth noting, worth flagging, signal, noise, aerobic engine, rhythm, lands, delve, nuance, testament, journey, landscape, navigate, leverage, unlock, elevate, holistic, robust, crucial. Do not use "real" or "actual" as intensifiers ("a real jump").
- No contrast slogans such as "X, not Y" or "it's not X, it's Y". Say what is true.
- No aphorisms, and no one-line closers that sound like a poster. Say what the numbers show and what this block does about it.`;

// ── Shape proposal (Claude, forced tool) ─────────────────────────────────────
export const SHAPE_TOOL = {
  name: "propose_plan_shape",
  description: "Propose the training-plan shape for this athlete. Phases emerge from what the DATA says is missing. Never force a fixed template. If the athlete is already aerobically fit, skip or shrink base. Anchor start volume on their real current volume.",
  input_schema: {
    type: "object",
    properties: {
      archetype: { type: "string", enum: ["rebuild_base", "progressive_build", "race_specific", "sharpen"] },
      rationale: { type: "string", description: "2-3 sentences, grounded in the features, written to the athlete. Plain words, no em dash." },
      phases: {
        type: "array",
        description: "In order, covering every training week (taper included, race week excluded).",
        items: {
          type: "object",
          properties: {
            name: { type: "string", enum: ["base", "build", "peak", "taper"] },
            weeks: { type: "integer", minimum: 1 },
            focus: { type: "string", description: "One line, athlete-facing. Plain words, no em dash." },
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

export interface ShapePromptInput {
  /// TRAINING weeks the phases must sum to: race week is the generator's, not the model's.
  planWeeks: number;
  taperWeeks: number;
  /// Mid-block (#102): 0 when the athlete starts at week 1.
  firstWeekIndex: number;
  weeksToRace: number;
  daysPerWeek: number;
  risk: string;
  distance: DistanceProfile;
  distanceLabel: string;
  raceMi: number;
  raceName: string | null;
  raceDate: string;
  goalTimeS: number | null;
  paceBasisSource: PaceBasis["source"];
  prefs: Preferences;
  /// Riegel current fitness at the race distance, or null when no run qualifies.
  projectedFinishS: number | null;
  features: Features;
}

/// The system prompt for the forced shape call. Pure, so prompts_test.ts can read the real
/// thing rather than a copy that drifts from it.
export function shapeSystemPrompt(a: ShapePromptInput): string {
  const targetLine = a.goalTimeS != null
    ? `target ${fmtClock(a.goalTimeS)}`
    : `no target time, so the goal is to finish. Training paces are derived from ${
      a.paceBasisSource === "fitness" ? "current fitness" : "a conservative default (no usable recent runs)"
    }, not a goal; do not invent a target in the rationale`;

  const bigMark = a.distance.bigLongRunMi;
  const raceLines = [
    `- This is a ${a.distanceLabel === "custom" ? `${a.raceMi.toFixed(1)}-mile` : a.distanceLabel} race block. ${
      a.raceMi <= 6.3
        ? "Short race: speed and VO₂ work matter more than long-run length."
        : "Endurance race: threshold work and long runs carry the block."
    }`,
    a.taperWeeks === 0
      ? `- No taper phase: race week itself is the taper for this distance. The last phase ends the week before race week.`
      : `- End with a taper of EXACTLY ${a.taperWeeks} week${a.taperWeeks === 1 ? "" : "s"} (race week excluded).`,
    `- peak_weekly_mi is typically ${a.distance.peakBandMi[0]}–${a.distance.peakBandMi[1]} for this distance; above ${a.distance.peakBandMi[1]} only if vol_4wk_avg_mi is already higher. long_run_peak_mi ≤ ${a.distance.longRunCapMi}.`,
    a.firstWeekIndex > 0
      ? `- The athlete is ALREADY in week ${a.firstWeekIndex + 1} of this block. Phases cover only the remaining ${a.planWeeks} weeks; start_weekly_mi = vol_4wk_avg_mi exactly (they are mid-block, not starting).`
      : null,
    bigMark != null && a.prefs.longRunsBig != null
      ? `- The athlete wants exactly ${a.prefs.longRunsBig} long run${a.prefs.longRunsBig === 1 ? "" : "s"} of ${bigMark}+ mi; the generator places them in the peak phase, so size peak to hold them.`
      : null,
    a.prefs.courseType === "rolling" || a.prefs.courseType === "hilly"
      ? `- Course is ${a.prefs.courseType}: the generator adds hill work to base/build.`
      : null,
    // The rationale is shown beside the projection; with none stored, a finish time in the
    // prose would be the same made-up number #205 removed from the column.
    a.projectedFinishS == null
      ? `- No run of ${QUALIFYING_MI}+ mi in the last 8 weeks, so there is no projected finish. Do not estimate, predict or quote a finish time for the athlete in the rationale.`
      : null,
  ].filter(Boolean).join("\n");

  return `You design the SHAPE of a running plan for Tempo. The athlete's real data and constraints are below. Rules:
- Phases emerge from what the data says is missing. An already-fit athlete does NOT get sent back to base. A rebuilding athlete gets mostly aerobic work.
- phases[].weeks must sum to EXACTLY ${a.planWeeks}.
- Anchor start_weekly_mi on vol_4wk_avg_mi (at most ~15% above it; ambitious risk_tolerance may stretch to ~25%).
- Ramp start→peak must stay plausible for ${a.planWeeks} weeks (~10%/wk standard, ~15%/wk ambitious); the generator adds step-back weeks automatically.
${raceLines}
- long_run_peak_mi ≤ 35% of peak_weekly_mi and ≤ roughly double longest_run_8wk_mi.
- risk_tolerance: ${a.risk}. The rationale says what the data supports, and no more than that.

${PLAN_VOICE}

<athlete>
goal: ${a.raceName ?? "race"} (${a.distanceLabel}, ${a.raceMi.toFixed(1)} mi) on ${a.raceDate}, ${targetLine}
weeks_until_race: ${a.weeksToRace}
days_per_week: ${a.daysPerWeek}
features: ${JSON.stringify(a.features, null, 1)}
</athlete>`;
}
