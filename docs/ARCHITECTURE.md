# Tempo — v1 Architecture

Locked decisions for the first buildable, TestFlight-able version (closed beta for friends).

## Scope (v1)
Full app **minus the paywall** — onboarding, the core tabbed app, run history/detail,
progress/trajectory, and the AI coach. Monetization comes after the beta proves the loop.

| Decision | Choice | Why |
|----------|--------|-----|
| Platform | **iOS, SwiftUI** | Native, Apple Watch + HealthKit, App Store target |
| Data source (v1) | **Apple HealthKit only** | No approval gate; captures runs from Apple Watch + most Garmin/Coros via Health. Strava (restrictive API) and Garmin (partner approval) come later. |
| Plan engine | **Hybrid** | Deterministic rules build the plan skeleton; an LLM handles daily adaptation nuance + explanations + coach chat |
| Backend | **Supabase** | Postgres + Auth + Edge Functions; great fit for relational training data and an LLM proxy |
| LLM | **Claude API** (`claude-opus-4-8` / `claude-sonnet-4-6`) | Coaching tone + adaptation; called via a Supabase Edge Function so keys never ship in the app |
| Auth | Supabase Auth (Sign in with Apple) | Frictionless on iOS |

Not in v1: Strava/Garmin direct sync, in-app run recording, paywall/subscriptions, Android.

## High-level shape

```
┌─────────────── iOS app (SwiftUI) ───────────────┐
│  Onboarding · Today · Plan · Progress · Coach · You │
│  HealthKit ingest → local cache (SwiftData)        │
│  TrainingEngine (rules) — paces, periodization     │
└───────────────┬─────────────────────────────────┘
                │ HTTPS (supabase-swift)
┌───────────────▼─────────────────────────────────┐
│  Supabase: Postgres (RLS) · Auth · Edge Functions │
│   - /adapt    rules+LLM daily session adaptation   │
│   - /coach    LLM chat (calm-expert persona)       │
│   - /plan     generate plan from goal              │
└───────────────┬─────────────────────────────────┘
                │
            Claude API
```

- **Source of truth:** Supabase Postgres. The app keeps a SwiftData cache for offline/fast reads.
- **Runs** are ingested from HealthKit on device, normalized, and upserted to Supabase.
- **Plan generation & adaptation** run server-side (Edge Functions) so the engine + prompts can
  iterate without app releases. The deterministic pace/periodization math is shared logic
  (TypeScript in the function; mirrored in Swift `Engine/` for instant on-device previews).

## The hybrid engine

1. **Rules (deterministic, testable):**
   - Goal time → training paces (see `ios/Tempo/Engine/TrainingPaces.swift`).
   - Periodization: Base → Build → Peak → Taper, week templates by phase and days/week.
   - Volume progression with ~3-week build + step-back, capped ramp rate.
   - Load tracking: CTL/ATL/Form (EWMA of training load) → readiness + over/under-training read.
2. **LLM layer (Claude, server-side):**
   - **Daily adaptation:** given the planned session + recent runs + readiness, adjust today's
     session (easier/shorter/swap) and write the one-line *why*.
   - **Coach chat:** calm-expert persona, grounded in the user's plan + recent data.
   - **Explanations:** turn rule outputs into human, motivating copy.
   - Guardrails: LLM can only choose within rule-sanctioned bounds (it tunes, it doesn't invent
     unsafe jumps).

## Build sequence
- [ ] **0. Foundation** (this commit): architecture, DB schema, design tokens, pace engine
- [ ] **1. App shell** — SwiftUI tab nav matching the prototype; design-system components from tokens
- [ ] **2. Auth + HealthKit** — Sign in with Apple; request Health permissions; ingest run history
- [ ] **3. Onboarding** — Welcome → (HealthKit) Connect → Goal Setup → generate plan
- [ ] **4. Core read screens** — Today, Plan, Run History, Run Detail (from real Health data)
- [ ] **5. Progress** — CTL/ATL/Form + trajectory + projection from goal
- [ ] **6. Engine on server** — Edge Functions for plan + daily adapt
- [ ] **7. Coach** — chat via Edge Function → Claude
- [ ] **8. Polish + TestFlight** — closed beta

## What we still need (ops)
- Apple Developer Program account ($99/yr) for TestFlight + HealthKit entitlement
- A Supabase project (provision when ready; schema in `supabase/migrations/`)
- An Anthropic API key (stored as a Supabase function secret, never in the app)
- App icon + a couple of brand assets (have the design language; need the icon)
