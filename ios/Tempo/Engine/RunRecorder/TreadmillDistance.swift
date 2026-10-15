import Foundation

/// A treadmill run's distance (#116): counted from steps while he runs, put right by the
/// console at the end.
///
/// Indoors there is no GPS. The phone estimates distance from his steps, and that estimate is
/// off by 5–15% — in either direction, depending on stride, pocket and belt. The treadmill's
/// console is the truth, so the save screen asks for it (#130) and the run is rescaled to it
/// before it goes anywhere.
///
/// **Why the rescale happens before Health has a single metre.** HealthKit has no way to take
/// a sample back out of a workout: `HKWorkoutBuilder.addSamples` saves each sample to the
/// database as it is added, and the builder offers no remove. A treadmill run whose distance
/// went into the workout as he ran could be corrected *up* (add the difference) but never
/// *down*, and the phone over-counts as often as it under-counts. So on a treadmill, as
/// outdoors, HealthKit's own distance collection is off, Tempo keeps the curve itself (from
/// Core Motion, `Steps`), and the whole curve is written once, at Save — the console's curve
/// when he gave one, the phone's untouched when he didn't.
///
/// Pure. `WorkoutRecorder` feeds it readings and writes what it returns.
enum TreadmillDistance {

    // MARK: - Counting while he runs

    /// Core Motion's running step distance, turned into the treadmill curve.
    ///
    /// `CMPedometer` reports a cumulative total since the moment it was started, and keeps
    /// counting while the run is paused — a walk to the water fountain is steps too. So each
    /// reading is credited as the *difference* from the last one, and only while the run is
    /// running: a paused stretch moves the baseline without moving the curve, the way
    /// HealthKit's collection did when the session was paused.
    struct Steps: Equatable {
        /// The last cumulative reading, nil before the first since the stream (re)started.
        private(set) var lastReadingM: Double?

        init() {}

        /// The point to append to the curve for one reading, or nil when it adds nothing.
        ///
        /// - Parameters:
        ///   - totalM: Core Motion's cumulative distance since the stream started.
        ///   - t: seconds since the run started, wall clock — the curve's own time axis.
        ///   - running: whether the run is running now. Paused, the reading only moves the baseline.
        ///   - last: the curve's last point.
        mutating func credit(totalM: Double, t: Double, running: Bool,
                             after last: BestEfforts.Point) -> BestEfforts.Point? {
            guard totalM.isFinite, t.isFinite else { return nil }
            // A total that went backwards is a restarted counter, not negative running.
            let delta = max(0, totalM - (lastReadingM ?? 0))
            lastReadingM = totalM
            guard running, delta > 0 else { return nil }
            return BestEfforts.Point(t: max(last.t, t), m: last.m + delta)
        }
    }

    // MARK: - The console's word

    /// What the athlete typed in, against what the phone counted.
    struct Correction: Codable, Equatable {
        /// The treadmill console's distance. What the run becomes.
        var consoleM: Double
        /// The phone's step estimate it replaces. The run's `original` (the pre-correction
        /// snapshot every corrected run keeps).
        var estimateM: Double
    }

    /// The correction to apply, or nil to leave the run exactly as counted.
    ///
    /// Nil when he skipped it, when the reading is not a distance (zero, negative, not a
    /// number), and when it reads the same as the estimate at the stepper's resolution — the
    /// stepper is prefilled with the estimate to a hundredth, and Save on an untouched
    /// stepper must not mark a run "corrected" by the rounding of its own prefill.
    static func correction(consoleM: Double?, estimateM: Double, units: Units) -> Correction? {
        guard let consoleM, consoleM.isFinite, consoleM > 0 else { return nil }
        let estimate = estimateM.isFinite ? max(0, estimateM) : 0
        guard hundredths(consoleM, units) != hundredths(estimate, units) else { return nil }
        return Correction(consoleM: consoleM, estimateM: estimate)
    }

