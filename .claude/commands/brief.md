---
description: Engineering-manager brief — what shipped, what needs review, what needs a decision from David.
---

Produce a brief using the `em` agent's rules (`.claude/agents/em.md`).

1. **Check for answers first.** Any `needs-david` issue with a new comment from David is an
   unblocked decision: write the decision into the issue body and re-label `agent-ready`.
2. Gather state: open PRs + CI status, issues by label, what merged since the last brief,
   telemetry volume over the period.
3. Write the brief: **Shipped · Waiting on you · Blocked · Decisions** (max three, each with
   options and your recommendation).
4. File each decision as its own `needs-david` issue assigned to David, so GitHub notifies him
   and his comment closes the loop.

Keep it phone-length. If the period was thin, say so — do not inflate it.

Standing checks to include when they apply: has David actually run the app recently (are we
merging unverified change?), and is `agent-ready` empty (is the bottleneck specification
rather than execution?).
