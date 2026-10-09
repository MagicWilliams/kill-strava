-- Purge the anonymous users CI created in production before the staging split (#65).
--
-- Between 2026-08-23 and 2026-08-27 the CI smoke test signed in anonymously against the
-- production project 54 times. Each sign-in left an auth.users row plus its profiles row
-- and nothing else. The cause is already fixed (CI now points at staging); this removes the debris.
--
-- Every account in this project is anonymous, David's included, so "anonymous" is NOT a
-- filter here. A user is debris only if it was created in the CI window AND owns no row in
-- any table that holds user data. David chose to keep the 8 zero-data users from
-- 9–12 Jul (probably his own early simulator runs), so they fall outside the window on purpose.
--
-- Dry run, 2026-10-09, read-only: 62 users own no data. 54 of them fall in the window, none
-- has signed in since 2026-08-27 23:13 UTC, and the 5 users who own data are untouched,
-- David (402e4b96…, 1,464 runs) among them.
--
-- Irreversible: deleting from auth.users cascades to profiles. The guard aborts the
-- whole migration unless exactly 54 rows match, so a drifted database changes nothing.

do $$
declare
  n int;
begin
  create temp table ci_debris on commit drop as
  select u.id
  from auth.users u
  where u.created_at >= '2026-08-23' and u.created_at < '2026-08-28'
    and not exists (select 1 from goals                g where g.user_id = u.id)
    and not exists (select 1 from sessions             s where s.user_id = u.id)
    and not exists (select 1 from plans                p where p.user_id = u.id)
    and not exists (select 1 from runs                 r where r.user_id = u.id)
    and not exists (select 1 from metrics_daily        m where m.user_id = u.id)
    and not exists (select 1 from coach_messages       c where c.user_id = u.id)
    and not exists (select 1 from risk_acknowledgments k where k.user_id = u.id)
    and not exists (select 1 from app_events           e where e.user_id = u.id)
    and not exists (select 1 from check_ins            i where i.user_id = u.id)
    and not exists (select 1 from run_efforts          f where f.user_id = u.id);

  select count(*) into n from ci_debris;
  if n <> 54 then
    raise exception 'expected 54 CI users, found % — aborting, nothing deleted', n;
  end if;

  delete from auth.users where id in (select id from ci_debris);
end $$;

-- Verify after (must read 13 users, David's 1,464-run account among them):
--   select count(*) from auth.users;
--   select count(*) from runs where user_id::text like '402e4b96%';
