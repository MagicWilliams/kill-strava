// The one call `coach` and `plan` make right before spending Anthropic money. The decisions
// are in usage_limit.ts and claim_usage (migration 0024); this only connects them.

import { createClient } from "npm:@supabase/supabase-js@2";
import { readClaim, refusalResponse, type UsageKind, type UsageVerdict } from "./usage_limit.ts";

/**
 * Claims one call of `kind` for whoever `authorization` belongs to. Returns the Response to
 * send back if the call is refused, or null to go ahead.
 *
 * This is also what proves there is a user behind a `coach` call: `verify_jwt` accepts the
 * legacy anon key, which has none. It costs one PostgREST round trip, and needs no separate
 * `auth.getUser()` because `claim_usage` reads the same JWT.
 */
export async function usageRefusal(authorization: string | null, kind: UsageKind): Promise<Response | null> {
  if (!authorization) return refusalResponse({ outcome: "no_user" }, kind);

  let verdict: UsageVerdict;
  try {
    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authorization } } },
    );
    verdict = readClaim(await supa.rpc("claim_usage", { p_kind: kind }));
  } catch (err) {
    verdict = { outcome: "proceed", fault: String(err) };
  }

  if (verdict.outcome === "proceed") {
    // Loud, because while this fires nothing is being limited.
    if (verdict.fault) console.error("usage limiter unavailable", kind, verdict.fault);
    return null;
  }
  if (verdict.outcome === "limited") console.warn("usage limited", kind, verdict.retryAfterS);
  return refusalResponse(verdict, kind);
}
