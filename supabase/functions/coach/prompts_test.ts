// The coach copies how its prompt is written (#264), so these hold the prompt itself to the
// rules it gives the model. VOICE is scanned separately because it has to name the banned words.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { goalLifecycle, END_GOAL_FEATURE } from "./goal_lifecycle.ts";
import { HELD_BACK_PLAN } from "./goal_guard.ts";
import { ACKNOWLEDGE_RULES } from "./proposals.ts";
import {
  BLOCK_REVIEW_INSTRUCTIONS,
  CONFIRM_BELOW_REPLY,
  LOST_THREAD_REPLY,
  OTHER_TOOLS,
  persona,
  SUMMARIZE_INSTRUCTIONS,
  TAKEAWAY_INSTRUCTIONS,
  TOOL_RESULT_PROPOSED,
  TOOL_RESULT_RECORDED,
  VOICE,
} from "./prompts.ts";
import { RUN_FACTS_FEATURE, runEditing } from "./run_corrections.ts";

const EM_DASH = "—";
const TAUGHT_WORDS = /niggl|honest|genuinely|lean into/i;

function everyPrompt(): Record<string, string> {
  const out: Record<string, string> = {
    takeaway: TAKEAWAY_INSTRUCTIONS,
    block_review: BLOCK_REVIEW_INSTRUCTIONS,
    summarize: SUMMARIZE_INSTRUCTIONS,
    tools: JSON.stringify(OTHER_TOOLS),
    recorded: TOOL_RESULT_RECORDED,
    proposed: TOOL_RESULT_PROPOSED,
    lost_thread: LOST_THREAD_REPLY,
    confirm_below: CONFIRM_BELOW_REPLY,
    held_back: HELD_BACK_PLAN,
    acknowledge: ACKNOWLEDGE_RULES,
  };
  // Every client gets a different combination of these, so each one is checked.
  for (const features of [[], [RUN_FACTS_FEATURE, END_GOAL_FEATURE]]) {
    const runs = runEditing(features);
    const goals = goalLifecycle(features);
    const name = features.length === 0 ? "legacy" : "current";
    out[`persona_${name}`] = persona(runs.rules, goals.rules).replace(VOICE, "");
    out[`run_tools_${name}`] = JSON.stringify(runs.tools);
    out[`goal_tools_${name}`] = JSON.stringify(goals.tools);
  }
  return out;
}

Deno.test("no prompt contains an em dash", () => {
  for (const [name, text] of Object.entries(everyPrompt())) {
    assertEquals(text.includes(EM_DASH), false, name);
  }
  assertEquals(VOICE.includes(EM_DASH), false);
});

Deno.test("no prompt teaches the words the voice rules ban", () => {
  for (const [name, text] of Object.entries(everyPrompt())) {
    assertEquals(text.match(TAUGHT_WORDS)?.[0], undefined, name);
  }
});

Deno.test("the persona carries the voice rules", () => {
  const runs = runEditing([]);
  const goals = goalLifecycle([]);
  assert(persona(runs.rules, goals.rules).includes(VOICE));
});

// TakeawayReply.fallbackPrefix in the app. A build that stops recognizing this line caches it
// as the run's takeaway, which is the bug #137 fixed.
Deno.test("the fallback line keeps the prefix installed apps match on", () => {
  assert(LOST_THREAD_REPLY.startsWith("Lost my train of thought"));
});
