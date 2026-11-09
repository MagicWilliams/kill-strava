// How large one call to `coach` or `plan` may be.
//
// `claim_usage` bounds how many calls a user makes, but the client decides what is in each one,
// and `coach` hands `messages`, `context`, `run` and `block` to the model. A refusal here comes
// before the claim and before Anthropic, so it spends nothing and counts against nothing.

/**
 * The most a request may be, in bytes. Sized so a real athlete never reaches it: refusing the
 * coach someone is training with costs far more than the tokens this saves.
 *
 * `coach`: the largest thing the app builds is `summarize`, up to `ChatHistory.pageSize` (200)
 * messages plus the whole athlete context. Even if every one of those messages were 1,500 bytes,
 * and the context were at the app's own ceilings (60 memory facts, doubles every day for 21 days
 * with a 500-character note on each), it comes to about 400 KB. supabase/tests pins that.
 *
 * `plan`: a goal card and the intake's preferences, so its largest part is what the athlete
 * typed in the intake's notes. Only `race_name` and `race_date` reach the model, but those are
 * whatever the request says they are.
 */
export const MAX_REQUEST_BYTES = {
  coach: 512 * 1024,
  plan: 64 * 1024,
} as const;

/**
 * The request's body as text, or null if it is over `limit`.
 *
 * Counts what actually arrives and stops reading there. Content-Length only gets to refuse
 * early: the caller writes that header, and a chunked request doesn't have one.
 */
export async function readBodyWithin(req: Request, limit: number): Promise<string | null> {
  const declared = Number(req.headers.get("content-length"));
  if (declared > limit) return null;
  if (!req.body) return "";

  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.length;
    if (received > limit) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder().decode(bytes);
}

/**
 * How many bytes of prompt Anthropic would be sent.
 *
 * The body's size doesn't bound this. The coach pretty-prints `context`, `run` and `block` into
 * the system prompt, and that indentation grows with depth: a 10 KB body of nested arrays
 * renders to 25 MB. So `coach` measures the prompt too, against the same limit. Nesting deeper
 * than that overflows the stack in `JSON.stringify`, which lands in the handler's catch, and
 * that spends nothing either.
 */
export function promptBytes(system: string, messages: unknown): number {
  const encoder = new TextEncoder();
  return encoder.encode(system).length + encoder.encode(JSON.stringify(messages)).length;
}

/**
 * The words the athlete reads. Like the usage limit's, they say what happened and that nothing
 * was lost, so they can't be mistaken for a dead connection. They also say what to do, because
 * unlike a limit this doesn't end on its own.
 *
 * One line per function and not per mode: a body over the limit is refused unparsed, so `coach`
 * can't know which mode it was, and these words have to be true on every screen.
 */
export const TOO_LARGE_MESSAGE: Record<keyof typeof MAX_REQUEST_BYTES, string> = {
  coach:
    "That's more than the coach can read at once. If this is a long conversation, starting a new one will clear it. Your data is saved, and this isn't a connection problem.",
  plan:
    "That goal is more than the plan engine can read at once. Ask the coach to propose it again. Your existing plan wasn't changed.",
};

/** The refusal. The app recognizes `request_too_large` by name, as it does `usage_limited`. */
export function tooLargeResponse(fn: keyof typeof MAX_REQUEST_BYTES): Response {
  // Never the body itself: it is the athlete's words. Worth finding in the logs, because if a
  // real athlete ever lands here the cap is wrong.
  console.warn("request too large", fn);
  return Response.json(
    { error: "request_too_large", message: TOO_LARGE_MESSAGE[fn] },
    { status: 413 },
  );
}
