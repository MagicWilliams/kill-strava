---
title: "Tempo — Drift Detector PRD"
project: Tempo
type: prd
status: draft
created: 2026-10-15
source: claude.ai planning session (explored-with-Claude; decisions are Magic's)
tags: [tempo, prd, side-projects, drift-detector]
---

# Tempo — Drift Detector PRD

Project: [[Tempo]] · Decisions: [[decision-log]] · Related: [[prd-01-intake-v2]] · Repo audit: [§14](#14-repo-audit-2026-10-15)

> **Status:** Draft from a planning session on 2026-10-15. Decisions below were made by Magic in that session. Nothing here has been built or verified against the repo yet. Treat it as a spec, not a status report.
>
> **Revised the same day after the repo audit (§14).** David's calls: Tempo stays free for now (§3), the privacy claim comes out (§4), the existing plan engine stays (§6.3, §8), rule 3 holds and its current violations are tracked (§11), and the work queue is GitHub Issues, not Linear (§0).

---

## 0. Instructions for Claude Code (read first)

You are picking this up in a session with access to the Tempo repo and project status (Linear). Do these in order, and **stop at each gate for Magic's explicit "go."**

1. **Log this PRD to Obsidian.**
   - Find Magic's Obsidian vault. If you can't locate it with certainty, ask for the path — don't guess.
   - Save this file into the vault's Tempo area (e.g. `Projects/Tempo/PRDs/2026-10-15 Tempo Drift Detector PRD.md`, or wherever existing Tempo notes live — match the vault's conventions).
   - Keep the frontmatter. Add `[[Tempo]]` and any existing Tempo index/MOC note as wikilinks at the top, and add a link back to this PRD from that index note.
   - If the `obsidian-notes` skill is available, run its lint afterwards and fix broken links.
2. **Audit the repo against this PRD.** For each issue in §9, report: already exists / partially exists / not started, with file paths. Flag anything in the repo that conflicts with decisions here (e.g. Strava API usage, injury language, an LLM computing metrics).
3. **GATE — propose issues.** Show the issue list (adjusted for what already exists) as a preview. Wait for "go" before creating anything. *(Revised: Tempo's work queue is GitHub Issues with the repo's `agent-ready` / `needs-david` / `needs-device` labels, not Linear.)*
4. **GATE — before UI work (#6),** ask Magic for the Figma design system link and build from it. Do not invent a new design system.
5. **Propose the rules in §11** as additions to the repo's `CLAUDE.md`. Wait for sign-off before writing.

Working loop (Magic's Side Projects OS): one issue = one agent session = one branch = one PR = one review. Keep the ready queue ~1 week deep. Magic is the bottleneck at spec and review time, not the agents.

---

## 1. Overview

**Tempo** is a native iOS AI running coach. This PRD repositions it and specs its core v1 feature.

**Positioning:** Tempo is the private layer that sits on top of everything a runner already uses (Garmin, Strava, Runna, Apple Watch, a coach), reads across all of it, and answers one question: **"Am I on track?"**

**The core feature — the Drift Detector:** Tempo builds its own model of where a runner *should* be this week to hit their goal race time, compares that to where their fitness actually is, and tells them, calmly, when they've drifted far enough off course to need an adjustment — how far off they are, and what to change.

**The war line (vs. incumbents):**
> Runna checks whether you did the workouts. Tempo checks whether the workouts are working.

---

## 2. Strategic context (why this, why now)

Summary of the reasoning that led here:

- **Code is no longer scarce; distribution, taste, trust, and accumulated data are.** An app that's "a prompt + a UI on a model" gets absorbed by AI harnesses. Tempo survives by owning things a harness + generic connector can't replicate: longitudinal training state, a modeling point of view, and calm, timely delivery.
- **Target the 99% who don't use Claude Code.** Most runners will never wire up MCP servers. They'll pay for a packaged, opinionated App Store product. The gap between what AI can do and what normal people can reach is the opportunity.
- **"Comparable to Strava/Runna" is not a reason to switch.** The wedge is that Magic's runners use *all* of those tools at once. Their data and advice are scattered. Tempo is the one coach that reads across everything.
- **Platform neutrality is the weapon.** Garmin won't coach well off Strava data; Strava won't judge your Garmin plan. Tempo is on nobody's side but the runner's.
- **Comprehensive input, short output.** Anxious runners don't want more charts. Tempo takes in everything and returns one answer. If it becomes the fifth dashboard, it loses.
- **Distribution advantage:** Magic can reach ~100 experienced runners directly via DMs and run crews. Most indie devs don't have that. (Other channels: Substack, Instagram, word of mouth at races.)

### Key external constraint: Strava's API
Strava's November 2024 API agreement limits third-party apps to showing a user's data only to that user and prohibits using Strava API data in AI models or similar applications. A June 2026 update told developers using Strava data in AI to stop and seek written guidance. **An AI coach reading Strava's API is exactly the target of these rules.**
→ **Decision: build on Apple Health (HealthKit) only.** Garmin, Coros, Strava, Runna, and Apple Watch can all write runs to Health, so Tempo gets cross-platform data without anyone's permission.
Source: https://www.techrepublic.com/article/news-strava-api-scraping-crackdown

---

## 3. Business model

**Decided (revised 2026-10-15): free for now. Pricing comes later.** This matches the free-with-full-access decision in [[decision-log]]. No payment UI or paywall gets built in v1.

*Deferred, from the planning session, for when pricing comes back up:* paid coaching rather than ads (~$8/month; ~1,250 paying runners for a $10k MRR stretch goal); a free tier of logging and basic insight with the Drift Detector and AI coaching paid; ads rejected because they need tracking and undercut privacy. Test willingness to pay at the end of the beta.

---

## 4. Privacy claim

**Removed for now (2026-10-15).** The drafted line, "We never store or sell your data — it's processed only to answer you", isn't true of today's architecture. Supabase stores runs, the full coach chat, free-text notes, photos and injury notes, and there's no delete or export. Chat, notes and run detail also go to Anthropic. No privacy claim ships in copy until one is written to match a mapped data flow (rule 5 in §11).

---

## 5. Target user (v1)

A runner **with some experience, signing up for another race**, with a goal finish time, at least **8 weeks** out from race day. They likely use some mix of Strava, Garmin, Runna, and/or a coach.

**The moment they'd pay:** a missed week, or the anxiety of not knowing where they stand in training — the feeling that you have to study charts and stats just to get a sense of the big picture.

---

## 6. The Drift Detector — feature spec

### 6.1 Core model (all computed in code)
1. **Current fitness estimate.** Estimate the runner's race-equivalent fitness from recent qualifying efforts. **Exclude easy/recovery runs** as a fitness signal. **Smooth** the estimate so one bad run (heat, hills) doesn't swing it.
2. **Expected trajectory curve.** A curve from the runner's fitness at signup to their goal time on race day, including taper. This is "Tempo's model of where they should be."
3. **Drift.** The gap between current fitness and where the curve says they should be **this week** — not the gap to the goal itself.
   - ⚠️ Comparing to the goal directly would flag nearly everyone early in a block, because fitness hasn't been built yet.

### 6.2 Status tiers (vs. the expected curve)
| Status | Drift | Behavior |
|---|---|---|
| On track | < 2% | Reassure. Show projection. |
| Drifting | 2% – < 5% | Calm heads-up. Light suggestions. |
| Off track | ≥ 5% | "You're off, here's how far, here are suggested changes." |

Thresholds are starting values; the beta tunes them. (For scale: 5% on a 3:30 marathon ≈ 10.5 minutes.)

### 6.3 What Tempo says after detecting drift
- How far off they are (from code).
- Suggested changes (AI-written, based only on computed numbers).
- **The Drift Detector doesn't rewrite plans in v1.** It judges progress; it doesn't prescribe workouts. *(Revised: Tempo keeps its existing plan engine, which David trains on. A drift alert never triggers a plan rewrite on its own; changing the plan stays an explicit, confirmed action the athlete takes.)*

### 6.4 Experience & feel
- **Hero visualization:** one line — projected fitness/finish vs. the expected curve. It *is* the answer to "Am I on track?" Opening the app shows it, and it's different every time because runs move it. This is the "fresh" reason to return whether a runner is thriving or struggling.
- **Updates after every synced run**, with a smoothed headline that moves slowly.
- **Weekly tab** as an alternative view.
- **Tone: calm.** Example: "Some catching up to do — here's a doable path." Not alarmist.
- **No injury or medical claims.** Frame everything as training load and deviation from the trajectory. Runners draw their own conclusions about burnout.

### 6.5 Notifications
- Default: news waits for the runner to open the app.
- Pushes are allowed after a workout syncs or a period of inactivity, but **must state direction** — no vague teasers ("Coach wants to talk"), which read as bad news to anxious runners, and no guilt.
  - ✅ "Long run synced. Your projection held at 3:31."
  - ✅ "Quiet week. Here's an easy way back in."
  - ❌ "Your coach wants to talk."
  - ❌ "You haven't run in 5 days."

---

## 7. Data & backend

- **Platform:** Native iOS with a backend (existing).
- **Data source v1:** Apple Health only.
- **Onboarding collects:** goal race, race date, goal time (race ≥ 8 weeks out), and **backfills past runs from Apple Health** on day one so the curve and projection aren't empty.
- **Numbers from code, words from the model.** All metrics (fitness, curve, drift, projections) are deterministic code with unit tests. The LLM receives computed values and writes the explanation and suggestions. The model never computes a number the user will act on.
- **Open data question:** HealthKit workouts don't label "easy run." Classification likely needs pace and/or heart-rate heuristics relative to the runner's own baseline.

---

## 8. Scope

### In scope (v1)
Drift Detector end to end: onboarding + Health backfill, fitness estimator, expected curve, drift tiers, hero viz + weekly tab, AI explanation + suggestions, directional notifications, beta metrics.

### Out of scope (v1)
- Plan rewrites driven by drift (the existing plan engine stays as it is)
- Android
- Garmin direct integration, Strava API
- Social / sharing features
- Injury or medical claims
- Ads, payments, open-sourcing

### Success metrics (feature-level acceptance)
1. In the beta, **most testers who receive a drift alert agree it was right** (and ideally changed something).
2. **≥ 50% of testers open Tempo weekly for 4 weeks without a nudge.**

---

## 9. Milestones & issues

Each issue = one PR. Definition of Ready: context, testable acceptance criteria, out-of-scope line, technical notes, sized to one PR, no open product questions. **Audit the repo first — some of these (especially #5) may already partly exist.**

### Milestone 1 — The Engine
All code, all unit-tested, no UI. Goal: numbers Magic trusts before anything is shown to testers.

#### #1 Spike: choose the fitness formula `spike`
- **Context:** Tempo needs an established, defensible method to estimate race-equivalent fitness from recent runs.
- **Do:** Compare candidates (e.g. Riegel's race-time formula, Daniels' VDOT-style estimates, an HR-adjusted approach). Recommend one, with tradeoffs, and define what counts as a "qualifying effort." Propose an easy-run classification heuristic (pace/HR relative to the runner's baseline).
- **Acceptance:** A short written recommendation in the repo (`docs/`) with the chosen formula, qualifying-effort rules, easy-run heuristic, and known failure cases.
- **Out of scope:** Implementation.

#### #2 Fitness estimator `feature`
- **Context:** Implements #1.
- **Do:** Function that takes a runner's recent workouts and returns a smoothed race-equivalent fitness estimate. Excludes easy/recovery runs. Smoothing so single outliers barely move it.
- **Acceptance:**
  - Unit tests with fixtures: steady block; one heat-wave run; one hilly run; a recovery run; a missed week; sparse data.
  - The heat/hill fixtures move the estimate less than a defined tolerance.
  - Returns a clear "insufficient data" state rather than a fake number.
- **Out of scope:** UI, AI.

#### #3 Expected trajectory curve `feature`
- **Context:** "Tempo's model of where they should be."
- **Do:** Given fitness at signup, goal time, and race date, produce the expected fitness for any week of the block, including taper.
- **Acceptance:**
  - Curve starts at signup fitness and reaches goal fitness by race day.
  - Unit tests for 8-, 12-, 16-, and 20-week blocks, and for an ambitious vs. conservative goal.
  - Rejects races < 8 weeks out.
- **Out of scope:** Re-planning when the goal changes (note as follow-up).

#### #4 Drift calculator + status tiers `feature`
- **Do:** Compare current fitness (#2) to this week's expected value (#3). Return drift % and status: on track (< 2%), drifting (2–< 5%), off track (≥ 5%). Thresholds are config, not hard-coded.
- **Acceptance:**
  - Unit tests at and around each boundary.
  - Week 2 of a 16-week block with normal early fitness → "on track," not "off track."
  - Insufficient data → no status, not a false alarm.
- **Out of scope:** Copy, notifications.

### Milestone 2 — The Surface
**Gate:** get the Figma design system link from Magic before #6.

#### #5 Onboarding + Health backfill `feature`
- **Do:** Collect goal race, date, goal time (≥ 8 weeks out). Request HealthKit permission. Backfill historical running workouts on first launch.
- **Acceptance:**
  - Projection and curve render on day one for a runner with Health history.
  - Clean handling of: permission denied, no history, race < 8 weeks out.
- **Out of scope:** Garmin/Strava direct.

#### #6 Hero visualization + weekly tab `feature`
- **Do:** One-line hero chart: projected trajectory vs. expected curve, current status. Updates after each synced run with the smoothed headline. Weekly tab as an alternate view.
- **Acceptance:**
  - Built with Tempo's existing Figma design system.
  - Readable in under 5 seconds: a tester can answer "Am I on track?" without explanation.
  - All three statuses + insufficient-data state designed.
- **Out of scope:** Additional charts. (If a proposed element doesn't answer a runner question, cut it.)

#### #7 AI explanation + suggested changes `feature`
- **Do:** For each status, generate a calm explanation and (for drifting/off track) suggested changes. Input is **only** computed values from Milestone 1.
- **Acceptance:**
  - The model never computes or alters a metric; all numbers in output come from code (verify via tests/evals).
  - Eval cases for each status, plus edge cases (missed week, sparse data).
  - No injury/medical language (add an eval check).
  - Tone: calm.
- **Out of scope:** Plan generation, chat.

### Milestone 3 — The Loop

#### #8 Notifications `feature`
- **Do:** Push after a workout syncs and after inactivity, per §6.5.
- **Acceptance:** Every push states direction. No teaser or guilt copy. Respects iOS permission and a sensible frequency cap.
- **Out of scope:** Marketing pushes.

#### #9 Beta metrics `chore`
- **Do:** Measure weekly opens (with/without a preceding push) and an in-app "Was this right?" response on drift alerts.
- **Acceptance:** Can report both success metrics in §8 at week 4. Collection is consistent with the privacy claim in §4.
- **Out of scope:** Third-party analytics SDKs that conflict with the privacy claim.

---

## 10. Beta rollout

- **TestFlight is already live.**
- **Wave 1 (now): 10–20 testers** for basic feedback. **Hold the rest of the ~100** until the Drift Detector ships — testers who arrive before it exists will judge Tempo without its best feature, and each DM is one first impression.
- **Parallel concierge test (optional, recommended):** for 5 runners, hand-run the weekly "am I on track?" readout (pull their data, have Claude draft it, send it). Ask if they'd pay ~$8/month. If they forward it or notice when it's late, the product is real.
- **End of beta:** test willingness to pay.

---

## 11. Proposed rules (for the Tempo repo's `CLAUDE.md`)

Propose these to Magic; add only on sign-off.

1. For every proposed feature, name the single runner question it answers. If it answers none, or adds another chart, push back.
2. Measure progress toward the runner's goal via Tempo's expected curve, never adherence to a third-party plan.
3. Numbers come from code; words come from the model. The model never computes a metric the user will act on. *(Kept by David, 2026-10-15. Current violations: run corrections #206, goal time and plan volume #207.)*
4. Never claim injury prediction or medical outcomes in copy or prompts. Describe training load and deviation from the trajectory only.
5. Every privacy claim in copy must map to a specific data flow in code. If the flow changes, the claim gets reviewed.
6. Before building on any third-party data source, check its current API terms for AI-use restrictions and flag the risk first.
7. Notifications state direction. No teaser or guilt copy.
8. Don't open a new beta wave until the core feature that wave is meant to test has shipped.

---

## 12. Open questions

1. Which issues already exist in the repo? (Answer during the audit.)
2. Fitness formula and easy-run heuristic (resolved by #1).
3. What exactly does the backend store, and what does the AI provider retain? (Partly answered in §14. Needed before any privacy copy ships.)
4. Figma design system link (needed before #6).
5. ~~Paid tier price and paywall~~ Deferred: Tempo is free for now.
6. Disclaimer language for coaching guidance (not medical advice), and whether App Store review needs it.
7. Follow-up: what happens when a runner changes their goal or race mid-block?

---

## 13. Decision log (2026-10-15)

| Topic | Decision |
|---|---|
| Money | ~~Paid coaching~~ **Revised: free for now; pricing later.** |
| Privacy claim | ~~"We never store or sell…"~~ **Revised: removed until it matches the data flows.** |
| Positioning | Private, cross-platform layer answering "Am I on track?" |
| First user | Experienced runner signing up for another race, ≥ 8 weeks out |
| Drift measured against | Tempo's own expected curve toward the goal time |
| After an alert | "You're off, here's how far, here are suggested changes." No plan rewriting. |
| Beta success | People come back weekly, for good runs and bad |
| Notifications | Wait for the runner to open the app; directional pushes after sync/inactivity |
| Tone | Calm |
| Update cadence | After every run, smoothed; weekly tab as alt view |
| Design | Existing Figma design system |
| Data v1 | Apple Health only |
| Computation | Numbers in code, words from the model |
| Stack | Native iOS + backend |
| Thresholds | Drifting 2–< 5%, off track ≥ 5% (vs. curve) |
| Android | Not a concern for v1 |
| Beta | Free; TestFlight live; staged waves |
| Plan engine | **Revised: kept.** Drift never rewrites a plan by itself. |
| Rule 3 | **Kept.** Existing violations tracked in #206, #207. |
| Work queue | **Revised: GitHub Issues**, not Linear. |

---

## 14. Repo audit (2026-10-15)

Audited at `main` 615658c. Paths are under `ios/Tempo/` unless noted.

| PRD item | State | Where |
|---|---|---|
| #1 Fitness formula | **Partial.** Riegel (`t2 = t1·(d2/d1)^1.06`) exists. Nothing classifies a completed run as easy or recovery. | `Engine/TrainingPaces.swift:34`, `Engine/ProjectionHistory.swift:58` |
| #2 Fitness estimator | **Partial.** The projection is the single fastest run of ≥ 2.5 mi, not smoothed. The app looks back 42 days, the server 56. Insufficient-data states exist. | `ProjectionHistory.swift:23`, `supabase/functions/plan/index.ts:78` |
| #3 Expected curve | **Not started.** The only "this week" signal is planned mileage. | `supabase/functions/plan/generator.ts:473` |
| #4 Drift and tiers | **Partial.** A yes/no "on track / behind goal" against the goal itself. | `Screens/ProgressScreen.swift:51`, `ProjectionDetailView.swift:378` |
| #5 Onboarding and backfill | **Mostly exists.** Intake, HealthKit permission, full-history backfill, empty and denied states. Gap: the ≥ 8-week drift eligibility. | `Screens/OnboardingView.swift`, `Engine/TrainingIntake.swift`, `Stores/RunStore.swift:133` |
| #6 Hero chart | **Partial.** The projection card and history chart look backward only, with no curve toward race day. | `ProjectionDetailView.swift:200–330` |
| #7 AI explanation | **Not started.** | |
| #8 Notifications | **Not started.** No notification code, no push entitlement. | |
| #9 Beta metrics | **Partial.** First-party `app_events` telemetry, no third-party SDKs. No weekly-open or "Was this right?" events. | `Services/Telemetry.swift`, `supabase/migrations/0006_telemetry.sql` |

**Conflicts found, and what happened to them**
- Free vs paid: resolved, free for now (§3).
- Privacy claim false today: claim removed (§4).
- Plan generation already exists: kept (§6.3).
- Model computes numbers: rule 3 kept. Run-correction totals → #206; goal time and plan volume → #207.
- Coach prompt hard-coded to David → #204.
- `/plan` stores a made-up projection (goal × 1.06) when no run qualifies → #205.
- Strava auto-upload (#106) closed as not planned. README's "Strava import" wording corrected.
- Injury language: the coach asks about injuries and steers away from risk, but makes no injury-prediction or medical claims. No change needed.

