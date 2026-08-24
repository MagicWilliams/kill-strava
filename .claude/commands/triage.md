---
description: Surface new Tempo issues from telemetry, edge-function logs, and recent code changes; file them on GitHub.
---

Run a triage pass on Tempo using the `scout` agent's rules (`.claude/agents/scout.md`).

1. **Telemetry** — query `app_events` in Supabase (project `lpgdhqqroyqdrjsrlodo`) for the
   last 7 days. Group by `event` and `level`; compare against the 7 days before that so you
   are ranking by *change*, not raw volume.
2. **Edge functions** — errors and non-200s from `coach` and `plan`. Run the Supabase security
   and performance advisors.
3. **Code** — review only what changed since the last triage (`git log`) plus anything
   telemetry pointed at. Do not re-scan the whole repo.

Then file or update GitHub issues on `MagicWilliams/kill-strava`. Search before filing —
comment on existing issues rather than duplicating. Maximum 5 new issues.

Finish with a summary: what you examined, what you filed, what you passed on and why.

If `app_events` is empty or the table does not exist yet, say so directly — it means either
the telemetry migration is unapplied or the app has not run since it shipped. That is itself
worth reporting, and it is not a reason to pad the run with speculative code findings.
