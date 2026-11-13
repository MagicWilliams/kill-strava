// What `delete-account` is allowed to touch, in what order, and what counts as done.
//
// Kept apart from index.ts and pure, for the same reason `usage_limit.ts` is: every mistake
// this code can make is silent and expensive. Deleting one key too many takes another
// athlete's photos; reporting success too early tells someone their data is gone while it
// is still on the server; running the steps in the wrong order orphans objects nothing can
// name any more.

/** The private bucket run photos live in (migration 0016). */
export const PHOTO_BUCKET = "run-photos";

/**
 * The order the steps run in, and it is load-bearing.
 *
 * Every `user_id` / `profiles.id` foreign key is `on delete cascade`, so deleting the auth
 * user empties the tables on its own. Storage is the exception: Postgres does not delete
 * Storage objects, and `storage.objects` rows survive the user they belonged to. Once the
 * user is gone the uid is the only thing that ever named those objects, so photos go first
 * or they stay forever.
 */
export const DELETION_ORDER = ["photos", "account"] as const;
export type DeletionStep = typeof DELETION_ORDER[number];

/** One entry of a Storage `list()` page. A folder placeholder has no `id`. */
export type ListEntry = { name?: unknown; id?: unknown };

/** Anything that is not exactly one lowercase UUID is not a user id. */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * The caller's id, from the user the JWT resolved to.
 *
 * The body never gets a say. A uid read from the request would turn this function into
 * "delete whoever you name", with the service role key behind it: the one shape of bug here
 * that reaches other people's data.
 */
export function callerID(user: { id?: unknown } | null | undefined): string | null {
  const id = user?.id;
  if (typeof id !== "string") return null;
  const uid = id.toLowerCase();
  return UUID.test(uid) ? uid : null;
}

/**
 * The folder that holds this athlete's photos: `<uid>/`, matching the key
 * `RunJournalPayload.photoPath` writes and the RLS policies in migration 0016.
 */
export function photoPrefix(uid: string): string {
  return `${uid}/`;
}

/**
 * One page of a listing split into objects to remove and folders to descend into.
 *
 * Photo keys are `<uid>/<run id>/<photo id>.jpg`, so a listing of the athlete's folder is
 * all folders and no files. `list()` is not recursive, so a version of this that only read
 * the first level would delete nothing and still report success.
 *
 * A name that tries to climb out of the prefix is dropped rather than resolved. Storage
 * returns names relative to the folder asked for and so should never produce one, which is
 * exactly why a name that does is not something to pass on to `remove()`.
 */
export function partitionListing(
  prefix: string,
  entries: readonly ListEntry[],
): { objects: string[]; folders: string[] } {
  const objects: string[] = [];
  const folders: string[] = [];
  for (const entry of entries) {
    const name = entry?.name;
    if (typeof name !== "string" || name.length === 0) continue;
    if (name.startsWith("/") || name.split("/").includes("..")) continue;
    // Supabase marks a file with a row id; a folder is a synthetic entry with none.
    if (entry.id === null || entry.id === undefined) folders.push(`${prefix}${name}/`);
    else objects.push(`${prefix}${name}`);
  }
  return { objects, folders };
}

/**
 * Last gate before `remove()`: every key sits inside this athlete's own folder.
 *
 * `partitionListing` already builds keys from the prefix it was handed, so this can only
 * fire if a future caller assembles a list some other way. It is cheap, and the failure it
 * guards against is deleting a stranger's run photos.
 */
export function ownsAll(uid: string, keys: readonly string[]): boolean {
  const prefix = photoPrefix(uid);
  return keys.every((key) => key.startsWith(prefix) && key.length > prefix.length);
}

/** How one step went. `ok` is the only thing the verdict reads; `detail` is for the log. */
export type StepResult = { ok: boolean; detail?: string };

export type Verdict = {
  status: number;
  body: { deleted: boolean; step?: DeletionStep; error?: string; message?: string };
};

/**
 * The words the athlete reads when deletion did not happen. Like the usage limiter's, they
 * say that nothing changed, because the alternative reading, "it half worked", is the one
 * that would make someone stop trusting the answer.
 */
export const DELETE_FAILED_MESSAGE =
  "Tempo couldn't delete your account just now. Nothing was deleted, and your data is still here. Try again, or email david@delight.studio.";

/**
 * 200 only when both steps succeeded.
 *
 * A partial pass is a failure with a 500, and the app leaves the phone exactly as it was: a
 * sign-out on top of a half-finished deletion would strand whatever is left on the server
 * behind an account nothing can sign into again.
 */
export function verdict(results: Record<DeletionStep, StepResult>): Verdict {
  for (const step of DELETION_ORDER) {
    if (!results[step].ok) {
      return {
        status: 500,
        body: { deleted: false, step, error: "delete_failed", message: DELETE_FAILED_MESSAGE },
      };
    }
  }
  return { status: 200, body: { deleted: true } };
}
