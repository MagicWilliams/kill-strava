---
title: "Spike: the Drift Detector's fitness formula"
project: Tempo
type: spike
status: proposed
created: 2026-10-29
issue: 234
tags: [tempo, spike, drift-detector]
---

# Spike: the Drift Detector's fitness formula

Issue #234 · [PRD-02: Drift Detector](prd-02-drift-detector.md), Milestone 1, item #1 · [Decision log](decision-log.md)

> **Status: a recommendation, not a decision.** Nothing here is built. David accepts or
> changes it; the last section is the spec for the estimator issue that follows (PRD #2).
>
> **What this is grounded in:** the code as of `main` 1a2f33f (`Engine/ProjectionHistory.swift`,
> `Engine/LoadModel.swift`, `Engine/TrainingPaces.swift`, `Engine/BestEfforts.swift`,
> `supabase/functions/plan/features.ts`) and the archive facts already recorded in issues
> #227, #228 and #229. **No production query was run for this spike** (no database tool in the
> session). The read-only queries that would calibrate the constants are in
> [Calibration queries](#calibration-queries-read-only).

## The short answer

1. **Formula: Daniels' VDOT**, one number per qualifying effort, read out to the goal distance
   by inverting the same formula. On race-relevant inputs it agrees with today's Riegel to
   within 1.5%, so it isn't a big change. It's chosen because it accounts for how long an
   effort took as well as how far it went, and because its outputs can be checked against
   Daniels' published tables.
2. **The formula is the small decision. Selection is the big one.** Today one run sets the
   number. Easy runs count when nothing faster exists, and a long run with a fast finish never
   counts. Those choices move the number by 5–10%. The formula choice moves it by about 1%.
3. **Qualifying effort:** a whole run of at least 2.5 mi, or a 5K/10K/half/marathon segment
   from `run_efforts`. It must be at least 6% faster than the runner's 60-day median pace, and
   between 4:00 and 20:00/mi. Low HR (only against a measured max HR) or a logged RPE of 4 or
   less demotes it to easy. Neither can promote a run.
4. **Smoothing:** a recency-weighted mean (21-day half-life) of the best 3 efforts in a
   **56-day window**. A single best more than 5% above the next one is held out until a second
   effort confirms it.
5. **Insufficient data:** no baseline (fewer than 5 runs in 60 days), fewer than 2 counted
   efforts, or no qualifying effort in the last 21 days. Each is a named state, never a number.
6. **One window for the app and `/plan`: 56 days.**

## What exists today

| | App (`ProjectionHistory`) | Server (`/plan`, `features.ts`) |
|---|---|---|
| Window | 42 days | 56 days |
| Effort | fastest **whole-run average** pace, ≥ 2.5 mi, ≤ 20:00/mi | same rule |
| Formula | Riegel, `t₂ = t₁·(d₂/d₁)^1.06` (`PaceModel.equivalentTime`) | same, TS copy in `generator.ts` |
| Smoothing | none: one run | none: one run |
| Easy runs | not excluded | not excluded |
| No qualifying run | no projection, honest empty state | `null` since #205 |

The two windows already disagree. The app and `/plan` can name different runs as the athlete's
fitness on the same day.

`LoadModel` already has the baseline the classifier needs: the median moving pace of the last
60 days. It's the reference that "intensity" is measured against. It counts every run
(including the 77:00/mi recording from #227) and falls back to all history when the last 60
days are empty. The estimator needs a stricter version of that, described below.

`run_efforts` (migration 0011, `Engine/BestEfforts.swift`) holds the fastest segment of each
standard distance inside each run. The app scans it on device from HealthKit samples, newest
first. Segment durations use the sample clock, so a segment that spans a pause reads slow.
Manual runs have no segments.

### How David's archive looks to these rules

- **Many easy runs, few hard ones, sparse races.** The median pace is close to easy pace.
  When a 42-day window holds no workout, the "fastest run" is an easy run read as a race
  effort. The #228 write-up names the 29 Oct 5 mi at 9:40/mi as the run that would set the
  projection: about 4:3x for the marathon. That isn't a measure of fitness. It's what the
  rule produces when it has nothing better to read.
- **Hard work hides inside long runs.** A 16-miler with the last 10K at marathon pace has an
  easy whole-run average. Whole-run averaging can't see that 10K. `run_efforts` can.
- **HR is unreliable.** Garmin HR often doesn't reach Health with the workout. The HR repair
  pass backfills only the last 90 days. `/plan` gets `avg_hr` only, with no streams. No
  resting HR is stored anywhere. Max HR is the athlete's own value (`profiles.max_hr`) only if
  he reported one; otherwise it's 220 − age, or 192.
- **RPE is new.** The journal (#120) started in October 2026, so nearly the whole archive has
  no RPE.
- **Recording artefacts exist.** About 30 live rows are slower than 15:00/mi (#229), some of
  them watches left recording. #229's 15 Oct run includes miles at 5:02/mi, possibly in a car.
- **No treadmill or indoor flag reaches `runs`.** `WorkoutRow.Workout.indoor` is read from
  HealthKit and then dropped: "`runs` has no column for it yet".

Conclusion: on the real archive, any rule is **pace-only in practice**. HR and RPE can improve
recent runs but can't carry the estimate.

## The candidates

### A. Riegel on the best effort (today)

`t₂ = t₁ · (d₂/d₁)^1.06`, one fixed exponent fitted to trained runners (Riegel, 1981).

- **Needs:** distance and moving time. Every row has both.
- **Fails when:**
  - Only distance changes the conversion, not duration. A 30-minute 5K and a 20-minute 5K get
    the same ratio, but the slower runner fades more over a marathon. At the slow end it's off
    by 1.4% (30:00 5K → 4:47:44 vs VDOT's 4:43:39) and 6.5% for a 20:00/mi effort.
  - Its known weakness for recreational runners is optimism over the marathon. VDOT shares it
    (see failure cases).
- **On David's archive:** the formula isn't the problem. Selection is: one run, whole-run
  average, easy runs allowed.

### B. Daniels VDOT

Two fitted curves from *Daniels' Running Formula*. With `v` in m/min and `t` in minutes:

```
VO2(v)  = −4.60 + 0.182258·v + 0.000104·v²
%max(t) = 0.8 + 0.1894393·e^(−0.012778·t) + 0.2989558·e^(−0.1932605·t)
VDOT    = VO2(v) / %max(t)
```

A projected time at distance `d` is the `t` where `VDOT(d, t)` equals the estimate. VDOT falls
steadily as `t` grows, so a bisection finds it.

- **Needs:** distance and time, the same as Riegel.
- **Fails when:** the effort wasn't race-hard. A tempo run read as a race underestimates
  fitness, just as with Riegel. Outside about 4 minutes to 4 hours, the curve is extrapolating.
- **On David's archive:** it behaves like Riegel, with the same selection problems. It gives
  one number that doesn't depend on the target distance, so smoothing happens once and the
  goal distance is only a readout.

How close the two are (marathon readout, computed for this spike):

| Effort | VDOT | Marathon, VDOT | Marathon, Riegel | Riegel vs VDOT |
|---|---|---|---|---|
| 5K 20:00 | 49.8 | 3:11:17 | 3:11:49 | +0.3% |
| 5K 25:00 | 38.3 | 3:57:55 | 3:59:47 | +0.8% |
| 5K 30:00 | 30.8 | 4:43:39 | 4:47:44 | +1.4% |
| 10K 45:00 | 45.3 | 3:27:15 | 3:27:01 | −0.1% |
| Half 1:40:00 | 45.1 | 3:27:47 | 3:28:30 | +0.3% |
| 13.1 mi @ 9:00 | 37.2 | 4:03:45 | 4:06:00 | +0.9% |
| 2.5 mi @ 20:00 | 11.9 | 9:26:41 | 10:03:47 | +6.5% |

On the marathon, 1% of VDOT ≈ 0.8% of finish time, across VDOT 35–55. So the PRD's 2% and 5%
tiers are roughly 2.5 and 6 VDOT-percent.

### C. HR-adjusted pace

Estimate %VO2max from heart rate (Swain: `%HRmax ≈ 0.64·%VO2max + 37`, or %HRR ≈ %VO2R with a
resting HR). Then `VO2max ≈ VO2(v) / %VO2max`, the way Garmin's and Firstbeat's estimates
work. Its strength is that it reads every run, including easy ones. So it has far more data
and doesn't need maximal efforts.

- **Needs:** reliable per-run HR, an accurate max HR, and ideally resting HR. Tempo has
  unreliable HR, max HR that is usually estimated, and no resting HR.
- **Fails when:**
  - **Max HR is off.** 220 − age is commonly off by around 10 bpm. At 160 bpm, a max of 180
    instead of a true 190 moves the estimate by 9% VDOT, about 7.5% of marathon time. That's
    more than the whole "off track" tier.
  - Cardiac drift on long runs, heat (HR up, so it reads as unfit), caffeine, optical-HR
    dropouts, and averages that include stops.
- **On David's archive:** HR is missing on many rows and absent beyond the 90-day repair
  window. Replaying history would mostly have no input.

### Recommendation: B, VDOT

- **Why not A:** for race-relevant inputs, A and B agree within 1.5%. B is better on two
  counts. First, it accounts for duration, which matters for slower runners and for run-walk
  athletes beyond David. Second, Daniels' published tables give an independent check the tests
  can pin. A third reason: the trajectory curve (PRD #3) needs one unit that doesn't depend on
  distance to interpolate in, and VDOT is one.
- **Why not C:** its accuracy depends on the input Tempo has least of. Its main error, a wrong
  max HR, is bigger than the signal it's meant to detect.
- **HR's role:** it only demotes runs in the classifier. A separate efficiency signal (pace at
  fixed HR over time) is a candidate follow-up once HR coverage has been measured.

**Leave `TrainingPaces` on Riegel.** Training paces aren't the fitness estimate. Changing them
would shift the plan David is training on, and that needs its own issue.

## Qualifying efforts

A **candidate** is a whole run or one of its `run_efforts` segments. A candidate **qualifies**
when it passes every one of these checks:

| Rule | Value | Why |
|---|---|---|
| In the window | `asOf − 56 d < start ≤ asOf` | see [The window](#the-window). `start ≤ asOf` keeps replay honest, as in `settingRun`. |
| Whole run: distance | ≥ 4,023 m (2.5 mi) | unchanged from `ProjectionHistory.minQualifyingMiles` |
| Whole run: duration | ≤ 4 h moving | where VDOT's `%max(t)` stops being fitted data |
| Segment: distance key | 5,000 / 10,000 / 21,098 / 42,195 only | 400 m, 800 m and the mile are strides and hills, too short to count as sustained |
| Pace ceiling | ≤ 1,200 s/mi (20:00) | unchanged from #228, a walk or a watch left recording |
| Pace floor | ≥ 240 s/mi (4:00) | faster than any human over 5K or more, so a car, bike or GPS jump |
| Parent run | the run's own average pace passes the ceiling | a run that is itself an artefact (#229) contributes no segments either. That's the 5:02/mi miles inside a 77:00/mi run. |
| Classification | `quality` (below) | the PRD: easy and recovery runs aren't a fitness signal |

**One contribution per run:** each run counts once, at the highest VDOT among its qualifying
candidates. A 10K segment inside a half-length run would otherwise count three times (whole
run, 5K and 10K).

**Segment pace** is the segment's `duration_s` divided by its true distance
(`BestEfforts.Distance.meters`, not the rounded key).

## The easy/recovery classifier

Measured against the runner's own **baseline**:

> **baseline** = median moving pace (s/mi) of runs in `(asOf − 60 d, asOf]` that are at least
> 1 mi long and pass the 4:00–20:00/mi window. It needs **at least 5** such runs; otherwise
> there is no baseline.

This is `LoadModel`'s 60-day median with two changes. It excludes artefacts (a recording at
77:00/mi shouldn't move the median). It has no fallback to all history, because after a layoff
the old baseline describes someone else. **`LoadModel` itself isn't changed.** Its numbers are
pinned bit-for-bit by `LoadModelRPETests`.

Then, for a candidate with average pace `p`:

| Class | Rule (pace) |
|---|---|
| `quality` | `p ≤ 0.94 × baseline`: at least 6% faster than the median |
| `recovery` | `p ≥ 1.06 × baseline`: at least 6% slower |
| `easy` | anything between |

Demotions, which only ever push a run toward easy:

- **RPE.** A logged `journal.rpe` of 1–4 makes the run `easy` (1–2: `recovery`), however fast
  it looks. The athlete's word outranks the math, and `LoadModel.referenceRPE = 4` is already
  the effort Tempo assigns to a run at median pace. This applies to segments too, because RPE
  rates the whole session.
- **HR.** Only for the whole-run candidate, and only with a measured `profiles.max_hr` (never
  220 − age or 192): `avg_hr < 0.75 × maxHR` makes it `easy`. Daniels puts easy running at
  65–79% of max. 75% is set low so that only clearly easy runs are caught: downhill, a short
  GPS distance, or a fast-looking run at conversational effort. Segments skip this rule,
  because the run's average HR includes the easy miles around the segment.

**Why HR and RPE never promote.** A hot, hilly or tired run can feel hard and still be slow.
Promoting it would add a low VDOT to the pool, and in sparse weeks that pulls the estimate
down for reasons that aren't fitness. Demotion only removes evidence.

**Why 6%.** In `LoadModel`'s own calibration notes, an easy run is about 8% slower than the
median and a threshold run about 15% faster. Marathon pace is typically 10–15% faster than easy
pace. 6% faster than the median sits below marathon effort and above conversational pace. It's
a starting value; [calibration query 2](#calibration-queries-read-only) shows where the archive
actually splits.

## Smoothing

From the qualifying efforts (one per run) in the window:

1. **Hold out an unconfirmed best.** Sort by VDOT. If the best is more than **5%** above the
   second best (about 4% of marathon time), set it aside as `heldOut`. A real breakthrough
   shows up again. A short GPS distance or a stretch in a car doesn't. In the spike's
   simulation, a 48.0 effort in a steady block at 45 is held out. A second effort at 47.6 three
   days earlier confirms it, and the estimate moves to 47.4.
2. **Take the best 3** by VDOT.
3. **Keep it current.** If none of those 3 is within the last 21 days, replace the lowest with
   the newest qualifying effort. Without this, a real decline would read as no change: the old
   peaks would keep winning. In the simulation, three old 46s and two recent 44s give 44.9,
   not 46.
4. **Weighted mean.** `estimate = Σ wᵢ·VDOTᵢ / Σ wᵢ`, with `wᵢ = 0.5^(ageᵢ / 21 d)`.

What this does:

- **Slow outliers.** A hot or hilly run is slower, so it doesn't make the top 3 when at least
  3 better efforts exist. **It changes nothing.**
- **Fast outliers** are held out (step 1).
- **A missed week changes nothing.** Exponential weights keep their ratios when every effort
  ages by the same amount, so the estimate stays the same unless an effort crosses day 56 or
  step 3 kicks in. The same property is why the estimate needs a staleness rule (below).
- **An effort leaving the window** is a small step, because its weight at day 56 is 0.16.
- **Sparse data is where it's weakest.** With only 3 qualifying efforts, the hot run is one of
  them. Because it's the newest, it carries the most weight. Simulated: 45, 45 and a hot 42.75
  give 44.07, −2.5%. That's documented, not hidden. The insufficient-data floor is 2 efforts,
  not 3, because refusing to say anything for weeks is worse for this user.

## Insufficient data

The estimator returns one of these instead of a number:

| State | When | What the runner sees (copy is PRD #6/#7's call) |
|---|---|---|
| `noBaseline(runs:)` | fewer than 5 runs of ≥ 1 mi in 60 days | not enough recent running to know what "easy" is for you |
| `tooFewEfforts(found:)` | fewer than 2 qualifying efforts after the hold-out | no workout or race recently to read fitness from |
| `stale(lastEffort:)` | no qualifying effort in the last 21 days | the newest evidence is weeks old |

Checked in that order. Drift (PRD #4) shows no status for any of them, never a false alarm.

## The window

**56 days, shared by the app and `/plan`.**

- **Recency comes from the decay, not the window.** The window only limits how much history
  is visible. At a 21-day half-life, an effort at day 42 already weighs 0.25, so lengthening
  the window to 56 mostly softens the step when an effort ages out.
- **David's quality efforts are sparse.** With a 2-effort floor and easy runs excluded, 42
  days would leave him in `tooFewEfforts` more often for no gain in accuracy.
- **`/plan` already reads 8 weeks:** `longest_run_8wk_mi` and
  `consistency_weeks_with_runs_of_last_8`.

Moving `ProjectionHistory.windowDays` from 42 to 56, and moving `/plan` onto the estimator,
belong to the issue that **wires the estimator in**, not to the estimator itself. Until then,
the existing projection and its tests stay as they are.

**`/plan` sharing the rule:** port the estimator to TypeScript as its own issue, using the
fixtures listed below as a shared table. Mirror the constants with a "Mirrors …" comment, as
`MAX_QUALIFYING_PACE_S` already does. `/plan` would also need to read `run_efforts`, which it
doesn't today.

## Known failure cases

| Case | What happens | Mitigation now | Later |
|---|---|---|---|
| **Training isn't racing** | Every effort below race effort reads slow, and with sparse races the estimate is biased low, roughly 5–7% for a threshold session read as a race. Drift against a curve that starts at the estimator's own reading mostly cancels this early in the block. **It doesn't cancel at race day**, where the curve ends at the absolute goal time. | best-of-3 picks the hardest efforts; races, when they happen, dominate | **PRD #3 must account for this**: flag it in that issue. A tune-up race fixes it directly. |
| **Heat** | pace slows, HR rises | slow, so outside the top 3 when the data are dense; HR can't promote | a "hot" journal tag that excludes a run; weather is out of scope |
| **Weeks of heat** | every effort slows, so the estimate falls | none. It's real on the road, not fitness. | same |
| **Hills** | slow, so outside the top 3. A net-downhill course is fast. | top 3 / hold-out | elevation isn't in `runs` |
| **Treadmill** | the distance comes from the accelerometer or console, often off by 5–10% either way | hold-out catches fast; top 3 catches slow | add an `indoor` column (`WorkoutRow` already reads it) and exclude indoor runs. Needs a migration. |
| **Watch left recording (#229)** | moving time = wall clock, average pace 77:00/mi | ceiling excludes the run **and its segments** | #229's fix at ingest (needs David) |
| **Car or bike inside a run** | 5:02/mi miles produce a 5K segment at about VDOT 66 | parent-run rule if the run is an artefact; otherwise hold-out | a per-segment "too fast to be running" guard, if #229 confirms the car |
| **GPS short or long** | ±2–5% pace error | hold-out over 5%; under that, one of three in the mean | none |
| **Sparse data** | fewer efforts, more weight on each, −2.5% simulated | `tooFewEfforts`, `stale` | tune the floor in beta |
| **Return from a layoff** | old peaks still in the window overstate the estimate. Simulated: 50, 50 at days 50–54 plus a fresh 46 gives 47.1 (+2%). | `stale` until the first fresh effort; step 3 keeps it in | an explicit detraining factor if the beta shows it |
| **Taper** | fewer and shorter quality sessions; `stale` can fire in the last 3 weeks | none | PRD #4 may want to hold the last reading through race week. That's a product call. |
| **Run-walk or very slow runners** | VDOT is fitted on continuous running | duration-aware formula; 20:00 ceiling | none |
| **Unpaged archive reads** | PostgREST truncates an unbounded select at 1,000 rows, so runs missing from memory become missing efforts | a 56-day window is far below the cap, as long as the caller reads newest-first | the wiring issue checks the caller pages or filters by date |

## Calibration queries (read-only)

Not run for this spike. Each one is a `select` against the live database; none writes. Run
them before the estimator's constants are frozen.

```sql
-- 1. How much HR is there, by age? (Decides whether the HR rule matters at all.)
select date_trunc('quarter', start_time) as quarter,
       count(*) as runs,
       count(avg_hr) as with_hr,
       round(100.0 * count(avg_hr) / nullif(count(*), 0), 1) as pct_with_hr
from runs
where superseded_by is null and start_time >= now() - interval '2 years'
group by 1 order by 1;

-- 2. Pace ÷ trailing-60-day median, by decile (where the 0.94 / 1.06 cut-offs fall).
with r as (
  select id, start_time, duration_s / (distance_m / 1609.34) as pace
  from runs
  where superseded_by is null and distance_m >= 1609 and duration_s > 0
    and duration_s / (distance_m / 1609.34) between 240 and 1200
    and start_time >= now() - interval '1 year'
)
select percentile_cont(array[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9])
         within group (order by r.pace / b.median) as deciles,
       count(*) filter (where r.pace <= 0.94 * b.median) as would_be_quality,
       count(*) as classified
from r
cross join lateral (
  select percentile_cont(0.5) within group (order by p.pace) as median, count(*) as n
  from r p
  where p.start_time <= r.start_time and p.start_time > r.start_time - interval '60 days'
) b
where b.n >= 5;

-- 3. Is there a measured max HR? (The HR rule is off without one.)
select max_hr from profiles;
```

## Spec for the estimator

This section is meant to be filed as is as an `agent-ready` issue: **"feat: a smoothed fitness
estimate from qualifying efforts (Drift Detector #2)"**.

**Where it goes:** `ios/Tempo/Engine/FitnessEstimate.swift`, pure, with tests in
`ios/TempoTests/FitnessEstimateTests.swift`. No I/O, no UI, no change to `ProjectionHistory`,
`LoadModel`, `TrainingPaces` or `features.ts`. Wiring it in is a separate issue.

### Signature

```swift
enum FitnessEstimate {

    enum RunClass: Equatable { case recovery, easy, quality }

    enum Source: Equatable { case wholeRun, segment(distanceKey: Int) }

    /// One run's part in a reading.
    struct Contribution: Equatable {
        let runID: UUID
        let date: Date
        let source: Source
        let vdot: Double
        let weight: Double          // 0.5^(age / halfLifeDays); 0 for `heldOut`
    }

    struct Reading: Equatable {
        let vdot: Double
        let counted: [Contribution]         // newest first, 2...topN entries
        let heldOut: Contribution?          // an unconfirmed best, not in `vdot`
        let baselinePaceSecPerMile: Double

        /// Projected finish over `meters`, whole seconds.
        func finishSeconds(meters: Double) -> Int
    }

    enum Insufficient: Equatable {
        case noBaseline(runs: Int)
        case tooFewEfforts(found: Int)
        case stale(lastEffort: Date)
    }

    enum Result: Equatable {
        case reading(Reading)
        case insufficient(Insufficient)
    }

    /// The estimate as of `asOf`. Only runs with `start <= asOf` are read (replay-honest).
    static func estimate(
        runs: [RunSummary],
        efforts: [UUID: [BestEfforts.Effort]],   // run_efforts by run id; missing = none scanned
        asOf: Date,
        measuredMaxHR: Int?,                     // profiles.max_hr only; nil turns the HR rule off
        calendar: Calendar = ProjectionHistory.calendar
    ) -> Result

    static func baselinePace(_ runs: [RunSummary], asOf: Date, calendar: Calendar = ProjectionHistory.calendar) -> Double?

    static func classify(
        paceSecPerMile: Double, baseline: Double,
        avgHR: Int?, measuredMaxHR: Int?, rpe: Int?
    ) -> RunClass

    static func vdot(meters: Double, seconds: Double) -> Double
    static func finishSeconds(vdot: Double, meters: Double) -> Double   // bisection, 2 min–10 h
}
```

### Inputs

`RunSummary` as it exists (moving `durationS`, `distanceM`, `avgHR`, `journal.rpe`, `start`,
`id`). `BestEfforts.Effort` as stored in `run_efforts`. `measuredMaxHR` is `RunStore.maxHR`, the
profile value, **not** `effectiveMaxHR`.

### Outputs

`Result`: a `Reading` (VDOT, the efforts behind it with their weights, any held-out effort, the
baseline it classified against) or an `Insufficient` reason. Finish time at any distance comes
from `Reading.finishSeconds(meters:)`.

### Constants

| Name | Value |
|---|---|
| `windowDays` | 56 |
| `halfLifeDays` | 21 |
| `freshDays` | 21 |
| `topN` | 3 |
| `minCountedEfforts` | 2 |
| `confirmRatio` | 1.05 |
| `minWholeRunMeters` | 4,023 (`ProjectionHistory.minQualifyingMiles` × 1609.34) |
| `maxEffortS` | 14,400 |
| `segmentKeys` | [5000, 10000, 21098, 42195] |
| `slowestPaceSecPerMile` | 1,200 (`ProjectionHistory.maxQualifyingPaceSecPerMile`) |
| `fastestPaceSecPerMile` | 240 |
| `baselineDays` | 60 |
| `baselineMinRuns` | 5 |
| `baselineMinMeters` | 1,609 |
| `qualityRatio` | 0.94 |
| `recoveryRatio` | 1.06 |
| `hrEasyFraction` | 0.75 |
| `rpeEasyMax` / `rpeRecoveryMax` | 4 / 2 |

### Order of operations

1. Baseline, or `.noBaseline`.
2. Candidates in the window: whole runs, plus segments from runs that pass the parent-run
   ceiling. Apply the distance, duration and pace window.
3. Classify each candidate (whole runs get the HR rule, everything gets RPE) and keep
   `quality`.
4. Keep one per run, the highest VDOT.
5. Hold out the best if it beats the second by more than `confirmRatio`.
6. Fewer than `minCountedEfforts` left: `.tooFewEfforts`. None within `freshDays`: `.stale`.
7. Take the top `topN`. If none is within `freshDays`, replace the lowest with the newest.
8. Weighted mean.

### Test fixtures

Each is a named test written against a dated scenario, the way `ProjectionHistoryTests` is.
"Unchanged" means within 0.01 VDOT. The PRD's movement tolerance is **0.5% VDOT** (about
0.4% of marathon time, under a minute at 3:30), well inside the 2% on-track tier.

1. **Formula pins.** `vdot(5000, 1200) ≈ 49.8`, `vdot(10000, 2700) ≈ 45.26`. At VDOT 50 the
   formula gives 5K 19:56, 10K 41:20, half 1:31:31, marathon 3:10:40. Check those against the
   printed VDOT 50 row in *Daniels' Running Formula* when implementing, and pin to within
   0.25%. (This spike quoted the table from memory: 19:57 / 41:21 / 1:31:35 / 3:10:49.)
2. **Round trip.** `finishSeconds(vdot(m, t), m)` returns `t` within 1 s, for 5K through the
   marathon.
3. **Agrees with Riegel.** The comparison table above, to within 1.5% for 5K 20:00–30:00 →
   marathon.
4. **Steady block.** 8 weeks, one quality run a week at about VDOT 45 (±0.3), plus 4 easy
   runs a week. The result is a reading near 45 with 3 counted efforts.
5. **Heat-wave run.** The steady block plus today's 10K at 47:15 (5% slower). Unchanged.
6. **Hilly run.** The steady block plus a slow hilly quality run yesterday. Unchanged.
7. **Recovery run.** A run 8% slower than the baseline is classified `recovery`, and the
   estimate is unchanged.
8. **Missed week.** `asOf` + 7 days with no new runs, with fixtures chosen so nothing crosses
   day 56. Unchanged. A second case where one effort does cross shows a step no bigger than
   that effort's weight share.
9. **Sparse.** One quality effort gives `.tooFewEfforts(found: 1)`. Two give a reading. Two
   plus a hot run give the documented −2.5% (pinned so a change is deliberate).
10. **Layoff.** The newest qualifying effort is 22 days old: `.stale`. One fresh effort
    brings back a reading that includes it.
11. **Decline.** Three 46s at days 30–40 and two 44s at days 3 and 10 give a reading below 46
    that includes the day-3 effort.
12. **No baseline.** 4 runs in 60 days gives `.noBaseline(runs: 4)`. An all-history fallback
    must not rescue it.
13. **Watch left recording (#227/#229).** 13,047 m in 37,459 s is not a candidate, and a 5K
    segment of 938 s attached to it is ignored too.
14. **Car segment in a normal run.** A 938 s 5K segment in an otherwise normal run is held
    out (`heldOut` set, `vdot` unchanged).
15. **Breakthrough.** A 48.0 in a steady block at 45 is held out. With a second effort at 47.6
    it counts, and the estimate is about 47.4.
16. **Hard finish in a long run.** A 16 mi easy-average run whose 10K segment is quality
    counts once, as `.segment(10000)`.
17. **One per run.** Whole run, 5K and 10K all qualify. The run contributes one entry, the
    highest VDOT.
18. **RPE outranks pace.** A pace-`quality` run with RPE 3 is `easy`. RPE 2 is `recovery`.
    RPE 8 on a pace-`easy` run stays `easy`.
19. **HR demotion.** Measured max 190, average 135 (71%) on a pace-`quality` whole run gives
    `easy`. The same run with `measuredMaxHR: nil` stays `quality`. A segment from it stays
    `quality`.
20. **Replay honesty.** Efforts after `asOf` don't change the reading.
21. **Edges.** 2.5 mi exactly qualifies (by distance); 1,200 s/mi exactly qualifies and 1,201
    doesn't; 240 qualifies and 239 doesn't; pace at exactly 0.94 × baseline is `quality`.

### Done / verify

CI green with the suite above. There's nothing to see on the device yet: this issue adds no
UI and changes no number on screen. Device verification belongs to the wiring issue, where
Progress → Projected finish starts reading from the estimator.
