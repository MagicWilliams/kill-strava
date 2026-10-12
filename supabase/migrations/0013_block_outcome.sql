-- A training block can end (#100): the goal records how.
--
-- ⚠️  UNAPPLIED. Nobody but David (or the EM, on his say-so) applies a migration. Apply this
--     before merging the app change that reads it. Until these columns exist the app still
--     runs: the "review your block" card and the Block Review screen work from the active
--     plan, but "Close this block" fails its write (and says so) and Past blocks stays hidden.
--
-- Numbered 0013, not 0012: 0012 is already `run_overlap_reviews` (#85). Two files sharing a
-- prefix is how 0002 ended up ambiguous; not repeating it.
--
-- ── What is wrong ────────────────────────────────────────────────────────────────────
-- Chicago was 2026-10-11. Nothing in the schema can say a block *ended*: the goal stays
-- `is_active` with a race date in the past and the plan stays `active` with no sessions left.
-- The only existing way a goal goes inactive is the plan function retiring it when a new plan
-- is generated — which happened four times on 2026-07-10 alone (0010). So `is_active = false`
-- cannot mean "finished"; it also means "superseded by a regeneration". `completed_at` is
-- what tells a closed block apart from a discarded draft, and it is what Past blocks lists.
--
-- ── Shape ────────────────────────────────────────────────────────────────────────────
-- completed_at   when the athlete closed the block. Never set automatically.
-- outcome        how it ended. 'abandoned' is the block given up before race day; the app's
--                close-out offers raced / did_not_start / did_not_finish.
-- result_time_s  official finish time in seconds — typed by hand, or confirmed from the race
--                run. The *primary* path is by hand: Chicago 2026 was run with no watch and
--                Strava paused mid-race, so there is no race run to read it from.
-- race_run_id    the run that was the race, when there is one. `on delete set null`: deleting
--                a run must never take a finished block's result with it.
-- review         the coach's cached retrospective, {"v":1,"text":…,"generated_at":…}. One
--                Claude call per block, not one per screen open.
--
-- Closing writes these plus `is_active = false`, and `plans.status = 'done'` on the block's
-- plan ('done' is already in the 0001 check constraint). No new policy: "own goals" (0001)
-- already scopes every column of the row.

alter table goals add column if not exists completed_at  timestamptz;
alter table goals add column if not exists outcome       text;
alter table goals add column if not exists result_time_s integer;
alter table goals add column if not exists race_run_id   uuid references runs(id) on delete set null;
alter table goals add column if not exists review        jsonb;

alter table goals add constraint goals_outcome_check
  check (outcome in ('raced', 'did_not_start', 'did_not_finish', 'abandoned'));

-- A closed block always says how it ended, and only a closed block does.
alter table goals add constraint goals_outcome_closed_check
  check ((completed_at is null) = (outcome is null));

-- A finish time belongs to a race that was run, and is a real duration.
alter table goals add constraint goals_result_time_check
  check (result_time_s is null or (outcome = 'raced' and result_time_s > 0));

comment on column goals.completed_at is
  'When the athlete closed this block (#100). Null = still open, or superseded by a plan regeneration (is_active=false alone does not mean finished).';
comment on column goals.outcome is
  'How the block ended: raced | did_not_start | did_not_finish | abandoned. Set with completed_at, never without it.';
comment on column goals.result_time_s is
  'Official finish time, seconds. Entered by hand or confirmed from race_run_id.';
comment on column goals.race_run_id is
  'The run that was the race, if one exists. Null for a race run without a recording device.';
comment on column goals.review is
  'Cached coach retrospective for the block: {"v":1,"text":string,"generated_at":timestamptz}.';

-- ── Dry run (changes nothing; run before and after) ──────────────────────────────────
--
--   -- before: the block about to be closed — expect one row, Chicago, 2026-10-11, 3:15:00
--   select g.id, g.race_name, g.race_date, g.goal_time_seconds, g.distance,
--          p.id as plan_id, p.start_date, p.weeks
--     from goals g join plans p on p.goal_id = g.id
--    where g.is_active and p.status = 'active';
--
--   -- after applying: five new columns, null on every existing row — expect 0
--   select count(*) from goals
--    where completed_at is not null or outcome is not null or result_time_s is not null
--       or race_run_id is not null or review is not null;
--
--   -- after David closes Chicago in the app: expect one row, is_active false, plan done
--   select g.race_name, g.outcome, g.result_time_s, g.race_run_id, g.completed_at, g.is_active,
--          p.status, g.review->>'text' is not null as has_review
--     from goals g join plans p on p.goal_id = g.id
--    where g.completed_at is not null;
--
-- ── Reopen a block by hand (what an Undo would do) ───────────────────────────────────
--
--   update goals set completed_at = null, outcome = null, result_time_s = null,
--                    race_run_id = null, is_active = true where id = '<goal id>';
--   update plans set status = 'active' where id = '<plan id>';
