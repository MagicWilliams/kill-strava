---
tags: [tempo, decision-log]
---

# Decision log

Newest first. One entry per session that ships features or makes a product decision.

## 2026-11-04: Permission before anything goes to Claude

### Decisions
- **Nothing reaches Anthropic without an explicit yes** (App Review 5.1.2(i)). Every `coach` and `plan` call goes through `CoachGateway`, which checks `CoachConsent.maySend`. Not knowing is a no. A lint test fails if anything else touches the functions client.
- **Consent comes before the intake, not just before the interview.** Every answer on the intake form exists to be handed to the coach, so someone who says no skips it and lands in the app.
- **Existing athletes are asked at launch, once**, over the app rather than on first visit to the Coach tab. A takeaway generates in the background with no coach screen open, so waiting would just leave the coach silently off.
- **A decline stays quiet.** It isn't asked again. Coach surfaces say the coach is off and offer the way back, and the You tab has a row to change it either way, including withdrawing.
- **The screen lists more than the brief did**, because the payloads do: heart rate, splits, cadence, elevation, fitness numbers, best times, check-ins and what the athlete told the coach. PRD-02 rule 5 holds the copy to the flow, not to the shorter summary.
- **The decision is stored on the phone and on `profiles`**, newest wins, and a tie between different answers resolves to the decline. No server-side check in the functions yet: the app is the only thing that calls them.

### Shipped
- `Engine/CoachConsent` (the rule), `Services/CoachGateway` (the one way out), `Services/CoachConsentStore`, `Screens/CoachConsentView`, migration `0025_coach_consent.sql`.

### Next up
- David: tap Agree once the build lands, then the device check in the PR. Migration 0025 is applied to staging and production, and he delegated the copy review.
- Fill the `[UPDATE WHEN THE CONSENT SCREEN SHIPS]` placeholder in `docs/app-store-listing.md` once that file lands on `main`.
- `site/privacy.html` (#250) summarises the same flow more briefly than this screen; bring it up to the same list.

## 2026-11-04: Per-user usage limits before the public listing

### Decisions
- **Each kind of call has its own hourly and daily allowance:** chat, takeaway, block review, thread recap and plan. Background work can't use up an athlete's chat.
- **The limits live in a table, not in code.** Tuning one is an `update`, with no redeploy of the live coach.
- **A limiter that can't answer lets the call through.** It guards the bill, not access, so a missing migration or a database fault must not take the coach away. A caller PostgREST refuses (401/403) is the exception, because the caller controls that header.
- **Being limited is its own state in the app,** drawn in a neutral color and saying when it resets. It never reads as a connection failure or lost data.
- **Per-user limits don't bound the bill alone,** because anonymous accounts can still be minted per IP. The hard bound is a spend limit on the Anthropic side.

### Shipped
- Migration 0024 (`usage_limits`, `usage_counters`, `claim_usage`), the gate in `coach` and `plan`, and the limited state in every caller. Live on production: `coach` v24 and `plan` v10, which also took #245 and #246 live.

### Next up
- David sets the Anthropic spend limit and the anonymous sign-in limit, and sends one coach message on his phone as the device check.
- Cap the size of a request: limits count calls, and the client still decides how large each one is.

## 2026-10-15 (later): Drift Detector PRD, revised after the repo audit

### Decisions
- **Positioning:** Tempo is the private, cross-platform layer that answers "Am I on track?" on top of whatever a runner already uses. Core v1 feature: the Drift Detector. See [[prd-02-drift-detector]].
- **Drift is measured against Tempo's own expected curve** toward the goal time, not against the goal itself. Tiers: on track < 2%, drifting 2–< 5%, off track ≥ 5%. Thresholds are tunable config.
- **Money: free for now; pricing later.** The planning session leaned toward paid coaching. That's deferred, and the free decision above stands.
- **The privacy claim is removed for now.** "We never store or sell your data" isn't true of the current backend. No privacy copy ships until it maps to a real data flow.
- **The plan engine stays.** The Drift Detector judges progress; a drift alert never rewrites a plan by itself.
- **Rule 3 holds: numbers from code, words from the model.** Existing violations are tracked: run corrections (#206), goal time and plan volume (#207, needs David).
- **Apple Health only.** No Strava API. #106 (auto-upload to Strava) closed as not planned.
- **The work queue is GitHub Issues**, not Linear.

### Shipped
- PRD-02 filed with the repo audit (§14). README corrected: Health-only data and no paywall.
- Issues filed and building: #204 (coach prompt hard-coded to David), #205 (made-up projection when no run qualifies), #206 (run corrections computed in code).

### Next up
- Go/no-go on the Drift Detector issue list (PRD §9, adjusted by the audit) and on the §11 `CLAUDE.md` rules.
- #207: decide on goal time and plan volume under rule 3.
- Figma design-system link before the hero chart (the Figma connector needs authorizing).

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
