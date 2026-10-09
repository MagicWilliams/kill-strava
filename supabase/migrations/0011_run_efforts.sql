-- Sub-distance best efforts — the fastest 5K *inside* a run, not the fastest 5K+ run (#25).
--
-- Applied to production by hand on 2026-10-09 (SQL editor — not in schema_migrations).
--     Order matters only in that this is the next free number after 0010 (#64).
--
-- ── What this is ─────────────────────────────────────────────────────────────────────
-- `runs` already answers "fastest 10K+ run": the best *average* pace over a run of at
-- least that distance. That is a weaker claim than it sounds. A 20-miler with a hard
-- finish holds a 10 K best that whole-run averaging can never surface, because the easy
-- fifteen miles in front of it drag the average down. The real number is the fastest
-- segment of that distance wherever it fell inside the run, and it needs the per-run
-- distance timeline — which lives in HealthKit on the phone, not here.
--
-- So the computation happens on device (`Engine/BestEfforts.swift`, pure and tested) and
-- this table is where the answer lands so it never has to be computed again. Reading one
-- run's distance samples out of HealthKit is the expensive part of opening a run; doing it
-- 1,476 times is a one-off pass, not something to repeat on every launch.
--
-- ── The distances ────────────────────────────────────────────────────────────────────
-- 400 m, 800 m, 1 mi, 5 K, 10 K, half, marathon — David's list, decided on #25.
-- The keys below are rounded metres and must stay in lockstep with `BestEfforts.distances`
-- in the app; `BestEffortsTests.testCatalogMatchesTheMigrationsCheckConstraint` is the
-- thing that notices if they drift. The app computes on the *true* distance (1609.34 m,
-- 21097.5 m) and stores the rounded key, so a mile PR is a mile and not 1,609 m of it.

create table if not exists run_efforts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  run_id      uuid not null references runs(id) on delete cascade,
  distance_m  integer not null check (distance_m in (400, 800, 1609, 5000, 10000, 21098, 42195)),
  duration_s  integer not null check (duration_s > 0),
  created_at  timestamptz not null default now(),

  -- The pass is idempotent because of this line. A re-scan of a run it already covered
  -- upserts over the same row instead of adding a second, slightly different one, and a
  -- pass killed halfway through can simply be run again.
  unique (run_id, distance_m)
);

-- The PR table reads "best per distance": seven ordered reads, one row each.
create index if not exists run_efforts_best_idx on run_efforts (user_id, distance_m, duration_s);
create index if not exists run_efforts_run_idx  on run_efforts (run_id);

comment on table run_efforts is
  'Fastest segment of each standard distance *within* a single run (#25). Computed on device from the HealthKit distance timeline by Engine/BestEfforts.swift. A missing row means the run never covered that distance — it does not mean zero.';
comment on column run_efforts.distance_m is
  'Rounded metres, and a key rather than a measurement: 1609 is the mile (computed on 1609.34 m) and 21098 is the half (21097.5 m).';
comment on column run_efforts.duration_s is
  'Fastest elapsed seconds over that distance anywhere inside the run. Rounded — HealthKit sample spacing does not support sub-second claims.';

-- ── Which runs have been looked at ───────────────────────────────────────────────────
-- The obvious resume marker is "does this run have any run_efforts rows", and it is wrong:
-- a 2-mile shakeout legitimately produces rows for 400/800/1 mi and nothing else, and a run
-- whose samples HealthKit will not return produces none at all. Under a row-presence rule
-- those runs are re-read from HealthKit on every launch, forever, and the pass never ends.
--
-- "No efforts" is a result, so it gets recorded like one. This column is the only thing
-- that makes the backfill finite, and it is what the progress line on History counts.
alter table runs
  add column if not exists efforts_scanned_at timestamptz;

comment on column runs.efforts_scanned_at is
  'When the sub-distance effort scan last read this run''s HealthKit timeline. NULL means not yet scanned — not "no efforts". Clear it to force a re-scan: update runs set efforts_scanned_at = null;';

create index if not exists runs_efforts_pending_idx
  on runs (user_id, start_time desc) where efforts_scanned_at is null;

-- ── Row-level security ───────────────────────────────────────────────────────────────
alter table run_efforts enable row level security;

create policy "own run_efforts" on run_efforts for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ── Verification (run after; these change nothing) ───────────────────────────────────
--
-- 1. How far the backfill has got, which is the same number the History screen shows:
--
--   select count(*) filter (where efforts_scanned_at is not null) as scanned,
--          count(*)                                              as total
--   from runs where superseded_by is null and source = 'healthkit';
--
-- 2. The PR table, as the app builds it:
--
--   select distinct on (e.distance_m)
--          e.distance_m, e.duration_s, r.start_time::date
--   from run_efforts e join runs r on r.id = e.run_id
--   where r.superseded_by is null
--   order by e.distance_m, e.duration_s;
--
-- 3. The hard invariant — a run cannot hold a segment longer than the run itself
--    (must return zero rows):
--
--   select e.run_id, e.distance_m, r.distance_m as run_distance_m
--   from run_efforts e join runs r on r.id = e.run_id
--   where e.distance_m > r.distance_m + 1;
--
-- 4. The soft one. Effort durations are measured on the HealthKit sample clock, so a
--    segment that spans a pause is legitimately longer than the run's *moving* time —
--    that is the honest answer, not a bug. Compared against the wall clock it should
--    never exceed it, and rows here are worth a look rather than an alarm:
--
--   select e.run_id, e.distance_m, e.duration_s,
--          r.duration_s, r.elapsed_duration_s
--   from run_efforts e join runs r on r.id = e.run_id
--   where r.elapsed_duration_s is not null and e.duration_s > r.elapsed_duration_s;
