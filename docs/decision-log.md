---
tags: [tempo, decision-log]
---

# Decision log

Newest first. One entry per session that ships features or makes a product decision.

## 2026-10-15: Tempo stays free; intake v2 drafted from Runna

### Decisions
- **Tempo is free, with full access.** No feature, plan, or piece of your own data sits behind a paywall. If money ever comes into it, through optional ads or a donation, it buys a nicer experience, never more access. No payment or donation UI gets built now.
  - *Why:* Runna charges about $120 a year on top of a Strava subscription, so some runners pay $180–200 a year between the two, and there's no free path past the trial. When a very good plan costs almost nothing to generate, holding it hostage behind a subscription is exactly the problem Tempo exists to fix.
- **Onboarding stays distance-first.** No race database or race search. The race name stays optional free text.
- **Intake v2 direction**, from David going through Runna's onboarding: ask *why* you're training, your experience level, a self-reported current race time, which days you're free, and an honest "who this is built for" line. See [[prd-01-intake-v2]] (draft).

### Shipped (overnight 14–15 Oct)
- Recover a killed run at launch (#170), the live run screen (#171), the post-run save screen (#173)
- Race mode files the run as the goal's race (#174), Lock Screen Live Activity + Dynamic Island (#176)
- Run Detail journal (#177), treadmill rescale to the console distance (#180, #182)
- TestFlight revokes the development certificate each run mints (#103)

### Found
- The goal for a 5K was saved as a marathon: a create_plan card with no distance falls back to marathon (#184).
- The projection is always a marathon projection, whatever the goal (#185).

### Next up
- #184, #185 (p0, building), #186 keyboard/tab bar (p2, building)
- #183: reuse one CI development certificate, which ends the revocation emails
- #96 needs David's call: Coach v2 (chat threads, #87) or the data layer first
- PRD-01 open questions
