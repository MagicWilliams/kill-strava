# Tempo — agent operating manual

Read this before doing anything. `progress.md` is the narrative history; **GitHub Issues is
the work queue**; this file is the rulebook.

## What this is

An iOS marathon-coaching app (SwiftUI + HealthKit + Supabase + Claude), open source, free,
in **public TestFlight** since 2026-11-05. David is one user among testers, and still the only
reviewer. Production holds other people's data and the repo is public. Those two facts drive
most rules below.

- `ios/` — SwiftUI app. Project is generated from `project.yml` by XcodeGen; `.xcodeproj` is
  gitignored. Always `xcodegen generate` after touching `project.yml` or adding files.
- `supabase/migrations/` — schema, applied in order.
- `supabase/functions/` — Deno edge functions (`coach`, `plan`) calling Claude.
- `docs/ARCHITECTURE.md` — the locked stack and build sequence.

## The three hard limits

**1. You cannot run this app.** It needs a real iPhone, real HealthKit permission, and a
Garmin account feeding it. There is no path to you observing the UI. "Works" is a claim only
David can make. Never write "verified working" — write "compiles, tests pass, needs device
check" and say exactly what to tap.

**2. Cloud agents cannot compile Swift.** Linux sandboxes have no Xcode. If you are running
in the cloud, **CI is your compiler**: open the PR, read the Actions result, iterate on red.
Do not guess that Swift compiles. On David's Mac, build locally before pushing.

**3. The database is live and it holds real people's training.** David's 2,000+ runs and the
plan he is training on, plus testers' runs, plans, journals and coach conversations. Staging is
a throwaway project for simulators and CI, not a copy of this data. A real device always talks
to production.

## Verification contract

Every PR must be green on CI (`.github/workflows/ci.yml`):
- device-slice build (`generic/platform=iOS`, no signing) — proves the whole app compiles
- `xcodebuild test` on a simulator — the engine suite in `ios/TempoTests/`
- `deno check` on the edge functions

Local equivalent, from `ios/`:
```bash
xcodegen generate
xcodebuild -project Tempo.xcodeproj -scheme Tempo \
  -destination 'generic/platform=iOS' -quiet build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Tempo.xcodeproj -scheme Tempo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO
```
(Simulator names drift — `xcrun simctl list devices available` if that destination fails.)

**Any change to deterministic logic ships with tests.** The engine — `Engine/LoadModel.swift`,
`Engine/TrainingPaces.swift`, `Engine/RunDedupe.swift` — is pure by design so it can be
pinned. Every past bug in that layer silently corrupted a number on screen rather than
crashing; a test is the only thing that would have caught them.

## Never do these

- **Never apply a migration or deploy an edge function.** Write the SQL / the function change,
  put it in the PR, and stop. David applies it. `coach` and `plan` are live for him and for
  every tester; a bad deploy breaks all of them at once.
- **Never write to the production database.** Scoped reads for triage are fine (see
  "Production data").
- **Never put production data or David's health figures on GitHub.** The repo is public.
- **Never commit to `main`, never force-push, never rewrite published history.**
- **Never touch `.env`** (holds the Anthropic key) or move secrets into tracked files.
- **Never claim device-verified behavior.** See limit 1.
- **Never bundle unrelated work.** One issue, one PR, one reviewable diff.

## Production data

Accounts are anonymous, so a row never says whose it is. `site/privacy.html` tells testers
that their data goes to Supabase and Anthropic and that David can access the database to fix
problems. GitHub is not on that list.

- **Every read and dry run states its scope:** David's accounts, one named account, or everyone
  in aggregate. Never assume a row, a "latest" result or the biggest account is David's. Tables
  with no `user_id`, such as `plan_weeks`, scope through their parent.
- **David's account ids are not in this repo, and they stay out.** He may have several, because
  a reinstall can mint a new anonymous user. If you don't have them from private context, report
  everyone together and say the split is missing. Don't guess an owner from row volume.
- **Separate David from testers in triage.** Report telemetry and log findings as David / other
  users, with events, distinct users and app version. A tester's error is not his, and tester
  activity does not mean he ran the build.
- **Default to counts.** Reading a tester's free text (coach messages, journal notes, injury
  notes, check-ins) or photos needs David's go-ahead for that specific task.
