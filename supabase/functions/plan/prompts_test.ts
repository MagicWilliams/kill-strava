// The plan model copies how its prompt is written (#265), the same way the coach does, so
// these hold the prompt itself to the rules it gives the model. PLAN_VOICE is scanned
// separately because it has to name the banned words.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { PLAN_VOICE, SHAPE_TOOL, shapeSystemPrompt, type ShapePromptInput } from "./prompts.ts";
import { DISTANCES, DEFAULT_PREFERENCES, MI } from "./generator.ts";
import { extractFeatures } from "./features.ts";
import { stripDashes } from "../_shared/plain_text.ts";

const EM_DASH = "—";
/// Words the voice rules ban, which the prompt must therefore not model (coach/prompts_test.ts
/// guards the same list for the coach). "Honest" is here because the old rule line read
/// "Honest, not reckless", which taught the word and the contrast slogan in one breath.
const TAUGHT_WORDS = /niggl|honest|genuinely|lean into|worth noting|aerobic engine/i;

const FEATURES = extractFeatures([], DISTANCES.marathon.meters / MI);

function input(o: Partial<ShapePromptInput> = {}): ShapePromptInput {
  return {
    planWeeks: 15,
    taperWeeks: 2,
    firstWeekIndex: 0,
    weeksToRace: 15,
    daysPerWeek: 6,
    risk: "standard",
    distance: DISTANCES.marathon,
    distanceLabel: "marathon",
    raceMi: DISTANCES.marathon.meters / MI,
    raceName: "Spring Marathon",
    raceDate: "2027-04-18",
    goalTimeS: 4 * 3600,
    paceBasisSource: "goal",
    prefs: DEFAULT_PREFERENCES,
    projectedFinishS: 4 * 3600,
    features: FEATURES,
    ...o,
  };
}

/// Every prompt the plan function can build. Each branch writes its own prose, so each one is
/// checked rather than the default path only.
function everyPrompt(): Record<string, string> {
  const out: Record<string, string> = {
    tool: JSON.stringify(SHAPE_TOOL),
    default: shapeSystemPrompt(input()),
    // No target time: the "goal is to finish" line, from either basis.
    finish_fitness: shapeSystemPrompt(input({ goalTimeS: null, paceBasisSource: "fitness" })),
    finish_default: shapeSystemPrompt(input({ goalTimeS: null, paceBasisSource: "default" })),
    // No qualifying run, so no projection to quote.
    no_projection: shapeSystemPrompt(input({ projectedFinishS: null })),
    mid_block: shapeSystemPrompt(input({ firstWeekIndex: 8, planWeeks: 7, weeksToRace: 7 })),
    one_taper_week: shapeSystemPrompt(input({ taperWeeks: 1 })),
    big_long_runs: shapeSystemPrompt(input({ prefs: { ...DEFAULT_PREFERENCES, longRunsBig: 3 } })),
    ambitious: shapeSystemPrompt(input({ risk: "ambitious" })),
  };
  for (const key of ["1mi", "5k", "10k", "15k", "10mi", "half", "marathon"] as const) {
    const d = DISTANCES[key];
    out[`distance_${key}`] = shapeSystemPrompt(input({
      distance: d, distanceLabel: key, raceMi: d.meters / MI,
      taperWeeks: d.taperWeeks,
    }));
  }
  // A race whose distance is not in the table is described in miles.
  out.custom = shapeSystemPrompt(input({ distanceLabel: "custom", raceMi: 31.07 }));
  for (const courseType of ["flat", "rolling", "hilly", "trail"] as const) {
    out[`course_${courseType}`] = shapeSystemPrompt(input({
      prefs: { ...DEFAULT_PREFERENCES, courseType },
    }));
  }
  return out;
}

Deno.test("#265: no plan prompt contains an em dash", () => {
  for (const [name, text] of Object.entries(everyPrompt())) {
    // stripDashes() knows a range and a hyphenated word from a clause dash, so the prompt's
    // own "15–20" and "start→peak" are not false positives.
    assertEquals(stripDashes(text), text, name);
    assertEquals(text.includes(EM_DASH), false, name);
  }
  assertEquals(PLAN_VOICE.includes(EM_DASH), false);
});

Deno.test("#265: no plan prompt teaches the words the voice rules ban", () => {
  for (const [name, text] of Object.entries(everyPrompt())) {
    assertEquals(text.replace(PLAN_VOICE, "").match(TAUGHT_WORDS)?.[0], undefined, name);
  }
});

