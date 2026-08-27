-- Retire duplicate runs — the provable ones only.
--
-- Garmin Connect rewrites already-exported workouts as fresh HKWorkout objects when its
-- Health settings change. The (user_id, source, external_id) constraint sees strangers and
-- inserts them again. Engine/RunDedupe.swift closed this at ingest on 2026-07-10 and has
-- held since (zero duplicates after that date) — but nothing ever cleaned up the rows that
-- got in before it.
--
-- Soft delete, not DELETE. This is the only copy of five years of training, so a duplicate
-- is marked and filtered, never destroyed. Reversible with: update runs set superseded_by = null.
--
-- ── What this migration does NOT do, deliberately ────────────────────────────────────
-- Only rows that are duplicates BY CONSTRUCTION are marked: identical distance_m AND
-- identical duration_s, offset by an exact whole number of hours (0 for a straight re-export,
-- N hours for a timezone/DST re-import). Two genuinely different runs do not match to the
-- meter and the second.
--
-- A larger class exists — ~197 more rows where runs OVERLAP IN TIME but carry different
-- metrics. Those are not mechanical and must not be automated. Two real examples from this
-- database:
--
--   2023-11-19  26.68 mi / 188 min  (7:03/mi — the actual marathon)
--               27.59 mi / 304 min  (11:01/mi, HR 119 — the watch left running afterwards)
--
--     Every simple rule picks wrong here. "Keep the longest" and "keep the one with HR"
--     both delete the race and keep the blob.
--
--   2022-06-25  13.01 mi / 108 min, plus 4.52 + 0.50 + 4.92 + 3.66 mi
--
--     One long run stored as a whole AND as its segments. The right answer is to keep the
--     whole, but only a human can tell that shape from a genuine set of repeats.
--
-- The review query for that class is at the bottom of this file. David adjudicates it.

alter table runs
  add column if not exists superseded_by uuid references runs(id) on delete set null;

comment on column runs.superseded_by is
  'Non-null when this row duplicates another run; points at the surviving row. All list reads must filter `superseded_by is null`. Set by migration 0008 and by manual review.';

-- The app reads "my runs, newest first, excluding superseded".
create index if not exists runs_live_idx on runs (user_id, start_time desc) where superseded_by is null;

-- ── Mark the provable duplicates ─────────────────────────────────────────────────────
-- For each row, find the best twin: HR present wins (the richer record), then the earliest
-- start (the original, before the clock shifted), then lowest id as a stable tiebreak. A row
-- that is itself the best in its group has no better twin and survives.
update runs u
set superseded_by = k.keep_id
from (
  select distinct on (b.id) b.id as drop_id, a.id as keep_id
  from runs a
  join runs b
    on  a.id <> b.id
    and a.user_id = b.user_id
    and a.distance_m = b.distance_m
    and a.duration_s = b.duration_s
    and abs(extract(epoch from (b.start_time - a.start_time))) <= 12 * 3600
    and mod(abs(extract(epoch from (b.start_time - a.start_time)))::int, 3600) = 0
    and (
         (a.avg_hr is not null and b.avg_hr is null)
      or ((a.avg_hr is null) = (b.avg_hr is null) and a.start_time < b.start_time)
      or ((a.avg_hr is null) = (b.avg_hr is null) and a.start_time = b.start_time and a.id < b.id)
    )
  where a.superseded_by is null
    and b.superseded_by is null
    and not b.corrected            -- never retire a row the athlete has edited
  order by b.id, (a.avg_hr is null), a.start_time, a.id
) k
where u.id = k.drop_id;

-- Expected on David's database as of 2026-08-27: 59 rows marked, ~364 phantom miles removed,
-- 0 corrected rows touched. Verify with the first query below.

-- ── Verification (run these after; they change nothing) ──────────────────────────────
--
-- 1. What was retired, and the new totals:
--
--   select count(*) filter (where superseded_by is not null) as retired,
--          count(*) filter (where superseded_by is null)     as live,
--          round(sum(distance_m/1609.34) filter (where superseded_by is null)) as live_miles
--   from runs;
--
-- 2. The class this migration deliberately left alone — overlapping runs with different
--    metrics. Review by hand; set superseded_by manually on the ones that are wrong.
--
--   with r as (
--     select id, start_time, start_time + (duration_s || ' seconds')::interval as end_time,
--            distance_m, duration_s, avg_hr
--     from runs where superseded_by is null
--   )
--   select a.start_time::date as day,
--          round((a.distance_m/1609.34)::numeric,2) || ' mi / ' || (a.duration_s/60) || ' min' as run_a,
--          round((b.distance_m/1609.34)::numeric,2) || ' mi / ' || (b.duration_s/60) || ' min' as run_b,
--          a.id as a_id, b.id as b_id
--   from r a join r b on a.id < b.id and b.start_time >= a.start_time and b.start_time < a.end_time
--   order by a.start_time;