- **A cleanup names whose rows it touches.** Any migration or script that changes existing rows
  states how many rows change for David and for other users, keeps the originals, and gets
  David's approval on a dry run first. A dry run that shows other people's rows stays on his Mac,
  outside the repo. #268 is the live case.
- **On GitHub, counts only.** Issues, PRs, comments, commits, migrations, test fixtures and CI
  logs are public. Keep out user ids, message and journal text, goals, race dates, paces, times
  and heart rates, whether a tester's or David's. "3 users on build 412" is fine. A figure of
  David's that he needs to see goes on his private asks page. Other people's data doesn't go
  there either.

## What reaches testers

- **Every green merge may.** `testflight.yml` uploads each green `main`, and nothing filters by
  path, so a docs-only merge uploads a build too. Whether a build reaches the external group
  depends on App Store Connect settings agents can't see. Assume it does, and write "may have
  reached testers" rather than claiming either way.
- **Every deploy and migration does, at once.** `coach`, `plan` and the schema are shared, with
  no staged rollout, and they serve every build still installed, not only the newest. Server
  changes have to keep working with installed builds. CI can't prove that, so the PR says how it
  holds. Whoever applies a change does it on staging first, and applies a migration before
  merging app code that reads it. Staging has only throwaway accounts, so it can't show what a
  change does to real rows.

## The recorder is unmeasured

Run recorder v1 is open to testers, and its field test (#132) has no results: GPS accuracy, Lock
Screen, kill test, music, battery, treadmill, Health, Today, tunnel. CI and telemetry can't stand
in for it. A recorded run saves to the tester's Apple Health, so a wrong distance also ends up
outside Tempo.

- An item stays unmeasured until David posts its result on #132. Until then, don't write that the
  recorder is accurate or reliable, or how it does on battery, in a brief, PR, release note or
  listing copy. Naming a feature it has is fine.
- A tester's report of a failure is a bug. No reports is not a pass.
- A #132 comment holds pass/fail, plus percent error or battery drain where the item asks for it.
  No route, location, pace or heart rate.
- Whether the recorder stays open to testers before the checklist is done is David's call.

## Verdicts, estimates and missing data

Tempo judges runs: a session verdict, a grade colour, a block on or off track. Every judgement
follows the same rules as the numbers.

- **A verdict can be reproduced from its inputs in one sentence, and the athlete can override
  it.** The verdict comes from `Engine/`, with tests. The coach explains it and never picks it.
  An athlete's tag ("not the plan, pickup game") re-grades the run as what it actually was. If
  they dispute it with the coach, the result is that tag, not an edited engine output. This is
  "the athlete's word outranks the math", applied to grades.
- **A number based on an estimate says so wherever it appears, and points to the real value.**
  A formula max HR gets the "EST" label on every screen it colours, plus the call to action that
  replaces it with a tested value. A grade built on an estimate is an estimate too.
- **Missing data is grey, never a guess.** No heart rate, no samples, no plan: the run shows as
  ungraded, and that is stored as a result (the `efforts_scanned_at` lesson). This is different
  from unclear *intent*: the product can choose a default for that, such as "inconclusive means
  easy". Missing data never gets a default.

## Issue conventions

Type: `bug` · `feat` · `chore` · `spike`

Routing labels — every issue carries exactly one:
- `agent-ready` — spec is complete enough to implement unattended. Builders only pick these.
- `needs-david` — blocked on a product or priority call. EM raises the question with options
  and a recommendation; David answers in a comment; next triage re-labels it.
- `needs-device` — implementable, but only David can confirm it actually works.

Priority: `p0` (broken for David or testers) · `p1` (next) · `p2` (someday).

An `agent-ready` issue must state: the observed problem, where in the code it lives, what
"done" looks like, and how it gets verified. If you cannot write those four, it is
`needs-david`, not `agent-ready`.

**An idea David shares in chat is not a build order.** It becomes a `spike` issue labelled
`needs-david`, listing the open questions, each with a recommendation. Nothing gets built until
he has answered them. His answers become a "spec (interviewed David <date>)" section in
`progress.md`, and only then are the `agent-ready` build issues written from it, one per PR.

## Style

Match the surrounding code. This codebase leans on doc comments that explain *why* — the
Garmin re-export story, the "athlete's word outranks the math" rule. Keep that. Comments that
restate the code are noise; comments carrying a decision or a scar are the point.

Swift: pure logic in `Engine/`, I/O in `Services/`, view code stays declarative. Prefer
extracting a pure function over mocking a dependency.
