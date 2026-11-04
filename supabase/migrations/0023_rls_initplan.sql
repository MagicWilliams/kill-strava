-- Wrap auth.uid() as (select auth.uid()) in all 17 flagged RLS policies (#256).
--
-- ⚠️  UNAPPLIED. David applies it. Requires 0020. No app change depends on it.
--
-- Numbered 0023, not 0022: an in-flight branch already claims 0022 (body reports, #89).
-- Same reasoning as 0021's note — a shared prefix is how 0002 ended up ambiguous. Nothing
-- here depends on that branch, so the order they land in does not matter.
--
-- ── Why ──────────────────────────────────────────────────────────────────────────────
-- The Supabase performance advisor flagged 17 policies across 16 tables under
-- `auth_rls_initplan` (WARN). `auth.uid()` is `stable`, not `immutable`, so a bare call in
-- a RLS predicate is re-evaluated once per row scanned. Wrapping it in a scalar subquery —
-- `(select auth.uid())` — lets the planner hoist it into an InitPlan evaluated once per
-- statement, and the result is reused for every row.
--
-- Same predicate, same semantics: `auth.uid()` reads a per-statement GUC
-- (`request.jwt.claims`), so it cannot change mid-statement. Every table stays restricted to
-- its owning `user_id`/`id`. This is a plan-shape change, not a security change.
--
-- Prevention, not a fix for an observed symptom — the same call 0019 and 0021 made. Row
-- counts are small (`runs` is the largest at ~1,480), so nothing is measurably slow today.
-- But the per-row cost grows with every block logged, and the rewrite costs nothing.
--
-- `alter policy` rewrites the predicate in place: no window where a table sits unprotected,
-- which a drop-and-recreate would open. It is not `if exists`-able, so this file is not
-- re-runnable on a database where a policy has been renamed — it is, however, idempotent in
-- effect, since re-applying sets the same expression.
--
-- Scope: only the 17 policies the advisor actually flagged. The "run photos" policies on
-- `storage.objects` (0016) also call `auth.uid()::text` bare, but the advisor does not list
-- them — left alone deliberately, to keep this diff to what was reported.

-- ── 0001_init.sql ────────────────────────────────────────────────────────────────────
alter policy "own profile"  on profiles       using (id = (select auth.uid()))      with check (id = (select auth.uid()));
alter policy "own goals"    on goals          using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
alter policy "own plans"    on plans          using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
alter policy "own sessions" on sessions       using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
alter policy "own runs"     on runs           using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
alter policy "own metrics"  on metrics_daily  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
alter policy "own coach"    on coach_messages using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- plan_weeks inherit access via their plan: the comparison inside the EXISTS needs the same
-- wrap, or the subquery re-evaluates auth.uid() for every `plans` row it probes.
alter policy "own plan_weeks" on plan_weeks
  using (exists (select 1 from plans p where p.id = plan_weeks.plan_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from plans p where p.id = plan_weeks.plan_id and p.user_id = (select auth.uid())));

-- ── 0002_corrections_agency.sql ──────────────────────────────────────────────────────
alter policy "own acks" on risk_acknowledgments
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
alter policy "own check_ins" on check_ins
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ── 0006_telemetry.sql ───────────────────────────────────────────────────────────────
-- Insert-only from the client (the app reports, it never reads its own history), so these
-- two are single-clause: `for insert` has no USING, `for select` has no WITH CHECK.
alter policy "own events insert" on app_events with check (user_id = (select auth.uid()));
alter policy "own events read"   on app_events using      (user_id = (select auth.uid()));

-- ── 0011_run_efforts.sql ─────────────────────────────────────────────────────────────
alter policy "own run_efforts" on run_efforts
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ── 0012_run_overlap_reviews.sql ─────────────────────────────────────────────────────
alter policy "own overlap reviews" on run_overlap_reviews
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ── 0016_run_journal.sql ─────────────────────────────────────────────────────────────
alter policy "own shoes" on shoes
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ── 0020_coach_threads.sql ───────────────────────────────────────────────────────────
alter policy "own coach threads" on coach_threads
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
alter policy "own coach memory" on coach_memory
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ── Check (changes nothing) ──────────────────────────────────────────────────────────
--
--   select tablename, policyname, qual, with_check from pg_policies
--   where schemaname = 'public' order by tablename, policyname;
--
-- Every `qual`/`with_check` above should read `( SELECT auth.uid() AS uid)` — Postgres'
-- deparsed form of the wrap — and none should contain a bare `auth.uid()`. The next
-- performance-advisor run should list no `auth_rls_initplan` findings, and no new
-- `security` findings.
