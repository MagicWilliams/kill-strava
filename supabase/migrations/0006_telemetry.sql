-- App telemetry (autonomy foundation, 2026-08-16)
-- The app has been a black box: every real bug so far (the vanished plan, the Garmin
-- double-count, HR zones capping at 15s) was found by David noticing something wrong on
-- his phone. This table is the feedback channel that lets an agent see the same things.
--
-- Deliberately NOT a crash reporter. It records the moments the app already knows are
-- interesting — a caught error, a retry, a sync that changed data unexpectedly — so the
-- triage agent can rank recurring events instead of guessing from source alone.

create table if not exists app_events (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  level       text not null check (level in ('info','warn','error')),
  event       text not null,          -- stable dot-path key, e.g. 'sync.dedupe_dropped'
  detail      text,                   -- human-readable one-liner
  context     jsonb not null default '{}'::jsonb,   -- structured payload; NO PII, NO health data
  app_version text,
  os_version  text,
  created_at  timestamptz not null default now()
);

-- Triage reads "what's been happening lately, worst first".
create index if not exists app_events_recent_idx on app_events (created_at desc);
create index if not exists app_events_event_idx  on app_events (event, created_at desc);

alter table app_events enable row level security;

-- Insert-only from the client: the app reports, it never reads or edits its own history.
-- (Prevents a bug in the app from erasing the evidence of that bug.)
create policy "own events insert" on app_events for insert
  with check (user_id = auth.uid());
create policy "own events read" on app_events for select
  using (user_id = auth.uid());

-- Retention: 90 days is well past the point where an unfixed event is still news.
-- Run manually or from a scheduled job; not automatic, so nothing deletes silently.
comment on table app_events is
  'Client telemetry for autonomous triage. Prune with: delete from app_events where created_at < now() - interval ''90 days'';';
