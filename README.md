# Tempo

**Marathon coaching, honestly.** An AI-adaptive marathon training app — a direct, independent
alternative to Runna (now owned by Strava). Built to be used, starting with the 2025/2026 build-up
to the Chicago Marathon.

> Working name: **Tempo**. Status: design complete (12 screens + clickable prototype);
> v1 build underway. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the locked stack
> (iOS/SwiftUI · HealthKit · hybrid engine · Supabase · Claude).

## Why this exists

Runna was acquired by Strava. Tempo is an independent take that leans into three things its
competitors do poorly:

1. **Smarter adaptive plans** — the plan reshapes around your real runs, fatigue, and life, not a
   fixed PDF schedule.
2. **Real coaching & motivation** — a calm-expert AI coach that checks in, explains the *why*, and
   holds you accountable.
3. **Data depth & honesty** — deep, honest analysis (splits, zones, HR drift, training load) with
   no upsell walls or Strava lock-in.

## Product decisions (v1)

| Area | Decision |
|------|----------|
| Platform | **iOS native (SwiftUI)** — Apple Watch + HealthKit, App Store target |
| Plan engine | **AI-adaptive** (LLM + rules) over a proven training-science backbone |
| Recording | **Sync-first** — import from Apple Health / Garmin / Strava. In-app run recording comes later. |
| Coach voice | **Calm expert** — measured, knowledgeable, no hype |
| Data sources | Apple Health (HealthKit), Garmin Connect, Strava import |

### Reference athlete (drives sample data + tone)
Goal: **sub-3:15 at Chicago (Oct)**. Currently rebuilding from a small base (~0–20 mi/wk) after an
inconsistent year. Plans should start with a **base-building block**, not peak-week heroics.

## Design system

Built in Figma with real token variables (Dark + Light modes). Aesthetic: **technical, data-rich,
dark-first** with a single electric accent — deliberately *not* Strava orange / Runna brights.

**Type**
- Display / titles: **Space Grotesk** (Bold)
- UI / body: **Inter** (Regular → Extra Bold)
- Metrics / labels: **Roboto Mono** (Medium)

**Core color tokens (Dark)**

| Token | Hex | Use |
|-------|-----|-----|
| `bg/canvas` | `#0B0D10` | App background |
| `bg/surface` | `#161A20` | Cards (v2) |
| `bg/elevated` | `#222831` | Raised surfaces, borders |
| `bg/inset` | `#0E1014` | Wells, tab bar |
| `border/default` | `#222831` | Card borders |
| `text/primary` | `#F3F5F8` | Primary text |
| `text/secondary` | `#9BA5B3` | Secondary text |
| `text/tertiary` | `#646E7C` | Labels |
| `accent/volt` | `#CDFB45` | The hero accent ("Volt") |
| `status/success` | `#34D399` | Success |
| `status/warning` | `#FBBF24` | Warning |
| `status/danger`  | `#F87171` | Danger |
| `status/info`    | `#3BD7F5` | Info / sync |

**Pace / HR zones** (perceptual ramp, used everywhere data is shown)

| Zone | Hex |
|------|-----|
| Z1 easy | `#4F8DF7` |
| Z2 aerobic | `#34D399` |
| Z3 tempo | `#CDFB45` |
| Z4 threshold | `#FB923C` |
| Z5 max | `#F43F5E` |

Spacing scale: `2 4 6 8 12 16 20 24 32 40 48 64`
Radius scale: `sm 6 · md 10 · lg 14 · xl 20 · 2xl 28 · full 999`

## Screens (v2 complete — 12 screens)

**Onboarding**
1. **Welcome** — brand-first intro
2. **Connect your runs** — sync-first (Apple Health / Garmin / Strava)
3. **Goal Setup** — pick race, goal finish time, run days/week, current volume
4. **Paywall** — Tempo Pro: features, Annual/Monthly pricing, free trial

**Core app (tab bar: Today · Plan · Progress · Coach · You)**
5. **Today** — daily home: readiness ring, session card, workout structure, coach cue, week, last run
6. **Plan** — adaptive 18-week plan: race countdown, training phases, adaptive adjustments, week list
7. **Progress** — goal-trajectory hub: projected finish vs goal, fitness trajectory toward ceiling,
   training-block phase progress, consistency, key-session benchmarks, recent-runs preview
8. **Coach** — calm-expert conversational coaching with quick replies
9. **You** — profile: goal hero, year stats, personal bests, connected sources, preferences

**Detail**
10. **Run History** — all runs grouped by week, training-load-balance read (under/over-training), per-run tags
11. **Run Detail** — run breakdown: splits chart vs target, time-in-zone, HR drift, coach takeaway
12. **Fitness** — training-load trends: CTL curve, fitness/fatigue/form, weekly mileage, pace trends

## Prototype (clickable)

The screens are wired into an interactive Figma prototype — full onboarding chain
(Welcome → Connect → Goal Setup → Paywall → Today), working bottom-tab navigation
across the 5 main screens, and deep links: last run → Run Detail, coach cue → Coach,
You → Fitness, Progress → "See all" → Run History → Run Detail. Start point: **Welcome**.

- **Play:** https://www.figma.com/proto/pwk7w2hbbQDFL35Penijae?node-id=11-2&starting-point-node-id=11-2&scaling=scale-down
- **Design file:** https://www.figma.com/design/pwk7w2hbbQDFL35Penijae

## Next steps

- [ ] Add remaining screens: Profile/You, Stats/Fitness trends, Paywall/subscribe, run-detail map
- [ ] Wire screens into a clickable Figma prototype
- [ ] Scaffold the SwiftUI app: design tokens in code, navigation shell, HealthKit sync
- [ ] Plan-generation engine (LLM + training-science rules) and adaptive re-planning
- [ ] TestFlight ahead of the summer training block
