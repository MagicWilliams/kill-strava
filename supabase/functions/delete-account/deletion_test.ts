import { assert, assertEquals, assertFalse } from "jsr:@std/assert@^1";
import {
  accountResult,
  bearerToken,
  callerID,
  DELETE_FAILED_MESSAGE,
  DELETION_ORDER,
  type DeletionStep,
  eachOf,
  ownsAll,
  partitionListing,
  PHOTO_BUCKET,
  photoPrefix,
  resolveCaller,
  runSteps,
  type StepResult,
  verdict,
} from "./deletion.ts";

const MINE = "11111111-2222-4333-8444-555555555555";
const SOMEONE_ELSE = "99999999-8888-4777-8666-555555555555";

// Invented ids throughout: the repo is public, and a real object key names a real athlete's
// run (CLAUDE.md, "On GitHub, counts only").

Deno.test("the caller is whoever the JWT resolved to", () => {
  assertEquals(callerID({ id: MINE }), MINE);
  assertEquals(callerID({ id: MINE.toUpperCase() }), MINE, "keys are written lowercase");
});

Deno.test("no user, no id, or a non-uuid id is nobody", () => {
  assertEquals(callerID(null), null);
  assertEquals(callerID(undefined), null);
  assertEquals(callerID({}), null);
  assertEquals(callerID({ id: 7 }), null);
  assertEquals(callerID({ id: "" }), null);
  assertEquals(callerID({ id: "../../etc" }), null);
  assertEquals(callerID({ id: `${MINE} ${SOMEONE_ELSE}` }), null);
});

Deno.test("photos are deleted before the account", () => {
  // Not cosmetic. Postgres cascades into every user table but not into Storage, and once the
  // auth user is gone nothing names `<uid>/...` any more.
  // Then the photos again, for an upload that was in flight during the first sweep.
  assertEquals([...DELETION_ORDER], ["photos", "account", "stragglers"]);
});

Deno.test("the prefix is the athlete's own folder in the private bucket", () => {
  assertEquals(PHOTO_BUCKET, "run-photos");
  assertEquals(photoPrefix(MINE), `${MINE}/`);
});

Deno.test("a listing of the athlete's folder is run folders, not files", () => {
  // `<uid>/<run id>/<photo id>.jpg`: the first level holds no objects at all, which is why
  // a non-recursive sweep would delete nothing and still look like it worked.
  const runs = ["aaaaaaaa-1111-4111-8111-111111111111", "bbbbbbbb-2222-4222-8222-222222222222"];
  const { objects, folders } = partitionListing(
    photoPrefix(MINE),
    runs.map((name) => ({ name, id: null })),
  );
  assertEquals(objects, []);
  assertEquals(folders, runs.map((run) => `${MINE}/${run}/`));
});

Deno.test("a run folder yields its photo objects, keyed from the prefix", () => {
  const prefix = `${MINE}/aaaaaaaa-1111-4111-8111-111111111111/`;
  const { objects, folders } = partitionListing(prefix, [
    { name: "cccccccc-3333-4333-8333-333333333333.jpg", id: "row-1" },
    { name: "dddddddd-4444-4444-8444-444444444444.jpg", id: "row-2" },
  ]);
  assertEquals(objects, [
    `${prefix}cccccccc-3333-4333-8333-333333333333.jpg`,
    `${prefix}dddddddd-4444-4444-8444-444444444444.jpg`,
  ]);
  assertEquals(folders, []);
});

Deno.test("a name that climbs out of the folder is dropped, not resolved", () => {
  const { objects, folders } = partitionListing(photoPrefix(MINE), [
    { name: "..", id: null },
    { name: "../" + SOMEONE_ELSE, id: "row-1" },
    { name: "/" + SOMEONE_ELSE + "/photo.jpg", id: "row-2" },
    { name: "", id: "row-3" },
    { name: 7, id: "row-4" },
  ]);
  assertEquals(objects, []);
  assertEquals(folders, []);
});

Deno.test("an empty folder placeholder is an object like any other", () => {
  // Supabase writes `.emptyFolderPlaceholder` into a folder created with no file in it. It
  // is a real row with a real key, so it has to go or the folder outlives the account.
  const { objects } = partitionListing(photoPrefix(MINE), [
    { name: ".emptyFolderPlaceholder", id: "row-1" },
  ]);
  assertEquals(objects, [`${MINE}/.emptyFolderPlaceholder`]);
});

