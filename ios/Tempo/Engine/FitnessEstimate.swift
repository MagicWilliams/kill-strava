import Foundation

/// The runner's current fitness as one smoothed number — the Drift Detector's input
/// (PRD-02 item #2, issue #244). Pure, no I/O. The design and every constant below are
/// argued in `docs/spike-fitness-formula.md`; this file is that spec, implemented.
///
/// Why this exists alongside `ProjectionHistory`: today one run sets the projection, easy
/// runs count when nothing faster exists, and a long run with a fast finish never counts.
/// Those selection choices move the number by 5–10%; the formula choice (Riegel vs VDOT)
/// moves it by about 1%. So most of this file is *selection*:
///
///     baseline (60-day median pace, artefacts out, no all-history fallback)
///       → candidates in a 56-day window: whole runs + their 5K/10K/half/marathon segments
///       → keep `quality` (≥ 6% faster than baseline; RPE and measured HR only ever demote)
///       → one contribution per run, its highest VDOT
///       → hold out an unconfirmed best (> 5% clear of the next)
///       → best 3, kept current, recency-weighted (21-day half-life)
///
/// Not wired in anywhere yet. `ProjectionHistory`, `LoadModel`, `TrainingPaces` and the
/// `/plan` copy in `features.ts` are untouched on purpose: moving the app and `/plan` onto
/// this, and their window from 42 to 56 days, is the wiring issue's job.
enum FitnessEstimate {

    // MARK: - Constants (spike: "Constants")

    /// Shared by the app and `/plan` once both are wired in. Recency comes from the decay,
    /// not the window; the window only bounds what is visible.
    static let windowDays = 56
    static let halfLifeDays = 21.0
    /// An effort this recent keeps the estimate current (step 7) and the reading un-stale.
    static let freshDays = 21
    static let topN = 3
    /// Two, not three: refusing to say anything for weeks is worse for this user than a
    /// sparse reading, whose weakness is documented in the sparse fixture.
    static let minCountedEfforts = 2
    /// A best more than 5% above the second best waits for a second effort to confirm it.
    /// A real breakthrough shows up again; a short GPS distance or a car ride doesn't.
    static let confirmRatio = 1.05

    /// `ProjectionHistory.minQualifyingMiles` (2.5) in whole metres. An integer on purpose:
    /// `distance_m` is stored whole, so a run of exactly 2.5 mi arrives as 4,023 m, and
    /// comparing against 4,023.35 would quietly reject the very distance this floor names.
    static let minWholeRunMeters = 4_023
    /// Four hours of moving time: where Daniels' `%max(t)` curve stops being fitted data.
    static let maxEffortS = 14_400
    /// 400 m, 800 m and the mile are strides and hills, too short to read as sustained.
    static let segmentKeys: Set<Int> = [5_000, 10_000, 21_098, 42_195]
    /// Same ceiling as the projection (#227): slower is a walk or a watch left recording.
    static let slowestPaceSecPerMile = ProjectionHistory.maxQualifyingPaceSecPerMile
    /// Faster than any human over 5K or more: a car, a bike, or a GPS jump.
    static let fastestPaceSecPerMile = 240

    static let baselineDays = 60
    static let baselineMinRuns = 5
    static let baselineMinMeters = 1_609

    /// Calibrated against the archive before freezing (issue #244): these cut-offs split it
    /// sensibly, so they stay as the spike proposed them.
    static let qualityRatio = 0.94
    static let recoveryRatio = 1.06
    /// Daniels puts easy running at 65–79% of max; 75% is set low so only clearly easy
    /// runs are caught.
    static let hrEasyFraction = 0.75
    /// `LoadModel.referenceRPE` is 4: the effort Tempo already assigns to a run at median
    /// pace. Anything the athlete rated at or below it was not a fitness test.
    static let rpeEasyMax = 4
    static let rpeRecoveryMax = 2

    private static let metersPerMile = 1609.34
    private static let secondsPerDay = 86_400.0

    // MARK: - Output types

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

