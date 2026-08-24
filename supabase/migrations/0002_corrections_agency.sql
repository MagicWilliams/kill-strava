-- Corrections + athlete agency (design decisions 2026-07-08)
-- Runs become editable (coach write tools); Supabase `runs` is now the read path.
-- Risk tolerance is a standing athlete preference; check-ins are the trust mechanism.

-- ─── Run corrections ───────────────────────────────────────────────────────
-- Ingest from HealthKit is insert-only, so these fields survive re-sync.
alter table runs add column if not exists corrected boolean not null default false;
alter table runs add column if not exists correction_note text;   -- what changed / provenance
alter table runs add column if not exists original jsonb;         -- pre-correction snapshot (first correction only)

-- ─── Risk tolerance (user agency over paternalism) ─────────────────────────
alter table profiles add column if not exists risk_tolerance text not null default 'standard'
  check (risk_tolerance in ('standard','ambitious'));

-- What risk was named when the athlete confirmed ambitious mode (audit of informed consent).
create table if not exists risk_acknowledgments (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  risk       text not null,
  created_at timestamptz not null default now()
);
alter table risk_acknowledgments enable row level security;
create policy "own acks" on risk_acknowledgments for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ─── Daily check-ins (self-report: gates hard sessions, feeds readiness) ───
create table if not exists check_ins (
  user_id    uuid not null references auth.users(id) on delete cascade,
  date       date not null,
  feels_ok   boolean not null,
  note       text,
  created_at timestamptz not null default now(),
  primary key (user_id, date)
);
alter table check_ins enable row level security;
create policy "own check_ins" on check_ins for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());
