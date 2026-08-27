-- Moving time and elapsed time, as two columns on one run.
--
-- ⚠️  APPLY 0008 FIRST. This migration writes `superseded_by`, which 0008 creates. As of
--     2026-08-27 production had 0006 and 0007 applied by hand but **not 0008**, while the
--     app on main already filters `superseded_by is null` on every run read. Check with:
--       select 1 from information_schema.columns
--        where table_name='runs' and column_name='superseded_by';
--
-- ── What this is ─────────────────────────────────────────────────────────────────────
-- A run has two honest durations. Moving time excludes the seconds the athlete was
-- stopped; elapsed time is the wall clock. Strava shows both, and the difference is a
-- coaching signal — a long run broken up by fifteen minutes of standing around is a
-- different session from the same distance run straight through, at the same moving pace.
--
-- `duration_s` keeps its meaning: **moving time**, the number every pace, total, record,
-- and load score is computed from. `elapsed_duration_s` is new and purely additive, so
-- nothing downstream shifts when this runs.
--
-- ── Why it also retires rows ─────────────────────────────────────────────────────────
-- For years the two clocks arrived in Apple Health as *two separate HKWorkout objects* —
-- identical distance to the meter, one moving duration, one elapsed. Ingest had no way to
-- know they were one run, so both were stored and every all-time total counted that run
-- twice. That is the class David identified in #30: not junk to be thrown away, but one
-- run whose second copy is carrying a number worth keeping.
--
-- So each pair collapses into a single run holding both clocks. Nothing is deleted: the
-- redundant row is soft-retired via `superseded_by` and reversible with
--   update runs set superseded_by = null, elapsed_duration_s = null;
--
-- ── What it deliberately does NOT touch ──────────────────────────────────────────────
-- Only pairs whose `distance_m` is identical **to the meter**. Two recordings of one
-- outing by two devices do not agree to the meter; one activity exported twice always
-- does, because both describe the same GPS trace. The archive's remaining overlapping
-- pairs — ~86 that agree within 5% and ~58 that differ by more, including the 2023-11-19
-- marathon stored beside the blob of the watch left running afterwards — are NOT this
-- shape and are left alone for #30. The review query for them is at the bottom.

alter table runs
  add column if not exists elapsed_duration_s integer
    check (elapsed_duration_s is null or elapsed_duration_s >= 0);

comment on column runs.duration_s is
  'Moving time in seconds — time actually running, excluding stops. The default clock: every pace, total, record and load score computes from this one.';
comment on column runs.elapsed_duration_s is
  'Elapsed (wall-clock) time in seconds, when the source recorded it. Never less than duration_s; the difference is stopped time. NULL means unknown, not zero.';