        /// Projected finish over `meters`, whole seconds. This is the race-equivalent time
        /// `Drift.measure` and `TrajectoryCurve` consume.
        func finishSeconds(meters: Double) -> Int {
            Int(FitnessEstimate.finishSeconds(vdot: vdot, meters: meters).rounded())
        }
    }

    /// Why there is no number. Each is a different empty state; Drift shows no status for
    /// any of them, never a false alarm.
    enum Insufficient: Equatable {
        /// Fewer than `baselineMinRuns` plausible runs of ≥ 1 mi in `baselineDays`: there is
        /// no telling what "easy" is for this runner right now.
        case noBaseline(runs: Int)
        /// Fewer than `minCountedEfforts` qualifying efforts once any hold-out is set aside.
        case tooFewEfforts(found: Int)
        /// No qualifying effort within `freshDays`; the newest evidence is weeks old.
        case stale(lastEffort: Date)
    }

    enum Result: Equatable {
        case reading(Reading)
        case insufficient(Insufficient)
    }

    // MARK: - The formula

    /// Daniels' VDOT for one effort: the oxygen cost of the pace divided by the fraction of
    /// VO2max sustainable for that long. With `v` in m/min and `t` in minutes:
    ///
    ///     VO2(v)  = −4.60 + 0.182258·v + 0.000104·v²
    ///     %max(t) = 0.8 + 0.1894393·e^(−0.012778·t) + 0.2989558·e^(−0.1932605·t)
    ///
    /// Source: J. Daniels & J. Gilbert, *Oxygen Power: Performance Tables for Distance
    /// Runners* (1979) — the equations behind the VDOT tables in *Daniels' Running Formula*.
    /// The book prints only the tables; the equations are reproduced by L. Simpson, "The
    /// Daniels/Gilbert Formula" (simpsonassociatesinc.com/runningmath1.htm, pp. 2–3), the
    /// reference cited by Wikipedia's "Jack Daniels (coach)" VDOT section.
    ///
    /// Checked against the published table rather than trusted: at VDOT 50 these equations
    /// give 5K 19:56, 10K 41:20, half 1:31:31, marathon 3:10:40, against the printed row's
    /// 19:57 / 41:21 / 1:31:35 / 3:10:49 — every cell within 0.1%. The VDOT 30 row agrees to
    /// 0.2%. Both rows are pinned in `FitnessEstimateTests` at 0.25%.
    static func vdot(meters: Double, seconds: Double) -> Double {
        guard meters > 0, seconds > 0 else { return 0 }
        let t = seconds / 60
        let v = meters / t
        let vo2 = -4.60 + 0.182258 * v + 0.000104 * v * v
        let percentMax = 0.8 + 0.1894393 * exp(-0.012778 * t) + 0.2989558 * exp(-0.1932605 * t)
        return vo2 / percentMax
    }

    /// The `t` at which `vdot(meters, t)` equals `vdot`, by bisection over 2 min–10 h.
    ///
    /// VDOT falls monotonically as `t` grows at any fixed distance (both the oxygen cost and
    /// the sustainable fraction fall), so bisection is exact to the iteration count. Outside
    /// the bracket the answer is clamped to its edge rather than extrapolated: the curve is
    /// not fitted data there, and an engine that never invents numbers shouldn't start here.
    static func finishSeconds(vdot target: Double, meters: Double) -> Double {
        var lo = 120.0, hi = 36_000.0
        guard meters > 0 else { return lo }
        if vdot(meters: meters, seconds: lo) <= target { return lo }
        if vdot(meters: meters, seconds: hi) >= target { return hi }
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if vdot(meters: meters, seconds: mid) > target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    // MARK: - Baseline and classifier

    /// Median moving pace (s/mi) of plausible runs in `(asOf − 60 d, asOf]`, or nil with
    /// fewer than `baselineMinRuns` of them.
    ///
    /// `LoadModel`'s 60-day median with two deliberate differences. Artefacts are out (the
    /// pace window), so a 77:00/mi watch-left-recording can't drag the median. And there is
    /// **no fallback to all history**: after a layoff the old baseline describes someone
    /// else, and classifying today's runs against it would call every jog a workout.
    static func baselinePace(
        _ runs: [RunSummary],
        asOf: Date,
        calendar: Calendar = ProjectionHistory.calendar
    ) -> Double? {
        let paces = baselineRuns(runs, asOf: asOf, calendar: calendar).map(exactPace)
        guard paces.count >= baselineMinRuns else { return nil }
        let sorted = paces.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Pace against the baseline first, then the demotions. Demotions only ever push toward
    /// easy: a hot, hilly or tired run can feel hard and still be slow, and promoting it
    /// would add a low VDOT that pulls a sparse estimate down for reasons that aren't
    /// fitness. Demotion only removes evidence.
    ///
    /// - `rpe`: the athlete's word outranks the math. 1–2 is recovery, 3–4 easy, however
    ///   fast it looks. Applies to segments too — RPE rates the whole session.
    /// - `avgHR` / `measuredMaxHR`: only a *measured* max (`profiles.max_hr`), never
    ///   220 − age or 192, whose ~10 bpm error is bigger than the signal. Callers pass nil HR
    ///   for segments: the run's average includes the easy miles around the segment.
    static func classify(
        paceSecPerMile: Double, baseline: Double,
        avgHR: Int?, measuredMaxHR: Int?, rpe: Int?
    ) -> RunClass {
        guard baseline > 0 else { return .easy }
        // Compared as a ratio, not against `0.94 × baseline`: division is correctly rounded,
        // so a pace of exactly 94% lands on the literal 0.94 and the boundary is inclusive
        // without an epsilon.
        let ratio = paceSecPerMile / baseline
        var cls: RunClass = ratio <= qualityRatio ? .quality : (ratio >= recoveryRatio ? .recovery : .easy)

        if let rpe, rpe >= 1 {
            if rpe <= rpeRecoveryMax { cls = demote(cls, to: .recovery) }
            else if rpe <= rpeEasyMax { cls = demote(cls, to: .easy) }
        }
        if let avgHR, let measuredMaxHR, measuredMaxHR > 0,
           Double(avgHR) < hrEasyFraction * Double(measuredMaxHR) {
            cls = demote(cls, to: .easy)
        }
        return cls
    }

    // MARK: - The estimate

    /// The estimate as of `asOf`. Only runs with `start <= asOf` are read (replay-honest).
    ///
    /// - Parameters:
    ///   - efforts: `run_efforts` by run id. A missing key means the run was never scanned
    ///     (or is manual), which is "no segments", not an error.
    ///   - measuredMaxHR: `RunStore.maxHR`, the profile value — **not** `effectiveMaxHR`.
    ///     Nil turns the HR rule off.
    static func estimate(
        runs: [RunSummary],
        efforts: [UUID: [BestEfforts.Effort]],
        asOf: Date,
        measuredMaxHR: Int?,
        calendar: Calendar = ProjectionHistory.calendar
    ) -> Result {
        // 1. Baseline.
        guard let baseline = baselinePace(runs, asOf: asOf, calendar: calendar) else {
            return .insufficient(.noBaseline(runs: baselineRuns(runs, asOf: asOf, calendar: calendar).count))
        }
        guard let windowStart = calendar.date(byAdding: .day, value: -windowDays, to: asOf),
              let freshStart = calendar.date(byAdding: .day, value: -freshDays, to: asOf)
        else { return .insufficient(.tooFewEfforts(found: 0)) }

        // 2–4. Candidates → quality → one per run.
        var pool: [Contribution] = []
        for run in runs where run.start > windowStart && run.start <= asOf {
            if let best = bestQualityCandidate(run, efforts: efforts[run.id] ?? [], baseline: baseline,
                                               measuredMaxHR: measuredMaxHR, asOf: asOf) {
                pool.append(best)
            }
        }
        // Highest first; equal VDOTs break to the newer run so the order is total.
        pool.sort { $0.vdot == $1.vdot ? $0.date > $1.date : $0.vdot > $1.vdot }

        // 5. Hold out an unconfirmed best.
        var heldOut: Contribution?
        if pool.count >= 2, pool[0].vdot > confirmRatio * pool[1].vdot {
            let best = pool.removeFirst()
            heldOut = Contribution(runID: best.runID, date: best.date, source: best.source,
                                   vdot: best.vdot, weight: 0)
        }

        // 6. Enough, and recent enough.
        guard pool.count >= minCountedEfforts else {
            return .insufficient(.tooFewEfforts(found: pool.count))
        }
        guard let newest = pool.max(by: { $0.date < $1.date }) else {
            return .insufficient(.tooFewEfforts(found: 0))
        }
        guard newest.date > freshStart else {
            return .insufficient(.stale(lastEffort: newest.date))
        }

        // 7. Best `topN`, kept current. Without the swap a real decline reads as no change:
        // the old peaks keep winning until they age out of the window.
        var counted = Array(pool.prefix(topN))
        if !counted.contains(where: { $0.date > freshStart }) {
            counted[counted.count - 1] = newest
        }

        // 8. Recency-weighted mean.
        let totalWeight = counted.reduce(0) { $0 + $1.weight }
        let vdot = counted.reduce(0) { $0 + $1.weight * $1.vdot } / totalWeight
        counted.sort { $0.date > $1.date }

        return .reading(Reading(vdot: vdot, counted: counted, heldOut: heldOut,
                                baselinePaceSecPerMile: baseline))
    }

    // MARK: - Internals

    private static func baselineRuns(_ runs: [RunSummary], asOf: Date, calendar: Calendar) -> [RunSummary] {
        guard let start = calendar.date(byAdding: .day, value: -baselineDays, to: asOf) else { return [] }
        return runs.filter { run in
            run.start > start && run.start <= asOf && run.distanceM >= baselineMinMeters
                && paceInWindow(run.paceSecPerMile)
        }
    }

    /// The 4:00–20:00/mi window, read on whole-second pace exactly as `ProjectionHistory`
    /// reads its ceiling (`RunSummary.paceSecPerMile`, truncated), so a run the projection
    /// accepts at 20:00 is accepted here too.
    private static func paceInWindow(_ pace: Int?) -> Bool {
        guard let pace else { return false }
        return pace >= fastestPaceSecPerMile && pace <= slowestPaceSecPerMile
    }

    private static func exactPace(_ run: RunSummary) -> Double {
        Double(run.durationS) / (Double(run.distanceM) / metersPerMile)
    }

    /// The run's one contribution: its highest-VDOT candidate that classifies as `quality`.
    /// One per run, or a 10K segment inside a half-length run would count three times.
    private static func bestQualityCandidate(
        _ run: RunSummary, efforts: [BestEfforts.Effort], baseline: Double,
        measuredMaxHR: Int?, asOf: Date
    ) -> Contribution? {
        let rpe = run.journal.rpe
        var best: (source: Source, vdot: Double)?
        func consider(_ source: Source, _ v: Double) {
            if let current = best, current.vdot >= v { return }
            best = (source, v)
        }

        if run.distanceM >= minWholeRunMeters, run.durationS <= maxEffortS,
           paceInWindow(run.paceSecPerMile),
           classify(paceSecPerMile: exactPace(run), baseline: baseline,
                    avgHR: run.avgHR, measuredMaxHR: measuredMaxHR, rpe: rpe) == .quality {
            consider(.wholeRun, vdot(meters: Double(run.distanceM), seconds: Double(run.durationS)))
        }

        // Segments only from a run that is not itself an artefact: a watch left recording
        // at 77:00/mi can hold "5K" miles at 5:02/mi — a car, not a race (#229).
        if let parentPace = run.paceSecPerMile, parentPace <= slowestPaceSecPerMile {
            for effort in efforts where segmentKeys.contains(effort.distanceM) && effort.durationS <= maxEffortS {
                // True distance, not the rounded key: the half is 21,097.5 m, stored as 21,098.
                guard let d = BestEfforts.distance(forKey: effort.distanceM), effort.durationS > 0 else { continue }
                let seconds = Double(effort.durationS)
                let pace = seconds / (d.meters / metersPerMile)
                guard paceInWindow(Int(pace)),
                      classify(paceSecPerMile: pace, baseline: baseline,
                               avgHR: nil, measuredMaxHR: measuredMaxHR, rpe: rpe) == .quality
                else { continue }
                consider(.segment(distanceKey: effort.distanceM), vdot(meters: d.meters, seconds: seconds))
            }
        }

        guard let best else { return nil }
        let ageDays = asOf.timeIntervalSince(run.start) / secondsPerDay
        return Contribution(runID: run.id, date: run.start, source: best.source, vdot: best.vdot,
                            weight: pow(0.5, ageDays / halfLifeDays))
    }

    /// Never lowers a class, only caps it.
    private static func demote(_ cls: RunClass, to cap: RunClass) -> RunClass {
        func rank(_ c: RunClass) -> Int { c == .recovery ? 0 : (c == .easy ? 1 : 2) }
        return rank(cls) <= rank(cap) ? cls : cap
    }
}