    /// A distance as the stepper shows it: whole hundredths of a mile or km.
    static func hundredths(_ meters: Double, _ units: Units) -> Int {
        Int((units.distance(meters: meters) * 100).rounded())
    }

    /// The curve to write into the workout: `timeline` itself with no correction; else the
    /// same run, scaled so it ends on the console's distance exactly.
    ///
    /// Proportional, point by point: every metre stretches by the same factor, so each split
    /// boundary moves to where that fraction of the console's distance was reached, and the
    /// splits and paces read back from Health are recomputed from it. Flat stretches (a pause)
    /// stay flat; time is never touched.
    ///
    /// With no step distance at all — the phone sat on the console, or Motion & Fitness is
    /// off — there is nothing to scale. The console's distance is then spread evenly over
    /// the time he was moving (`startedAt` to `endedAt`, less `pauses`), which is what a
    /// treadmill at one speed would have drawn, and far better than a run with no distance.
    static func rescaled(
        _ timeline: [BestEfforts.Point],
        by correction: Correction?,
        startedAt: Date?,
        endedAt: Date?,
        pauses: [RecorderState.Pause]
    ) -> [BestEfforts.Point] {
        guard let correction else { return timeline }
        let console = correction.consoleM
        guard let estimate = timeline.last?.m, estimate > 0 else {
            return evenly(console, startedAt: startedAt, endedAt: endedAt, pauses: pauses) ?? timeline
        }
        let k = console / estimate
        // Every point already at the end of the run (the flat after the last step) lands on
        // the console's figure itself, not on `estimate * k`, which can miss it in the last
        // bit of a double: the total must match the console exactly.
        return timeline.map { p in
            BestEfforts.Point(t: p.t, m: p.m >= estimate ? console : p.m * k)
        }
    }

    /// `meters` at one steady pace across the moving part of the run, as a curve in the
    /// run's own seconds. Nil without a start and an end to spread it between.
    static func evenly(_ meters: Double, startedAt: Date?, endedAt: Date?,
                       pauses: [RecorderState.Pause]) -> [BestEfforts.Point]? {
        guard let startedAt, let endedAt, endedAt > startedAt else { return nil }
        let endS = endedAt.timeIntervalSince(startedAt)

        // The stopped stretches, in run seconds, clipped to the run and in order.
        let stops: [(from: Double, to: Double)] = pauses.compactMap { p in
            let from = max(0, p.start.timeIntervalSince(startedAt))
            let to = min(endS, (p.end ?? endedAt).timeIntervalSince(startedAt))
            return to > from ? (from, to) : nil
        }.sorted { $0.from < $1.from }
        let stoppedS = stops.reduce(0) { $0 + ($1.to - $1.from) }
        let movingS = endS - stoppedS
        // Stopped the whole time: one step to the total at the end beats no distance.
        guard movingS > 0 else { return [BestEfforts.Point(t: 0, m: 0), BestEfforts.Point(t: endS, m: meters)] }

        let perS = meters / movingS
        var points = [BestEfforts.Point(t: 0, m: 0)]
        var m = 0.0, cursor = 0.0
        for stop in stops where stop.from >= cursor {
            m += (stop.from - cursor) * perS
            points.append(BestEfforts.Point(t: stop.from, m: m))
            points.append(BestEfforts.Point(t: stop.to, m: m))
            cursor = stop.to
        }
        points.append(BestEfforts.Point(t: endS, m: meters))
        return points
    }

    // MARK: - What the run says about it

    /// The run's `correction_note`, in the unit he ran in: "Treadmill console: 5.00 mi (phone
    /// estimated 4.71 mi)". The same column the coach's amendments write, so a console
    /// correction reads as an edited run, with its provenance, everywhere a correction does.
    static func note(_ c: Correction, units: Units) -> String {
        let console = "Treadmill console: " + units.formatDistance(meters: c.consoleM, decimals: 2)
        return c.estimateM > 0
            ? console + " (phone estimated " + units.formatDistance(meters: c.estimateM, decimals: 2) + ")"
            : console + " (phone counted no steps)"
    }
}
