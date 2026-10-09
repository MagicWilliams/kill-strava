import Foundation

/// The goal race, read back mat by mat — pure, no I/O.
///
/// A marathon is the one run where a generic run-detail page undersells what happened. The
/// questions after a race are specific: what did I go through halfway in, where did I start
/// giving time back, did the heart rate run away from me, was the block worth it. Every one
/// of those is arithmetic over two series the phone already holds — cumulative distance
/// against time, and heart rate against time — so the arithmetic lives here, where it can be
/// pinned, and `RaceRecapView` only draws it.
///
/// Inputs are plain arrays on purpose (`RunDetail` builds them from HealthKit). Nothing here
/// knows about HealthKit, Supabase or SwiftUI.
///
/// Sign convention, everywhere: a **delta is actual minus goal**, in seconds. Negative means
/// time banked (ahead of goal pace), positive means time given back. It is the convention a
/// race clock uses, and keeping one convention in the engine is what lets the table, the
/// chart and the share card agree without each re-deciding it.
///
/// Overlap note: PR #69 (sub-distance best efforts) also interpolates time-at-distance inside
/// a run. It had not merged when this was written, so `time(atMeters:)` here is the second
/// copy; whichever lands second should fold onto the other.
enum RaceRecap {

    static let marathonMeters = 42_195.0
    static let metersPerMile = 1609.34

    /// `goals.distance` → metres. The column is constrained to these four keys
    /// (`0001_init.sql`). An unreadable value falls back to the marathon: every goal this
    /// app has ever created is one, and `plan` only writes `"marathon"`.
    static func raceMeters(goalDistance: String?) -> Double {
        switch goalDistance {
        case "5k":   return 5_000
        case "10k":  return 10_000
        case "half": return 21_097.5
        default:     return marathonMeters
        }
    }

    // MARK: - Is this the race?

    /// A run counts as the race if it went at least this far. Low enough that a watch reading
    /// short (tunnels, a late start press) still qualifies; high enough that the shakeout on
    /// race morning never does.
    static let minRaceFraction = 0.90

    /// True when the run started on race day (the athlete's local calendar day) and covered at
    /// least 90% of the race distance.
    ///
    /// Day equality rather than a time window, because `goals.race_date` is a date with no
    /// time, parsed at local midnight (`PlanDates.day`).
    static func isRace(
        start: Date,
        distanceM: Int,
        raceDay: Date?,
        raceMeters: Double,
        calendar: Calendar = .current
    ) -> Bool {
        guard let raceDay, raceMeters > 0 else { return false }
        guard calendar.isDate(start, inSameDayAs: raceDay) else { return false }
        return Double(distanceM) >= raceMeters * minRaceFraction
    }

    static func isRace(run: RunSummary, goal: GoalInfo?, calendar: Calendar = .current) -> Bool {
        guard let goal else { return false }
        return isRace(
            start: run.start,
            distanceM: run.distanceM,
            raceDay: goal.raceDay,
            raceMeters: raceMeters(goalDistance: goal.distance),
            calendar: calendar
        )
    }

    // MARK: - GPS overread

    /// Measured distance, as a fraction of the race distance, inside which the excess is
    /// treated as GPS error and scaled away.
    ///
    /// Why this exists: a certified course is measured along the shortest legal line, and
    /// nobody runs that line — so every watch reads a marathon a little long. Chicago is worse
    /// than most. The first half is a canyon of towers and the course goes *under* Wacker and
    /// Columbus, and GPS bouncing off glass adds distance that was never run: 26.4–26.8 mi is
    /// the normal reading for a runner who ran exactly 26.2. Placed on raw distance, the 5K
    /// mat lands a few hundred metres before the real one, every split reads fast, and the
    /// finish arrives "at" 26.2 with half a mile still to run. Checked against the official
    /// chip splits, the recap would be wrong at every mat in the same direction.
    ///
    /// So, when the reading is plausibly *that* — 100% to 103% of the race — the whole
    /// cumulative curve is shrunk uniformly until the finish lands on 42,195 m. Uniform
    /// scaling assumes the error is spread along the course, which is not quite true
    /// (downtown is worse than Pilsen), but it is the only assumption the data supports, and
    /// it is right where it matters most: the finish.
    ///
    /// Outside the band, raw distance stands. Past 103% (27.0 mi for a marathon) the excess is
    /// too big to be drift — it is a warm-up, a walk to gear check, or a watch left running —
    /// and stretching the race to swallow it would move every mat. Under 100% the watch read
    /// short, and there is no principled way to invent the missing metres.
    static let overreadBand: ClosedRange<Double> = 1.00...1.03

