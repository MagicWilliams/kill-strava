-- Tempo v1 schema
-- Postgres (Supabase). Row-level security: a user only ever sees their own rows.

create extension if not exists "pgcrypto";

-- ─── Profile ──────────────────────────────────────────────────────────────
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text,
  units       text not null default 'mi' check (units in ('mi','km')),
  coach_voice text not null default 'calm_expert',
  created_at  timestamptz not null default now()
);

-- ─── Goal ─────────────────────────────────────────────────────────────────
create table if not exists goals (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  race_name         text,
  race_date         date,
  distance          text not null check (distance in ('5k','10k','half','marathon')),
  goal_time_seconds integer,             -- target finish time
  days_per_week     smallint not null default 5 check (days_per_week between 3 and 7),
  start_mileage     numeric,             -- current weekly volume (in `units`)
  is_active         boolean not null default true,
  created_at        timestamptz not null default now()
);
create index if not exists goals_user_idx on goals(user_id);

-- ─── Plan ─────────────────────────────────────────────────────────────────
create table if not exists plans (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  goal_id    uuid not null references goals(id) on delete cascade,
  start_date date not null,
  weeks      smallint not null,
  status     text not null default 'active' check (status in ('active','paused','done')),
  created_at timestamptz not null default now()
);
create index if not exists plans_user_idx on plans(user_id);

create table if not exists plan_weeks (
  id             uuid primary key default gen_random_uuid(),
  plan_id        uuid not null references plans(id) on delete cascade,
  week_index     smallint not null,      -- 0-based
  phase          text not null check (phase in ('base','build','peak','taper')),
  target_mileage numeric,
  focus          text
);
create index if not exists plan_weeks_plan_idx on plan_weeks(plan_id);

-- ─── Sessions (planned workouts) ──────────────────────────────────────────
create table if not exists sessions (
  id               uuid primary key default gen_random_uuid(),
  plan_id          uuid not null references plans(id) on delete cascade,
  week_id          uuid references plan_weeks(id) on delete cascade,
  user_id          uuid not null references auth.users(id) on delete cascade,
  date             date not null,
  type             text not null check (type in ('easy','long','tempo','threshold','interval','rest','race','cross')),
  title            text,
  target_distance_m integer,
  target_pace_sec   integer,             -- sec per `units`
  structure        jsonb,                -- steps: warmup/reps/cooldown
  status           text not null default 'planned' check (status in ('planned','done','skipped')),
  adapted          boolean not null default false,
  adaptation_note  text,
  run_id           uuid,                 -- linked completed run (set by matcher)
  created_at       timestamptz not null default now()
);
create index if not exists sessions_user_date_idx on sessions(user_id, date);

-- ─── Runs (completed activities, ingested from HealthKit) ─────────────────
create table if not exists runs (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  source         text not null default 'healthkit',
  external_id    text,                   -- HKWorkout uuid for dedupe
  start_time     timestamptz not null,
  distance_m     integer not null,
  duration_s     integer not null,
  avg_pace_sec   integer,                -- sec per `units`
  avg_hr         smallint,
  splits         jsonb,                  -- [{ idx, pace_sec, hr }]
  hr_drift_pct   numeric,
  load           numeric,                -- training-load score for CTL/ATL
  raw            jsonb,
  created_at     timestamptz not null default now(),
  unique (user_id, source, external_id)
);
create index if not exists runs_user_time_idx on runs(user_id, start_time desc);

-- ─── Daily fitness metrics (CTL/ATL/Form, readiness) ──────────────────────
create table if not exists metrics_daily (
  user_id   uuid not null references auth.users(id) on delete cascade,
  date      date not null,
  ctl       numeric,                     -- chronic load (fitness)
  atl       numeric,                     -- acute load (fatigue)
  form      numeric,                     -- ctl - atl
  readiness smallint,                    -- 0..100
  primary key (user_id, date)
);

-- ─── Coach chat ───────────────────────────────────────────────────────────
create table if not exists coach_messages (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('user','coach')),
  content    text not null,
  created_at timestamptz not null default now()
);
create index if not exists coach_user_time_idx on coach_messages(user_id, created_at);

-- ─── Row-level security ───────────────────────────────────────────────────
alter table profiles       enable row level security;
alter table goals          enable row level security;
alter table plans          enable row level security;
alter table plan_weeks     enable row level security;
alter table sessions       enable row level security;
alter table runs           enable row level security;
alter table metrics_daily  enable row level security;
alter table coach_messages enable row level security;

create policy "own profile"  on profiles       for all using (id = auth.uid())      with check (id = auth.uid());
create policy "own goals"    on goals          for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own plans"    on plans          for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own sessions" on sessions       for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own runs"     on runs           for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own metrics"  on metrics_daily  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own coach"    on coach_messages for all using (user_id = auth.uid()) with check (user_id = auth.uid());
-- plan_weeks inherit access via their plan
create policy "own plan_weeks" on plan_weeks for all
  using (exists (select 1 from plans p where p.id = plan_weeks.plan_id and p.user_id = auth.uid()))
  with check (exists (select 1 from plans p where p.id = plan_weeks.plan_id and p.user_id = auth.uid()));
