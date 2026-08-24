# Tempo — agent operating manual

Read this before doing anything. `progress.md` is the narrative history; **GitHub Issues is
the work queue**; this file is the rulebook.

## What this is

An iOS marathon-coaching app (SwiftUI + HealthKit + Supabase + Claude), open source, free,
in **beta-of-one**: David is the only user. That single fact drives most rules below.

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

**3. The database is live and it is his real training history.** 2,000+ real runs, an active
plan he is training on. There is no staging copy.

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
  put it in the PR, and stop. David applies it. `coach` is v11 and live in his hands; a bad
  deploy breaks the coach he is actively training with.
- **Never write to the production database.** Reads for triage are fine.
- **Never commit to `main`, never force-push, never rewrite published history.**
- **Never touch `.env`** (holds the Anthropic key) or move secrets into tracked files.
- **Never claim device-verified behavior.** See limit 1.
- **Never bundle unrelated work.** One issue, one PR, one reviewable diff.

## Issue conventions

Type: `bug` · `feat` · `chore` · `spike`

Routing labels — every issue carries exactly one:
- `agent-ready` — spec is complete enough to implement unattended. Builders only pick these.
- `needs-david` — blocked on a product or priority call. EM raises the question with options
  and a recommendation; David answers in a comment; next triage re-labels it.
- `needs-device` — implementable, but only David can confirm it actually works.

Priority: `p0` (broken for the only user) · `p1` (next) · `p2` (someday).

An `agent-ready` issue must state: the observed problem, where in the code it lives, what
"done" looks like, and how it gets verified. If you cannot write those four, it is
`needs-david`, not `agent-ready`.

## Style

Match the surrounding code. This codebase leans on doc comments that explain *why* — the
Garmin re-export story, the "athlete's word outranks the math" rule. Keep that. Comments that
restate the code are noise; comments carrying a decision or a scar are the point.

Swift: pure logic in `Engine/`, I/O in `Services/`, view code stays declarative. Prefer
extracting a pure function over mocking a dependency.
