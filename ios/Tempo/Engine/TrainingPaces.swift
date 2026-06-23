import Foundation

/// Deterministic pace math — the rules half of the hybrid engine.
///
/// From a goal race (distance + finish time) we derive the training paces a plan is built
/// around. This is a pragmatic first-pass model (Riegel for equivalent efforts + standard
/// physiological offsets from threshold). It is intentionally simple, pure, and unit-tested;
/// the LLM layer tunes *within* these bounds, it does not replace them.
///
/// All paces are seconds per mile. Convert at the edges for km users.
enum RaceDistance: String, CaseIterable {
    case fiveK = "5k", tenK = "10k", half = "half", marathon = "marathon"
    var miles: Double {
        switch self {
        case .fiveK: return 3.10686
        case .tenK: return 6.21371
        case .half: return 13.1094
        case .marathon: return 26.2188
        }
    }
}

/// Training paces in seconds per mile.
struct TrainingPaces: Equatable {
    let easy: Int          // conversational aerobic
    let marathon: Int      // goal marathon pace
    let threshold: Int     // ~1hr race effort / tempo
    let interval: Int      // ~VO2max, 3-5 min reps
    let repetition: Int    // short fast reps / strides
}

enum PaceModel {

    /// Riegel equivalent-performance: t2 = t1 * (d2/d1)^1.06.
    static func equivalentTime(seconds t1: Double, from d1: Double, to d2: Double) -> Double {
        t1 * pow(d2 / d1, 1.06)
    }

    /// Derive training paces from a goal race + finish time.
    static func paces(for distance: RaceDistance, goalSeconds: Double) -> TrainingPaces {
        // Anchor on the equivalent threshold pace (~ time you could hold for one hour).
        // Use the 10-mile equivalent as a stand-in for ~1hr effort, then express per mile.
        let tenMileTime = equivalentTime(seconds: goalSeconds, from: distance.miles, to: 10.0)
        let thresholdPace = tenMileTime / 10.0

        // Equivalent marathon pace, straight from Riegel.
        let marathonTime = equivalentTime(seconds: goalSeconds, from: distance.miles, to: RaceDistance.marathon.miles)
        let marathonPace = marathonTime / RaceDistance.marathon.miles

        // Standard offsets from threshold (seconds/mile).
        let easy       = thresholdPace + 75      // +60–90s; aerobic base
        let interval   = thresholdPace - 20      // ~VO2max reps
        let repetition = thresholdPace - 40      // short, fast

        return TrainingPaces(
            easy: Int(easy.rounded()),
            marathon: Int(marathonPace.rounded()),
            threshold: Int(thresholdPace.rounded()),
            interval: Int(interval.rounded()),
            repetition: Int(repetition.rounded())
        )
    }

    /// Format sec/mile as `m:ss`.
    static func format(_ secPerMile: Int) -> String {
        String(format: "%d:%02d", secPerMile / 60, secPerMile % 60)
    }
}

// Example (sub-3:15 marathon → goalSeconds = 11_700):
//   threshold ≈ 7:0x /mi, marathon ≈ 7:26 /mi, easy ≈ 8:1x–9:0x /mi
// matching the paces shown throughout the Tempo design.
