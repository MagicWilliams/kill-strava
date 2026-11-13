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
  callerID,
  DELETE_FAILED_MESSAGE,
  ownsAll,
  partitionListing,
  PHOTO_BUCKET,
  photoPrefix,
  type StepResult,
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

  const authorization = req.headers.get("Authorization");
  if (!authorization) {
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

  // Who is asking, read from the token and only from the token.
  const caller = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: { user } } = await caller.auth.getUser();
  const uid = callerID(user);
  if (!uid) {
    return Response.json({ deleted: false, error: "no_user" }, { status: 401 });
  }

  // From here on, the service role. Nothing below takes an id from the request.
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const photos = await removePhotos(admin, uid);
  // Order per DELETION_ORDER: Postgres cascades into every user table, but not into Storage.
  const account: StepResult = photos.ok
    ? await deleteUser(admin, uid)
    : { ok: false, detail: "not attempted" };

  const answer = verdict({ photos, account });
  if (!answer.body.deleted) {
    // No uid and no key in the log line: a failed deletion is still somebody's account, and
    // the step plus the reason is all that is needed to act on it.
    const detail = answer.body.step === "account" ? account.detail : photos.detail;
    console.error("delete-account failed", answer.body.step, detail);
  }
  return Response.json(answer.body, { status: answer.status });
});

/**
 * Every object under `<uid>/`, gone.
 *
 * Storage has no "delete this prefix", so the folder is walked and its keys removed a page
 * at a time. An empty folder is a success: most athletes have no photos at all, and that
 * must never be the thing that stops an account being deleted.
 *
 * Paging is by what is left behind. Removing objects takes their rows out of the listing,
 * so the next page of the same folder begins where the folders this page held now sit;
 * advancing by the page size instead would step straight over whatever moved up.
 */
async function removePhotos(admin: SupabaseClient, uid: string): Promise<StepResult> {
  const bucket = admin.storage.from(PHOTO_BUCKET);
  const queue: Array<{ prefix: string; depth: number }> = [{ prefix: photoPrefix(uid), depth: 0 }];

  while (queue.length > 0) {
    const { prefix, depth } = queue.pop()!;
    if (depth >= MAX_DEPTH) {
      return { ok: false, detail: "deeper than a photo key goes" };
    }

    let offset = 0;
    while (true) {
      const { data, error } = await bucket.list(prefix, { limit: PAGE, offset });
      if (error) return { ok: false, detail: `list: ${error.message}` };
      const page = data ?? [];
      if (page.length === 0) break;

      const { objects, folders } = partitionListing(prefix, page);
      if (objects.length > 0) {
        // Belt to partitionListing's braces: nothing outside this athlete's folder, ever.
        if (!ownsAll(uid, objects)) return { ok: false, detail: "key outside the caller's folder" };
        const { error: removeError } = await bucket.remove(objects);
        if (removeError) return { ok: false, detail: `remove: ${removeError.message}` };
      }
      for (const folder of folders) queue.push({ prefix: folder, depth: depth + 1 });

      // Nothing removed and nothing new to skip means the page was neither: stop rather
      // than ask for it again.
      if (objects.length === 0 && folders.length === 0) break;
      offset += folders.length;
    }
  }
  return { ok: true };
}

/** The auth user, and with it every row that cascades off it (migrations 0001 to 0025). */
async function deleteUser(admin: SupabaseClient, uid: string): Promise<StepResult> {
  const { error } = await admin.auth.admin.deleteUser(uid);
  return error ? { ok: false, detail: error.message } : { ok: true };
}
