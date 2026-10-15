// #206 — the coach reports what the athlete said; the app computes the corrected run.
//
// What these pin is the deploy-order contract: the function and the app ship separately, so
// the build David has installed (which sends no `features` and only understands totals) must
// keep getting the totals schema from a function that has learned facts, and a facts client
// must never be handed a total the model computed.

import { assert, assertEquals } from "jsr:@std/assert@^1";
import { RUN_FACTS_FEATURE, runEditing, shapeRunInput, speaksRunFacts } from "./run_corrections.ts";

type Tool = { name: string; input_schema: { properties: Record<string, unknown>; required: string[] } };
const tool = (tools: Tool[], name: string) => tools.find((t) => t.name === name)!;

Deno.test("#206: an installed pre-#206 build (no features) keeps the totals schema it was built against", () => {
  for (const features of [undefined, null, [], ["something_else"], "run_facts"]) {
    assertEquals(speaksRunFacts(features), false, `features=${JSON.stringify(features)}`);
    const { tools, rules } = runEditing(features);
    const amend = tool(tools, "amend_run");
    const add = tool(tools, "add_run");
    assert("distance_m" in amend.input_schema.properties);
    assert("duration_s" in amend.input_schema.properties);
    // The old app's applyAdd refuses a card without these two, so they stay required.
    assertEquals(add.input_schema.required.includes("distance_m"), true);
    assertEquals(add.input_schema.required.includes("duration_s"), true);
    assert(rules.includes("compute the FINAL corrected totals yourself"));
  }
});

Deno.test("#206: a facts build gets tools with no totals and no HR estimate in them", () => {
  const { tools, rules } = runEditing([RUN_FACTS_FEATURE]);
  for (const name of ["amend_run", "add_run"]) {
    const props = Object.keys(tool(tools, name).input_schema.properties);
    for (const total of ["distance_m", "duration_s", "avg_hr"]) {
      assert(!props.includes(total), `${name} must not offer ${total}`);
    }
    assert(props.includes("unit"));
    assert(props.includes("stated_avg_hr"));
  }
  const amendProps = Object.keys(tool(tools, "amend_run").input_schema.properties);
  for (const fact of ["added_distance", "added_time", "added_pace", "actual_distance", "actual_time"]) {
    assert(amendProps.includes(fact), `amend_run offers ${fact}`);
  }
  assert(!rules.includes("compute the FINAL corrected totals yourself"));
  assert(!rules.includes("Estimate missing values"));
});

Deno.test("#206: a facts card is scrubbed of any total the model sent anyway", () => {
  const shaped = shapeRunInput("amend_run", {
    run_id: "r1",
    unit: "mi",
    added_distance: 1.2,
    added_pace: "8:30",
    distance_m: 11587, // the model's own arithmetic, despite the schema
    duration_s: 3612,
    avg_hr: 141,
    based_on: { distance_m: 1, duration_s: 1 },
    note: "Forgot to restart the watch after the light.",
  }, true);
  assertEquals(shaped, {
    run_id: "r1",
    unit: "mi",
    added_distance: 1.2,
    added_pace: "8:30",
    note: "Forgot to restart the watch after the light.",
  });
});

Deno.test("#206: a fact with the wrong JSON type is dropped rather than failing the app's decode", () => {
  const shaped = shapeRunInput("add_run", {
    start_time: "2026-10-14T12:00:00Z",
    unit: "km",
    run_distance: "8", // a string where the app decodes a number would fail the whole reply
    run_time: 2400, // a number where the app decodes a clock string
    run_pace: "5:00",
    distance: 8, // create_plan's race key (#184), a string in the app: never on a run card
    stated_avg_hr: 151.6,
  }, true);
  assertEquals(shaped, { start_time: "2026-10-14T12:00:00Z", unit: "km", run_pace: "5:00", stated_avg_hr: 152 });
});

Deno.test("#206: legacy clients and other tools pass through untouched", () => {
  const legacy = { run_id: "r1", distance_m: 12875, duration_s: 4512, avg_hr: 141, note: "n" };
  assertEquals(shapeRunInput("amend_run", legacy, false), legacy);
  const session = { session_id: "s1", target_distance_m: 8000, note: "n" };
  assertEquals(shapeRunInput("update_session", session, true), session);
});
