// #238 — tune-ups and dropping a race.
//
// What these pin is the deploy-order contract again (#206): the build David has installed
// sends `features: ["run_facts"]` and has no idea what an end_goal card is. If this function
// offered it the tool anyway, "I'm not racing it anymore" would come back as a card whose
// Confirm fails with "Unknown action type". So end_goal exists only for a build that asks.

import { assert, assertEquals } from "jsr:@std/assert@^1";
import { END_GOAL_FEATURE, goalLifecycle, RACE_ROLE_PROPERTY, speaksEndGoal } from "./goal_lifecycle.ts";
import { RUN_FACTS_FEATURE } from "./run_corrections.ts";

Deno.test("#238: a build that doesn't send end_goal is never offered the tool or told it exists", () => {
  for (const features of [undefined, null, [], [RUN_FACTS_FEATURE], "end_goal", { end_goal: true }]) {
    assertEquals(speaksEndGoal(features), false, `features=${JSON.stringify(features)}`);
    const { tools, rules } = goalLifecycle(features);
    assertEquals(tools.length, 0, `features=${JSON.stringify(features)}`);
    assert(!rules.includes("end_goal"), "a prompt naming a tool the model can't call invites a made-up one");
  }
});

Deno.test("#238: a build that sends end_goal gets the tool, through the confirm card like every write", () => {
  const { tools, rules } = goalLifecycle([RUN_FACTS_FEATURE, END_GOAL_FEATURE]);
  assertEquals(tools.map((t) => t.name), ["end_goal"]);
  const schema = tools[0].input_schema;
  assertEquals(Object.keys(schema.properties).sort(), ["reason", "summary"]);
  // reason is optional: "I'm not racing it" is enough on its own.
  assertEquals(schema.required, ["summary"]);
  assert(rules.includes("end_goal"));
  assert(rules.includes("Today goes back to just running"));
});

Deno.test("#238: the tune-up rule reaches every build; race_role is goal | tune_up", () => {
  // Not gated: a pre-#238 build decodes a create_plan card and drops the key it doesn't know.
  for (const features of [undefined, [RUN_FACTS_FEATURE, END_GOAL_FEATURE]]) {
    assert(goalLifecycle(features).rules.includes('race_role "tune_up"'));
  }
  assertEquals(RACE_ROLE_PROPERTY.enum, ["goal", "tune_up"]);
});

Deno.test("#238: the prompt lines name nobody", () => {
  // The coach is talking to whoever's data is in <athlete_context>; rules say "the athlete".
  const { rules } = goalLifecycle([END_GOAL_FEATURE]);
  for (const name of ["David", " he ", " his ", " him "]) {
    assert(!rules.includes(name), `rules must not say ${JSON.stringify(name)}`);
  }
});