Deno.test("only keys inside the athlete's own folder may be removed", () => {
  assert(ownsAll(MINE, [`${MINE}/run/photo.jpg`]));
  assert(ownsAll(MINE, []), "nothing to remove is not a violation");
  assertFalse(ownsAll(MINE, [`${SOMEONE_ELSE}/run/photo.jpg`]));
  assertFalse(ownsAll(MINE, [`${MINE}/run/photo.jpg`, `${SOMEONE_ELSE}/run/photo.jpg`]));
  assertFalse(ownsAll(MINE, [photoPrefix(MINE)]), "the bare folder names no object");
  assertFalse(ownsAll(MINE, [`${MINE}-and-more/run/photo.jpg`]), "a uid prefix is not the uid");
});

Deno.test("folders are swept several at once, and every one of them", async () => {
  const items = Array.from({ length: 50 }, (_, i) => i);
  const seen: number[] = [];
  let running = 0;
  let most = 0;
  const result = await eachOf(items, 8, async (item) => {
    running++;
    most = Math.max(most, running);
    await Promise.resolve();
    seen.push(item);
    running--;
    return { ok: true };
  });
  assertEquals(result, { ok: true });
  assertEquals(seen.sort((a, b) => a - b), items);
  assert(most > 1 && most <= 8, `ran ${most} at once`);
  assertEquals(await eachOf([], 8, () => Promise.resolve({ ok: false })), { ok: true }, "nothing to sweep");
});

Deno.test("one folder that could not be swept fails the sweep and stops it", async () => {
  let started = 0;
  const result = await eachOf(Array.from({ length: 50 }, (_, i) => i), 4, async (item) => {
    started++;
    await Promise.resolve();
    return item === 2 ? { ok: false, detail: "storage down" } : { ok: true };
  });
  assertEquals(result, { ok: false, detail: "storage down" });
  assert(started < 50, "nothing new starts after a failure");
});

// The steps, and what each failure leaves behind.

const OK: StepResult = { ok: true };
const NO: StepResult = { ok: false, detail: "storage down" };

/** Runs the steps with invented results, recording which ones actually ran. */
async function run(outcome: Partial<Record<DeletionStep, StepResult>>) {
  const ran: DeletionStep[] = [];
  const step = (name: DeletionStep) => () => {
    ran.push(name);
    return Promise.resolve(outcome[name] ?? OK);
  };
  const results = await runSteps({
    photos: step("photos"),
    account: step("account"),
    stragglers: step("stragglers"),
  });
  return { ran, answer: verdict(results) };
}

Deno.test("200 only when every step succeeded", async () => {
  const { ran, answer } = await run({});
  assertEquals(ran, ["photos", "account", "stragglers"]);
  assertEquals(answer, { status: 200, body: { deleted: true } });
});

Deno.test("a failed photo sweep leaves the account alone", async () => {
  // The account is what names the photos. Deleting it now would strand them.
  const { ran, answer } = await run({ photos: NO });
  assertEquals(ran, ["photos"]);
  assertEquals(answer.status, 500);
  assertFalse(answer.body.deleted);
  assertEquals(answer.body.step, "photos");
});

Deno.test("a half-finished deletion is a failure, and names the step", async () => {
  // The one the copy has to survive: the photos are gone and the account is not.
  const account = await run({ account: { ok: false, detail: "500" } });
  assertEquals(account.ran, ["photos", "account"]);
  assertEquals(account.answer.status, 500);
  assertFalse(account.answer.body.deleted);
  assertEquals(account.answer.body.step, "account");

  // The account went but the last sweep did not, so a photo may be left. Not a success: the
  // phone keeps its token, and the retry comes back as `already_gone` and sweeps again.
  const stragglers = await run({ stragglers: NO });
  assertEquals(stragglers.answer.status, 500);
  assertFalse(stragglers.answer.body.deleted);
  assertEquals(stragglers.answer.body.step, "stragglers");
});

Deno.test("the failure copy is true after every kind of failure", () => {
  const body = verdict({ photos: OK, account: NO, stragglers: NO }).body;
  assertEquals(body.error, "delete_failed");
  assertEquals(body.message, DELETE_FAILED_MESSAGE);
  // It used to say "Nothing was deleted, and your data is still here", which is false once
  // the photo sweep has run and unknowable once `deleteUser` has been called.
  assertFalse(/nothing was deleted|still here/i.test(DELETE_FAILED_MESSAGE));
  assert(DELETE_FAILED_MESSAGE.includes("couldn't confirm"));
  assert(DELETE_FAILED_MESSAGE.includes("Some or all of your data may already be gone"));
  assert(DELETE_FAILED_MESSAGE.includes("Try again"));
  assertFalse(/[\u2013\u2014]/.test(DELETE_FAILED_MESSAGE), "no dashes in copy");
});

