-- Coach consent: the athlete's answer to "may Tempo send your data to Anthropic's Claude?"
--
-- ── What this is ─────────────────────────────────────────────────────────────────────
-- App Review guideline 5.1.2(i) requires explicit permission before personal data goes to a
-- third-party AI. `Engine/CoachConsent.swift` decides from these two columns; every call to the
-- `coach` and `plan` functions passes through `Services/CoachGateway.swift`, which checks it.
--
-- Null means never asked, and that is deliberately where every existing row starts. There is
-- no backfill: David sees the screen once, like anyone else who has never agreed.
--
-- The latest decision only, not a history. `coach_consent_at` is when it was made, and it is
-- what settles a disagreement with the copy the phone keeps (`CoachConsent.resolve`).
--
-- The existing `profiles` RLS policies cover these columns: a user reads and writes only their
-- own row.
--
-- ── The app does not depend on this being applied ────────────────────────────────────
-- It reads these columns in a query of its own, separate from the launch profile read. With
-- the columns absent the decision lives on the phone, the coach works once the athlete agrees,
-- and the decision is written up on the first launch after this is applied.
--
-- Safe to run twice. Reversible with:
--   alter table profiles drop column coach_consent, drop column coach_consent_at;

alter table profiles
  add column if not exists coach_consent text check (coach_consent in ('agreed', 'declined')),
  add column if not exists coach_consent_at timestamptz;
