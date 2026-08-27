# Tempo — build progress

> Read me first each session. Architecture + build sequence: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

_Last updated: 2026-08-27 (coach unbroken; the run archive opens up)_

## Where we are

Build sequence status (numbers from ARCHITECTURE.md):

- [x] **0. Foundation** — architecture doc, DB schema (`supabase/migrations/0001_init.sql`), design tokens, pace engine
- [x] **1. App shell** — 5 tab screens (Today · Plan · Progress · Coach · You) render from mock data; design-system components built from tokens; **compiles clean** (verified 2026-07-08, `xcodebuild generic/platform=iOS` → BUILD SUCCEEDED)
- [x] **2. Auth + HealthKit** — done for beta-of-one: **anonymous Supabase auth** on launch (enabled in project settings via Management API; Sign in with Apple deferred to pre-TestFlight), HealthKit authorization prompt on first launch, full run history read (Garmin runs arrive via Garmin Connect → Apple Health), background upsert to Supabase `runs`.
- [ ] **3. Onboarding** — Welcome → Connect → Goal Setup exist in Figma only, not in Swift. Goal is hardcoded (sub-3:15 Chicago 2026-10-11) in `RunStore.goalDescription` + `ProgressScreen.raceDate`.
- [~] **4. Core read screens on live data** — Today (real date, real weekly mileage counter + day dots, real last run) and Progress (real weekly mileage trend, real recent-runs list, real race countdown) are live. Plan, You, and Today's session/readiness cards are still mock; Progress projection/block cards now show honest "plan engine pending" placeholders instead of fake numbers.
- [ ] **5. Progress (CTL/ATL/Form)** — not started (needs plan engine)
- [~] **6. Engine on server** — `coach` Edge Function deployed (v1, ACTIVE) — Claude (`claude-sonnet-5`) via plain fetch, `ANTHROPIC_API_KEY` set as function secret. Plan/adapt functions still to come.
- [x] **7. Coach chat** — live end-to-end: ChatStore → Edge Function → Claude, grounded in a `CoachContext` snapshot (last 21 days of runs + 8 weeks mileage + goal). History persists in `coach_messages`. Auto-opens with a data-grounded status read; quick-reply chips. Smoke-tested 2026-07-08 with a real reply.
- [ ] **8. Polish + TestFlight**

## Loose ends / ops

- ~~Fonts~~ **Fonts added 2026-07-08** — all 6 ttfs in `Resources/Fonts/`, PostScript names verified against `Tokens.swift`, confirmed bundled in the built .app.
- **`DEVELOPMENT_TEAM` is empty** in `ios/project.yml` — David sets his team in Xcode Signing (already did once to run on device; re-set after each `xcodegen generate` unless we pin it in project.yml).
- **Anonymous-user churn:** each app reinstall (or keychain wipe) mints a new anonymous Supabase user; old rows orphan. Fine for beta-of-one; Sign in with Apple fixes it properly.
- **Uncommitted:** everything from tonight's session, plus `ios/Tempo/Tempo.entitlements`. `.env` holds the Anthropic token — covered by `.gitignore`, keep it out of git.
- Apple Developer Program ($99/yr) still needed for TestFlight; free personal team fine for on-device dev (7-day install expiry).
- App icon still needed.
- Simulator runtime on this Mac broken (CoreSimulator mismatch — reboot / finish Xcode update). Device-only for now.

## New ideas captured 2026-07-08 (David)

- Coach conversations should **infer/recalibrate the goal** and define how a workout or week gets evaluated → feeds the future goal/plan engine.
- Weekly mileage counter — ✅ shipped (Today card + Progress trend).
- Deeper "synthesized analysis of how I'm tracking toward the plan" — v0 lives in the coach's kickoff status read; the full version needs the plan engine.

## Plan-engine design decisions (David, 2026-07-08, late)

1. **Assessment-driven plan shape — no fixed 4-phase template.** The generator must first assess real training data (volume trend, consistency, long-run capability, presence of quality work, projected current fitness) and pick a plan shape that fits — e.g. an already-fit athlete with 13 weeks gets a race-specific/speed-endurance block, not a forced Base phase. Phases are emergent from what's missing, not a template. Safety invariants (ramp caps, long-run caps vs history) stay deterministic in code.
2. **Run history must be editable via conversation.** Example: "today's run was actually 8 mi, not the logged 6 — I forgot to start my watch; add 2 mi @ 10:00 at the start and infer HR." Coach gets write tools (amend_run / add_run) with in-chat confirmation. **Architectural consequence: Supabase `runs` becomes the read path** (HealthKit becomes ingest-only, insert-only so corrections survive re-sync); all derived metrics (weekly mileage, load, readiness) compute from the corrected table. Originals preserved for audit; estimated fields flagged.
3. **Don't soften goal tension.** The engine should say the honest thing even when the prescription is big ("six hours of running"). Goal-feasibility talk is direct.
4. **User agency over injury-safety paternalism.** Conservative ramps are the *default*, never a wall. If the athlete says "I feel fine, I want to go for this": name the specific risk once, get explicit confirmation, then commit to the ambitious line — remembered as a standing preference (risk-tolerance on the athlete profile), re-confirmed only at meaningful escalation points, not relitigated every message. Aggressive sessions gate on a lightweight pre-run check-in ("feeling okay? anything hurt?") — that self-report is the trust mechanism AND a data input to readiness. Listening cuts both ways: a pain report gets the same immediate respect as ambition (no "push through it"). The one thing never overridden is honesty — if a trajectory genuinely threatens the athlete's ability to race at all, the coach says so prominently. That serves the goal; it isn't gatekeeping. (Context: beta-of-one, David trials everything on himself first.)

