---
title: Tempo roadmap
tags: [tempo, roadmap]
updated: 2026-11-24
---

# Roadmap

One milestone at a time. Anything not on the current milestone waits, however good it is.
GitHub holds the live state: the [Public beta milestone](https://github.com/MagicWilliams/kill-strava/milestone/2).
This page says why the list is what it is.

## Now: Public beta

**The bar:** someone who isn't David can install Tempo, keep their training on a
new phone, delete it if they want, get a working first launch, and get builds on purpose
rather than on every merge.

This is no longer hypothetical. The public TestFlight opened on 2026-11-05 and other people are
using the app. Per-user usage limits (#262) and request size caps (#276) are live. The consent
screen (#263) merged, but only newer builds have it and the server doesn't check it, so consent
is still open (#283). What's left:

| # | Item | State | Why it's on the bar |
|---|---|---|---|
| #294 | Sign in with Apple, linked to the anonymous account | needs David | A new phone or a lost Keychain session loses the plan, coach history and corrections today |
| #295 | Delete my account and data | in review (PR #299) | App Store 5.1.1(v), and the only way out today is asking David |
| #285 | First launch never shows an empty app | needs David | 2 of the first 5 testers got zero runs |
| #296 | Set the external TestFlight group to hand-promoted builds | needs David | Decided 2026-11-08 (#279). Only the App Store Connect setting is left, and agents can't see it |
| #297 | Mark David's accounts so triage can split him from testers | needs David | A tester's crash currently reads as his |
| #132 | Recorder field test, or label it unmeasured | needs device | Recorded runs save to testers' Apple Health |
| #283 | Enforce consent on the server, and check the screen on a device | needs David | Older builds still reach the coach with no answer on record |

Five of the seven are waiting on David, not on code. Each issue states the options and a
recommendation.

Done when every row above is closed. Then the "What to Test" note for the next external
build can stop saying "this might lose your data".

## Next: decide the hook

After the bar, the open product question is what keeps a stranger using Tempo:

- **The coach and the plan.** This is what testers actually used in their first week.
- **The Drift Detector** ([[prd-02-drift-detector]]). The stated v1 feature. The engine is
  merged: the fitness estimate, the expected curve and the drift tiers (#244, #235, #236). The
  hero chart and weekly tab aren't built.

Pick one and give it the next milestone. Don't pick both.

## Parked

Good ideas that don't change whether a stranger has a good first week. Nothing here gets
built until it moves up.

- Tempo MCP server ([[prd-03-tempo-mcp]])
- Coach v2: body reports (#89, PR #217), the read card (#90), the weekly review (#91)
- Apple Watch recording (#133), structured workouts (#134), custom live fields (#135)
- Garmin developer access (#12)
- Log-noise cleanups for cancelled tasks (#281, #286, #289, #292)
- Duplicate and wall-clock run cleanup in David's own archive (#153, #229, #252)

## How this page stays true

- Builders pick `agent-ready` issues **on the current milestone first**. Off-milestone work
  waits unless it's a `p0`.
- When a milestone closes, add a [[decision-log]] entry and move the next one up here.
- New ideas go to the Parked list or to an issue, not into the current milestone, unless
  they block the bar.
