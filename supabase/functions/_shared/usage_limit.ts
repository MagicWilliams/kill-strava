// What a per-user usage claim means, and what the athlete is told when it is refused.
//
// The limits themselves live in the `usage_limits` table and the check-and-count in the
// `claim_usage` function (migration 0024), because only one transaction can stop concurrent
// calls from all slipping through. This file is the part that decides what to do with the
// answer, kept pure because its worst mistake would be silent: reading a refusal as a pass
// leaves the bill unbounded, and reading a limiter fault as a refusal takes the coach down.

export type UsageKind = "chat" | "takeaway" | "block_review" | "summarize" | "plan";

/** Every kind a function can claim. Each must have rows in `usage_limits`. */
export const USAGE_KINDS: readonly UsageKind[] = ["chat", "takeaway", "block_review", "summarize", "plan"];

/** Which allowance a `coach` request draws on. No mode, or one we don't know, is a chat turn. */
export function usageKindForMode(mode: unknown): UsageKind {
  if (mode === "takeaway" || mode === "block_review" || mode === "summarize") return mode;
  return "chat";
}

/** The fields of a supabase-js `rpc` result that matter here. */
export type ClaimResult = {
  data: unknown;
  error: { code?: string; message?: string } | null;
  status?: number;
};

export type UsageVerdict =
  /** Spend. `fault` says the limiter could not answer, so it is logged. */
  | { outcome: "proceed"; fault?: string }
  | { outcome: "no_user" }
  | { outcome: "limited"; retryAfterS: number };

/** Only reached if `claim_usage` ever says "limited" with no usable wait. */
const FALLBACK_RETRY_S = 3600;

/**
 * Reads a `claim_usage` answer.
 *
 * A limiter that cannot answer lets the call through: a missing migration or a database blip
 * must not take away the coach an athlete is training with, and this is a guard on the bill,
 * not on access. The exception is 401/403. That is PostgREST refusing the caller, which is
 * how an expired token or the publishable key arrives (`anon` has no EXECUTE), and the
 * caller controls that header, so passing those through would be a way around the limit.
 */
export function readClaim(result: ClaimResult): UsageVerdict {
  if (result.error) {
    if (result.status === 401 || result.status === 403) return { outcome: "no_user" };
    return { outcome: "proceed", fault: `${result.status ?? "?"} ${result.error.code ?? ""} ${result.error.message ?? ""}`.trim() };
  }
  const claim = result.data as { allowed?: unknown; reason?: unknown; retry_after_s?: unknown } | null;
  if (claim?.allowed === true) return { outcome: "proceed" };
  if (claim?.reason === "no_user") return { outcome: "no_user" };
  if (claim?.reason === "limited") {
    const wait = claim.retry_after_s;
    return { outcome: "limited", retryAfterS: typeof wait === "number" && wait > 0 ? Math.ceil(wait) : FALLBACK_RETRY_S };
  }
  return { outcome: "proceed", fault: `unreadable claim: ${JSON.stringify(result.data)}` };
}

/** "in about 40 minutes". Rounded up, so a limit never appears to outlast its promise. */
export function resetPhrase(seconds: number): string {
  if (seconds < 60) return "in under a minute";
  const minutes = Math.ceil(seconds / 60);
  if (minutes < 60) return `in about ${minutes} minute${minutes === 1 ? "" : "s"}`;
  const hours = Math.ceil(minutes / 60);
  return `in about ${hours} hour${hours === 1 ? "" : "s"}`;
}

/**
 * The words the athlete reads. Each one says it is a limit, when it ends, and that nothing
 * was lost, so that it can't be mistaken for a dead connection or for missing data
 * (`LaunchGate`: a failure never wears another failure's face).
 */
export function limitMessage(kind: UsageKind, retryAfterS: number): string {
  const reset = resetPhrase(retryAfterS);
  switch (kind) {
    case "chat":
      return `You've reached the coach's limit for now. It resets ${reset}. Your conversation is saved, and this isn't a connection problem.`;
    case "takeaway":
      return `You've reached the limit on coach reads for now. It resets ${reset}, and this run's read appears the next time you open it after that.`;
    case "block_review":
      return `You've reached the limit on coach retrospectives for now. It resets ${reset}. Your block and result are saved.`;
    case "summarize":
      return `You've reached the limit on conversation recaps for now. It resets ${reset}. Your conversations are saved.`;
    case "plan":
      return `You've reached the limit on plan builds for now. It resets ${reset}. Your existing plan wasn't changed.`;
  }
}

/** The response for a verdict that refuses. The app recognizes `usage_limited` by name. */
export function refusalResponse(
  verdict: Exclude<UsageVerdict, { outcome: "proceed" }>,
  kind: UsageKind,
): Response {
  if (verdict.outcome === "no_user") {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  return Response.json(
    {
      error: "usage_limited",
      kind,
      retry_after_s: verdict.retryAfterS,
      message: limitMessage(kind, verdict.retryAfterS),
    },
    { status: 429, headers: { "Retry-After": String(verdict.retryAfterS) } },
  );
}