// The retry after a lost reply. The server deletes the account, the answer never arrives, and
// the phone is left with a genuine token for a user who does not exist. Refused with a 401, the
// person could never finish. Accepted too easily, an expired token or an outage would read as
// "deleted" and the phone would throw away the only way back to living rows.

/** An unsigned token with the given claims: these tests supply the auth server's answer. */
function token(claims: unknown): string {
  const part = (value: unknown) =>
    btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `${part({ alg: "HS256" })}.${part(claims)}.signature`;
}
const MY_TOKEN = token({ sub: MINE, role: "authenticated", is_anonymous: true });
const GONE = { status: 403, code: "user_not_found" };

Deno.test("a living account is whoever the auth server says, not what the token claims", () => {
  assertEquals(
    resolveCaller({ user: { id: MINE }, error: null }, token({ sub: SOMEONE_ELSE })),
    { kind: "signed_in", uid: MINE },
  );
});

Deno.test("a genuine token for a user who no longer exists is an account already gone", () => {
  assertEquals(resolveCaller({ user: null, error: GONE }, MY_TOKEN), { kind: "already_gone", uid: MINE });
  assertEquals(
    resolveCaller({ user: null, error: { ...GONE, status: 404 } }, MY_TOKEN),
    { kind: "already_gone", uid: MINE },
  );
});

Deno.test("no other auth failure is ever read as a deletion", () => {
  const failures: Array<[string, { status?: unknown; code?: unknown } | null]> = [
    ["expired, malformed or forged", { status: 403, code: "bad_jwt" }],
    ["the same, spelled the way a client library does", { status: 400, code: "invalid_jwt" }],
    ["signed out elsewhere, account alive", { status: 403, code: "session_not_found" }],
    ["auth-js turns that into a missing session", { status: 400, code: undefined }],
    ["no token at all", { status: 401, code: "no_authorization" }],
    ["banned, account alive", { status: 403, code: "user_banned" }],
    ["rate limited", { status: 429, code: "over_request_rate_limit" }],
    ["auth server down", { status: 503, code: undefined }],
    ["no answer at all", { status: 0, code: undefined }],
    ["a proxy's 404", { status: 404, code: undefined }],
    ["the right word on a server error", { status: 500, code: "user_not_found" }],
    ["the right word with no status", { code: "user_not_found" }],
    ["no user and no error", null],
  ];
  for (const [why, error] of failures) {
    assertEquals(resolveCaller({ user: null, error }, MY_TOKEN), { kind: "nobody" }, why);
  }
});

Deno.test("a gone account needs a token that names exactly one user", () => {
  const bad = [
    "",
    "not.a.jwt",
    "only.two",
    token({ role: "anon" }),
    token({ sub: "" }),
    token({ sub: `${MINE}/../${SOMEONE_ELSE}` }),
    token(null),
  ];
  for (const each of bad) {
    assertEquals(resolveCaller({ user: null, error: GONE }, each), { kind: "nobody" }, each);
  }
});

Deno.test("a user the server returned but cannot identify is nobody", () => {
  assertEquals(resolveCaller({ user: { id: 7 }, error: GONE }, MY_TOKEN), { kind: "nobody" });
});

Deno.test("deleting a user who is already gone is done, and any other error is not", () => {
  assertEquals(accountResult(null), { ok: true });
  assertEquals(accountResult({ status: 404, code: "user_not_found", message: "User not found" }), { ok: true });
  assertFalse(accountResult({ status: 404, message: "not found" }).ok, "a 404 from something else");
  assertFalse(accountResult({ status: 500, code: "user_not_found", message: "x" }).ok);
  assertFalse(accountResult({ status: 500, code: "unexpected_failure", message: "x" }).ok);
  assertFalse(accountResult({ status: 0, message: "fetch failed" }).ok);
});

Deno.test("only a bearer token is a token", () => {
  assertEquals(bearerToken("Bearer abc.def.ghi"), "abc.def.ghi");
  assertEquals(bearerToken("bearer abc"), "abc");
  for (const bad of [null, "", "Bearer", "Bearer ", "Basic abc", "abc", "Bearer a b"]) {
    assertEquals(bearerToken(bad), null);
  }
});
