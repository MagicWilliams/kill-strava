// Tempo account deletion — the one thing the app cannot do for itself.
//
// App Review 5.1.1(v): an app that creates an account must offer deletion of that account
// from inside the app. Tempo's accounts are anonymous, created on first launch, so the only
// person who can ask for one to go is whoever is holding the phone it lives on.
//
// Deleting an auth user needs the service role key, which must never be in the app, so the
// whole operation is here. The caller's JWT says who they are; the body says nothing. Every
// decision this makes about what to delete, in what order, and whether it worked is in
// deletion.ts, which is pure and tested.
//
// This function calls no model and sends nothing to Anthropic, so there is no usage claim
// and no consent check. Someone withdrawing their data must not be refused because they
// withdrew it.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  accountResult,
  bearerToken,
  DELETE_FAILED_MESSAGE,
  eachOf,
  ownsAll,
  partitionListing,
  PHOTO_BUCKET,
  photoPrefix,
  resolveCaller,
  runSteps,
  type StepResult,
  SWEEP_WIDTH,
  verdict,
} from "./deletion.ts";

/** One page of a Storage listing. The API's own maximum per call. */
const PAGE = 100;

/**
 * How deep the sweep goes under `<uid>/`. Keys are `<uid>/<run id>/<photo id>.jpg`, so two
 * levels is the shape; the cap is here so a surprise in the bucket costs a log line rather
 * than an unbounded walk under a service role key.
 */
const MAX_DEPTH = 4;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return Response.json({ error: "POST only" }, { status: 405 });
  }

  const token = bearerToken(req.headers.get("Authorization"));
  if (!token) {
    return Response.json({ deleted: false, error: "no_user" }, { status: 401 });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) {
    console.error("delete-account is missing its environment");
    return Response.json(
      { deleted: false, error: "delete_failed", message: DELETE_FAILED_MESSAGE },
      { status: 500 },
    );
  }

  // Who is asking, read from the token and only from the token. Passed explicitly so the
  // answer is about this token and no other: `resolveCaller` relies on that.
  const caller = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await caller.auth.getUser(token);
  const who = resolveCaller({ user: data?.user, error }, token);
  if (who.kind === "nobody") {
    return Response.json({ deleted: false, error: "no_user" }, { status: 401 });
  }
  const uid = who.uid;

  // From here on, the service role. Nothing below takes an id from the request.
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // The same steps whether or not the account is already gone. On a retry after a lost reply
  // they find nothing to do, and what makes the 200 true is that they looked.
  const results = await runSteps({
    photos: () => removePhotos(admin, uid),
    account: () => deleteUser(admin, uid),
    stragglers: () => removePhotos(admin, uid),
  });

  const answer = verdict(results);
  if (answer.body.step) {
    // No uid and no key in the log line: a failed deletion is still somebody's account, and
    // the step plus the reason is all that is needed to act on it.
    console.error("delete-account failed", who.kind, answer.body.step, results[answer.body.step].detail);
  }
  return Response.json(answer.body, { status: answer.status });
});

/**
 * Every object under `<uid>/`, gone.
 *
 * Storage has no "delete this prefix", so the folders are walked a level at a time, several
 * folders of a level at once. A level is listed to its end before any of its folders is
 * emptied: emptying one takes it out of its parent's listing and would move the next page. An
 * empty folder is a success: most athletes have no photos at all, and that must never be the
 * thing that stops an account being deleted.
 */
async function removePhotos(admin: SupabaseClient, uid: string): Promise<StepResult> {
  let level = [photoPrefix(uid)];
  for (let depth = 0; level.length > 0; depth++) {
    if (depth >= MAX_DEPTH) return { ok: false, detail: "deeper than a photo key goes" };
    const below: string[] = [];
    const swept = await eachOf(level, SWEEP_WIDTH, (prefix) => sweepFolder(admin, uid, prefix, below));
    if (!swept.ok) return swept;
    level = below;
  }
  return { ok: true };
}

/**
 * Remove one folder's objects a page at a time, and add its folders to `below`.
 *
 * Paging is by what is left behind. Removing objects takes their rows out of the listing, so
 * the next page begins where the folders this page held now sit; advancing by the page size
 * instead would step straight over whatever moved up.
 */
async function sweepFolder(
  admin: SupabaseClient,
  uid: string,
  prefix: string,
  below: string[],
): Promise<StepResult> {
  const bucket = admin.storage.from(PHOTO_BUCKET);
  let offset = 0;
  while (true) {
    const { data, error } = await bucket.list(prefix, { limit: PAGE, offset });
    if (error) return { ok: false, detail: `list: ${error.message}` };
    const page = data ?? [];

    const { objects, folders } = partitionListing(prefix, page);
    if (objects.length > 0) {
      // Belt to partitionListing's braces: nothing outside this athlete's folder, ever.
      if (!ownsAll(uid, objects)) return { ok: false, detail: "key outside the caller's folder" };
      const { error: removeError } = await bucket.remove(objects);
      if (removeError) return { ok: false, detail: `remove: ${removeError.message}` };
    }
    below.push(...folders);

    // A short page is the last one. Nothing removed and nothing new to skip means the page
    // was neither: stop rather than ask for it again.
    if (page.length < PAGE || (objects.length === 0 && folders.length === 0)) return { ok: true };
    offset += folders.length;
  }
}

/** The auth user, and with it every row that cascades off it (migrations 0001 to 0025). */
async function deleteUser(admin: SupabaseClient, uid: string): Promise<StepResult> {
  const { error } = await admin.auth.admin.deleteUser(uid);
  return accountResult(error);
}
