-- Carry the athlete's history over to a new anonymous user. Run by hand, once, by David —
-- and ONLY if the app ever opens empty. As of 2026-10-09 the paid team kept ID 2P8QGJVNJ7,
-- so TestFlight builds share the Keychain with the old Xcode builds and this isn't needed.
-- NOT a migration — it lives outside supabase/migrations/ so nothing applies it by accident.
--
-- Why this exists: auth is anonymous, and the session lives in the iOS Keychain under the
-- signing team's ID. If a build is ever signed by a different team than the one that
-- created the session, that install cannot see the old session. It signs in anonymously as a brand-new user, and the trigger
-- in 0002_auth_profile_trigger gives that user an empty profile. Nothing is deleted — the
-- 2,000+ runs, plan, corrections and coach history are all still on the old user — they are
-- just owned by an identity the phone can no longer prove it is.
--
-- The fix moves ownership old → new. Every user-owned table references auth.users(id)
-- directly (none go through profiles), so this is a flat list of updates.
--
-- The new user has already ingested HealthKit by the time you run this — the app does that
-- on first launch. Those rows are a strict subset of what the old user already has (same
-- phone, same HealthKit uuids), so they are deleted rather than merged. The old rows carry
-- the corrections, dedupe history (superseded_by) and coach takeaways; the new ones don't.
--
-- Find the new id: Supabase dashboard → Authentication → Users, newest anonymous user, created
-- the minute you first opened the TestFlight build. Or:
--   select id, created_at from auth.users order by created_at desc limit 3;

-- ─── Fill in the new id (old is David's, read from production 2026-10-09) ───────────────
-- Runs as-is in the Supabase SQL editor: the whole file executes in one session.
create temp table if not exists ids as
select '402e4b96-61b4-418b-8e16-1d0b59cc943f'::uuid as old_id,
       'REPLACE-WITH-NEW-UUID'::uuid               as new_id;

-- ─── 1. Dry run: look before touching anything ────────────────────────────────────────────
select 'old' as who, t.* from (
  select
    (select count(*) from runs           where user_id = (select old_id from ids)) as runs,
    (select count(*) from plans          where user_id = (select old_id from ids)) as plans,
    (select count(*) from goals          where user_id = (select old_id from ids)) as goals,
    (select count(*) from sessions       where user_id = (select old_id from ids)) as sessions,
    (select count(*) from coach_messages where user_id = (select old_id from ids)) as coach_messages,
    (select count(*) from check_ins      where user_id = (select old_id from ids)) as check_ins,
    (select count(*) from profiles       where id      = (select old_id from ids)) as profile
) t
union all
select 'new', t.* from (
  select
    (select count(*) from runs           where user_id = (select new_id from ids)),
    (select count(*) from plans          where user_id = (select new_id from ids)),
    (select count(*) from goals          where user_id = (select new_id from ids)),
    (select count(*) from sessions       where user_id = (select new_id from ids)),
    (select count(*) from coach_messages where user_id = (select new_id from ids)),
    (select count(*) from check_ins      where user_id = (select new_id from ids)),
    (select count(*) from profiles       where id      = (select new_id from ids))
) t;
-- Expect: old ≈ 1,460 runs + a plan + coach history. New: runs from first-launch ingest,
-- 0 plans/goals/messages (unless onboarding was clicked through — then those get dropped too),
-- 1 profile. If "new" has anything you want to keep, stop here.

-- ─── 2. The move. Uncomment and run when the dry run looks right. ──────────────────────────
-- begin;
--
-- -- Drop the new user's first-launch rows (re-derivable from HealthKit).
-- delete from sessions               where user_id = (select new_id from ids);
-- delete from plans                  where user_id = (select new_id from ids);   -- cascades plan_weeks
-- delete from goals                  where user_id = (select new_id from ids);
-- delete from runs                   where user_id = (select new_id from ids);
-- delete from metrics_daily          where user_id = (select new_id from ids);
-- delete from coach_messages         where user_id = (select new_id from ids);
-- delete from check_ins              where user_id = (select new_id from ids);
-- delete from risk_acknowledgments   where user_id = (select new_id from ids);
-- delete from app_events             where user_id = (select new_id from ids);
-- delete from profiles               where id      = (select new_id from ids);
--
-- -- Re-own everything the old user had.
-- update profiles             set id      = (select new_id from ids) where id      = (select old_id from ids);
-- update runs                 set user_id = (select new_id from ids) where user_id = (select old_id from ids);
-- update goals                set user_id = (select new_id from ids) where user_id = (select old_id from ids);
-- update plans                set user_id = (select new_id from ids) where user_id = (select old_id from ids);
-- update sessions             set user_id = (select new_id from ids) where user_id = (select old_id from ids);
-- update metrics_daily        set user_id = (select new_id from ids) where user_id = (select old_id from ids);
-- update coach_messages       set user_id = (select new_id from ids) where user_id = (select old_id from ids);
-- update check_ins            set user_id = (select new_id from ids) where user_id = (select old_id from ids);
-- update risk_acknowledgments set user_id = (select new_id from ids) where user_id = (select old_id from ids);
-- update app_events           set user_id = (select new_id from ids) where user_id = (select old_id from ids);
--
-- -- Re-run the dry-run query above: old should be all zeros, new should match old's counts.
-- commit;
--
-- The old auth.users row is left in place, empty. Delete it later from the dashboard if you
-- like; nothing references it any more.
