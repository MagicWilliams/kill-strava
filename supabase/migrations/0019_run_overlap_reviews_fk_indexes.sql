-- Covering indexes for run_overlap_reviews' foreign keys to runs (#98).
--
-- ⚠️  UNAPPLIED. David applies it. Requires 0012. No app change depends on it.
--
-- ── Why ──────────────────────────────────────────────────────────────────────────────
-- The Supabase performance advisor flagged `run_overlap_reviews_run_a_fkey` and
-- `run_overlap_reviews_run_b_fkey` (unindexed_foreign_keys) after 0012 landed. The primary
-- key `(user_id, run_a, run_b)` only serves lookups that lead with `user_id`; nothing
-- serves `run_a` or `run_b` alone. So when a `runs` row is deleted, each `on delete
-- cascade` has to full-scan this table to find the reviews that name it.
--
-- Prevention, not a fix for a slow query: the table is empty today and the app never
-- hard-deletes a run (retirement sets `superseded_by`, per #30). But a cascade that scans
-- grows with every decision recorded, and the index costs nothing at this size.
--
-- Re-runnable: `if not exists`.

create index if not exists run_overlap_reviews_run_a_idx on run_overlap_reviews(run_a);
create index if not exists run_overlap_reviews_run_b_idx on run_overlap_reviews(run_b);

-- ── Check (changes nothing) ──────────────────────────────────────────────────────────
--
--   select indexname from pg_indexes
--   where tablename = 'run_overlap_reviews' order by indexname;
--
-- Expect run_overlap_reviews_pkey, run_overlap_reviews_run_a_idx, run_overlap_reviews_run_b_idx.
-- The next performance-advisor run should no longer list either fkey under
-- unindexed_foreign_keys.
