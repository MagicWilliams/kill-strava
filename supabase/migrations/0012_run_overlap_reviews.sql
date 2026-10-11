-- Overlapping runs, resolved by hand (#30).
--
-- ⚠️  UNAPPLIED. Apply before merging the app change that reads it. Until this table exists
--     the app hides the review row entirely (an absent table is not an empty queue), so
--     shipping the app first is harmless — it just does nothing.
--
-- ── What this is ─────────────────────────────────────────────────────────────────────
-- 0008 and 0009 retired every duplicate that is one by construction (identical distance to
-- the meter). What remains are live runs that overlap in time but disagree: two devices on
-- one outing, a run stored whole and as its splits, the watch left running after the
-- 2023-11-19 marathon. No rule picks the survivor safely, so David rules on each pair on the
-- "Review overlapping runs" screen.
--
-- "Keep left / keep right" retires the other run the same way 0008/0009 did: the row gets
-- `superseded_by = <kept id>`, marked and never deleted, reversible. That alone would make
-- the pair disappear. "Both are real" changes no run at all — so without a record of it
-- the pair would come back on every launch, forever. This table is that record, and it is
-- written for every decision so a keep can be undone and audited too.
--
-- ── Shape ────────────────────────────────────────────────────────────────────────────
-- Keyed on the ordered pair: `run_a < run_b` in uuid order, enforced by the check, so
-- (x, y) and (y, x) cannot both exist. `kept_a` / `kept_b` name a side of that key, not a
-- side of the screen. The app computes the same ordering (`RunDedupe.OverlapKey`).

create table if not exists run_overlap_reviews (
  user_id      uuid not null references auth.users(id) on delete cascade,
  run_a        uuid not null references runs(id) on delete cascade,
  run_b        uuid not null references runs(id) on delete cascade,
  decision     text not null check (decision in ('kept_a', 'kept_b', 'both_real')),
  reviewed_at  timestamptz not null default now(),

  primary key (user_id, run_a, run_b),
  check (run_a < run_b)
);

comment on table run_overlap_reviews is
  'One row per overlapping pair of runs the athlete has ruled on (#30). kept_a/kept_b: the other run was retired via runs.superseded_by. both_real: two genuine runs, nothing retired — this row is the only thing stopping the pair being asked about again.';

alter table run_overlap_reviews enable row level security;

-- Same policy as `runs` (0001): every row is the athlete's own.
create policy "own overlap reviews" on run_overlap_reviews
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ── Dry run (changes nothing) ────────────────────────────────────────────────────────
--
-- The queue the app will show (before applying, drop the `where not exists` clause — it
-- reads this table) — live overlapping pairs not yet reviewed. Note this orders
-- each pair by START TIME, not by id: query 4 at the bottom of 0009 joins on a.id < b.id
-- and also requires b to start after a, which silently drops every pair whose earlier run
-- holds the larger uuid. Expect this count to be higher than that query's.
--
--   with r as (
--     select id, start_time, start_time + (duration_s || ' seconds')::interval as end_time
--     from runs where superseded_by is null
--   )
--   select count(*) as unresolved_pairs
--   from r a join r b
--     on a.id <> b.id
--    and (a.start_time < b.start_time or (a.start_time = b.start_time and a.id::text < b.id::text))
--    and b.start_time < a.end_time
--   where not exists (
--     select 1 from run_overlap_reviews v
--     where v.run_a = least(a.id, b.id) and v.run_b = greatest(a.id, b.id)
--   );
--
-- What has been decided so far:
--
--   select decision, count(*) from run_overlap_reviews group by decision;
--
-- Undo one decision by hand (the app's Undo does exactly this):
--
--   update runs set superseded_by = null where id = '<retired id>';
--   delete from run_overlap_reviews where run_a = '<a>' and run_b = '<b>';
