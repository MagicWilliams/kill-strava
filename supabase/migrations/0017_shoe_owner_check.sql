-- A run can only be worn in its own athlete's shoes (#121).
--
-- ⚠️  UNAPPLIED. The EM applies it (staging, then production). Requires 0016.
--     Requires Postgres 15+ for `on delete set null (shoe_id)` — check `select version();`.
--
-- ── The gap ──────────────────────────────────────────────────────────────────────────
-- 0016 gave `runs.shoe_id` a plain `references shoes(id)`. RLS on `runs` lets an athlete
-- update only their own rows, but it says nothing about *what* they write into them, and a
-- foreign-key check is not subject to RLS — it sees every shoe in the table. So a client
-- that knows (or guesses) another athlete's shoe id can set it on its own run: the write
-- succeeds, and that run's miles now count toward a pair it can't even read. Today there is
-- one athlete; the hole is still the wrong shape to ship a public app on.
--
-- ── The fix: a composite foreign key ─────────────────────────────────────────────────
-- `(runs.shoe_id, runs.user_id) → (shoes.id, shoes.user_id)`. The pair must exist together,
-- so a shoe id belonging to anyone else is refused (23503) by the constraint itself.
-- Chosen over a trigger because it is declarative and closes both directions at once: a
-- trigger on `runs` alone would still let someone move a worn shoe to another `user_id`
-- afterwards, whereas the FK refuses that update too (NO ACTION on update).
--
-- `on delete set null (shoe_id)` keeps 0016's promise — deleting a pair nulls the shoe on
-- its runs and never touches `runs.user_id` (which is NOT NULL; a bare `set null` would try
-- to null both columns and fail the delete).
--
-- MATCH SIMPLE (the default): a run with no shoe has a NULL in the pair and is not checked,
-- which is all 2,000+ existing runs.
--
-- Re-runnable: every object is dropped-if-exists before it is created. Applied as one
-- transaction (as every migration here is), so a refused validation changes nothing.
--
-- Reversible with:
--   alter table runs drop constraint if exists runs_shoe_owner_fkey;
--   alter table runs add constraint runs_shoe_id_fkey
--     foreign key (shoe_id) references shoes(id) on delete set null;
--   drop index if exists runs_shoe_user_idx;
--   create index if not exists runs_shoe_idx on runs(shoe_id) where shoe_id is not null;
--   alter table shoes drop constraint if exists shoes_id_user_key;

-- ── Precheck — must return zero rows before applying ────────────────────────────────
--   select r.id, r.user_id, s.user_id as shoe_owner
--     from runs r join shoes s on s.id = r.shoe_id
--    where s.user_id <> r.user_id;
-- Any row here is a run already pointing at someone else's shoe; VALIDATE below will
-- refuse the new constraint, and the migration fails with nothing changed.

-- 1. Drop the old FK (and, on a re-run, this migration's own objects) — the composite FK
--    depends on the unique key, so it goes first.
alter table runs  drop constraint if exists runs_shoe_owner_fkey;
alter table runs  drop constraint if exists runs_shoe_id_fkey;
alter table shoes drop constraint if exists shoes_id_user_key;

-- 2. The target of a composite FK must be unique. `id` already is; this names the pair.
alter table shoes
  add constraint shoes_id_user_key unique (id, user_id);

-- 3. The owner-aware FK. Validates every existing run as it is added (a handful at most
--    carry a shoe; the partial index keeps the rest out of it).
alter table runs
  add constraint runs_shoe_owner_fkey
  foreign key (shoe_id, user_id) references shoes(id, user_id)
  on update no action
  on delete set null (shoe_id);

-- 4. Cover the new FK's columns (the Supabase advisor flags an unindexed FK, #98). Still
-- partial — most of the archive will never carry a shoe — and it still serves "every run
-- in this pair", which is the shoe-mileage query.
create index if not exists runs_shoe_user_idx on runs(shoe_id, user_id) where shoe_id is not null;
drop index if exists runs_shoe_idx;

comment on column runs.shoe_id is
  'Shoes worn. Must be one of this run''s athlete''s own shoes (FK runs_shoe_owner_fkey, 0017). SET NULL if the shoe row is deleted, so a run never disappears with its shoes.';

-- ── Verify ───────────────────────────────────────────────────────────────────────────
--   select conname, pg_get_constraintdef(oid), convalidated from pg_constraint
--    where conrelid = 'runs'::regclass and conname like 'runs_shoe%';
--     -- one row: runs_shoe_owner_fkey, FOREIGN KEY (shoe_id, user_id) REFERENCES
--     --   shoes(id, user_id) ON DELETE SET NULL (shoe_id), convalidated = true
--     -- and no runs_shoe_id_fkey
--   select indexname from pg_indexes where tablename = 'runs' and indexname like 'runs_shoe%';
--     -- runs_shoe_user_idx only
--
-- Behaviour check, as the athlete (anon key, their JWT) — expect the second to fail 23503:
--   update runs set shoe_id = '<one of my shoes>'       where id = '<my run>';  -- ok
--   update runs set shoe_id = '<someone else''s shoe>'  where id = '<my run>';  -- refused
