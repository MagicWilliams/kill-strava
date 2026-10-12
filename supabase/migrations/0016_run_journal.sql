-- Run journal (#120): what the athlete says about a run after finishing it — effort, feel,
-- notes, a title, a photo, and the shoes it was run in.
--
-- ⚠️  UNAPPLIED. The EM applies it (staging, then production). The app reads these columns
--     only after checking they exist: until this lands, the archive read falls back to the
--     pre-journal column list and every run shows an empty journal, so shipping the app
--     first is harmless — journal writes simply fail and are logged.
--
-- ── What this is ─────────────────────────────────────────────────────────────────────
-- The recorder's post-run screen (#129) collects RPE, feel + notes, title + photo, and shoe.
-- None of that had anywhere to live. Text lands on `runs`; the photo lands in a private
-- Storage bucket, with its object key on `runs.photo_path`; shoes get their own table so a
-- pair can be retired and its mileage totalled (#121).
--
-- ── Order matters ────────────────────────────────────────────────────────────────────
-- 1. `shoes` first — `runs.shoe_id` references it.
-- 2. `runs` journal columns.
-- 3. The `run-photos` bucket and its policies on storage.objects.
--
-- Purely additive: no existing column changes, no row is rewritten, every new `runs`
-- column is nullable with no default, so `alter table` is a catalog-only change on 2,000+
-- rows. The app's archive read names its columns explicitly, so it is unaffected until the
-- journal-aware build asks for them.
--
-- Reversible with (photos in the bucket must be removed through the Storage API first;
-- Postgres will not delete Storage objects for you):
--   drop policy if exists "run photos: read own"   on storage.objects;
--   drop policy if exists "run photos: insert own" on storage.objects;
--   drop policy if exists "run photos: update own" on storage.objects;
--   drop policy if exists "run photos: delete own" on storage.objects;
--   delete from storage.buckets where id = 'run-photos';   -- only once it is empty
--   alter table runs drop column if exists shoe_id, drop column if exists photo_path,
--     drop column if exists title, drop column if exists notes,
--     drop column if exists feel_tags, drop column if exists rpe;
--   drop table if exists shoes;

-- ── 1. Shoes ─────────────────────────────────────────────────────────────────────────
create table if not exists shoes (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  name             text not null check (length(btrim(name)) > 0),
  brand            text,
  model            text,
  started_at       timestamptz not null default now(),
  retired_at       timestamptz,
  -- Miles already on the pair before Tempo saw it, in metres (the app's one distance unit
  -- in storage; display converts). A pair bought used, or worn before the athlete switched
  -- apps, would otherwise read as new.
  start_mileage_m  integer not null default 0 check (start_mileage_m >= 0),
  created_at       timestamptz not null default now(),

  check (retired_at is null or retired_at >= started_at)
);
create index if not exists shoes_user_idx on shoes(user_id);

comment on table shoes is
  'The athlete''s shoes (#120/#121). Mileage = start_mileage_m + sum(runs.distance_m where shoe_id = id). Retire, never delete: deleting a pair nulls shoe_id on every run it was worn for.';

alter table shoes enable row level security;

-- Same policy shape as `runs` (0001): every row is the athlete's own.
drop policy if exists "own shoes" on shoes;
create policy "own shoes" on shoes
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ── 2. The journal on runs ───────────────────────────────────────────────────────────
alter table runs
  add column if not exists rpe        smallint check (rpe is null or rpe between 1 and 10),
  add column if not exists feel_tags  text[],
  add column if not exists notes      text,
  add column if not exists title      text,
  add column if not exists photo_path text,
  add column if not exists shoe_id    uuid references shoes(id) on delete set null;

-- Covering index for the foreign key — the Supabase advisor flags an unindexed FK (#98),
-- and "every run in this pair" is exactly the query shoe mileage runs. Partial: most of the
-- archive predates shoes and will never carry one.
create index if not exists runs_shoe_idx on runs(shoe_id) where shoe_id is not null;

comment on column runs.rpe is
  'Session RPE, 1–10, as the athlete reported it after the run. NULL = not asked or not answered.';
comment on column runs.feel_tags is
  'Short feel tags picked after the run (e.g. {"heavy legs","smooth"}). NULL = none picked.';
comment on column runs.notes is
  'Free-text post-run notes. The athlete''s own words; never sent to telemetry.';
comment on column runs.title is
  'Athlete-given title. NULL = the app names the run.';
comment on column runs.photo_path is
  'Object key inside the private run-photos bucket: <auth uid, lowercase>/<run id>/<photo id>.jpg. Read via a signed URL.';
comment on column runs.shoe_id is
  'Shoes worn. SET NULL if the shoe row is deleted, so a run never disappears with its shoes.';

-- ── 3. Photo storage ─────────────────────────────────────────────────────────────────
-- Private: a photo is read through a short-lived signed URL, never a public link. The app
-- resizes to ≤ 2048 px JPEG before upload (well under 2 MB in practice); the 10 MB cap is
-- a backstop, not the budget. JPEG only, because that is the only thing the app writes.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('run-photos', 'run-photos', false, 10485760, array['image/jpeg'])
on conflict (id) do nothing;

-- Ownership is the first path segment: `<auth.uid()>/…`. `auth.uid()::text` is the
-- LOWERCASE uuid form; Swift's `UUID.uuidString` is UPPERCASE. The app lowercases the
-- prefix (`RunJournalPayload.photoPath`, pinned by tests) — an uppercase prefix would be
-- refused by every one of these policies.
--
-- All four verbs: the app uploads with `upsert: true` so a retry after a lost response
-- overwrites its own object instead of failing as a duplicate, and Storage's upsert needs
-- select + insert + update.
--
-- RLS on storage.objects is already enabled by Supabase and the table is owned by
-- supabase_storage_admin — do not `alter table storage.objects …` here.
drop policy if exists "run photos: read own" on storage.objects;
create policy "run photos: read own" on storage.objects
  for select to authenticated
  using (bucket_id = 'run-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "run photos: insert own" on storage.objects;
create policy "run photos: insert own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'run-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "run photos: update own" on storage.objects;
create policy "run photos: update own" on storage.objects
  for update to authenticated
  using (bucket_id = 'run-photos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'run-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "run photos: delete own" on storage.objects;
create policy "run photos: delete own" on storage.objects
  for delete to authenticated
  using (bucket_id = 'run-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- ── Verify ───────────────────────────────────────────────────────────────────────────
--   select column_name, data_type from information_schema.columns
--    where table_name = 'runs'
--      and column_name in ('rpe','feel_tags','notes','title','photo_path','shoe_id');
--     -- six rows
--   select count(*) from runs where rpe is not null or notes is not null;
--     -- 0 right after applying: nothing was backfilled
--   select id, public, file_size_limit, allowed_mime_types from storage.buckets
--    where id = 'run-photos';
--     -- one row, public = false
--   select policyname, cmd from pg_policies
--    where schemaname = 'storage' and tablename = 'objects' and policyname like 'run photos:%';
--     -- four rows: SELECT, INSERT, UPDATE, DELETE
--   select tablename, policyname from pg_policies where tablename = 'shoes';
--     -- "own shoes"
