import Foundation

/// The cut-offs between the three drift tiers, in percent (PRD-02 §6.2).
///
/// A value rather than literals in `Drift.measure` because the PRD calls these starting
/// numbers: "the beta tunes them". Tuning should be a one-line change at the call site, and
/// the tests can pin the tier logic independently of whichever numbers win.
struct DriftThresholds: Equatable {
    /// Drift at or above this is `drifting`. Below it is `onTrack`.
    var driftingAt: Double
    /// Drift at or above this is `offTrack`. For scale: 5% on a 3:30 marathon is ~10.5 min.
    var offTrackAt: Double

    init(driftingAt: Double = 2, offTrackAt: Double = 5) {
        self.driftingAt = driftingAt
        self.offTrackAt = offTrackAt
    }

    /// The PRD's values: on track < 2%, drifting 2–< 5%, off track ≥ 5%.
    static let standard = DriftThresholds()
}

/// How far the runner's current fitness is from where the expected curve says they should
/// be *this week* — the Drift Detector's core number (PRD-02 §6.1.3, issue #236).
///
/// The comparison is to this week's point on the curve, not to the goal. Today's Progress
/// card asks "projection ≤ goal?", and that question flags nearly everyone early in a block,
/// because the fitness the goal needs hasn't been built yet. A runner in week 2 who is
/// exactly where the plan expects is on track, however far they still are from race pace.
///
/// Both inputs are race-equivalent finish times in seconds, so slower is larger and a
/// positive drift means behind the curve. This takes plain values on purpose: it does not
/// know how the fitness estimate or the curve are produced, so it can't be wrong about them.
enum Drift {

    enum Status: Equatable {
        case onTrack
        case drifting
        case offTrack
    }

    struct Reading: Equatable {
        /// `(current − expected) / expected × 100`. Signed: negative is ahead of the curve.
        let percent: Double
        /// `current − expected`, in seconds. Signed the same way as `percent`.
        let gapSeconds: Double
        let status: Status
    }

    enum Result: Equatable {
        /// No estimate or no expectation to compare. Not a status: the Detector says
        /// nothing rather than raise an alarm it can't back with a number.
        case insufficientData
        case measured(Reading)

        var reading: Reading? {
            guard case .measured(let r) = self else { return nil }
            return r
        }
    }

    /// - Parameters:
    ///   - current: the runner's current race-equivalent fitness, in seconds. Nil when the
    ///     estimator has nothing qualifying to go on.
    ///   - expected: this week's value on the expected trajectory curve, in seconds. Nil
    ///     when there is no curve (no goal, no race date, block too short).
    static func measure(
        current: Double?,
        expected: Double?,
        thresholds: DriftThresholds = .standard
    ) -> Result {
        // A zero, negative or non-finite time is not a finish time; treating it as one would
        // divide by zero or print a drift of thousands of percent. Same answer as missing.
        guard let current, let expected,
              current.isFinite, expected.isFinite,
              current > 0, expected > 0
        else { return .insufficientData }

        let gap = current - expected
        let percent = gap / expected * 100
        return .measured(Reading(
            percent: percent,
            gapSeconds: gap,
            status: status(forPercent: percent, thresholds: thresholds)
        ))
    }

    /// The tier for a drift percentage. Lower bounds are inclusive, per the PRD table.
    /// Ahead of the curve is on track — a negative drift is never an alarm.
    static func status(forPercent percent: Double, thresholds: DriftThresholds = .standard) -> Status {
        if percent >= thresholds.offTrackAt { return .offTrack }
        if percent >= thresholds.driftingAt { return .drifting }
        return .onTrack
    }
}
