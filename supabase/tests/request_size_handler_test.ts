// The request-size cap through the real `coach` and `plan` handlers, with `fetch` stubbed.
//
// What matters about a refusal is what didn't happen after it: no usage claim, no Anthropic
// request. That's an ordering inside each handler, which request_size_test.ts can't see, so
// these run the handlers and record every call they make. It lives here because importing a
// handler needs env and network permissions the logic tests don't have.

import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@^1";
import { MAX_REQUEST_BYTES, TOO_LARGE_MESSAGE } from "../functions/_shared/request_size.ts";

type Handler = (req: Request) => Promise<Response>;

Deno.env.set("ANTHROPIC_API_KEY", "test-key");
Deno.env.set("SUPABASE_URL", "http://supabase.test");
Deno.env.set("SUPABASE_ANON_KEY", "test-anon");

/** Imports a function's index.ts and keeps the handler it hands to `Deno.serve`. */
async function handlerFrom(load: () => Promise<unknown>): Promise<Handler> {
  const serve = Deno.serve;
  let handler: Handler | undefined;
  (Deno as unknown as { serve: unknown }).serve = (h: Handler) => {
    handler = h;
  };
  try {
    await load();
  } finally {
    (Deno as unknown as { serve: unknown }).serve = serve;
  }
  return handler!;
}

const coach = await handlerFrom(() => import("../functions/coach/index.ts"));
const plan = await handlerFrom(() => import("../functions/plan/index.ts"));

/** Runs `fn` with `fetch` answering as Supabase and Anthropic would, and returns the URLs called. */
async function recordingCalls<T>(fn: () => Promise<T>): Promise<{ result: T; calls: string[] }> {
  const real = globalThis.fetch;
  const calls: string[] = [];
  globalThis.fetch = ((input: Request | URL | string) => {
    const url = input instanceof Request ? input.url : String(input);
    calls.push(url);
    if (url.includes("/rpc/claim_usage")) return Promise.resolve(Response.json({ allowed: true }));
    if (url.includes("api.anthropic.com")) {
      return Promise.resolve(Response.json({ content: [{ type: "text", text: "A real reply." }] }));
    }
    // `plan` asking who this is. No user is enough: these tests stop at the size check or here.
    return Promise.resolve(Response.json({ message: "no user" }, { status: 401 }));
  }) as typeof fetch;
  try {
    return { result: await fn(), calls };
  } finally {
    globalThis.fetch = real;
  }
}

function posted(fn: string, body: string | ReadableStream<Uint8Array>): Request {
  return new Request(`http://edge.test/${fn}`, {
    method: "POST",
    body,
    headers: { Authorization: "Bearer test-jwt", "content-type": "application/json" },
  });
}

/**
 * The largest `summarize` the app could plausibly build, from its own ceilings rather than from
 * anyone's data: a full `ChatHistory.pageSize` page with every message 1,500 bytes (a long reply,
 * on both sides of the conversation), and a context with 60 memory facts (`memoryLimit`), doubles
 * every day for the 21-day window with a 500-character note on each (`CoachJournal.notesLimit`),
 * and a 44-session plan window.
 */
function largestRealSummarize(): string {
  const id = "11111111-2222-3333-4444-555555555555";
  return JSON.stringify({
    mode: "summarize",
    messages: Array.from({ length: 200 }, (_, i) => ({
      role: i % 2 === 0 ? "user" : "assistant",
      content: "x".repeat(1500),
    })),
    context: {
      today: "Nov 4, 2026", units: "mi", mode: "training", goal: "3:15:00 at a marathon",
      risk_tolerance: "standard", max_hr: 190, max_hr_basis: "measured",
      settings: { days_per_week: 6, long_run_day: "Sunday" },
      plan: {
        race: "A marathon", race_date: "2027-03-01", goal_time: "3:15:00", week: 4, weeks_total: 18,
        phase: "build", week_target_mi: 50, today_session: "Threshold repeats — 3×1 mi @ 7:05 (planned)",
        projected_finish: "3:20:00",
        sessions_window: Array.from({ length: 44 }, () => ({
          id, date: "Nov 4, 2026", type: "threshold", title: "Threshold repeats — 3×1 mi @ 7:05", status: "planned",
        })),
      },
      fitness: { readiness: 70, fitness_ctl: 50.1, fatigue_atl: 60.2, form: -10.1 },
      recent_runs: Array.from({ length: 42 }, () => ({
        id, date: "Nov 4, 2026", miles: 10.2, pace_per_mile: "8:30", stopped_min: 4, avg_hr: 150,
        corrected: false, rpe: 6, feel_tags: ["heavy legs", "windy"], notes: "n".repeat(500),
      })),
      weekly_mileage: Array.from({ length: 8 }, () => ({ week_of: "Nov 4, 2026", miles: 50.2, runs: 7 })),
      best_efforts: {
        efforts: Array.from({ length: 7 }, () => ({
          distance: "5K", time: "18:45", pace_per_mile: "6:02", date: "Nov 4, 2026", run_id: id,
        })),
      },
      goal_detail: { distance_m: 42195, preferences: { notes: "n".repeat(2000) } },
      memory: { facts: Array.from({ length: 60 }, () => "f".repeat(500)), picking_up: "p".repeat(240) },
    },
  });
}

