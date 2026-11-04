// `claim_usage` (migration 0024) against real Postgres, by way of PGlite.
//
// It lives outside supabase/functions/ because it needs permissions the logic tests don't:
// it reads the migration file and loads a WASM database. CI runs it as its own step.
//
// PGlite has one connection, so this pins the arithmetic and the access rules, not the
// advisory lock under concurrent calls.

import { assert, assertEquals, assertRejects } from "jsr:@std/assert@^1";
import { PGlite } from "npm:@electric-sql/pglite@0.2.17";
import { USAGE_KINDS } from "../functions/_shared/usage_limit.ts";

const ATHLETE = "11111111-1111-1111-1111-111111111111";
const OTHER = "22222222-2222-2222-2222-222222222222";
const DELETED = "33333333-3333-3333-3333-333333333333";

type Claim = { allowed: boolean; reason?: string; retry_after_s?: number };

/** A database with just enough of Supabase's shape for the migration to apply. */
async function database(): Promise<PGlite> {
  const db = new PGlite();
  await db.exec(`
    create role anon; create role authenticated;
    create schema auth;
    create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as
      $$ select nullif(current_setting('request.jwt.sub', true), '')::uuid $$;
    grant usage on schema auth to anon, authenticated;
    grant usage on schema public to anon, authenticated;
    grant execute on function auth.uid() to anon, authenticated;
    -- What Supabase's default privileges hand every new table and function.
    alter default privileges in schema public grant all on tables to anon, authenticated;
    alter default privileges in schema public grant execute on functions to anon, authenticated;
    insert into auth.users values ('${ATHLETE}'), ('${OTHER}');
  `);
  await db.exec(await Deno.readTextFile(new URL("../migrations/0024_usage_limits.sql", import.meta.url)));
  return db;
}

/** Calls claim_usage the way PostgREST does: as `authenticated`, with the JWT's sub set. */
async function claim(db: PGlite, user: string | null, kind = "chat"): Promise<Claim> {
  await db.exec(`set request.jwt.sub = '${user ?? ""}'; set role authenticated;`);
  try {
    const { rows } = await db.query<{ claim: Claim }>("select claim_usage($1) as claim", [kind]);
    return rows[0].claim;
  } finally {
    await db.exec("reset role;");
  }
}

async function limit(db: PGlite, kind: string, windowS: number, maxCalls: number) {
  await db.query(
    "update usage_limits set max_calls = $3 where kind = $1 and window_s = $2",
    [kind, windowS, maxCalls],
  );
}

async function counted(db: PGlite, user: string, kind: string, windowS: number): Promise<number> {
  const { rows } = await db.query<{ total: number }>(
    "select coalesce(sum(calls), 0)::int as total from usage_counters where user_id = $1 and kind = $2 and window_s = $3",
    [user, kind, windowS],
  );
  return rows[0].total;
}

Deno.test("every kind the functions can claim has an hourly and a daily limit", async () => {
  const db = await database();
  for (const kind of USAGE_KINDS) {
    const { rows } = await db.query<{ window_s: number; max_calls: number }>(
      "select window_s, max_calls from usage_limits where kind = $1 order by window_s",
      [kind],
    );
    assertEquals(rows.map((r) => r.window_s), [3600, 86400], kind);
    assert(rows[0].max_calls > 0 && rows[0].max_calls <= rows[1].max_calls, kind);
  }
  await db.close();
});

Deno.test("calls are allowed up to the limit, and the next is refused", async () => {
  const db = await database();
  await limit(db, "chat", 3600, 2);
  assertEquals((await claim(db, ATHLETE)).allowed, true);
  assertEquals((await claim(db, ATHLETE)).allowed, true);
  const refused = await claim(db, ATHLETE);
  assertEquals(refused.allowed, false);
  assertEquals(refused.reason, "limited");
  assert(refused.retry_after_s! > 0 && refused.retry_after_s! <= 3600);
  await db.close();
});

Deno.test("a refused call is not counted, so hammering never pushes back the reset", async () => {
  const db = await database();
  await limit(db, "chat", 3600, 1);
  await claim(db, ATHLETE);
  for (let i = 0; i < 5; i++) await claim(db, ATHLETE);
  assertEquals(await counted(db, ATHLETE, "chat", 3600), 1);
  await db.close();
});

Deno.test("a full hour spends nothing from the day", async () => {
  const db = await database();
  await limit(db, "chat", 3600, 1);
  await claim(db, ATHLETE);
  await claim(db, ATHLETE);
  assertEquals(await counted(db, ATHLETE, "chat", 86400), 1);
  await db.close();
});

Deno.test("a full day refuses even when the hour has room", async () => {
  const db = await database();
  await limit(db, "chat", 86400, 1);
  await claim(db, ATHLETE);
  const refused = await claim(db, ATHLETE);
  assertEquals(refused.reason, "limited");
  assert(refused.retry_after_s! <= 86400);
  await db.close();
});

