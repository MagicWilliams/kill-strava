import { assert, assertEquals, assertFalse } from "jsr:@std/assert@^1";
import {
  callerID,
  DELETE_FAILED_MESSAGE,
  DELETION_ORDER,
  ownsAll,
  partitionListing,
  PHOTO_BUCKET,
  photoPrefix,
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
  assertEquals([...DELETION_ORDER], ["photos", "account"]);
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

Deno.test("200 only when the photos went and the account went", () => {
  assertEquals(verdict({ photos: { ok: true }, account: { ok: true } }), {
    status: 200,
    body: { deleted: true },
  });
});

Deno.test("a half-finished deletion is a failure, and names the step", () => {
  const photosFailed = verdict({ photos: { ok: false, detail: "storage down" }, account: { ok: true } });
  assertEquals(photosFailed.status, 500);
  assertFalse(photosFailed.body.deleted);
  assertEquals(photosFailed.body.step, "photos");

  // The one that matters most: the rows are gone but the photos are not. Reporting this as
  // success would leave objects in the bucket that nothing will ever name again.
  const accountFailed = verdict({ photos: { ok: true }, account: { ok: false, detail: "500" } });
  assertEquals(accountFailed.status, 500);
  assertFalse(accountFailed.body.deleted);
  assertEquals(accountFailed.body.step, "account");
});

Deno.test("the refusal says nothing was deleted", () => {
  const body = verdict({ photos: { ok: false }, account: { ok: true } }).body;
  assertEquals(body.error, "delete_failed");
  assertEquals(body.message, DELETE_FAILED_MESSAGE);
  assert(DELETE_FAILED_MESSAGE.includes("still here"));
});