## Links

- Figma prototype: https://www.figma.com/proto/pwk7w2hbbQDFL35Penijae?node-id=11-2&starting-point-node-id=11-2&scaling=scale-down
- Figma design file: https://www.figma.com/design/pwk7w2hbbQDFL35Penijae
- Supabase project ref: `lpgdhqqroyqdrjsrlodo`

## Run Detail spec (interviewed David 2026-07-08)

Full-screen **push** from Today's last-run card AND Progress → Recent runs rows. Layout top-to-bottom:
1. **Map hero** — route from HealthKit workout route, **colored by pace** (zone ramp); tap → fullscreen pan/zoom. No GPS → styled "Indoor run" banner strip (page keeps its shape).
2. **Coach's read** — 2–4 sentence honest take, **auto-generated on first open, cached in `runs.coach_takeaway`** (nulled when a run is corrected → regenerates). "Discuss with Coach" → switches to Coach tab.
3. **Stats grid** — distance hero; avg pace (moving), elapsed pace, best pace (rolling 30s), avg speed; moving time + elapsed time (full Garmin-style trio, stopped time derived from sample gaps); avg + max HR; elevation gain; cadence; calories. Hide tiles whose data is absent. If corrected: "edited" strip with the correction note.
4. **Pace + HR overlay chart** — one chart, both series normalized, **scrubbable cursor** with readout (mile, pace, HR at point).
5. **Time-in-zone bars** — 5 HR zones (Garmin %max bands), zone ramp colors, minutes + share. Zones anchor on `profiles.max_hr`; **default = formula (220−age→192)**, overridable via chat ("my tested max HR is X" → coach `update_athlete` tool) and later via onboarding.
6. **Elevation profile** — area chart from route altitudes.
7. **Splits table** — per mile: pace + bar vs avg, avg HR, elev Δ.

Later wishlist (explicitly deferred): watch laps, weather, PR detection, share card, HR drift.
**Queued: onboarding interview** — David wants a full Q&A session before onboarding gets built (zones/max HR live there too).

## Plan-engine spec (interviewed David 2026-07-08, late)

**Goal flow:** engine assesses real history first → coach opens with "here's what I think you should target and why" (maybe 3:15, maybe not) → David confirms via card → plan generates. No plan exists before that confirmation.

**Plan parameters are chat-mutable settings with full cascade.** days/week (start: 6), long-run day (start: Sunday), quality dose (coach decides by phase from: data available, current behavior, time to race). Saying "drop me to 5 days" in chat must: update settings → regenerate forward plan → recompute projection → all in one confirmed action. These same parameters are onboarding questions later.

**Sessions:** mixed prescription — quality days fully structured (reps/paces from the pace engine), easy days effort + distance range. **Adaptation: adapt small automatically (with the one-line why), confirm-card anything that reshapes a week or block.** Today card: two-tap check-in gates hard days; completed runs auto-match to sessions and get a verdict. **Horizon: 2 weeks firm, remainder as phase/mileage/key-session sketch that crystallizes as it approaches.**

**Strength/mobility: PRESCRIBED, not just avoided** (a real differentiator; also an onboarding topic). **Tune-up race: coach decides and proposes.** **Projection: recomputes after every run, visible live; coach narrates movement.**

**North star (what everyone else got wrong):** rigidity when life happens; no real *why* per session; cookie-cutter starts ignoring history; volume worship; and Garmin specifically — "stats with no inference, no context about the race you're running." Sense-making must NOT be paywalled.

**Onboarding to-do list keeps growing (own session, own interview):** run days/week, long-run day, quality appetite, no-race goal inference (ask about goals + risk tolerance), strength/cross-training prescription, max HR, goal setup.

## Onboarding spec (interviewed David 2026-07-09) — ✅ BUILT same session

