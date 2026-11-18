-- The weekly coach review (#91), and the allowance that bounds it.
--
-- ⚠️  UNAPPLIED. David applies it. Apply before merging the app change that reads it: until
--     this table exists the Weekly review row reads as unwritten forever (the read fails,
--     the app keeps the row quiet), and the `review` coach mode has nowhere to store what
--     it writes.
--
-- Numbered 0026: 0022 is claimed by an in-flight branch (body reports, #89), the same note
-- 0023 carries, and 0023 through 0025 are taken.
--
-- ── What this is ─────────────────────────────────────────────────────────────────────
-- The app can say what happened today and what the plan says next, and nothing in it steps
-- back one week. The weekly review is that step back: one write-up per finished training
-- week, generated once and then read, not regenerated.
--
-- One row per athlete per week, which is what `unique (user_id, week_of)` is for. The
-- generation trigger is "the first time Coach home opens on or after Monday", and two
-- appearances can race (a tab switch, then a pull to refresh). Without the constraint the
-- loser of that race writes a second review of the same week and the screen has two
-- answers; with it, the second insert is refused and the app reads the row that won.
--
-- ── Why the prose is split, not one blob ─────────────────────────────────────────────
-- The screen renders a headline and three labelled sections (Training / How the plan moved
-- / Next week). Storing them as one block of text would mean parsing the labels back out of
-- prose on every read, months after it was written, and every way that fails is silent: a
-- model that renames a heading would leave the screen showing one long paragraph under
-- "Training" and nothing under the other two. `review.ts` parses once, at the moment of the
-- round trip, and refuses anything half-formed; this table stores the result in the shape
-- the screen draws.
--
-- `stats` holds the numbers the tiles show, as computed at the time of writing
-- (`Engine/WeeklyReview.swift`). Stored rather than recomputed on read for the same reason:
-- a review is the coach's account of one week, and the archive underneath it moves — a
-- Garmin re-export or a corrected run would make last month's review quote numbers its own
-- prose contradicts.
--
-- Reversible with:
--   drop table if exists weekly_reviews;
--   delete from usage_limits where kind = 'review';

create table if not exists weekly_reviews (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  -- The Monday that opens the week being reviewed, in the athlete's own Mon–Sun weeks
  -- (`RunHistory.weekStart`). A date and not a timestamp: a week is named, not timed.
  week_of    date not null,
  -- One line, the first thing on the screen.
  headline   text not null check (length(btrim(headline)) > 0),
  -- {"training": "...", "plan_moved": "...", "next_week": "..."} — see review.ts, which
  -- returns nothing at all rather than a review missing a section.
  body       jsonb not null,
  -- The tiles: miles against plan, sessions done, form at each end of the week.
  stats      jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  -- When the athlete opened it. Null is what puts the dot on the Coach home row, so this is
  -- the whole of "unread" — there is no separate flag to disagree with it.
  read_at    timestamptz,

  unique (user_id, week_of),
  check (read_at is null or read_at >= created_at)
);

comment on table weekly_reviews is
  'One coach write-up per finished training week (#91), generated the first time Coach home opens on or after Monday and then never regenerated. body holds the three sections the screen draws; stats holds the numbers as they stood when it was written. read_at null means the Coach home row shows its unread dot.';

-- The app reads exactly one shape: "my reviews, newest week first". The unique constraint
-- above already indexes (user_id, week_of) and covers the foreign key with user_id leading,
-- which is what the performance advisor asks of a FK column (#98, #212, #254) — so there is
-- deliberately no second index here.

alter table weekly_reviews enable row level security;

-- Same policy as every other athlete-owned table, written the way 0023 left them:
-- `(select auth.uid())` so the planner evaluates it once per statement instead of once per
-- row. Dropped first, as in 0016 and 0020, so the file is re-runnable.
drop policy if exists "own weekly reviews" on weekly_reviews;
create policy "own weekly reviews" on weekly_reviews
  for all using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ── The allowance ────────────────────────────────────────────────────────────────────
-- A review is one model round trip per athlete per week, so these are the smallest limits
-- in the table. They exist for the same reason the others do (0024): the ceiling on what a
-- single account can spend has to be a row in the database, not a line in a function that a
-- retry loop can walk past. `usage_claim_test.ts` holds every kind the functions can claim
-- to having both windows.
insert into usage_limits (kind, window_s, max_calls) values
  ('review', 3600,  5),
  ('review', 86400, 10)
on conflict (kind, window_s) do nothing;

-- ── Check (changes nothing) ──────────────────────────────────────────────────────────
--
-- The table starts empty; the first review lands the next time Coach home opens on or
-- after a Monday — expect 0 rows today, and never more than one per athlete per week:
--
--   select count(*) as reviews, count(distinct user_id) as athletes from weekly_reviews;
--
-- Both windows are in place for the new kind — expect two rows, 3600 then 86400:
--
--   select window_s, max_calls from usage_limits where kind = 'review' order by window_s;
