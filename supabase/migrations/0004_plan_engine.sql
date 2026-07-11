-- Plan engine, stage A (spec: progress.md "Plan-engine spec")

-- Chat-mutable plan settings (asked again during onboarding later).
alter table profiles add column if not exists days_per_week smallint not null default 6
  check (days_per_week between 3 and 7);
-- 0 = Sunday … 6 = Saturday
alter table profiles add column if not exists long_run_day smallint not null default 0
  check (long_run_day between 0 and 6);

-- The assessment that shaped the plan (features + proposed shape + rationale),
-- and the live projected finish (recomputed as runs land).
alter table plans add column if not exists assessment jsonb;
alter table plans add column if not exists projected_finish_s integer;
