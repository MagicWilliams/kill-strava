-- Training intake (#102): every race from the mile to the marathon, and what the athlete
-- wants from the block.
--
-- ── What this is ─────────────────────────────────────────────────────────────────────
-- The "Train for something" intake asks for the race (any distance, its course, the kind
-- of goal), how much plan the athlete wants, and what they want coached. Those answers
-- land on the goal row, because the goal is the block: `plan` (#104) shapes the schedule
-- from them, and the coach weights its advice toward `preferences.focus`.
--
-- ── Changes ──────────────────────────────────────────────────────────────────────────
-- 1. `goals.distance` widens from ('5k','10k','half','marathon') to every race the intake
--    offers, plus 'custom'. It stays the LABEL.
-- 2. `goals.distance_m` is the source of truth for math. Backfilled from the label for
--    every existing row, so no goal is left without one.
-- 3. `course_type`, `goal_type`, `started_week` (mid-block import), and `preferences`
--    (versioned jsonb: {v:1, plan_style, long_runs_20plus, course_type, focus[], quality[],
--    notes}).
--
-- Purely additive apart from the widened check: every existing row satisfies the new one,
-- nothing is dropped, and the app reads goals with `select *` so it works on either side
-- of this migration.
--
-- ── Does not touch ───────────────────────────────────────────────────────────────────
-- #100's 0012 block-outcome columns (completed_at, outcome, result_time_s, race_run_id,
-- review). No column here shares a name with them, and the two apply in either order.
--
-- Reversible with:
--   alter table goals drop column if exists preferences, drop column if exists started_week,
--     drop column if exists goal_type, drop column if exists course_type,
--     drop column if exists distance_m;
--   -- and, only if no row uses a new label:
--   alter table goals drop constraint goals_distance_check;
--   alter table goals add constraint goals_distance_check
--     check (distance in ('5k','10k','half','marathon'));

-- ── 1. Widen the distance label ──────────────────────────────────────────────────────
-- 0001 declared the check inline, so Postgres named it. It is `goals_distance_check` by
-- default, but rather than bet production on the default, drop whichever CHECK constraint
-- on `goals` constrains the `distance` column alone.
do $$
declare
  c record;
begin
  for c in
    select con.conname
      from pg_constraint con
      join pg_attribute att
        on att.attrelid = con.conrelid and att.attnum = any (con.conkey)
     where con.conrelid = 'public.goals'::regclass
       and con.contype = 'c'
       and att.attname = 'distance'
       and array_length(con.conkey, 1) = 1
  loop
    execute format('alter table public.goals drop constraint %I', c.conname);
  end loop;
end $$;

alter table goals
  add constraint goals_distance_check
    check (distance in ('1mi','5k','10k','15k','10mi','half','marathon','custom'));

-- ── 2. distance_m, the number the math uses ──────────────────────────────────────────
alter table goals
  add column if not exists distance_m integer
    check (distance_m is null or distance_m between 400 and 100000);

update goals
   set distance_m = case distance
         when '1mi'      then 1609
         when '5k'       then 5000
         when '10k'      then 10000
         when '15k'      then 15000
         when '10mi'     then 16093
         when 'half'     then 21098
         when 'marathon' then 42195
       end
 where distance_m is null
   and distance <> 'custom';

-- A custom race has no label to fall back on; its metres are the only distance it has.
alter table goals drop constraint if exists goals_custom_distance_has_meters;
alter table goals
  add constraint goals_custom_distance_has_meters
    check (distance <> 'custom' or distance_m is not null);

-- ── 3. What the athlete told the intake ──────────────────────────────────────────────
alter table goals
  add column if not exists course_type text
    check (course_type is null or course_type in ('flat','rolling','hilly','trail'));

alter table goals
  add column if not exists goal_type text
    check (goal_type is null or goal_type in ('time','finish','pr','unsure'));

-- Mid-block import: the week of the block the athlete was in when the plan was built
-- (1-based). NULL for a block started from week 1.
alter table goals
  add column if not exists started_week smallint
    check (started_week is null or started_week between 1 and 52);

alter table goals
  add column if not exists preferences jsonb
    check (preferences is null or jsonb_typeof(preferences) = 'object');

comment on column goals.distance is
  'Race distance LABEL: 1mi | 5k | 10k | 15k | 10mi | half | marathon | custom. Math reads distance_m.';
comment on column goals.distance_m is
  'Race distance in metres — the source of truth for every calculation. Required for custom.';
comment on column goals.course_type is
  'flat | rolling | hilly | trail. Rolling/hilly put hill work in the build (#104).';
comment on column goals.goal_type is
  'time | finish | pr | unsure. Anything but time: the coach proposed the target from the data.';
comment on column goals.started_week is
  'Mid-block import: the block week (1-based) the athlete was in when this plan was built. NULL = started at week 1.';
comment on column goals.preferences is
  'Versioned intake answers: {v:1, plan_style: full|weekly|none, long_runs_20plus, course_type, focus: [fueling|pacing|race_day|recovery|strength|mental], quality: [intervals|tempo|hills|race_pace], notes}.';

-- ── Verify ───────────────────────────────────────────────────────────────────────────
--   select distance, distance_m, count(*) from goals group by 1, 2 order by 1;
--     -- every row has distance_m; marathon rows read 42195
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--    where conrelid = 'public.goals'::regclass and contype = 'c';
--     -- exactly one check on distance, listing all eight labels
