// What a race is for, and how a goal ends early (#238; David's calls 1A and 3A on #232).
//
// On 15 Oct the athlete told the coach the Turkey Trot was a tune-up. Nothing could store
// that, so the app could never say it. Once a goal existed there was also no way to drop it:
// a block ended by being raced and closed out, or by being replaced with a new create_plan.
// "I'm not racing it anymore" had no path back to just running (#101).
//
// - race_role rides on create_plan and lands in goals.preferences.race_role (jsonb, so no
//   migration). It is not gated: an installed build that predates it decodes the card and
//   ignores the key, the same as any field it doesn't know.
// - end_goal is a new card type, and an installed build that predates it would show it as
//   "Unknown action type" and fail the Confirm. So it is offered only to a build that says it
//   handles it (END_GOAL_FEATURE), the same handshake run_facts uses (#206). Like every write,
//   the card is the athlete's consent and the app does the write. This function writes
//   nothing.

export const END_GOAL_FEATURE = "end_goal";

/** Whether the calling app can apply an end_goal card. */
export function speaksEndGoal(features: unknown): boolean {
  return Array.isArray(features) && features.includes(END_GOAL_FEATURE);
}

/** create_plan's race_role property. Missing means "goal". */
export const RACE_ROLE_PROPERTY = {
  type: "string",
  enum: ["goal", "tune_up"],
  description:
    "What this race is for. \"tune_up\" when the athlete calls it a tune-up: a race run on the way to a bigger goal rather than the goal itself. Leave it out for the race they are building toward.",
};

const RACE_ROLE_RULES = `- A tune-up is a race the athlete runs on the way to a bigger goal, not the goal itself. When they call a race a tune-up, set race_role "tune_up" on create_plan. goal_detail.preferences.race_role "tune_up" means the active race is one: treat it as a hard effort inside the training, not the peak of the block. If they say a tune-up has become the race they care about, propose create_plan with race_role "goal".`;

const END_GOAL_RULES = `- When the athlete says they are no longer racing the active goal or want to stop training for it ("I'm not racing it anymore", "drop the race"), call end_goal. On confirm the app closes the goal and its plan; their runs stay, and Today goes back to just running. A new date, distance or target is create_plan, not end_goal; a lighter week is update_session or update_plan_settings. Never call it unprompted, and only when <athlete_context> has a plan or goal to end.
- When mode is "race_passed" and they ran the race, end_goal is not the path: the "review your block" card on Today records the result. end_goal is for a race they will not run, or did not.`;

const END_GOAL_TOOL = {
  name: "end_goal",
  description:
    "Retire the active goal and its plan when the athlete says they are not racing it anymore. Their runs stay; the app returns them to just running after they confirm.",
  input_schema: {
    type: "object",
    properties: {
      reason: { type: "string", description: "Why they are dropping it, in their words, condensed. Omit if they gave none." },
      summary: { type: "string", description: "One line for the confirm card, e.g. 'End my Turkey Trot plan'." },
    },
    required: ["summary"],
  },
};

/** The goal-lifecycle prompt lines and tools for the calling app. */
export function goalLifecycle(features: unknown) {
  return speaksEndGoal(features)
    ? { rules: `${RACE_ROLE_RULES}\n${END_GOAL_RULES}`, tools: [END_GOAL_TOOL] }
    : { rules: RACE_ROLE_RULES, tools: [] as typeof END_GOAL_TOOL[] };
}
