-- Clear takeaways that are the coach's fallback line, so those runs are read again (#137).
--
-- ⚠️  UNAPPLIED. The EM applies it, after a dry run of the count below. One-off data fix: no
--     schema change, and safe to run before or after the app and coach changes ship.
--
-- ── The scar ─────────────────────────────────────────────────────────────────────────
-- When a completion came back empty twice, the coach edge function answered with
-- "Lost my train of thought there — ask me that again." — in takeaway mode too.
-- TakeawayService cached any non-empty reply in `runs.coach_takeaway` and never regenerates
-- a cached one, so that sentence became the run's permanent read on Today and Run Detail.
-- The Sonnet 5 thinking-budget incident (every completion empty) is when it would have
-- happened most. The coach now returns an empty reply for a takeaway and the app refuses to
-- cache the line (Engine/TakeawayReply.swift); this clears the rows written before that.
--
-- Nulling the column is exactly "never generated": the next open of that run (or the
-- Today match) asks the coach again. Nothing else on the row is touched.
--
-- The match is a case-sensitive prefix, the same test as `TakeawayReply.fallbackPrefix`, so
-- a real takeaway can't be caught by it — no coach read opens with those words.
--
-- Dry run (read-only):
--   select count(*) from runs where coach_takeaway like 'Lost my train of thought%';
--
-- Re-runnable: a second run matches nothing.

update runs
   set coach_takeaway = null
 where coach_takeaway like 'Lost my train of thought%';
