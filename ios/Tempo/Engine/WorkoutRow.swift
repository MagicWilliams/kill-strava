import Foundation

/// The one mapping from a saved Apple Health workout to a `runs` row (#122).
///
/// Two writers produce rows from HKWorkouts: the HealthKit sync, which ingests everything in
/// Health, and the run recorder, which writes the run it just saved so Today shows it without
/// waiting for that sync. They must agree to the byte on `(user_id, source, external_id)` —
/// that triple is the unique key the sync dedupes on. If the recorder wrote the uuid
/// lowercase, or under a different `source`, the next sync would see a stranger and insert
/// the run a second time: the 2026-07-10 week that read 31 miles instead of 15, self-inflicted.
/// And they must agree on every number, or a run's pace would depend on which path happened
/// to write it. So neither path builds a row by hand; both go through here.
///
/// Pure: `HealthService` turns an `HKWorkout` into a `Workout` and the recorder hands one
/// over from its own save, and nothing below touches HealthKit.
enum WorkoutRow {

    /// What a saved workout says about itself — the fields a row is built from, as HealthKit
    /// reports them, before any rounding.
    struct Workout: Codable, Equatable {
        /// `HKWorkout.uuid`. Becomes `external_id`, the dedupe key.
        var uuid: UUID
        var start: Date
        var end: Date
        /// `totalDistance` in meters; nil when the workout carried none.
        var distanceM: Double?
        /// `HKWorkout.duration` — HealthKit's own moving time, paused stretches excluded.
        var movingS: TimeInterval
        /// Average heart rate from the workout's statistics, in bpm; nil when none recorded.
        var avgHR: Double?
        /// `HKMetadataKeyIndoorWorkout` — a treadmill run. Carried so both paths read it the
        /// same way, but `runs` has no column for it yet, so it does not reach the row.
        var indoor: Bool = false
        /// A treadmill run Tempo recorded and the athlete put right by its console (#116),
        /// from the workout's metadata (`RecordingMetadata.correction(from:)`). Nil for
        /// every other workout.
        var correction: Correction? = nil

        struct Correction: Codable, Equatable {
            /// What the console said: the run's distance.
            var consoleM: Double
            /// The phone's step estimate it replaced.
            var estimateM: Double
            /// `runs.correction_note`, written in the unit he ran in.
            var note: String
        }
    }

    /// Every row this mapping writes is a HealthKit row, whichever path wrote it.
    static let source = "healthkit"

    /// At or under this, a workout is a GPS blip or an accidental start, not a run. Ingest has
    /// always dropped these; a recorded run this short is dropped for the same reason, so
    /// that it never becomes a row the sync would have refused.
    static let minimumDistanceM = 200

    /// The workout as a run, before dedupe. `id` is the HealthKit uuid — this is the
    /// ingest/fallback shape, not a database row.
    ///
    /// Two clocks, both straight off the workout record: `movingS` excludes paused stretches
    /// and start→end is the wall clock. They differ only when the athlete stopped. See
    /// `TimeAccounting`.
    ///
    /// A console-corrected workout's distance is the console's figure, to the metre. Its
    /// samples sum to the same number, but HealthKit adds them in floating point, and a
    /// 5.00 km run whose total comes back as 4,999.9999 m would truncate to 4,999.
    static func summary(_ w: Workout) -> RunSummary {
        RunSummary(
            id: w.uuid,
            start: w.start,
            distanceM: w.correction.map { Int($0.consoleM.rounded()) } ?? Int(w.distanceM ?? 0),
            durationS: Int(w.movingS),
            elapsedS: Int(w.end.timeIntervalSince(w.start)),
            avgHR: w.avgHR.map { Int($0.rounded()) },
            source: source,
            externalID: w.uuid.uuidString
        )
    }

    /// Whether a summary is long enough to be a run at all.
    static func isRun(_ s: RunSummary) -> Bool {
        s.distanceM > minimumDistanceM
    }

    /// The `runs` insert for a run that dedupe has kept. `s` must be a `summary(_:)` (or a
    /// dedupe merge of two), whose `id` is still the HealthKit uuid.
    ///
    /// `external_id` is `uuid.uuidString` — **uppercase**, because that is how every one of the
    /// 2,000+ rows already stored was written. The unique key compares text, so the case is
    /// part of the identity.
    static func insert(_ s: RunSummary, userID: String) -> RunInsert {
        RunInsert(
            user_id: userID,
            source: source,
            external_id: s.id.uuidString,
            start_time: s.start,
            distance_m: s.distanceM,
            duration_s: s.durationS,
            elapsed_duration_s: s.elapsedS,
            avg_pace_sec: s.paceSecPerMile,
            avg_hr: s.avgHR
        )
    }

    /// `row`, marked the way every edited run is marked when `w` carries a console correction
    /// (#116): `corrected`, the note, and `original` — the run as the phone counted it, the
    /// same pre-correction snapshot a coach amendment keeps. Once `corrected` is set, the
    /// athlete's word outranks the math everywhere (the HR backfill, the detail screen, the
    /// coach's own amendments, which keep this `original` rather than overwrite it).
    ///
    /// The row as given when there is no correction, so every other run is written exactly
    /// as before.
    static func corrected(_ row: RunInsert, by w: Workout) -> RunInsert {
        guard let c = w.correction else { return row }
        var out = row
        out.corrected = true
        out.correction_note = c.note
        out.original = original(row, estimateM: c.estimateM)
        return out
    }

    /// The run as the phone counted it: the estimate's distance and pace, everything else as
    /// the row has it — a console correction changes the distance and nothing else.
    static func original(_ row: RunInsert, estimateM: Double) -> RunInsert.Original {
        let meters = Int(estimateM.isFinite ? max(0, estimateM) : 0)
        return RunInsert.Original(
            distance_m: meters,
            duration_s: row.duration_s,
            avg_hr: row.avg_hr,
            avg_pace_sec: TimeAccounting.paceSecPerMile(seconds: row.duration_s,
                                                        miles: Double(meters) / Units.metersPerMile)
        )
    }
}
