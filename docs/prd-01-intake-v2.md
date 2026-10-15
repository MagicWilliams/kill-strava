---
tags: [tempo, prd]
status: draft
created: 2026-10-15
---

# PRD-01: Intake v2, meeting people where they are

> Status: **draft**. These are David's notes from going through Runna's onboarding (2026-10-15), set against what Tempo's intake (#102) already asks. The issues get filed only after David has read this.

## Why

Runna's onboarding is good at one thing we should copy: it figures out **who the athlete is** before it builds anything. Most of its questions already overlap with our intake, so this is a gap list, not a rebuild.

There's also a reason that goes past copying. Training history is not a reliable read of fitness. David's own archive showed "0 mi for 5 of the last 6 weeks" right after he ran Chicago, because runs were missing, not because he'd stopped running. When the data is thin or wrong, the athlete's own answer is the better starting point. This follows the rule the codebase already lives by: *the athlete's word outranks the math.*

## What Tempo already asks (#102)

| Runna asks | Tempo today |
|---|---|
| What race are you running | ✅ **Distance first** (1 mi → marathon, plus custom), race name as optional free text, and a date |
| Race goal | ✅ A time / just finish / a PR / not sure, plus an optional target |
| Days you can run | ⚠️ A **count** (days per week) plus a long-run day, but not *which* days |
| Strength training | ⚠️ A yes/no only |
| What else you're interested in | ✅ Focus areas: fueling, pacing, race day, recovery, strength, mental |
| Workout types | ✅ Intervals, tempo, hills, race pace |

Race lookup: Runna's race search doesn't cover every race, and searching for one you can't find is a dead end. **Keep distance-first.** The race name stays optional text that can be filled in later. We won't build a race database.

## Gaps, and what we'd add

### R1. Why are you training?
The first question: what brings you here?
- Training for a race
- General health and fitness
- Getting back into running
- Starting to run (from zero)
- Just running, no goal

This feeds the plan's shape (a return-to-running build isn't a race block) and the coach's tone. "Just running" already exists as a situation (#101). This question generalizes it.

### R2. Experience level
Beginner / intermediate / advanced / elite, self-rated. It sets volume ceilings, how complex the workouts get, and how much the coach explains. Check it against history when there is some, but the athlete's answer comes first.

### R3. What could you race today?
Ask for a recent race result, or an honest estimate, at any distance. That seeds the pace basis (`paceBasis` in `plan/generator.ts`) when history is thin, missing or misleading. Today, with no qualifying run, the generator falls back to a default marathon basis.

### R4. Which days you're free
Weekday chips (Mon–Sun) instead of a count. The count comes from the chips, and the long-run day is picked from them.

### R5. Who this is built for
State it plainly during onboarding: the plans are built for recreational runners in a stated range, not for Olympic Trials qualifiers. Runna does this, and it's honest. It sets expectations and avoids a plan that pretends to cover what it can't.

### R6. Strength, a little deeper
Beyond yes/no, ask how many days, and whether you have equipment or only bodyweight. Keep it light. This is not a strength-programming product.

## Non-goals
- A race database or race search.
- **Any paywall.** See the [[decision-log]] entry for 2026-10-15: Tempo is free with full access.

## Open questions (David)
1. **R5 range:** what range do we say plans are built for? For example, a marathon from roughly 2:45 to 6:00, and the equivalent for other distances.
2. **R2 "elite":** offer it at all, if R5 tells elites the app isn't for them? Or offer it and answer it honestly?
3. **R3 vs history:** when the self-estimate and the archive disagree, does the estimate win outright, or does it win only while history is thin (for example, fewer than N qualifying runs in six weeks)?
4. **Order:** does R1 go before the existing "situation" step or replace it?

## Next
David reviews → split into issues (R1+R2, R3, R4, R5, R6), each one `agent-ready` once its open question is answered.
