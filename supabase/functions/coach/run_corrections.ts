// Run corrections (#206): the coach reports what the athlete SAID; the app does the math.
//
// Rule 3, kept by David on 2026-10-15: numbers come from code, words come from the model.
// Before this, amend_run/add_run asked Claude for the FINAL corrected totals and an estimated
// HR, and the app wrote them into `runs` — where they feed the load model, readiness and the
// projection. Now the tools carry the athlete's own facts ("another 1.2 mi at 8:30", "the
// watch stopped 14 minutes early") and `ios/Tempo/Engine/RunCorrection.swift` computes the
// totals from the stored run.
//
// Both schemas live here because the app and this function ship separately. An installed
// build that predates #206 only knows totals, and sends no `features`; it keeps getting the
// totals tools and the prompt it was built against. A build that reads facts says so with
// RUN_FACTS_FEATURE. So deploying this function first breaks nothing, and an app build that
// lands first simply keeps receiving totals (which it still handles) until this deploys.

export const RUN_FACTS_FEATURE = "run_facts";

/** Whether the calling app reads fact-style run corrections. */
export function speaksRunFacts(features: unknown): boolean {
  return Array.isArray(features) && features.includes(RUN_FACTS_FEATURE);
}

// ── Totals (the schema every pre-#206 build understands) ─────────────────────────────────

const LEGACY_RULES = `- Runs in <athlete_context> carry an "id". When the athlete says logged data is wrong or incomplete (forgot to start the watch, treadmill run missing, etc.), propose the fix with the amend_run tool — use the exact id, and compute the FINAL corrected totals yourself (e.g. un-recorded miles get added to both distance and duration at the stated pace).
- For a run that was never recorded at all, propose add_run.
- Estimate missing values (like HR for an added segment) only from this athlete's own comparable data, conservatively, and say in the note what was estimated and how.`;

const LEGACY_TOOLS = [
  {
    name: "amend_run",
    description:
      "Propose a correction to an existing run's recorded data. Provide FINAL corrected values (not deltas). Only include fields that change.",
    input_schema: {
      type: "object",
      properties: {
        run_id: { type: "string", description: "The run's id, exactly as it appears in <athlete_context>." },
        distance_m: { type: "integer", description: "Corrected total distance in meters." },
        duration_s: { type: "integer", description: "Corrected total duration in seconds." },
        avg_hr: { type: "integer", description: "Corrected average heart rate, bpm." },
        note: { type: "string", description: "What changed, why, and what was estimated (and how)." },
        summary: { type: "string", description: "One line for the confirm card, with concrete numbers. e.g. 'Correct Tue's run: 6.0 → 8.0 mi, 55:12 → 1:15:12, avg HR est. 138'" },
      },
      required: ["run_id", "note", "summary"],
    },
  },
  {
    name: "add_run",
    description: "Propose logging a run that was never recorded.",
    input_schema: {
      type: "object",
      properties: {
        start_time: { type: "string", description: "ISO 8601 datetime the run started." },
        distance_m: { type: "integer" },
        duration_s: { type: "integer" },
        avg_hr: { type: "integer", description: "Only if the athlete stated it or it can be estimated from their own data; note the estimate." },
        note: { type: "string", description: "Provenance: why this is being added manually." },
        summary: { type: "string", description: "One line for the confirm card, with concrete numbers." },
      },
      required: ["start_time", "distance_m", "duration_s", "note", "summary"],
    },
  },
];

// ── Facts (#206) ─────────────────────────────────────────────────────────────────────────

const FACTS_RULES = `- Runs in <athlete_context> carry an "id". When the athlete says logged data is wrong or incomplete (forgot to start the watch, the watch stopped early, the treadmill distance was off), propose the fix with amend_run using the exact id.
- Run tools carry ONLY what the athlete told you, in their own numbers and unit. Never add, convert or estimate: no totals, no paces you worked out, no heart rate. The app computes the corrected distance, time and pace from the stored run and shows them on the confirm card.
  - Running the watch missed ("another 1.2 mi at 8:30"): added_distance, added_time and/or added_pace — whichever they gave.
  - "The watch stopped 14 minutes early": added_time "14:00", plus added_distance or added_pace if they said it. With only a time, the app counts it at the run's recorded pace and says so.
  - "It was really 6.0 miles", "it took 52:10": actual_distance, actual_time.
  - stated_avg_hr only for an average heart rate they read off another device. For added running, leave heart rate out: the app keeps the recorded average and labels it.
- For a run that was never recorded at all, propose add_run with whichever two of distance, time and pace they gave.
- A run card's summary names the facts, not totals: "Add 1.2 mi at 8:30/mi to Tuesday's run". Do not quote corrected totals in your message either; the card shows them.`;