    struct Normalised: Equatable {
        let meters: [Double]
        /// Multiplier applied to every point. Exactly 1 when raw distance was kept.
        let scale: Double
        var wasScaled: Bool { scale != 1 }
    }

    static func normalise(meters: [Double], raceMeters: Double) -> Normalised {
        guard let total = meters.last, total > 0, raceMeters > 0,
              overreadBand.contains(total / raceMeters) else {
            return Normalised(meters: meters, scale: 1)
        }
        let k = raceMeters / total
        var scaled = meters.map { $0 * k }
        // Exactly the race distance, not one rounding error short of it — otherwise the finish
        // mat would be "unreachable" by a nanometre and fall back to a different code path.
        scaled[scaled.count - 1] = raceMeters
        return Normalised(meters: scaled, scale: k)
    }

    // MARK: - Time at distance

    /// Elapsed seconds at which the cumulative distance first reached `target`, linearly
    /// interpolated between samples. Nil past the end of the run.
    ///
    /// "First reached" matters at a standstill (an aid station, a portaloo): the curve is flat
    /// there, and the mat was crossed at the start of the flat, not the end.
    static func time(atMeters target: Double, times: [Double], meters: [Double]) -> Double? {
        guard times.count == meters.count, let first = meters.first, let last = meters.last,
              target >= 0, target <= last else { return nil }
        if target <= first { return times[0] }
        // Invariant: meters[lo] < target <= meters[hi].
        var lo = 0, hi = meters.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if meters[mid] < target { lo = mid } else { hi = mid }
        }
        let f = (target - meters[lo]) / (meters[hi] - meters[lo])
        return times[lo] + f * (times[hi] - times[lo])
    }

    // MARK: - Mats

    /// The timing mats a big-city marathon reports, in order. Distances short of the race
    /// are used, so a half gets 5K–20K and a 10K gets 5K.
    static let standardMats: [(label: String, meters: Double)] = [
        ("5K", 5_000), ("10K", 10_000), ("15K", 15_000), ("20K", 20_000),
        ("Half", 21_097.5),
        ("25K", 25_000), ("30K", 30_000), ("35K", 35_000), ("40K", 40_000),
    ]

    struct Mat: Identifiable, Equatable {
        let id: Int
        let label: String
        let meters: Double
        /// Race clock at this mat, from the watch's start.
        let elapsedS: Double
        /// Pace over the segment since the previous mat (or the start), seconds per mile.
        let segmentPaceSecPerMile: Double
        /// Cumulative actual minus even goal pace. Negative = banked. Nil with no goal time.
        let deltaS: Double?
        let isFinish: Bool
    }

    /// Places every mat on the (already normalised) curve.
    ///
    /// The finish mat is always present: at the race distance when the curve reaches it, and
    /// otherwise at the end of the run — a watch that read short still finished the race.
    /// Intermediate mats past the end of a short reading are omitted rather than guessed.
    static func mats(times: [Double], meters: [Double], raceMeters: Double, goalS: Int?) -> [Mat] {
        guard times.count == meters.count, let lastT = times.last, raceMeters > 0 else { return [] }

        var placed: [(label: String, meters: Double, t: Double)] = []
        for mat in standardMats where mat.meters < raceMeters {
            guard let t = time(atMeters: mat.meters, times: times, meters: meters) else { break }
            placed.append((mat.label, mat.meters, t))
        }
        let finishT = time(atMeters: raceMeters, times: times, meters: meters) ?? lastT
        placed.append(("Finish", raceMeters, finishT))

        let goalPerMeter = goalS.flatMap { $0 > 0 ? Double($0) / raceMeters : nil }
        var out: [Mat] = []
        var prevT = times.first ?? 0, prevM = 0.0
        for (i, p) in placed.enumerated() {
            let dm = p.meters - prevM
            let pace = dm > 0 ? (p.t - prevT) / (dm / metersPerMile) : 0
            out.append(Mat(
                id: i,
                label: p.label,
                meters: p.meters,
                elapsedS: p.t,
                segmentPaceSecPerMile: pace,
                deltaS: goalPerMeter.map { p.t - $0 * p.meters },
                isFinish: i == placed.count - 1
            ))
            prevT = p.t
            prevM = p.meters
        }
        return out
    }

    // MARK: - Halves

    struct Halves: Equatable {
        let firstS: Double
        let secondS: Double
        /// Second half minus first. Negative is a negative split.
        var splitS: Double { secondS - firstS }
        var isNegativeSplit: Bool { splitS < 0 }
    }

    /// First and second half, split at exactly half the race distance on the normalised
    /// curve — so for a marathon, the same instant as the Half mat.
    static func halves(times: [Double], meters: [Double], raceMeters: Double, finishS: Double) -> Halves? {
        guard let halfT = time(atMeters: raceMeters / 2, times: times, meters: meters),
              finishS > halfT else { return nil }
        return Halves(firstS: halfT, secondS: finishS - halfT)
    }

    // MARK: - HR drift

    /// Fewer samples than this in either half and the mean is noise, not drift. Garmin writes
    /// HR to Health sparsely and sometimes not at all for a run; a "drift" built from a
    /// handful of samples would be presented with the same confidence as a real one.
    static let minHRSamplesPerHalf = 20

    struct HRDrift: Equatable {
        let firstHalfBPM: Double
        let secondHalfBPM: Double
        var bpm: Double { secondHalfBPM - firstHalfBPM }
        var percent: Double { bpm / firstHalfBPM * 100 }
    }

    /// Mean HR before the halfway instant vs. from it to the finish. Samples after the finish
    /// (the shuffle to the medal) are excluded — they would drag the second half down.
    static func hrDrift(hrTimes: [Double], hrBPM: [Double], halfS: Double, finishS: Double) -> HRDrift? {
        guard hrTimes.count == hrBPM.count else { return nil }
        var first: [Double] = [], second: [Double] = []
        for (t, bpm) in zip(hrTimes, hrBPM) where t >= 0 && t <= finishS {
            if t < halfS { first.append(bpm) } else { second.append(bpm) }
        }
        guard first.count >= minHRSamplesPerHalf, second.count >= minHRSamplesPerHalf else { return nil }
        let a = first.reduce(0, +) / Double(first.count)
        let b = second.reduce(0, +) / Double(second.count)
        guard a > 0 else { return nil }
        return HRDrift(firstHalfBPM: a, secondHalfBPM: b)
    }

    // MARK: - Fade point

    /// Giving back less than this between the most-banked mat and the finish is noise, not a
    /// fade — a few seconds lost on a bridge and won back is not where the race turned.
    static let fadeToleranceS = 15.0

    /// The mat where the athlete was furthest ahead of goal before time started coming back:
    /// the minimum cumulative delta among the mats before the finish (the later one on a tie),
    /// provided the finish is more than `fadeToleranceS` worse than it.
    ///
    /// Nil when there is no goal, or when the finish is itself the most-banked point (the
    /// athlete never faded — even pace or a strong close).
    static func fadePoint(_ mats: [Mat]) -> Mat? {
        guard let finish = mats.last, finish.isFinish, let finishDelta = finish.deltaS else { return nil }
        var best: Mat?
        for mat in mats.dropLast() {
            guard let d = mat.deltaS else { continue }
            if let b = best?.deltaS, d > b { continue }
            best = mat
        }
        guard let best, let bestDelta = best.deltaS, finishDelta - bestDelta > fadeToleranceS else { return nil }
        return best
    }

    // MARK: - The whole recap

    struct Recap: Equatable {
        let raceMeters: Double
        /// What the watch read, before any scaling.
        let measuredMeters: Double
        let scale: Double
        var wasScaled: Bool { scale != 1 }
        let mats: [Mat]
        let finishS: Double
        let goalS: Int?
        let halves: Halves?
        let hrDrift: HRDrift?
        let fadePoint: Mat?

        /// Finish minus goal. Negative = under goal.
        var finishDeltaS: Double? { mats.last?.deltaS }
    }

    /// Nil when there is no usable distance series (manual run, Health returned nothing).
    static func recap(
        times: [Double],
        meters: [Double],
        hrTimes: [Double],
        hrBPM: [Double],
        raceMeters: Double,
        goalS: Int?
    ) -> Recap? {
        guard times.count == meters.count, times.count >= 2,
              let measured = meters.last, measured > 0 else { return nil }
        let n = normalise(meters: meters, raceMeters: raceMeters)
        let mats = mats(times: times, meters: n.meters, raceMeters: raceMeters, goalS: goalS)
        guard let finish = mats.last else { return nil }
        let halves = halves(times: times, meters: n.meters, raceMeters: raceMeters, finishS: finish.elapsedS)
        let drift = halves.flatMap {
            hrDrift(hrTimes: hrTimes, hrBPM: hrBPM, halfS: $0.firstS, finishS: finish.elapsedS)
        }
        return Recap(
            raceMeters: raceMeters,
            measuredMeters: measured,
            scale: n.scale,
            mats: mats,
            finishS: finish.elapsedS,
            goalS: goalS.flatMap { $0 > 0 ? $0 : nil },
            halves: halves,
            hrDrift: drift,
            fadePoint: fadePoint(mats)
        )
    }

    // MARK: - The block

    static let blockWeeks = 16

    struct Block: Equatable {
        let miles: Double
        let runCount: Int
        let longest: RunSummary?
        /// What the finish projection read on race morning. Nil for non-marathon races — the
        /// projection only ever extrapolates to 26.2 — or when nothing qualified.
        let projectedFinishS: Int?
    }

    /// The sixteen weeks before race day, race day itself excluded — the race is the result
    /// of the block, not part of it, and counting it would make every block look 26 miles
    /// bigger and its longest run the race.
    ///
    /// The projection is replayed as of the instant race day began, through the same rule
    /// Progress uses (`ProjectionHistory`), so it is the number the app was showing that
    /// morning rather than one that has since seen the race.
    static func block(
        runs: [RunSummary],
        raceDay: Date,
        raceMeters: Double,
        calendar: Calendar = .current
    ) -> Block {
        let dayStart = calendar.startOfDay(for: raceDay)
        let from = calendar.date(byAdding: .day, value: -blockWeeks * 7, to: dayStart) ?? dayStart
        let inBlock = runs.filter { $0.start >= from && $0.start < dayStart }
        let projected = raceMeters == marathonMeters
            ? ProjectionHistory.projection(runs, asOf: dayStart.addingTimeInterval(-1))?.finishS
            : nil
        return Block(
            miles: inBlock.reduce(0) { $0 + $1.miles },
            runCount: inBlock.count,
            longest: inBlock.max { $0.distanceM < $1.distanceM },
            projectedFinishS: projected
        )
    }

    // MARK: - Formatting

    /// `h:mm:ss` past the hour, `m:ss` under it.
    static func formatClock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// A delta in the engine's sign convention: `-1:23` banked, `+0:45` given back, `0:00`
    /// dead on. The sign is always printed when non-zero, because on a race clock "1:23"
    /// with no sign is the one ambiguous thing you can show.
    static func formatDelta(_ seconds: Double) -> String {
        let rounded = seconds.rounded()
        if rounded == 0 { return "0:00" }
        return (rounded < 0 ? "-" : "+") + formatClock(abs(rounded))
    }
}
