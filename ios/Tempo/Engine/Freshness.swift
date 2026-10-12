import Foundation

/// Fitness / fatigue / form in one plain word — the Freshness card on the just-running
/// Today and the current-fitness card on Progress (#101).
///
/// Readiness already turns the load model into a word, but readiness answers a training
/// question: *can I do quality today?* "Primed" and "Run easy" are instructions, and with no
/// plan there is nothing to instruct. Freshness answers the question someone between blocks
/// actually has: *where am I?* — rested, carrying a week, or on the way up.
///
/// Thresholds are on form as a fraction of fitness, the same quantity readiness is built
/// from (`readiness = 55 + formPct × 90`), so the two words never contradict each other:
/// "fresh" sits in readiness's Primed band and "carrying fatigue" in its lower Loaded band
/// and below.
enum Freshness {

    enum State: Equatable {
        /// Fitness is negligible: little or no running in the last six weeks.
        case rested
        /// Form well above zero — fatigue has cleared off the fitness underneath it.
        case fresh
        /// Fatigue well above fitness. The day after a marathon reads like this, correctly.
        case carryingFatigue
        /// Balanced form, fitness rising over the last four weeks.
        case building
        /// Balanced form, fitness flat or easing.
        case steady

        var label: String {
            switch self {
            case .rested:          return "Rested"
            case .fresh:           return "Fresh"
            case .carryingFatigue: return "Carrying fatigue"
            case .building:        return "Building"
            case .steady:          return "Holding steady"
            }
        }

        var caption: String {
            switch self {
            case .rested:          return "Not much recent load — fitness and fatigue are both low."
            case .fresh:           return "Fatigue has cleared. Whatever you've built is ready to use."
            case .carryingFatigue: return "Recent running outweighs your base right now. Easy days absorb it."
            case .building:        return "Fitness is climbing and fatigue is keeping pace."
            case .steady:          return "Fitness is holding and fatigue is in balance."
            }
        }
    }

    /// Below this CTL there is nothing meaningful to read form off. CTL is roughly average
    /// daily load in easy-mile units, so 0.5 is about three and a half easy miles a week.
    static let restedBelowCTL = 0.5
    /// Form / fitness above this is fresh — readiness ≥ 70, inside Primed.
    static let freshAbove = 0.17
    /// Form / fitness below this is carrying fatigue — readiness ≤ 46, Loaded or below.
    static let fatiguedBelow = -0.10
    /// Fitness up at least this fraction over four weeks counts as building.
    static let buildingGain = 0.05

    /// - Parameters:
    ///   - ctlFourWeeksAgo: fitness 28 days back, from `FitnessMetrics.ctlSeries`. Nil when
    ///     the series is too short to say; that never reads as building.
    static func state(ctl: Double, atl: Double, ctlFourWeeksAgo: Double?) -> State {
        // Low fitness with real recent load is someone (re)starting, not someone resting:
        // the first fortnight back reads as building, not as "both low".
        guard ctl >= restedBelowCTL else { return atl >= restedBelowCTL ? .building : .rested }
        let formPct = (ctl - atl) / ctl
        if formPct > freshAbove { return .fresh }
        if formPct < fatiguedBelow { return .carryingFatigue }
        if let before = ctlFourWeeksAgo, ctl >= before * (1 + buildingGain) {
            return .building
        }
        return .steady
    }

    static func state(_ m: FitnessMetrics) -> State {
        state(ctl: m.ctl, atl: m.atl, ctlFourWeeksAgo: ctlFourWeeksAgo(m.ctlSeries))
    }

    /// The series is one point per day, newest last; 28 days back is index `count − 29`.
    static func ctlFourWeeksAgo(_ series: [(date: Date, ctl: Double)]) -> Double? {
        let i = series.count - 29
        return i >= 0 ? series[i].ctl : nil
    }
}
