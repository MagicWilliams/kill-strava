-- One active plan, one active goal — stand down the three inert duplicates.
--
-- ⚠️  NOT APPLIED. Nobody but David applies a migration (CLAUDE.md). This file is the
--     proposal; the two counts at the bottom are how it gets proved.
--
-- ── What is wrong ────────────────────────────────────────────────────────────────────
-- Four `goals` rows carry `is_active = true` and four `plans` rows carry `status =
-- 'active'` at the same time, all created inside ~75 minutes on 2026-07-10 during a run of
-- plan regenerations. Each regeneration wrote a fresh goal and plan without clearing the
-- flag on its predecessor. Re-confirmed read-only on 2026-10-03: still 4 and 4.
--
-- Two different goal times are live at once (3:15 and 3:30) and three different projected
-- finishes. So every `where is_active` / `where status = 'active'` read has four candidates
-- and no declared tie-break. It has been benign only because `created_at desc` happens to
-- return the right row — that is luck, not a rule, and the luck runs out the first time a
-- read orders by anything else.
--
-- ── Which one survives, and why ──────────────────────────────────────────────────────
-- Plan `655a140b…` / goal `2291695a…`, goal time 3:15:00. It is the newest of the four and
-- the only one ever used: all 20 `done` sessions hang off it, the most recent on 8 Sep. The
-- other three have zero completed sessions. This is the plan David has actually been
-- training on, so its goal time is the real one.
--
-- ── Named rows only ──────────────────────────────────────────────────────────────────
-- Both statements list literal UUIDs — not a `created_at` ordering, not a subquery, not
-- `where id <> '655a140b…'`. A rule would re-interpret itself if the data moved under it;
-- six named rows mean the diff is auditable by eye, and re-running this with
-- `status = 'active'` / `is_active = true` reverts it exactly.
--
-- No DELETE: the inert plans keep their weeks and sessions, they just stop claiming to be
-- current. No schema change — the partial unique index that would make four-active
-- unrepresentable is deliberately deferred (see #64, out of scope until after Chicago).
--
-- `'done'` is the stood-down value already in use: it is in the check constraint on
-- `plans.status` in 0001_init.sql, and it is what the retire path in
-- supabase/functions/plan/index.ts writes to plans it supersedes.

-- Three inert plans → done. Keeps 655a140b-d1c3-45af-a417-0244d4efe6db active.
update plans
   set status = 'done'
 where id in (
   '8954e49a-058a-4ec0-97fd-02753e682911',   -- 3:15:00, 0 done sessions
   'dcba848c-faae-43d7-89cd-d467f54f55fc',   -- 3:30:00, 0 done sessions
   'fc9a7e7d-bb99-4dbb-b7b4-8514660f49c2'    -- 3:30:00, 0 done sessions
 );

-- Their three goals → inactive. Keeps 2291695a-d680-4a25-a63b-f9e654293288 (3:15:00) active.
update goals
   set is_active = false
 where id in (
   '9966ae7f-6fbd-4bb3-99ed-d74db8b852c7',   -- 3:15:00
   'b00a8e9c-fe55-4a5f-916f-970ce259b4b9',   -- 3:30:00
   '0155a045-9c48-4732-8cb2-1b27f4e733c1'    -- 3:30:00
 );

-- ── Verification (run these after; they change nothing) ──────────────────────────────
--
--   -- expect 1 and 1
--   select count(*) from goals where is_active;
--   select count(*) from plans where status = 'active';
--
--   -- expect exactly the kept pair, 3:15:00, with the 20 done sessions
--   select p.id as plan_id, g.id as goal_id, g.goal_time_seconds,
--          count(*) filter (where s.status = 'done') as done_sessions
--     from plans p
--     join goals g on g.id = p.goal_id
--     left join sessions s on s.plan_id = p.id
--    where p.status = 'active' and g.is_active
--    group by p.id, g.id, g.goal_time_seconds;
