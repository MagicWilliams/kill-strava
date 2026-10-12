import Foundation

/// Closing a block: what the athlete says happened, turned into exactly the rows that get
/// written — pure, no I/O (#100).
///
/// The race may not exist as a run at all. David ran Chicago 2026 with no watch, and the
/// Strava app on his phone paused itself mid-race, so there is nothing in Health that
/// `RaceRecap.isRace` could find. **Typing the official finish time is therefore the primary
/// path**, not a fallback for when the run is missing. When a race run *is* found, its clock
/// is offered as the starting value and the athlete confirms or corrects it — a watch clock
/// is not the chip time.
enum BlockCloseout {

    /// How the block ended. Raw values are the `goals.outcome` check constraint (0013).
    enum Outcome: String, CaseIterable, Equatable {
        case raced
        case didNotStart = "did_not_start"
        case didNotFinish = "did_not_finish"
        /// Given up before race day. Not offered by the close-out (which only appears once
        /// the race has passed) but legal in the column, so modelled.
        case abandoned
    }

    // MARK: - Finish time

    /// Paces outside this band (seconds per mile) are not a finish time anyone ran: faster than
    /// three minutes a mile is beyond the world record at every distance, slower than thirty is
    /// walking with stops. Used only to settle which way a two-part entry was meant.
    static let plausiblePace: ClosedRange<Double> = 180...1_800

    /// Read a typed finish time, using the race distance to settle the one real ambiguity.
    ///
    /// `h:mm:ss` is unambiguous. Two parts are not: "18:45" for a 5K means minutes and
    /// seconds, but "3:28" for a marathon means hours and minutes — nobody types the seconds
    /// of a time they're rounding. So a two-part entry is read as `m:ss` first and as `h:mm`
    /// only if `m:ss` would be an impossible pace for this distance. Nil when it's neither.
    static func parseFinish(_ text: String, raceMeters: Double) -> Int? {
        let parts = text
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let n = parts.map { $0! }

        func plausible(_ s: Int) -> Bool {
            guard s > 0, raceMeters > 0 else { return false }
            return plausiblePace.contains(Double(s) / (raceMeters / RaceRecap.metersPerMile))
        }

        switch n.count {
        case 3:
            guard n[1] < 60, n[2] < 60 else { return nil }
            let s = n[0] * 3600 + n[1] * 60 + n[2]
            return plausible(s) ? s : nil
        case 2:
            guard n[1] < 60 else { return nil }
            let asMinSec = n[0] * 60 + n[1]
            if plausible(asMinSec) { return asMinSec }
            let asHourMin = n[0] * 3600 + n[1] * 60
            return plausible(asHourMin) ? asHourMin : nil
        default:
            return nil
        }
    }

    // MARK: - What gets written

    /// The `goals` update. Every column is written, **nulls included**: re-closing a block as
    /// "didn't start" after first saving a time must clear `result_time_s`, and a synthesized
    /// `Encodable` drops nil keys — which would leave the old time behind and trip the
    /// `result_time_s … outcome = 'raced'` check in 0013.
    struct GoalPatch: Encodable, Equatable {
        let is_active: Bool
        let completed_at: String
        let outcome: String
        let result_time_s: Int?
        let race_run_id: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(is_active, forKey: .is_active)
            try c.encode(completed_at, forKey: .completed_at)
            try c.encode(outcome, forKey: .outcome)
            try c.encode(result_time_s, forKey: .result_time_s)
            try c.encode(race_run_id, forKey: .race_run_id)
        }

        enum CodingKeys: String, CodingKey {
            case is_active, completed_at, outcome, result_time_s, race_run_id
        }
    }

    /// The `plans` update. `'done'` is already in the 0001 check constraint and is what the
    /// plan function writes to the plans it supersedes.
    struct PlanPatch: Encodable, Equatable {
        var status = "done"
    }

    enum CloseoutError: Error, Equatable {
        /// "Raced" with no time. The time is the point of the close-out.
        case missingFinishTime
    }

    static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// - Parameters:
    ///   - finishS: required for `.raced`, ignored (and written as null) for anything else —
    ///     a DNF's partial clock is not a result.
    ///   - raceRunID: the run that was the race, if there is one. Only a raced block keeps it.
    static func goalPatch(
        outcome: Outcome,
        finishS: Int?,
        raceRunID: UUID?,
        now: Date
    ) throws -> GoalPatch {
        let raced = outcome == .raced
        if raced, (finishS ?? 0) <= 0 { throw CloseoutError.missingFinishTime }
        return GoalPatch(
            is_active: false,
            completed_at: timestamp.string(from: now),
            outcome: outcome.rawValue,
            result_time_s: raced ? finishS : nil,
            race_run_id: raced ? raceRunID?.uuidString : nil
        )
    }

    // MARK: - Logging the race as a run

    /// `runs.external_id` for a race logged from the close-out. Derived from the goal, so
    /// closing the same block twice (a retry after a lost response) upserts one run rather
    /// than inserting two — the same reasoning as `ManualRunIdentity`.
    static func raceRunExternalID(goalID: UUID) -> String {
        "race:\(goalID.uuidString)"
    }

    struct RaceRunInsert: Encodable, Equatable {
        let user_id: String
        var source = ManualRunIdentity.source
        let external_id: String
        let start_time: String
        let distance_m: Int
        /// Chip time on both clocks: an official result has no "moving time".
        let duration_s: Int
        let elapsed_duration_s: Int
        let avg_pace_sec: Int?
        let correction_note: String
    }

    /// The optional "also log it as a run": distance = the race distance off the goal (never
    /// an assumed 42,195 m), duration = the official finish time.
    static func raceRun(
        userID: String,
        goalID: UUID,
        raceName: String,
        start: Date,
        raceMeters: Double,
        finishS: Int
    ) -> RaceRunInsert {
        let miles = raceMeters / RaceRecap.metersPerMile
        return RaceRunInsert(
            user_id: userID,
            external_id: raceRunExternalID(goalID: goalID),
            start_time: timestamp.string(from: start),
            distance_m: Int(raceMeters.rounded()),
            duration_s: finishS,
            elapsed_duration_s: finishS,
            avg_pace_sec: miles > 0 ? Int((Double(finishS) / miles).rounded()) : nil,
            correction_note: "\(raceName): official finish time, logged at block close-out (no recording)."
        )
    }

    // MARK: - Result against the goal

    /// Result minus goal, in seconds — `RaceRecap`'s sign convention: negative is under goal.
    static func delta(resultS: Int?, goalS: Int?) -> Int? {
        guard let resultS, let goalS, resultS > 0, goalS > 0 else { return nil }
        return resultS - goalS
    }
}
