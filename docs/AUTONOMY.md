# The autonomous loop

How Tempo iterates on itself, and where David sits in it.

## The shape

```
telemetry + logs + code  ──▶  SCOUT   ──▶  GitHub Issues
                                              │
                          ┌───────────────────┤
                          │                   │
                    agent-ready          needs-david
                          │                   │
                          ▼                   ▼
                       BUILDER ──▶ PR ──▶    EM ──▶ decision issue
                          │        │          │      (assigned to David)
                          │        ▼          │              │
                          └──── CI green ─────┘              ▼
                                   │                    his comment
                                   ▼                         │
                            David reviews ◀──────────────────┘
                                   │
                                   ▼
                                 merge
```

Three roles, deliberately separated — a single agent that finds, fixes, and judges its own
work grades its own homework.

- **Scout** (`.claude/agents/scout.md`) finds problems, files issues, writes no code.
- **Builder** (`.claude/agents/builder.md`) implements one issue, opens one PR, merges nothing.
- **EM** (`.claude/agents/em.md`) reads the board and asks David the few things only he can
  answer. Writes no code either.

Run them with `/triage`, `/build-next`, `/brief`.

## Why CI exists

Autonomy without verification is noise generation. CI is the only thing standing between
"an agent wrote plausible Swift" and "the app still works." It is also, for cloud agents,
literally the compiler — Linux sandboxes have no Xcode, so a cloud Builder pushes and reads
the Actions result rather than compiling anything itself.

The gate is deliberately narrow and honest about it: **it proves the app compiles and the
deterministic engine behaves. It cannot prove the app works.** Nobody but David can prove
that. Every PR therefore carries on-device verification steps for him.

## Why telemetry exists

Tempo has one user, so there is no aggregate signal — and yet every real bug so far (the
vanished plan, the Garmin double-count reading 31 miles instead of 15, HR zones capping at
15s) was found by David noticing a wrong number and reconstructing the cause from memory.

`app_events` (migration `0006_telemetry.sql`) closes that gap. The app reports the moments it
already knows are interesting; Scout ranks what recurs. This converts David's dogfooding from
an anecdote into an input.

It is not a crash reporter and holds no health data or PII — counts, durations, and stable
enum-ish keys only. See `ios/Tempo/Services/Telemetry.swift`.

## Where the split runs

| Work | Where | Why |
|------|-------|-----|
| Triage, briefs, issue grooming | cloud routine | no Mac needed, runs on a schedule |
| Edge functions, SQL, docs | cloud routine | Deno and SQL verify on Linux |
| Swift implementation | David's Mac (`/loop`) or cloud + CI | fast local feedback vs. hands-off |
| Applying migrations, deploying functions | **David only** | live DB, live coach, no staging |
| Merging | **David only** | current setting: review everything |

## Guardrails

The binding rules live in `CLAUDE.md` and every agent reads them. The load-bearing ones:

- Nothing merges without David.
- No migration is applied and no edge function deployed by an agent — the SQL ships in the PR
  and stops there. `coach` is live in his hands while he trains.
- No writes to the production database.
- No agent claims device-verified behavior.
- One issue, one PR. Unrelated findings become new issues, not bigger diffs.

## Failure modes to watch

**The board fills with plausible work nobody wants.** Scout is capped at 5 issues per run and
told that a noisy board is worse than an empty one. EM is explicitly licensed to say an issue
is not worth doing.

**Unverified change accumulates.** Merged PRs mean "compiled and passed tests," not "works."
If David goes a fortnight without running the app, the loop is producing unverified change —
EM checks for this each brief and says so.

**The queue starves.** If `agent-ready` is empty, the bottleneck is specification, not
execution. The fix is an interview with David, not more scouting.
