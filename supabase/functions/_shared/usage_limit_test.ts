// How a `claim_usage` answer is read, and what the athlete is told.
//
// Pinned because both ways of getting this wrong are silent. A refusal read as a pass leaves
// the Anthropic bill unbounded, with nothing on screen to say so. A limiter fault read as a
// refusal takes the coach away from an athlete who has done nothing wrong, and would tell
// them it was their fault. The check-and-count itself is pinned against real Postgres in
// supabase/tests/usage_claim_test.ts.

import { assert, assertEquals, assertMatch, assertStringIncludes } from "jsr:@std/assert@^1";
import {
  limitMessage, readClaim, refusalResponse, resetPhrase, USAGE_KINDS, usageKindForMode,
} from "./usage_limit.ts";

// ── Which allowance a call draws on ─────────────────────────────────────────────────

Deno.test("each coach mode draws on its own allowance", () => {
  assertEquals(usageKindForMode("takeaway"), "takeaway");
  assertEquals(usageKindForMode("block_review"), "block_review");
  assertEquals(usageKindForMode("summarize"), "summarize");
});

Deno.test("no mode is a chat turn", () => {
  assertEquals(usageKindForMode(undefined), "chat");
  assertEquals(usageKindForMode(null), "chat");
});

Deno.test("a mode we don't know is charged as chat, never a free pass", () => {
  // The caller writes this field. The handler treats an unknown mode as a chat turn, so the
  // allowance has to agree, or a made-up mode would be a limit-free coach.
  assertEquals(usageKindForMode("anything"), "chat");
  assertEquals(usageKindForMode("plan"), "chat");
  assertEquals(usageKindForMode(7), "chat");
});

// ── Reading the claim ───────────────────────────────────────────────────────────────

Deno.test("an allowed claim proceeds with nothing to report", () => {
  assertEquals(readClaim({ data: { allowed: true }, error: null, status: 200 }), { outcome: "proceed" });
});

Deno.test("a limited claim refuses and carries the wait", () => {
  assertEquals(
    readClaim({ data: { allowed: false, reason: "limited", retry_after_s: 1234 }, error: null, status: 200 }),
    { outcome: "limited", retryAfterS: 1234 },
  );
});

Deno.test("a limited claim with no usable wait still refuses", () => {
  for (const retry_after_s of [undefined, 0, -5, "soon"]) {
    const verdict = readClaim({ data: { allowed: false, reason: "limited", retry_after_s }, error: null, status: 200 });
    assertEquals(verdict.outcome, "limited");
    if (verdict.outcome === "limited") assert(verdict.retryAfterS > 0);
  }
});

Deno.test("no user behind the JWT is a 401, not a limit", () => {
  assertEquals(readClaim({ data: { allowed: false, reason: "no_user" }, error: null, status: 200 }), { outcome: "no_user" });
});

Deno.test("the publishable key and a dead token are refused, not waved through as a fault", () => {
  // `anon` has no EXECUTE on claim_usage. Reading this as "the limiter is down" would make
  // the key shipped in the app a way around every limit.
  const denied = { code: "42501", message: "permission denied for function claim_usage" };
  assertEquals(readClaim({ data: null, error: denied, status: 401 }), { outcome: "no_user" });
  assertEquals(readClaim({ data: null, error: denied, status: 403 }), { outcome: "no_user" });
  assertEquals(readClaim({ data: null, error: { code: "PGRST301", message: "JWT expired" }, status: 401 }), { outcome: "no_user" });
});

Deno.test("before the migration is applied, the coach keeps working", () => {
  // Deploying the function ahead of the migration must not interrupt anything.
  const verdict = readClaim({
    data: null,
    error: { code: "PGRST202", message: "Could not find the function public.claim_usage" },
    status: 404,
  });
  assertEquals(verdict.outcome, "proceed");
  if (verdict.outcome === "proceed") assertStringIncludes(verdict.fault ?? "", "PGRST202");
});

Deno.test("a database fault lets the call through, and says so", () => {
  for (const status of [500, 503, 0]) {
    const verdict = readClaim({ data: null, error: { message: "boom" }, status });
    assertEquals(verdict.outcome, "proceed");
    if (verdict.outcome === "proceed") assert(verdict.fault);
  }
});

Deno.test("an answer we can't read lets the call through, and says so", () => {
  for (const data of [null, {}, "yes", { allowed: "true" }, { allowed: false, reason: "new_reason" }]) {
    const verdict = readClaim({ data, error: null, status: 200 });
    assertEquals(verdict.outcome, "proceed");
    if (verdict.outcome === "proceed") assert(verdict.fault);
  }
});

// ── What the athlete reads ──────────────────────────────────────────────────────────

Deno.test("the wait reads in the largest unit that is still honest", () => {
  assertEquals(resetPhrase(1), "in under a minute");
  assertEquals(resetPhrase(59), "in under a minute");
  assertEquals(resetPhrase(60), "in about 1 minute");
  assertEquals(resetPhrase(61), "in about 2 minutes");
  assertEquals(resetPhrase(2400), "in about 40 minutes");
  assertEquals(resetPhrase(3540), "in about 59 minutes");
});

Deno.test("the wait rounds up, so a limit never outlasts what it promised", () => {
  assertEquals(resetPhrase(3541), "in about 1 hour");
  assertEquals(resetPhrase(3600), "in about 1 hour");
  assertEquals(resetPhrase(3601), "in about 2 hours");
  assertEquals(resetPhrase(86400), "in about 24 hours");
});

Deno.test("every message names the limit and when it ends", () => {
  for (const kind of USAGE_KINDS) {
    const message = limitMessage(kind, 2400);
    assertStringIncludes(message, "limit");
    assertStringIncludes(message, "in about 40 minutes");
  }
});

Deno.test("no message could be read as a dead connection or as lost data", () => {
  // The rule from LaunchGate. These words belong to the failures this state is not.
  for (const kind of USAGE_KINDS) {
    const message = limitMessage(kind, 2400);
    for (const word of ["unreachable", "couldn't", "failed", "offline", "lost", "deleted"]) {
      assert(!message.toLowerCase().includes(word), `${kind} says "${word}": ${message}`);
    }
  }
});

// ── The response ────────────────────────────────────────────────────────────────────

Deno.test("a refusal is a 429 the app can recognize, with the wait in both forms", async () => {
  const response = refusalResponse({ outcome: "limited", retryAfterS: 2400 }, "chat");
  assertEquals(response.status, 429);
  assertEquals(response.headers.get("Retry-After"), "2400");
  const body = await response.json();
  assertEquals(body.error, "usage_limited");
  assertEquals(body.kind, "chat");
  assertEquals(body.retry_after_s, 2400);
  assertMatch(body.message, /in about 40 minutes/);
});

Deno.test("no user is a 401 with the same body plan has always sent", async () => {
  const response = refusalResponse({ outcome: "no_user" }, "plan");
  assertEquals(response.status, 401);
  assertEquals(await response.json(), { error: "unauthorized" });
});
