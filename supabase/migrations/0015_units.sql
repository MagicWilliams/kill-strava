-- Units (#108): the athlete's mi/km preference, one column on the profile.
--
-- ── What this is ─────────────────────────────────────────────────────────────────────
-- `profiles.units` is what `Engine/Units.swift` formats in. The You tab writes it; RunStore
-- reads it at launch. Miles is the default because every number already on screen is miles.
--
-- ── Why this is mostly a no-op ───────────────────────────────────────────────────────
-- 0001 already declared `units text not null default 'mi' check (units in ('mi','km'))`,
-- and on 2026-10-12 a read-only PostgREST probe (`select=units`) answered 200 on both
-- production and staging, so the column is there. Nothing has written to it. This
-- migration pins the column's shape rather than trusting that 0001 ran exactly as written,
-- since `create table if not exists` would have skipped the column entirely on a table that
-- already existed. Every statement is idempotent: on a database where 0001 applied cleanly
-- it changes nothing, and it is safe to run twice.
--
-- The app does not depend on this being applied. It reads `units` in its own query,
-- separate from the launch profile read, and treats a failed read as miles. The setting's
-- write fails only if the column is missing, and the toggle then snaps back to its
-- previous value.
--
-- Reversible with: nothing to reverse on a database 0001 created. The column predates this.
-- (Dropping it would remove 0001's column, which this migration did not add.)

alter table profiles
  add column if not exists units text not null default 'mi';

-- A null can only exist if some earlier hand edit relaxed the column; heal it before
-- re-asserting not null.
update profiles set units = 'mi' where units is null;

alter table profiles alter column units set default 'mi';
alter table profiles alter column units set not null;

-- 0001 declared the check inline, so Postgres named it (`profiles_units_check` by default).
-- As in 0014, don't bet on the default: drop whichever single-column CHECK sits on `units`,
-- then add it back under a known name.
do $$
declare
  c record;
begin
  for c in
    select con.conname
      from pg_constraint con
      join pg_attribute att
        on att.attrelid = con.conrelid and att.attnum = any (con.conkey)
     where con.conrelid = 'public.profiles'::regclass
       and con.contype = 'c'
       and att.attname = 'units'
       and array_length(con.conkey, 1) = 1
  loop
    execute format('alter table public.profiles drop constraint %I', c.conname);
  end loop;
end $$;

alter table profiles
  add constraint profiles_units_check check (units in ('mi','km'));

comment on column profiles.units is
  'Display unit: mi | km. Storage stays SI everywhere (metres, seconds); this only changes how Units.swift formats.';

-- ── Verify ───────────────────────────────────────────────────────────────────────────
--   select units, count(*) from profiles group by 1;
--     -- every row 'mi' until someone flips the setting
--   select column_default, is_nullable from information_schema.columns
--    where table_name = 'profiles' and column_name = 'units';
--     -- 'mi'::text | NO
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--    where conrelid = 'public.profiles'::regclass and contype = 'c';
--     -- exactly one check on units: profiles_units_check