- **Hybrid**: Welcome (brand) + Connect (HealthKit moment, shows run count) as screens → **coach-led interview** in chat for everything human. **Hard gate**: full takeover until complete; surfaces for ANY user whose `profiles.onboarded_at` is null — including existing/active users (David gets it next launch).
- **Existing users**: interview prefills from `onboarding.known` (settings, risk, max HR, birthdate, active plan) — confirms in passing, never re-asks cold; **live plan survives** unless the goal changes.
- **No-race athletes**: goal-inference interview (what are they chasing, how should it feel) → training intent. **Zero runs found**: Connect shows the Garmin→Health hint; coach interviews stated baseline and starts conservative.
- **Collects**: goal/race, days per week, long-run day, risk appetite (trade named once), injuries past year, strength/cross-training + wants-it-prescribed, birthdate (kills the hardcoded age-28 HR formula), optional tested max HR.
- **Ends with plan live**: closing beat is the goal proposal → create_plan card → lands on Today with a real session. Coach calls `complete_onboarding` → flag written → app swaps to tabs reactively.
- **Mechanics**: migration `0005_onboarding` (onboarded_at, birthdate, injury_notes, strength_notes, wants_strength). Coach **v8**: onboarding persona section (one question per message, ~8 max), broadened `update_athlete` (birthdate/injuries/strength), `complete_onboarding` tool, and a **tool-continuation round** (tool-only replies get results fed back so the coach always speaks — found via smoke test when the interview stalled after recording a fact). During onboarding, small facts **auto-apply silently** (the answer is the consent); create_plan keeps its confirm card. Swift: `OnboardingView` (3 steps), `RootTabView` gate (splash → onboarding → app), `CoachView(onboarding:)`, `effectiveMaxHR` now birthdate-aware. Auth stays anonymous (SIWA pre-TestFlight).
- Smoke-tested: fact recorded + interview continued with honest volume flag + risk question. BUILD SUCCEEDED.

**Build sequence for the engine:**
- **A. Schema + settings** — plan_settings (days/week, long-run day) on profiles; plans gains assessment jsonb + projected_finish_s; check-ins UI hookup on Today.
- **B. /plan Edge Function** — reads runs via caller's JWT (RLS): deterministic feature extraction (4-wk volume/trend, consistency, long-run cap, pace spread, Riegel current fitness) → Claude proposes plan shape in a constrained schema → deterministic TS generator (port TrainingPaces) writes plan_weeks + sessions.
- **C. Goal-proposal loop** — coach tool `create_plan` (proposed goal + rationale) → confirm card → /plan runs → Plan tab + Today session card go real, "plan engine pending" pills die.
- **D. Matcher + verdicts** — runs auto-match sessions; weekly evaluation.
- **E. Adaptation** — small/auto + big/confirm, powered by check-ins + readiness.
- **F. Projection** — per-run recompute (client Riegel + volume-vs-plan), coach narration hooks.

## Gap audit (2026-07-11) — what's still missing

**Do next (small, high-value):**
- ~~HR backfill~~ ✅ 2026-07-11: new ingests get HR enrichment from the time window before insert; a capped repair pass (25 rows/refresh, 90-day window, corrected rows untouched) fills historical nulls — a few refreshes clear the backlog. Coach context now sees HR.
- ~~Auto-generate takeaways post-match~~ ✅ 2026-07-11: `TakeawayService` (shared by Run Detail + RunStore) generates in the background when the matcher marks today's session done — the coach's read is waiting on Today without opening the run. In-flight guard prevents duplicate generations.
- **Run History screen** — Progress caps at 14 days; 2,010 runs deserve a full, searchable history (Figma design exists).
- **Confirm cards don't survive restart** — persist pending actions.
- **David's side (calendar time):** ~~Apple Developer enrollment~~ ✅ has an account → next build session can add SIWA + push + TestFlight prep. **Garmin Connect Developer Program application** — steps given 2026-07-11; waiting on David to submit; approval typically days–weeks; unlocks Activity API (GPS routes → maps, watch laps) + Health API (sleep/HRV → readiness) + Training API (push workouts TO the watch).

**Chat polish shipped 2026-07-11 (late):** coach v11 empty-reply guard (logs stop_reason, one retry, honest fallback line — "empty reply" error now unreachable); context-aware quick replies (done→"Break down today's run"/"What's the focus tomorrow?", hard-day+no-check-in→"Something feels off today", missed sessions→"I missed a session — what now?", behind-goal→"How do we close the gap?", >3 days quiet→leads with the generic check-in); message timestamps (persisted created_at) with iMessage drag-from-right reveal + TODAY/YESTERDAY day separators.

**Needs the Apple Developer account ($99):**
- Sign in with Apple (replaces anonymous; survives reinstalls) → TestFlight beta.
- Push notifications (session reminders, proactive coach nudges).
- App icon + launch screen before anyone else sees it.

**Longer leads:**
- **Garmin API direct sync** — the only path to route maps (Garmin confirmed not exporting GPS to Health); partner approval takes weeks — apply early.
- **Weekly review** — proactive Sunday-night coach message reviewing the week vs plan (Supabase scheduled function + push).
- **Tune-up race proposal** — engine supports it; coach persona nudge + plan-generator awareness.
- Paywall (deliberately post-beta), Android (not v1).
- Run-detail wishlist: watch laps, weather, PR detection, share card, HR drift.

## Session log