Deno.test("with both windows full, the wait is the later reset", async () => {
  // Saying "in ten minutes" when the day's allowance is also gone would be a lie.
  const db = await database();
  await limit(db, "chat", 3600, 1);
  await limit(db, "chat", 86400, 1);
  await claim(db, ATHLETE);
  const { retry_after_s } = await claim(db, ATHLETE);
  const { rows } = await db.query<{ hour_s: number; day_s: number }>(`
    select 3600 - (extract(epoch from now())::bigint % 3600) as hour_s,
           86400 - (extract(epoch from now())::bigint % 86400) as day_s`);
  assert(Math.abs(retry_after_s! - Math.max(Number(rows[0].hour_s), Number(rows[0].day_s))) <= 2);
  await db.close();
});

Deno.test("calls from an earlier window no longer count", async () => {
  const db = await database();
  await limit(db, "chat", 3600, 1);
  await claim(db, ATHLETE);
  assertEquals((await claim(db, ATHLETE)).allowed, false);
  await db.exec("update usage_counters set window_start = window_start - interval '2 days'");
  assertEquals((await claim(db, ATHLETE)).allowed, true);
  await db.close();
});

Deno.test("allowances are per user", async () => {
  const db = await database();
  await limit(db, "chat", 3600, 1);
  await claim(db, ATHLETE);
  assertEquals((await claim(db, ATHLETE)).allowed, false);
  assertEquals((await claim(db, OTHER)).allowed, true);
  await db.close();
});

Deno.test("background work can't use up the athlete's chat", async () => {
  const db = await database();
  await limit(db, "takeaway", 3600, 1);
  await claim(db, ATHLETE, "takeaway");
  assertEquals((await claim(db, ATHLETE, "takeaway")).allowed, false);
  assertEquals((await claim(db, ATHLETE, "chat")).allowed, true);
  await db.close();
});

Deno.test("no user behind the JWT is refused and writes nothing", async () => {
  const db = await database();
  assertEquals(await claim(db, null), { allowed: false, reason: "no_user" });
  const { rows } = await db.query<{ n: number }>("select count(*)::int as n from usage_counters");
  assertEquals(rows[0].n, 0);
  await db.close();
});

Deno.test("a valid JWT for a deleted user is refused, not treated as a limiter fault", async () => {
  // Faults let a call through, so this one has to come back as an answer, not an error.
  const db = await database();
  assertEquals(await claim(db, DELETED), { allowed: false, reason: "no_user" });
  await db.close();
});

Deno.test("a kind with no limits is allowed and leaves no rows, so it can't grow the table", async () => {
  // claim_usage is reachable directly through PostgREST with any string for a kind.
  const db = await database();
  assertEquals(await claim(db, ATHLETE, "made_up"), { allowed: true });
  const { rows } = await db.query<{ n: number }>("select count(*)::int as n from usage_counters");
  assertEquals(rows[0].n, 0);
  await db.close();
});

Deno.test("the caller's own old rows are cleaned up, and nobody else's", async () => {
  const db = await database();
  await db.exec(`
    insert into usage_counters (user_id, kind, window_s, window_start, calls) values
      ('${ATHLETE}', 'chat', 3600, now() - interval '40 days', 3),
      ('${OTHER}',   'chat', 3600, now() - interval '40 days', 3)`);
  await claim(db, ATHLETE);
  const { rows } = await db.query<{ user_id: string }>(
    "select user_id from usage_counters where window_start < now() - interval '35 days'",
  );
  assertEquals(rows.map((r) => r.user_id), [OTHER]);
  await db.close();
});

Deno.test("deleting a user takes their counters with them", async () => {
  const db = await database();
  await claim(db, ATHLETE);
  await db.query("delete from auth.users where id = $1", [ATHLETE]);
  const { rows } = await db.query<{ n: number }>("select count(*)::int as n from usage_counters");
  assertEquals(rows[0].n, 0);
  await db.close();
});

// ── Access ──────────────────────────────────────────────────────────────────────────

Deno.test("the anon role can't call it", async () => {
  // How `readClaim` tells a caller with no user from a limiter fault: PostgREST turns this
  // into a 401.
  const db = await database();
  await db.exec("set role anon;");
  await assertRejects(() => db.query("select claim_usage('chat')"), Error, "permission denied");
  await db.exec("reset role;");
  await db.close();
});

for (const statement of [
  "select * from usage_limits",
  "select * from usage_counters",
  "update usage_limits set max_calls = 999999",
  "delete from usage_counters",
  `insert into usage_counters (user_id, kind, window_s, window_start) values ('${ATHLETE}', 'chat', 3600, now())`,
]) {
  Deno.test(`an athlete can't get around it directly: ${statement.split(" ").slice(0, 4).join(" ")}`, async () => {
    // A counter the athlete could reset would be no limit at all.
    const db = await database();
    await db.exec(`set request.jwt.sub = '${ATHLETE}'; set role authenticated;`);
    await assertRejects(() => db.query(statement), Error, "permission denied");
    await db.exec("reset role;");
    await db.close();
  });
}
