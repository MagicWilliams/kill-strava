// The {title, summary} a finished thread is written up as (#87), parsed out of the model's
// reply.
//
// Pure, for the same reason history.ts is: this decides the SHAPE of what the app stores, and
// every way it fails is silent. A thread summary is written to `coach_threads` once and then
// read for months — by the athlete, on the Coach tab, and by the coach itself as the
// "Picking up from" line of the next conversation. A recap that is actually a fenced code
// block, or the word "null", or four paragraphs of prose, is not a crash: it is a wrong
// sentence on a card, carried forward as fact.
//
// So nothing half-parsed is ever returned. The caller stores a summary or asks again next
// time; `ChatStore` treats an absent one as "not summarized yet", which is a state the thread
// list already knows how to show (Engine/CoachThreads.swift).

/// What the summarize pass returns. Both fields are non-empty by construction.
export interface ThreadSummary {
  title: string;
  summary: string;
}

/// Hard ceilings, enforced here rather than trusted to the prompt.
///
/// The title sits on one line of a thread row and the summary is clamped to two, so a model
/// that ignores "six words" costs a truncated card and not a broken layout. Clipped on a word
/// boundary, never mid-word: a recap ending "and the ca" reads like data loss.
export const TITLE_LIMIT = 60;
export const SUMMARY_LIMIT = 240;

/// Pull the JSON object out of a reply that may be fenced, prefaced, or both.
///
/// The model is asked for bare JSON and usually sends it. ```json fences are the common
/// deviation; a leading "Here's the summary:" is the other. Both are recoverable, and
/// recovering them is cheaper than a second round trip.
function jsonObject(text: string): unknown {
  const unfenced = text
    .replace(/^\s*```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/, "")
    .trim();
  const candidates = [unfenced];
  const first = unfenced.indexOf("{");
  const last = unfenced.lastIndexOf("}");
  if (first >= 0 && last > first) candidates.push(unfenced.slice(first, last + 1));
  for (const candidate of candidates) {
    try {
      return JSON.parse(candidate);
    } catch {
      continue;
    }
  }
  return null;
}

/// One line of prose: whitespace collapsed, clipped to `limit` on a word boundary.
function line(value: unknown, limit: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.replace(/\s+/g, " ").trim();
  if (!text) return null;
  if (text.length <= limit) return text;
  const head = text.slice(0, limit);
  const cut = head.lastIndexOf(" ");
  return (cut > limit / 2 ? head.slice(0, cut) : head).trimEnd() + "…";
}

/// The model's reply → a summary worth storing, or null.
///
/// Null covers everything that is not both fields present and non-empty: unparseable text, a
/// missing key, a null, a number, "" or "   ". The thread then stays unsummarized and is
/// offered to the next pass — which is the honest outcome, because a thread with a made-up
/// recap looks exactly like one with a real recap.
export function parseThreadSummary(reply: string | null | undefined): ThreadSummary | null {
  if (!reply) return null;
  const parsed = jsonObject(reply);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const record = parsed as Record<string, unknown>;
  const title = line(record.title, TITLE_LIMIT);
  const summary = line(record.summary, SUMMARY_LIMIT);
  if (!title || !summary) return null;
  return { title, summary };
}
