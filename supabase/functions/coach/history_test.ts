// #193 — the coach's messages array must end in a user turn, or Anthropic rejects the whole
// request: "This model does not support assistant message prefill."
//
// The incident: 2026-10-15 07:41 and 07:45 UTC, two `coach.invoke_failed` rows on 0.1.0+68,
// each a 502 the client could say nothing useful about. The trigger is the plan-confirm
// acknowledgement — `ChatStore.confirm` appends the athlete's "Confirmed — …" turn and then
// the plan engine's narration as a coach turn, and the acknowledgement round trip sends that
// transcript as-is. Pinned here rather than in the function because the shape of the array is
// a decision, and the only symptom of getting it wrong is an opaque 502.

import { assertEquals } from "jsr:@std/assert@^1";
import { normalizeHistory, sanitizeHistory, type WireMessage } from "./history.ts";

const USER = (content: string): WireMessage => ({ role: "user", content });
const COACH = (content: string): WireMessage => ({ role: "assistant", content });

Deno.test("#193: a history that already ends in a user turn is sent unchanged", () => {
  const history = [
    USER("how did Tuesday look?"),
    COACH("Steady 6 at 8:42 — right where an easy day should sit."),
    USER("and Wednesday?"),
  ];
  assertEquals(sanitizeHistory(history), [
    { role: "user", content: "how did Tuesday look?" },
    { role: "assistant", content: "Steady 6 at 8:42 — right where an easy day should sit." },
    { role: "user", content: "and Wednesday?" },
  ]);
});

Deno.test("#193: the plan-confirm acknowledgement — trailing narration is dropped, the confirm stays", () => {
  // Exactly what ChatStore.confirm leaves in the transcript for a create_plan card.
  const history = [
    USER("I want to run the Turkey Trot"),
    COACH("5K on November 26. Here's the goal I'd target — confirm below."),
    USER("Confirmed — Save my goal: 5K at Turkey Trot, Nov 27, 19:30"),
    COACH("Built a 6-week block: 4 days a week, long run Saturday."),
  ];
  const sent = sanitizeHistory(history);
  assertEquals(sent.length, 3);
  assertEquals(sent[sent.length - 1], {
    role: "user",
    content: "Confirmed — Save my goal: 5K at Turkey Trot, Nov 27, 19:30",
  });
});

Deno.test("#193: several trailing coach turns collapse down to the last thing the athlete said", () => {
  const history = [
    USER("Dismissed — Build my plan"),
    COACH("Understood."),
    COACH("Tell me when you want to revisit it."),
  ];
  assertEquals(sanitizeHistory(history), [{ role: "user", content: "Dismissed — Build my plan" }]);
});

Deno.test("#193: nothing to answer comes back empty, for index.ts to 400 on", () => {
  // The empty case index.ts has always guarded — it stays guarded.
  assertEquals(sanitizeHistory([]), []);
  assertEquals(sanitizeHistory(null), []);
  assertEquals(sanitizeHistory(undefined), []);
  // A history with no athlete turn at all is the same situation: there is no question.
  assertEquals(sanitizeHistory([COACH("…"), COACH("…")]), []);
});

Deno.test("#193: a one-shot takeaway/block-review history is untouched", () => {
  // index.ts replaces the history with a single synthetic user turn for mode=takeaway and
  // mode=block_review, so sanitizing must be a no-op on it.
  assertEquals(sanitizeHistory([USER("Write the coach's takeaway…")]), [
    { role: "user", content: "Write the coach's takeaway…" },
  ]);
});

Deno.test("#193: role mapping is unchanged — only an exact \"assistant\" is the coach", () => {
  assertEquals(
    normalizeHistory([{ role: "coach", content: "a" }, { role: "Assistant", content: "b" }, { role: "", content: "c" }])
      .map((m) => m.role),
    ["user", "user", "user"],
  );
  // ...which means a history ending in one of those is a user turn and survives sanitizing.
  assertEquals(sanitizeHistory([USER("hi"), { role: "coach", content: "x" }]).length, 2);
});

Deno.test("#193: content is still coerced to a string", () => {
  const odd = [{ role: "user", content: 12 as unknown as string }];
  assertEquals(sanitizeHistory(odd), [{ role: "user", content: "12" }]);
});
