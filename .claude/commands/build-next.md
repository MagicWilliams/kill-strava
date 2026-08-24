---
description: Implement the top agent-ready Tempo issue and open a PR that goes green on CI.
---

Work one issue to a PR using the `builder` agent's rules (`.claude/agents/builder.md`).

1. `gh issue list -R MagicWilliams/kill-strava --label agent-ready --state open`, ordered by
   priority label. Skip any that already have an open PR.
2. Read the issue fully, then read the code it names. If the spec does not survive contact
   with the code, re-label it `needs-david` explaining the ambiguity, and take the next one.
3. Branch `agent/<issue>-<slug>`, implement, add tests for any logic change.
4. Verify: locally if you have Xcode, otherwise push and iterate on CI until green.
5. Open the PR in the format the builder rules specify — including the **How David verifies
   this** section with literal on-device steps.

Do not merge. Do not apply migrations. Do not deploy edge functions. One issue, one PR.

$ARGUMENTS can name a specific issue number to work instead of picking the top one.
