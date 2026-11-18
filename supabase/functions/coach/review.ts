// The weekly review (#91) as the app stores it, parsed out of the model's reply.
//
// Pure, and strict for the same reason `summary.ts` is: this decides the SHAPE of something
// written once and then read for months. A review with its three sections collapsed into one,
// or a headline that is actually the word "null", is not a crash — it is a screen with two
// empty headings on it, and nothing to say which week went wrong.
//
// So nothing half-parsed is returned. The caller stores a whole review or stores nothing and
// leaves the week unreviewed, which is a state the app already shows (no row, no dot).

import { jsonObject, line } from "./summary.ts";

/// What the `review` mode returns. Every field is non-empty by construction.
export interface WeeklyReview {
  /// The one line at the top of the screen: what the week amounted to.
  headline: string;
  /// What the running itself was.
  training: string;
  /// What moved in the plan, and why — the prose beside the ledger link.
  plan_moved: string;
  /// What is coming, and what to do about it.
  next_week: string;
}

/// Hard ceilings, enforced here rather than trusted to the prompt.
///
/// The headline sits in two lines of display type at the top of the screen; each section is
/// one paragraph the athlete reads on a phone. A model that ignores "two sentences" costs a
/// clipped paragraph, not a broken layout, and the clip lands on a word boundary.
export const HEADLINE_LIMIT = 160;
export const SECTION_LIMIT = 700;

/// The model's reply → a review worth storing, or null.
///
/// Null covers everything that is not all four fields present and non-empty: unparseable
/// text, a missing section, a null, a number, "" or "   ". A week with no review is offered
/// again the next time Coach home opens, which is the honest outcome — a review with an
/// invented section reads exactly like one the coach wrote.
export function parseWeeklyReview(reply: string | null | undefined): WeeklyReview | null {
  if (!reply) return null;
  const parsed = jsonObject(reply);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const record = parsed as Record<string, unknown>;
  const headline = line(record.headline, HEADLINE_LIMIT);
  const training = line(record.training, SECTION_LIMIT);
  const planMoved = line(record.plan_moved, SECTION_LIMIT);
  const nextWeek = line(record.next_week, SECTION_LIMIT);
  if (!headline || !training || !planMoved || !nextWeek) return null;
  return { headline, training, plan_moved: planMoved, next_week: nextWeek };
}
