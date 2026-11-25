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
 *
 * `stragglers` is the photo sweep again, after the account. The phone may have been uploading
 * a photo while the first sweep ran, and Storage checks a token's signature, not whether its
 * user still exists, so that upload is accepted even after the account has gone.
 */
export const DELETION_ORDER = ["photos", "account", "stragglers"] as const;
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

/** The bearer token out of an `Authorization` header, or null. */
export function bearerToken(authorization: string | null): string | null {
  const match = /^Bearer\s+(\S+)$/i.exec(authorization?.trim() ?? "");
  return match ? match[1] : null;
}

/**
 * The `sub` a token claims. It proves nothing by itself: nothing here checks a signature, so
 * the only caller is `resolveCaller`, after the auth server has checked it.
 */
function claimedSubject(token: string): string | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    return callerID({ id: JSON.parse(atob(base64))?.sub });
  } catch {
    return null;
  }
}

/** The parts of an auth error a decision is made on. Never the message: wording changes. */
export type AuthFailure = { status?: unknown; code?: unknown };

/** The auth server saying, in its own code and not a proxy's, that a user does not exist. */
function saysUserNotFound(error: AuthFailure | null | undefined): boolean {
  const status = error?.status;
  return error?.code === "user_not_found" && (status === 403 || status === 404);
}

export type Caller =
  | { kind: "signed_in"; uid: string }
  /** A genuine, unexpired token for an account that has already been deleted. */
  | { kind: "already_gone"; uid: string }
  | { kind: "nobody" };

/**
 * Who is asking, from what the auth server said about this token.
 *
 * `already_gone` is how a retry ends when the first answer was lost: the account went, the
 * phone never heard, and refusing the retry with a 401 would leave it holding a dead session.
 *
 * `user_not_found` is the only code that means it. The auth server checks the signature and
 * the expiry before it looks the user up, so an expired, malformed or forged token never gets
 * that far: those are `bad_jwt`. A revoked session on a living account is `session_not_found`.
 * An outage carries no code. Every one of those is nobody, and nobody is never told "deleted".
 *
 * `token` must be the one `answer` is about. The uid is read from it because a missing user
 * has no row to read it from.
 */
export function resolveCaller(
  answer: { user: { id?: unknown } | null | undefined; error: AuthFailure | null | undefined },
  token: string,
): Caller {
  const uid = callerID(answer.user);
  if (uid) return { kind: "signed_in", uid };
  if (!answer.user && saysUserNotFound(answer.error)) {
    const gone = claimedSubject(token);
    if (gone) return { kind: "already_gone", uid: gone };
  }
  return { kind: "nobody" };
}

/**
 * What `admin.deleteUser` came back with. "There is no such user" is the outcome asked for,
 * not a failure: it is every retry after a lost reply, and the second of two taps that raced.
 */
export function accountResult(error: (AuthFailure & { message?: string }) | null): StepResult {
  if (!error || saysUserNotFound(error)) return { ok: true };
  return { ok: false, detail: error.message };
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
 * The words for a deletion that was not confirmed. They cannot say that nothing happened:
 * photos go first, so a failure after that has already removed some, and an error from
 * `deleteUser` does not prove the user is still there. What is true in every case is that it
 * is not confirmed, and that trying again is the way to finish it.
 */
export const DELETE_FAILED_MESSAGE =
  "Tempo couldn't confirm that your account was deleted. Some or all of your data may already be gone. Try again to finish, or email david@delight.studio.";

/**
 * Run the steps in order and stop at the first that fails, so the account is never deleted
 * while its photos are still in the bucket with nothing left to name them.
 */
export async function runSteps(
  steps: Record<DeletionStep, () => Promise<StepResult>>,
): Promise<Record<DeletionStep, StepResult>> {
  const skipped: StepResult = { ok: false, detail: "not attempted" };
  const results: Record<DeletionStep, StepResult> = {
    photos: skipped,
    account: skipped,
    stragglers: skipped,
  };
  for (const step of DELETION_ORDER) {
    results[step] = await steps[step]();
    if (!results[step].ok) break;
  }
  return results;
}

/**
 * 200 only when every step succeeded.
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