const UNIT = {
  type: "string",
  enum: ["mi", "km"],
  description: "The unit the athlete stated distances and paces in.",
};
const CLOCK = (what: string) => ({
  type: "string",
  description: `${what}, as a clock string exactly as stated: "14:00" is 14 minutes, "1:05:30" is an hour and five. Always m:ss or h:mm:ss.`,
});

const FACT_TOOLS = [
  {
    name: "amend_run",
    description:
      "Propose a correction to an existing run, as the facts the athlete stated. Never totals: the app computes the corrected run from the stored one. Include only what they said.",
    input_schema: {
      type: "object",
      properties: {
        run_id: { type: "string", description: "The run's id, exactly as it appears in <athlete_context>." },
        unit: UNIT,
        added_distance: { type: "number", description: "Distance the watch missed, in unit (e.g. 1.2)." },
        added_time: CLOCK("Time the watch missed"),
        added_pace: CLOCK("Pace of the missed running, per unit"),
        actual_distance: { type: "number", description: "The run's true total distance, in unit, only when the athlete states it." },
        actual_time: CLOCK("The run's true total moving time, only when the athlete states it"),
        stated_avg_hr: { type: "integer", description: "An average heart rate the athlete read off another device. Never an estimate." },
        note: { type: "string", description: "What the athlete said was wrong, in plain words. No computed numbers." },
        summary: { type: "string", description: "One line for the confirm card naming the facts, e.g. 'Add 1.2 mi at 8:30/mi to Tuesday's run'." },
      },
      required: ["run_id", "unit", "note", "summary"],
    },
  },
  {
    name: "add_run",
    description:
      "Propose logging a run that was never recorded, from what the athlete stated: any two of distance, time and pace. The app computes the rest.",
    input_schema: {
      type: "object",
      properties: {
        start_time: { type: "string", description: "ISO 8601 datetime the run started." },
        unit: UNIT,
        distance: { type: "number", description: "Distance, in unit." },
        time: CLOCK("Moving time"),
        pace: CLOCK("Average pace, per unit"),
        stated_avg_hr: { type: "integer", description: "Only if the athlete stated it. Never an estimate." },
        note: { type: "string", description: "Provenance: why this is being added manually." },
        summary: { type: "string", description: "One line for the confirm card naming the facts, e.g. 'Log Saturday's 5 mi treadmill run, 42:30'." },
      },
      required: ["start_time", "unit", "note", "summary"],
    },
  },
];

/** The run-editing prompt lines and tools for the calling app. */
export function runEditing(features: unknown) {
  return speaksRunFacts(features)
    ? { rules: FACTS_RULES, tools: FACT_TOOLS }
    : { rules: LEGACY_RULES, tools: LEGACY_TOOLS };
}

// `based_on` is the app's pinned base (ChatStore.applyAmend), never the model's to send.
const DROPPED = ["distance_m", "duration_s", "avg_hr", "based_on"];
const NUMBERS = ["added_distance", "actual_distance", "distance", "stated_avg_hr"];
const STRINGS = ["unit", "added_time", "added_pace", "actual_time", "time", "pace"];

/**
 * The tool input as it goes to the app. For a facts client, a run card is scrubbed of any
 * total the model produced despite the schema — the app would take a lone total as a
 * pre-#206 card and write it, which is exactly the model arithmetic this exists to stop —
 * and of any fact with the wrong JSON type, which would otherwise fail the app's decode of
 * the whole reply. A scrubbed card the app can't compute shows why on the card instead.
 * Other tools, and every legacy client, pass through untouched.
 */
export function shapeRunInput(
  name: string | undefined,
  input: Record<string, unknown>,
  facts: boolean,
): Record<string, unknown> {
  if (!facts || (name !== "amend_run" && name !== "add_run")) return input;
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(input)) {
    if (DROPPED.includes(key)) continue;
    if (NUMBERS.includes(key) && (typeof value !== "number" || !Number.isFinite(value))) continue;
    if (STRINGS.includes(key) && typeof value !== "string") continue;
    out[key] = value;
  }
  if (typeof out.stated_avg_hr === "number") out.stated_avg_hr = Math.round(out.stated_avg_hr);
  return out;
}
