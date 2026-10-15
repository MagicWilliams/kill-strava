// The messages array the coach actually sends Anthropic — the app's chat history, normalized.
//
// Pure, for the same reason plan/goal.ts is: this decides the SHAPE of the request, index.ts
// does the I/O, and the failure here is silent to the client — a bare `anthropic 502` in the
// one feature CLAUDE.md calls the most deploy-sensitive in the app.
//
// 2026-10-15 (#193): two `coach.invoke_failed` rows, four minutes apart, each a 502 wrapping
//
//     anthropic error 400 {"type":"invalid_request_error","message":"This model does not
//     support assistant message prefill. The conversation must end with a user message."}
//
// The history the app sent ended in an ASSISTANT turn, so Anthropic rejected the request
// outright. The path, which #193 could not pin: `ChatStore.confirm` appends
// "Confirmed — <summary>" as the user turn, then — for `create_plan` and
// `update_plan_settings`, the two actions that return a narration — appends the plan engine's
// narration as a COACH turn. `acknowledgeIfWarranted` then builds its history from
// `messages.suffix(24)`. Every plan-confirm acknowledgement was asking Claude to continue its
// own last sentence.
//
// Dropping trailing assistant turns heals that rather than merely naming it: what is left
// ends on "Confirmed — Save my goal: 5K at Turkey Trot", which is the turn the
// acknowledgement was always meant to answer. The narration drops out of the transcript the
// model sees, but what it narrates — the plan — is in <athlete_context>, re-read from the
// database before this call is made.

/// A turn as the app sends it. `role` is whatever came over the wire, not a checked union.
export interface WireMessage {
  role: string;
  content: string;
}

export interface AnthropicMessage {
  role: "user" | "assistant";
  content: string;
}

/// Role mapping, unchanged since the first version of this function: anything that is not
/// exactly "assistant" is the athlete talking. Kept as its own step so the trailing-turn rule
/// below is applied to the roles Anthropic will actually see, not the ones the app sent.
export function normalizeHistory(raw: readonly WireMessage[]): AnthropicMessage[] {
  return raw.map((m) => ({
    role: m.role === "assistant" ? "assistant" : "user",
    content: String(m.content),
  }));
}

/// The array to send: normalized, with trailing assistant turns removed so it ends on a real
/// user turn.
///
/// Empty means there is nothing for the coach to answer — a history that is all assistant, or
/// no history at all. The caller returns a named 400 instead of spending an Anthropic request
/// to be told the same thing in a shape the client can only report as a 502.
export function sanitizeHistory(raw: readonly WireMessage[] | null | undefined): AnthropicMessage[] {
  const msgs = normalizeHistory(raw ?? []);
  let end = msgs.length;
  while (end > 0 && msgs[end - 1].role === "assistant") end -= 1;
  return msgs.slice(0, end);
}