-- ── Fold each two-clock pair into one run ────────────────────────────────────────────
-- A pair is the same run recorded twice when distance matches to the meter, the durations
-- differ, and the starts are either within a minute or offset by an exact whole number of
-- hours (a timezone/DST re-import — the archive has 48 of those, same second past the
-- hour, up to 8 hours out).
--
-- The survivor is the row holding the SHORTER duration, because moving time can never
-- exceed elapsed time. That single fact is what makes this mechanical: there is no
-- judgment call about which copy is "better", only arithmetic about which clock is which.
with pair as (
  select a.id as a_id, b.id as b_id,
         a.duration_s as a_dur, b.duration_s as b_dur,
         a.avg_hr as a_hr, b.avg_hr as b_hr
  from runs a
  join runs b
    on  a.id <> b.id
    and a.user_id  = b.user_id
    and a.distance_m = b.distance_m           -- to the meter, or it is not the same trace
    and a.duration_s <> b.duration_s
    and (
          abs(extract(epoch from (b.start_time - a.start_time))) <= 60
       or (    abs(extract(epoch from (b.start_time - a.start_time))) <= 12 * 3600
           and mod(abs(extract(epoch from (b.start_time - a.start_time)))::int, 3600) = 0)
        )
  where not a.corrected and not b.corrected   -- an athlete edit is the record; never merge it
    and a.superseded_by is null and b.superseded_by is null
),
-- One survivor per cluster, not per pair: a row that is nobody's shorter partner is the
-- moving-time copy and survives; everything else in the cluster points at it. Choosing the
-- cluster minimum (rather than each row's own best partner) is what stops A→B→C chains,
-- where a survivor is itself retired and the run vanishes from every read.
keep as (
  select distinct on (b_id)
         b_id as drop_id,
         a_id as keep_id,
         a_dur as moving_s,
         b_dur as elapsed_s,
         b_hr  as donor_hr
  from pair
  where a_dur < b_dur                          -- keep the shorter clock
  order by b_id, a_dur, (a_hr is null), a_id
)
update runs u
set superseded_by = k.keep_id
from keep k
where u.id = k.drop_id;

-- Move the elapsed clock onto the survivor — but only when the gap is a real stop.
--
-- Half of the whole-hour pairs differ by one to eight seconds: that is a re-import
-- rounding differently, not the athlete standing still. Recording "3 seconds stopped"
-- would be inventing a fact, so those merges retire the duplicate and leave elapsed null.
-- 30 seconds is the floor, matching TimeAccounting.noiseFloorSeconds in the app.
update runs survivor
set elapsed_duration_s = dup.duration_s
from runs dup
where dup.superseded_by = survivor.id
  and dup.duration_s - survivor.duration_s >= 30
  and survivor.elapsed_duration_s is null;

-- Heart rate is not always on the copy that survived. Carry it across rather than lose it.
update runs survivor
set avg_hr = dup.avg_hr
from runs dup
where dup.superseded_by = survivor.id
  and survivor.avg_hr is null
  and dup.avg_hr is not null;

-- Expected on David's database as of 2026-08-27, applied after 0008:
--   ~71 pairs collapse · ~460 phantom miles removed · ~41 runs gain an elapsed time
--   · 0 corrected rows touched.

-- ── Verification (run after; these change nothing) ───────────────────────────────────
--
-- 1. What the merge did, and the new totals:
--
--   select count(*) filter (where superseded_by is not null)     as retired,
--          count(*) filter (where superseded_by is null)         as live,
--          count(*) filter (where elapsed_duration_s is not null and superseded_by is null)
--                                                                as with_both_clocks,
--          round(sum(distance_m/1609.34) filter (where superseded_by is null)) as live_miles
--   from runs;
--
-- 2. No survivor was itself retired (must return zero rows — the chain check):
--
--   select r.id from runs r
--   join runs s on r.superseded_by = s.id
--   where s.superseded_by is not null;
--
-- 3. The invariant, stated as a query (must return zero rows):
--
--   select id, duration_s, elapsed_duration_s from runs
--   where elapsed_duration_s is not null and elapsed_duration_s < duration_s;
--
-- 4. The classes this migration deliberately left for #30 — same outing, but NOT one
--    trace exported twice, so no mechanical rule can pick the survivor. Review by hand:
--
--   with r as (
--     select id, start_time, start_time + (duration_s || ' seconds')::interval as end_time,
--            distance_m, duration_s, avg_hr
--     from runs where superseded_by is null
--   )
--   select a.start_time::date as day,
--          round((a.distance_m/1609.34)::numeric,2) || ' mi / ' || (a.duration_s/60) || ' min' as run_a,
--          round((b.distance_m/1609.34)::numeric,2) || ' mi / ' || (b.duration_s/60) || ' min' as run_b,
--          round((abs(a.distance_m-b.distance_m)::numeric/greatest(a.distance_m,1))*100,1) as pct_apart,
--          a.id as a_id, b.id as b_id
--   from r a join r b on a.id < b.id
--    and b.start_time >= a.start_time and b.start_time < a.end_time
--   order by pct_apart, a.start_time;