Deno.test("#265: the prompt and the tool both ask for plain text", () => {
  assert(shapeSystemPrompt(input()).includes(PLAN_VOICE), "the voice rules reach the model");
  assert(PLAN_VOICE.includes("Never use an em dash"), "and they name the dash rule");
  const props = SHAPE_TOOL.input_schema.properties;
  assert(props.rationale.description.includes("no em dash"));
  assert(props.phases.items.properties.focus.description.includes("no em dash"));
});

// The rest of this file pins the prompt that moved out of index.ts, so the extraction is
// checked rather than eyeballed. These are the lines the plan's arithmetic depends on: the
// model's phases must sum to the training weeks the handler computed, and the taper it is
// told to end with is the distance table's, not its own.
Deno.test("#265: the moved prompt still carries the numbers the handler computed", () => {
  const p = shapeSystemPrompt(input());
  assert(p.includes("phases[].weeks must sum to EXACTLY 15"));
  assert(p.includes("End with a taper of EXACTLY 2 weeks (race week excluded)"));
  assert(p.includes("weeks_until_race: 15"));
  assert(p.includes("days_per_week: 6"));
  assert(p.includes("(marathon, 26.2 mi) on 2027-04-18, target 4:00:00"));
  assert(p.includes("risk_tolerance: standard"));
  assert(p.includes("long_run_peak_mi ≤ 22"), "the marathon's long-run cap");
  assert(p.includes("peak_weekly_mi is typically 35–85"), "the marathon's volume band");

  const one = shapeSystemPrompt(input({ taperWeeks: 1 }));
  assert(one.includes("taper of EXACTLY 1 week (race week excluded)"), "singular");
  const mile = shapeSystemPrompt(input({ distance: DISTANCES["1mi"], distanceLabel: "1mi", raceMi: 1, taperWeeks: 0 }));
  assert(mile.includes("No taper phase: race week itself is the taper"));
  assert(mile.includes("Short race: speed and VO₂ work"));
});

Deno.test("#265: the moved prompt still refuses to invent a finish time", () => {
  const finish = shapeSystemPrompt(input({ goalTimeS: null, paceBasisSource: "fitness" }));
  assert(finish.includes("no target time, so the goal is to finish"));
  assert(finish.includes("derived from current fitness"));
  assert(finish.includes("do not invent a target in the rationale"));

  const fallback = shapeSystemPrompt(input({ goalTimeS: null, paceBasisSource: "default" }));
  assert(fallback.includes("a conservative default (no usable recent runs)"));

  // #205: with no projection stored, a finish time in the prose would be a made-up number.
  const none = shapeSystemPrompt(input({ projectedFinishS: null }));
  assert(none.includes("there is no projected finish"));
  assert(none.includes("Do not estimate, predict or quote a finish time"));
  assert(!shapeSystemPrompt(input()).includes("there is no projected finish"));
});

Deno.test("#265: the moved prompt still tells a mid-block athlete they are mid-block", () => {
  const mid = shapeSystemPrompt(input({ firstWeekIndex: 8, planWeeks: 7, weeksToRace: 7 }));
  assert(mid.includes("ALREADY in week 9 of this block"));
  assert(mid.includes("Phases cover only the remaining 7 weeks"));
  assert(!shapeSystemPrompt(input()).includes("ALREADY in week"));
});

Deno.test("#265: the moved prompt still passes on the course and the long runs asked for", () => {
  for (const courseType of ["rolling", "hilly"] as const) {
    const p = shapeSystemPrompt(input({ prefs: { ...DEFAULT_PREFERENCES, courseType } }));
    assert(p.includes(`Course is ${courseType}: the generator adds hill work`));
  }
  for (const courseType of ["flat", "trail"] as const) {
    assert(!shapeSystemPrompt(input({ prefs: { ...DEFAULT_PREFERENCES, courseType } })).includes("adds hill work"));
  }
  const big = shapeSystemPrompt(input({ prefs: { ...DEFAULT_PREFERENCES, longRunsBig: 3 } }));
  assert(big.includes("exactly 3 long runs of 20+ mi"));
  const one = shapeSystemPrompt(input({ prefs: { ...DEFAULT_PREFERENCES, longRunsBig: 1 } }));
  assert(one.includes("exactly 1 long run of 20+ mi"), "singular");
  // A 5K has no big-long-run mark, so the question is not put to the model at all.
  const short = shapeSystemPrompt(input({
    distance: DISTANCES["5k"], distanceLabel: "5k", raceMi: DISTANCES["5k"].meters / MI,
    prefs: { ...DEFAULT_PREFERENCES, longRunsBig: 3 },
  }));
  assert(!short.includes("long runs of"));
});