- **2026-08-27 (the archive) — coach chat unbroken, and the Strava-replacement push begins.**
  - *The coach was answering every message with "Lost my train of thought there."* Root-caused
    from production logs in one query: `stop_reason: max_tokens`, `output_tokens: 1200`, of which
    `thinking_tokens: 1200`. **Sonnet 5 runs adaptive thinking by default when `thinking` is
    omitted, and thinking is drawn from the same `max_tokens` budget as the reply.** The ceilings
    in `coach` (1200 chat / 400 takeaway / 600 continuation) were sized for a model that didn't
    think, so the whole budget went to thinking and the response carried a lone thinking block —
    no text, no tool call. The empty-completion guard fired, the retry reused the same ceiling and
    failed identically, and a fallback written for an occasional hiccup became the only thing
    David ever saw. Run-detail takeaways (400) were almost certainly failing the same way.
    Fixed with a shared `SAMPLING` block: 16k ceiling, `thinking: {type: "adaptive"}` stated
    explicitly rather than inherited, `output_config: {effort: "medium"}` as the actual dial
    (#16 → PR #17). `plan/index.ts` carried the identical defect at 1500 (#18 → PR #28) — its
    failure mode was a bare 502 "no shape proposed" with no plan built. Confirmed while fixing it
    that forced `tool_choice` alongside thinking is a **Bedrock-only** restriction, so the forced
    choice stays. Both functions now log `stop_reason` + `usage` on the failure path; that line is
    the entire reason the first diagnosis took a log query instead of guesswork.
    **Both need David to deploy.**
  - *New direction from David:* the north star is **replacing Strava**, above all on rich run
    analysis — splits, maps, all of it — while staying fun and easy to scroll through past runs.
    Beta-of-one, so this means the analysis and the archive, not a social graph.
  - *The key discovery:* `RunStore.fetchFromSupabase()` has **no limit**, so all 2,010 runs were
    already resident in memory. The app showed a 14-day card. Every cross-run feature is therefore
    pure presentation — no fetch, no pagination, no migration.
  - *Shipped (#10 → PR #23):* `Engine/RunHistory.swift`, pure and pinned by 18 tests — month
    grouping with stored totals, Mon–Sun weeks, streaks, and records banded by distance (3 mi+ /
    10K+ / Half+ / Marathon) so a fast shakeout can't outrank a strong half. Records are
    **whole-run averages, not splits within a run**; the naming says "run" everywhere so the two
    never get conflated. `Screens/HistoryView.swift` owns its own ScrollView for a `LazyVStack`
    with pinned month headers; per-row bars scale to the month's longest run so a long scroll has
    rhythm. Filters: All / 10K+ / Half+ / PRs. Two doorways from Progress.
  - *Shipped (PR #24):* the **training wall** — `RunHistory.wall()` plus a `TrainingWall` view.
    Five years of running as one grid. Rest days included (a wall of only run days is a smear, not
    a pattern); days outside the year padded so Jan 1 lands on its real weekday, or the grid shears
    and the weekday rows stop meaning anything; fixed intensity bands rather than quantiles of the
    athlete's own distribution, so an easy day means the same thing in June as in a taper. Cells
    are 4.5pt so a full year fits without scrolling — far below a tap target, so selection is a
    **scrub**, and the 44pt readout is what opens the run. Drawn with `Canvas`: six years would
    otherwise be ~2,200 SwiftUI views in one scroll section.
  - *Judgment calls, cheap to reverse:* History is a pushed route rather than a sixth tab (six is
    past what a phone tab bar carries, and the archive needs its own scroll view).
  - *Filed for what's next:* #25 sub-distance best efforts (fastest 5K **within** a run — needs a
    background pass over per-run HealthKit series and a schema change, so it's a spike with real
    decisions for David), #26 year jump for the history scroll, #27 route matching ("you've run
    this before") — the true segment analog and, for a beta-of-one, arguably more valuable than
    Strava's version, since comparing David to David needs no leaderboard.
  - *Still not device-verified.* Nothing here has been seen running. The scrub in particular is a
    feel question only David can answer.

- **2026-08-23 (splash freeze) — root-caused to a paused Supabase project; the *freeze* fixed in the app.**
  - **Symptom:** app hangs on the "Tempo" splash forever. **Cause (infra):** the Supabase project `lpgdhqqroyqdrjsrlodo` is `INACTIVE` — free-tier auto-pause after ~7 days idle. Every launch request fails; `list_tables` against it times out. **David restores it from the dashboard; agents never touch project state.**
  - **Cause (app) — the real bug, and it outlives the outage.** `RootTabView` showed the splash for `needsOnboarding == nil`, and `nil` meant *both* "not loaded yet" and "load failed": the profile read was wrapped in `try?`, so any failure left the gate nil forever. No timeout, no error state, no retry — and `start()`'s `guard phase == .idle` meant the first failure was permanent for the process lifetime.
  - **Fix.** New `Engine`-style pure gate `Services/LaunchGate.swift`: `.loading | .onboarding | .ready | .unreachable(reason:)`, resolved by a pure `resolve(signedIn:profile:)`. Two invariants pinned by tests: *resolution never yields `.loading`* (a failure can't masquerade as loading) and *an unreadable profile never routes to `.onboarding`* (demoting an onboarded athlete into the setup interview would read as account loss).
  - Profile read now decodes `[Row]` via `.limit(1)` instead of `.single()` — PostgREST throws on a zero-row `.single()`, which is exactly what collapsed "no profile yet" into "couldn't read profile". Absent row → `.new`; thrown/timed-out → `.unreachable`.
  - Transport leash: `Supa` now builds its own `URLSession` (request 15s, resource 30s, `waitsForConnectivity = false`) instead of inheriting `URLSession.shared`'s 60s/7-day defaults. Plus `Deadline.run(_:)` for launch work that could stall off-network. `signInAnonymouslyIfNeeded()` returns `Bool` now — that one bit is the whole difference between a retry screen and a permanent splash.
  - `LaunchErrorView` + `RunStore.retryLaunch()` (resets the `phase` latch). Copy deliberately says *connection*, not *error* — the data was never at risk.
  - New telemetry: `auth.anonymous_sign_in_failed`, `launch.profile_unreadable`. Note these need migration `0006_telemetry` applied before they record anything.
  - Verified: `xcodegen` 0, device-slice build 0, **33 tests / 0 failures**. **David confirmed on device**: project restored, app launches, retry screen works.

- **2026-08-23 (loop live) — the autonomy loop is switched on.**
  - **Board seeded.** 9 labels (`agent-ready` / `needs-david` / `needs-device`, `p0`–`p2`, `feat`/`chore`/`spike`) + 8 issues (#6–#13) drawn from the 2026-07-11 gap audit and today's findings. The four `needs-david` ones are assigned to David so GitHub notifies him; his comment on the issue is the answer, and the next EM run reads it back and re-labels `agent-ready`. That round trip is the whole consult mechanism.
  - **Three cloud routines** (UTC crons; local times shift an hour at the November DST change):
    | Agent | Local | Cron (UTC) | Model | Connectors |
    |---|---|---|---|---|
    | Scout `/triage` | daily 08:17 PDT | `17 15 * * *` | sonnet | Supabase (read-only) |
    | Builder `/build-next` | weekdays 09:23 PDT | `23 16 * * 1-5` | opus | **none** |
    | EM `/brief` | Fridays 17:11 PDT | `11 0 * * 6` | opus | Supabase (read-only) |
  - **Least privilege matters here.** A routine created without an explicit `mcp_connections` list inherits *every* connected connector — Builder came up with Gmail, Slack, Stripe, Notion, Asana, Linear and Calendar attached. Cleared it to `[]`. An agent that acts autonomously on issue text from a public repo must not also hold the keys to email and payments; anyone can file an issue.
  - **PR hygiene lesson:** #4 was stacked on `chore/autonomy-foundation` and merged into *that branch*, not `main` — GitHub only auto-retargets a stacked PR when its base branch is **deleted**, and #3's branch survived. The launch fix silently missed `main`; re-opened as #5. Either delete the base branch on merge, or retarget the child before merging the parent.
  - Still gating everything: migration `0006_telemetry` is unapplied (#6). Until it runs, Scout's first pass will correctly report an empty `app_events` and little else.

- **2026-08-23 (autonomy foundation) — CI, an engine test suite, telemetry, and a three-agent org.**
  - **`.github/workflows/ci.yml`** — the piece everything else depends on. macOS runner: device-slice build + simulator tests; Ubuntu: `deno check` on the edge functions. Cloud agents run Linux and *cannot compile Swift*, so CI is literally their compiler. Simulator UDID resolved dynamically at run time rather than pinned (a pinned device name is a loop-wide outage waiting to happen).
  - **`ios/TempoTests/`** — first real tests. Written as regressions against actual incidents, not coverage padding: `RunDedupeTests` replays the 2026-07-10 Garmin re-export week; `LoadModelTests` pins "the athlete's word outranks the math" (a positive check-in must *not* inflate readiness, only lift the cap); `PaceModelTests` pins the sub-3:15 paces the doc comment already claimed were tested.
  - **`Engine/RunDedupe.swift`** — extracted the ±300s dedupe out of `HealthService.sync` as a pure function. Behavior-identical; the point is that the worst bug class in the app's history is now regression-testable without mocking HealthKit.
  - **Telemetry** — `supabase/migrations/0006_telemetry.sql` (`app_events`, RLS insert-only + own-read so a bug can't erase evidence of itself) + `Services/Telemetry.swift`, wired at 9 sites. No health data, no PII, stable dot-path keys. **Not applied yet** — until it is, the triage agent is blind.
  - **Agent org** — `CLAUDE.md` (rulebook: three hard limits, verification contract, never-do list), `.claude/agents/{scout,builder,em}.md`, `.claude/commands/{triage,build-next,brief}.md`, `docs/AUTONOMY.md`. Roles are split so no agent grades its own homework.
  - Decisions: David reviews every PR (nothing auto-merges); EM consults via GitHub decision issues assigned to him (Claude's push notifications only fire from a live local session, so a cloud routine can't reach his phone that way); stabilize before features.
  - **Correction to earlier notes:** the "simulator runtime broken (CoreSimulator mismatch)" line from 2026-07-08 is stale — iOS 18.2 and 26.5 runtimes both work; the full suite runs locally on iPhone 17 Pro.

- **2026-07-11 — Engagement pass: readiness goes real (the last hardcoded stub dies) + richer Today + polish.**
  - **LoadModel** (`Engine/LoadModel.swift`): per-run load = miles × intensity² (intensity = pace vs athlete's own 60-day median — self-calibrating, works without HR); CTL(42d)/ATL(7d) EWMAs; form = CTL−ATL; readiness 5–98 centered on form/fitness; a "something's off" check-in caps it at 40 (athlete's word outranks math). Computed every refresh; feeds coach context (`fitness` block).
  - **ReadinessDetailView**: ring + label/caption, Fitness/Fatigue/Form tiles, 8-week CTL area chart, check-in status, honest "how this works" (pace-based until Garmin HR flows). Router now takes `Route` enum (`.run`/`.readiness`).
  - **Today richer**: readiness card is real + tappable (chevron → breakdown); done sessions show the coach's cached read inline (3-line preview + "Full analysis") or a "Get the coach's read" link; after today is banked, a **Tomorrow** preview card appears.
  - **Coach tab spacing pass**: message rhythm 14→18, bubble line-spacing + rounder corners, header/quick-reply breathing room.
  - **You tab interactive**: goal hero → Plan; year stat tiles → Progress; best rows → the run that earned them (biggest week → Progress).
  - Garmin/Health confirmed: **no route data in Apple Health at all** → maps blocked on Garmin API (audit above). BUILD SUCCEEDED.

- **2026-07-10 (post-run) — Garmin re-export double-counting fixed; map lead identified.**
  - **Bug (weekly 15→31 instead of 18):** David's Garmin settings change made Garmin Connect **re-export this week's workouts as new HKWorkout objects (new uuids)** — uuid-keyed dedupe saw new runs: Tue 7.10 duplicated, Wed's corrected 8.00 joined by its resurrected raw 5.85. Math matched exactly (31.4).
  - **Cleanup (SQL, verified):** per (user, identical start_time): keep corrected-first-then-newest row, remap matched sessions to keeper, delete dupes, **re-point keeper external_id at the newest HK object** (so if Garmin's new setting exports routes, detail pages find them). David's week now 7.10 + 8.00 + 3.33 = 18.4 ✓.
  - **Durable fix:** `sync(_:existing:)` second dedupe layer — any candidate starting within ±5 min of an already-recorded run is skipped (plus intra-batch); `refresh()` reordered DB-fetch → dedupe-ingest → re-fetch-if-inserted.
  - **Map next steps (for David):** re-open a run's detail — external_ids now point at tonight's fresh HK workouts; if Garmin's new setting exports routes, maps appear. If not: check (1) Apple Health app → the workout → is there a route map at all? (2) Settings → Privacy & Security → Health → Tempo → "Workout Routes" toggle ON. If Health itself has no route → Garmin isn't exporting GPS; direct Garmin API sync is the roadmap fix.

- **2026-07-10 (late) — Plan-destruction bugs fixed + Stages E/G/H shipped.**
  - **Diagnosed from DB** (David's user `402e4b96`: 2,010 runs): his "vanished" plan was ALIVE in the DB — the UI destroyed its local copy. Three structural causes, all fixed:
    1. `loadPlan` assigned `plan = try?` — any cancelled pull-to-refresh or network blip nil'd the plan and wiped weeks/sessions. Now: fetch into locals, commit only on success, clear ONLY when the server definitively returns zero active plans; partial failures keep prior data.
    2. `/plan` retired the old plan BEFORE creating the new one (destruction window; mid-flight failure = no plan). Now **create-then-retire**: full insert chain first, cleanup-on-failure (delete new plan cascade + goal), retire others (`neq` new ids) only after success. Verified: regeneration leaves exactly {active: 1, done: 1}.
    3. Onboarding auto-applies ran in PARALLEL Tasks → paired duplicate regenerations 1s apart (visible in DB). Now sequential with a single coalesced rebuild at the end.
  - **Stage E (adaptation) v1**: auto-rule — missed quality/long this week claims a later easy slot (easy gets skipped), both marked `adapted` + note, silent, once per session; runs on every refresh after the matcher. Coach v10 gains `update_session` tool (move/change/skip one session, ids from new `plan.sessions_window` context) → confirm card ("Adjusting your session…"). "Adapted" tags + notes surface on Plan rows and Today's card; skipped sessions strikethrough.
  - **Stage G**: `wants_strength` → generator prescribes weekly Strength (type `cross`) on a non-running day, skipped during taper. Verified: 11 cross sessions on a 13-week/5-day plan.
  - **Stage H**: You tab real — goal hero (target/race/projected + on-track tag), year stats from real runs, Bests (longest, fastest 3mi+ pace, biggest week), Training settings card (days/long-run day/risk/max HR) with "Change via Coach".
  - **Discovery**: DB has an `on_auth_user_created → handle_new_user` trigger auto-creating profiles (predates this work) — profile INSERTs 409; use upsert/patch (app's ensureProfile already safe).
  - Functions: coach **v10**, plan **v2**. BUILD SUCCEEDED. David's plan intact — relaunch shows it.

- **2026-07-09 (onboarding)** — Onboarding interviewed, spec'd, and **shipped** (see "Onboarding spec" above). Next session candidates: stage E adaptation loop; Garmin route workaround decision; You tab still mock; consider `update_session` coach tool.

- **2026-07-09 (early AM)** — **Plan engine stages A–D + F shipped; E partial. Run Detail fixes + visual pass.**
  - *Detail fixes:* time-in-zone was capping sparse Garmin HR samples at 15s (1:20 run → 7 min of zones) — now uses real sample gaps (capped 10 min) normalized to the run's displayed time. Corrected runs normalize zones to corrected duration. Map: query already had time-window+source fallback; banner now source-aware ("Garmin didn't write a GPS route to Apple Health…"). Visual pass: content sheet overlaps hero with rounded top, 52pt distance hero row (grid slimmed), taller zone bars/split rows.
  - *A (schema):* `0004_plan_engine` — profiles.days_per_week (6) + long_run_day (0=Sun); plans.assessment jsonb + projected_finish_s. Check-in UI live on Today (two-tap, gates quality/long days, writes `check_ins`, feeds coach context).
  - *B (/plan fn v1):* reads runs via caller JWT → deterministic features (12-wk volume table, 4-wk avg/trend, consistency, longest run, best effort → Riegel fitness) → Claude proposes shape via forced tool (phases emerge from data; start volume anchored ±15% of actual; taper mandatory; long-run caps) → deterministic generator (TS port of TrainingPaces; step-back every 4th week; long run on long_run_day; quality Tue/Thu by phase recipe; easy fills) → writes goals/plans/plan_weeks/sessions, retires old actives.
  - *C (goal loop):* coach v6 tools `create_plan` + `update_plan_settings` (cascade: profile update → /plan regenerate → projection). App: ChatStore invokes /plan on confirm and narrates result into chat; RunStore owns plan/goal/weeks/sessions/todayCheckIn; TodayView real session card (check-in gate, done-with-matched-run state, no-plan CTA); PlanView real (countdown, phase chips, 2 firm weeks w/ session rows, sketch weeks); ProgressScreen projected + training-block cards real — **"plan engine pending" pills gone**. Coach quick-replies adapt to plan state.
  - *D (matcher):* on every refresh, planned past sessions claim same-day runs (status→done, run_id); Today shows "Done — X.X mi logged → View run".
  - *F (projection v1):* Riegel from best ≥2.5mi effort in 42d, recomputed each refresh, persisted when Δ>30s; Progress shows delta vs goal ("on track"/"behind goal").
  - *E (adaptation) — remaining:* check-ins + plan land in coach context (conversational adaptation works via existing tools), but the automatic small-tweak loop (missed-session reshuffle, readiness-driven swaps) is NOT built. Next session: /adapt pass or on-launch rules + `update_session` tool.
  - *Verified:* /plan smoke test (seeded 3-wk sparse history): rebuild_base, 13 wks, 13→27 mi/wk anchored on real 12.1 avg, Sunday long runs, 78 sessions, honest rationale ("3:15 isn't realistic from this base… expect to reassess"), projection 4:20:40. BUILD SUCCEEDED throughout.

- **2026-07-08 (post-launch fixes)** — David's device test caught two real bugs, both fixed and verified compiling:
  1. **Garmin samples aren't associated with workouts** — `predicateForObjects(from:)` returned nothing (tell: calories present from workout statistics, but zero HR/charts/route). Fix: association query first, then fall back to the workout's time window filtered to the same source app (so iPhone motion estimates never pollute a Garmin run). Applied to quantity samples AND route lookup.
  2. **Corrected runs showed raw HealthKit totals** (5.85 mi instead of the corrected 8.0). Fix: DB truth wins for distance/time/avg pace/HR on corrected runs; HK-only time-accounting tiles (moving/elapsed/elapsed-pace/speed) hide on corrected runs since they only describe the recorded portion; takeaway payload same. Banner now honest: "Indoor run" only when HKMetadataKeyIndoorWorkout says so, else "No route data" / "Logged manually".
  - Open question David's next retest answers: does Garmin write GPS routes into Health at all (map appears) or not (banner says "No route data").
- **2026-07-08 (late night)** — **Run Detail page shipped** (spec above, from the interview).
  - Migration `0003_run_detail`: `runs.coach_takeaway` (cached per-run read; nulled on amend so it regenerates), `profiles.max_hr` (nullable → 192 formula default).
  - Coach fn **v5**: `mode: "takeaway"` (one-shot per-run read, no tools, cached by app) + `update_athlete` tool (athlete reports tested max HR in chat → confirm card → profiles.max_hr; zones + context use it). CoachContext now carries max_hr + basis.
  - New `Services/RunDetail.swift`: HealthKit series loader — workout by uuid, distance/HR/step samples, workout route → pace curve (30s window, p5–p95 clamped), best pace (rolling ≥25s/≥100m), Garmin time trio (timer/moving/elapsed; moving from sample speeds >0.45 m/s), zones (%max bands 50–90), smoothed elevation gain/loss, cadence, calories, mile splits (pace/HR/elevΔ), route segments bucketed by pace percentiles (p10–p90 → 5 zone colors).
  - New `Screens/RunDetailView.swift`: pace-colored map hero (tap → fullscreen pan/zoom; indoor banner fallback), coach's read card (cache-or-generate → writes back to DB), 13-tile stats grid (nil-hiding), scrubbable pace+HR overlay chart with readout (mi/pace/HR/elev), time-in-zone bars (shows "MAX HR 192 EST" until measured), elevation profile, splits table with pace bars, edited-strip with correction note, "Discuss with Coach" → Coach tab.
  - Navigation: new `TabRouter` (selection + push path) + `NavigationStack` above the tab shell; Today's last-run card and every Progress recent-runs row now push the detail page.
  - **Fixed in review:** HealthKit read auth was missing workoutRoute/stepCount/activeEnergyBurned — added (next launch shows a one-time permission sheet for the new types; grant them or the map/cadence/calories stay empty).
  - Verified: BUILD SUCCEEDED; takeaway mode smoke-tested live (grounded, honest, cites splits + volume gap).
  - Wishlist parked: watch laps, weather, PR detection, share card, HR drift. **Queued: onboarding interview.**

- **2026-07-08 (night, cont.)** — Silenced the supabase-swift auth deprecation warning by setting `emitLocalSessionAsInitialSession: true` in `SupabaseClientOptions.AuthOptions` (Supa.swift). Uses default Keychain storage, so the anonymous session still persists across launches; we don't consume `authStateChanges`, so no logic change. The remaining console lines (`quic_crypto_queue_append`, `nw_connection_copy_*`, `nw_protocol_instance_set_output_handler`) are Network.framework/HTTP-3 (QUIC) noise from URLSession talking to Supabase — benign, not app bugs, no code fix.
- **2026-07-08 (night)** — **Source-of-truth flip + coach write tools (steps 1–2 of the engine plan), done and verified.**
  - Migration `0002_corrections_agency`: `runs` gains `corrected`/`correction_note`/`original`; `profiles.risk_tolerance` (standard|ambitious) + `risk_acknowledgments`; `check_ins` table (schema only — UI comes with sessions). Applied to remote.
  - Read path flipped: screens read Supabase `runs` (corrections win); HealthKit is ingest-only (insert-only upsert — verified a correction survives re-ingest) + offline fallback. `ensureProfile()` on launch.
  - Coach v4: Anthropic tool use (`amend_run`, `add_run`, `set_risk_tolerance`). Function never writes — it returns `proposed_actions`; the app renders a volt-bordered confirm card (Confirm/Dismiss) and executes client-side under RLS. Original values snapshotted on first correction; pace recomputed; confirmations/dismissals persisted into chat history so the coach knows.
  - Smoke-tested the forgot-my-watch scenario end-to-end: coach computed 6 mi @ 9:12 + 2 mi @ 10:00 → 8.0 mi / 1:15:12, HR 141 weighted from the athlete's own comparable run, exact run id. Found + fixed: model sometimes omits `summary` despite required schema (server now guarantees it; app falls back via `displaySummary`).
  - Corrected runs show an "edited" tag in Progress → Recent runs. BUILD SUCCEEDED.
  - Known gaps: confirm cards are ephemeral (not restored after app restart — history shows text only); `check_ins` has no UI yet; weekly aggregates recompute client-side from the corrected table.

- **2026-07-08 (evening)** — Made it real: anonymous auth enabled + wired, HealthKit → UI (RunStore), weekly mileage counter (Today) + mileage trend and recent runs (Progress), honest placeholders where the plan engine isn't built, fonts installed, `coach` Edge Function deployed and smoke-tested (Claude, grounded in real run data), CoachView fully conversational with persistence. Build verified: BUILD SUCCEEDED, fonts bundled. David runs it from Xcode (⌘R) on his iPhone.
- **2026-07-08** — Audit session: verified app compiles; confirmed services (HealthKit/Supabase) are scaffolded but unwired from UI; added `.gitignore` + this file. Next: pair iPhone, set signing team, run on device; then wire Phase 2 (auth + HealthKit ingest triggered from UI).