// The handlers build a supabase client, which starts timers it never stops.
const handlerTest = (name: string, fn: () => Promise<void>) =>
  Deno.test({ name, fn, sanitizeOps: false, sanitizeResources: false });

handlerTest("coach: an oversized body is refused before the claim and before Anthropic", async () => {
  const body = JSON.stringify({ messages: [{ role: "user", content: "x".repeat(MAX_REQUEST_BYTES.coach) }] });
  const { result, calls } = await recordingCalls(() => coach(posted("coach", body)));
  assertEquals(result.status, 413);
  assertEquals((await result.json()).error, "request_too_large");
  assertEquals(calls, []);
});

handlerTest("coach: a chunked body with no Content-Length gets the same refusal", async () => {
  const chunk = new Uint8Array(256 * 1024).fill(32);
  let sent = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (sent++ === 4) return controller.close();
      controller.enqueue(chunk);
    },
  });
  const { result, calls } = await recordingCalls(() => coach(posted("coach", stream)));
  assertEquals(result.status, 413);
  assertEquals(calls, []);
});

handlerTest("coach: a small body that renders into a huge prompt is refused the same way", async () => {
  const depth = 3000;
  const body = `{"messages":[{"role":"user","content":"hi"}],"context":${"[".repeat(depth)}${"]".repeat(depth)}}`;
  assert(body.length < 10_000);
  const { result, calls } = await recordingCalls(() => coach(posted("coach", body)));
  assertEquals(result.status, 413);
  assertEquals(calls, []);
});

handlerTest("coach: a one-shot mode's prompt is measured too", async () => {
  const depth = 3000;
  const body = `{"mode":"takeaway","run":${"[".repeat(depth)}${"]".repeat(depth)}}`;
  const { result, calls } = await recordingCalls(() => coach(posted("coach", body)));
  assertEquals(result.status, 413);
  assertEquals(calls, []);
});

handlerTest("coach: nesting too deep to render spends nothing either", async () => {
  const depth = 200_000;
  const body = `{"messages":[{"role":"user","content":"hi"}],"context":${"[".repeat(depth)}${"]".repeat(depth)}}`;
  assert(body.length < MAX_REQUEST_BYTES.coach);
  const { result, calls } = await recordingCalls(() => coach(posted("coach", body)));
  assert(!result.ok);
  assertEquals(calls, []);
});

handlerTest("coach: the largest real summarize goes through, with the claim before Anthropic", async () => {
  const body = largestRealSummarize();
  assert(new TextEncoder().encode(body).length < MAX_REQUEST_BYTES.coach);
  const { result, calls } = await recordingCalls(() => coach(posted("coach", body)));
  assertEquals(result.status, 200);
  assertEquals(calls.length, 2);
  assert(calls[0].includes("/rpc/claim_usage"), calls[0]);
  assert(calls[1].includes("api.anthropic.com"), calls[1]);
});

handlerTest("coach: an ordinary chat turn is unchanged", async () => {
  const body = JSON.stringify({ messages: [{ role: "user", content: "How was Tuesday?" }], context: { today: "Nov 4" } });
  const { result, calls } = await recordingCalls(() => coach(posted("coach", body)));
  assertEquals(result.status, 200);
  assertEquals((await result.json()).reply, "A real reply.");
  assertEquals(calls.length, 2);
});

handlerTest("plan: an oversized body is refused before anything else happens", async () => {
  const body = JSON.stringify({ race_date: "2027-03-01", race_name: "x".repeat(MAX_REQUEST_BYTES.plan) });
  const { result, calls } = await recordingCalls(() => plan(posted("plan", body)));
  assertEquals(result.status, 413);
  assertEquals(await result.json(), { error: "request_too_large", message: TOO_LARGE_MESSAGE.plan });
  assertEquals(calls, []);
});

handlerTest("plan: a goal with long intake notes passes the size check", async () => {
  // 20,000 characters is several pages on a phone. The stub then says there's no user, which
  // is the handler carrying on past the check.
  const body = JSON.stringify({
    goal_time_s: 11700, race_name: "A marathon", race_date: "2027-03-01", distance: "marathon",
    preferences: { notes: "n".repeat(20_000) },
  });
  const { result, calls } = await recordingCalls(() => plan(posted("plan", body)));
  assertNotEquals(result.status, 413);
  assertEquals(result.status, 401);
  assert(calls.length > 0);
});
