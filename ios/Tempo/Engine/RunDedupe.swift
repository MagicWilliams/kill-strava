import Foundation

/// Ingest dedupe — the rule that decides which HealthKit candidates are genuinely new.
///
/// Two layers of duplication exist, and only one of them is caught by the DB's
/// `(user_id, source, external_id)` unique constraint:
///
///  1. **Same HKWorkout re-read** — caught upstream by the uuid constraint.
///  2. **Garmin re-export** — when Garmin Connect's Health settings change it rewrites
///     already-exported workouts as brand-new `HKWorkout` objects with fresh uuids.
///     The uuid constraint sees strangers and happily inserts them again. This is what
///     turned a 15-mile week into 31 on 2026-07-10.
///
/// Layer 2's tell is the start time: the same run cannot start twice within minutes.
/// Anything beginning within `windowSeconds` of a run we already hold — whether that run
/// came from the DB or from earlier in this same batch — is the same run wearing a new id.
///
/// Pure and deterministic by design: this is the regression surface for a bug class that
/// silently corrupts every downstream metric (weekly mileage, CTL/ATL, projection).
enum RunDedupe {

    /// Two runs starting closer together than this are the same run.
    /// Five minutes comfortably exceeds any re-export clock skew while staying far
    /// below the gap between two genuinely separate runs.
    static let windowSeconds: TimeInterval = 300

    /// Candidates that are not already represented in `existing`, and not repeated
    /// within the batch itself. Order is preserved; the first candidate in a cluster wins.
    static func newRuns(
        from candidates: [RunSummary],
        existing: [RunSummary],
        window: TimeInterval = windowSeconds
    ) -> [RunSummary] {
        var kept: [RunSummary] = []
        for candidate in candidates {
            let isNear = { (other: RunSummary) in
                abs(other.start.timeIntervalSince(candidate.start)) < window
            }
            guard !existing.contains(where: isNear), !kept.contains(where: isNear) else { continue }
            kept.append(candidate)
        }
        return kept
    }
}
