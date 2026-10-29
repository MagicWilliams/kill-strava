-- Body reports (#89): what the athlete tells the coach about their body, as data.
--
-- Numbered 0022, not the 0020 this branch was cut with: coach threads (#87) took 0020 and
-- the goals index (#212) took 0021 while this sat in review. Same reasoning as 0021's own
-- note — a shared prefix is how 0002 ended up ambiguous. Nothing here depends on either.
--
-- ⚠️  UNAPPLIED. David applies it. The app ships first and is harmless until it lands:
--     `BodyReportService.snapshot` reports an unreadable table as *unavailable* rather than
--     as "nothing reported", so the Body section stays hidden, readiness is load-plus-check-in
--     exactly as it is today, and a `log_body` card fails with "Confirm to retry" instead of
--     silently dropping the athlete's word.
--
-- ── What this is ─────────────────────────────────────────────────────────────────────
-- "Left calf is tight, maybe a 3 out of 10" used to live in the chat transcript and nowhere
-- else. Readiness could hear the athlete only as a binary — `check_ins.feels_ok` — so a 3
-- and an 8 moved the number identically (both to the 40 cap) or not at all. This table is
-- the middle ground: a severity the load model can read, and a status the athlete controls.
--
-- ── The three statuses ───────────────────────────────────────────────────────────────
-- `open`     — reported, live.
-- `watching` — live, and the coach is tracking it across sessions. Same standing as `open`
--              for readiness: see `Engine/BodyReports.swift` for why severity alone decides
--              the cap. A 6/10 the coach happened to label "watching" must not quietly stop
--              capping readiness.
-- `cleared`  — resolved. The only status that stops counting, and `cleared_at` says when.
--
-- ── Severity ─────────────────────────────────────────────────────────────────────────
-- 0–10, the athlete's own number, in the same spirit as `runs.rpe`. The readiness threshold
-- lives in the app (`BodyReports.capSeverity`), not here: it is a tuning knob David changes
-- in a one-line diff, and baking it into a check constraint would make it a migration.
--
-- Reversible with:
--   drop table if exists body_reports;

create table if not exists body_reports (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  -- Free text, both of them: the body has more parts than an enum would ever list, and
  -- "left calf" / "tight" is the athlete's phrasing carried through to the card.
  area              text not null check (length(btrim(area)) > 0),
  sensation         text not null check (length(btrim(sensation)) > 0),
  severity          smallint not null check (severity between 0 and 10),
  status            text not null default 'open' check (status in ('open', 'watching', 'cleared')),
  opened_at         timestamptz not null default now(),
  cleared_at        timestamptz,
  -- The coach message whose card logged this, so the Body section can link back to the
  -- conversation it came from. No FK: `coach_messages` rows are the athlete's and can be
  -- pruned, and losing the link must never take the report with it.
  source_message_id uuid,
  created_at        timestamptz not null default now(),

  -- A cleared report has a date; a live one does not. Keeps "cleared but still counting"
  -- out of the data rather than relying on every reader to check both columns.
  check ((status = 'cleared') = (cleared_at is not null)),
  check (cleared_at is null or cleared_at >= opened_at)
);

-- The app's only query: this athlete's reports, newest first. Covers the FK to auth.users
-- too, which the performance advisor would otherwise flag (#98, #212).
create index if not exists body_reports_user_opened_idx on body_reports(user_id, opened_at desc);

comment on table body_reports is
  'What the athlete reported about their body (#89), logged by the coach''s log_body card. A live report (status open|watching) at severity >= BodyReports.capSeverity caps readiness the way a negative check-in does; clearing it restores the number.';
comment on column body_reports.severity is
  'The athlete''s own 0–10 number for how bad it is. The readiness threshold is in the app (Engine/BodyReports.swift), deliberately not in a constraint here.';
comment on column body_reports.status is
  'open | watching | cleared. Only cleared stops counting toward readiness — severity decides the cap, not which live label the coach chose.';
comment on column body_reports.source_message_id is
  'The coach_messages row whose confirm card logged this. Unenforced by design: pruning chat must not delete the report.';

alter table body_reports enable row level security;

-- Same policy shape as `runs` (0001) and `shoes` (0016): every row is the athlete's own.
drop policy if exists "own body_reports" on body_reports;
create policy "own body_reports" on body_reports
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ── Verify ───────────────────────────────────────────────────────────────────────────
--   select column_name, data_type from information_schema.columns
--    where table_name = 'body_reports' order by ordinal_position;
--     -- nine rows
--   select policyname, cmd from pg_policies where tablename = 'body_reports';
--     -- "own body_reports", ALL
--   select indexname from pg_indexes where tablename = 'body_reports' order by indexname;
--     -- body_reports_pkey, body_reports_user_opened_idx
--   select count(*) from body_reports;
--     -- 0: nothing is backfilled
