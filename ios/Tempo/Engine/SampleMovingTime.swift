import Foundation

/// Moving time measured from a workout's distance samples, and the rule for when that
/// measurement outranks the duration the workout reports about itself (#229, #237).
///
/// ── Why this exists ──────────────────────────────────────────────────────────────────
/// `HKWorkout.duration` is the recording app's moving time *only if that app writes pause
/// events*. A source that writes none reports the whole wall-clock span as its duration,
/// and ingest stored it as moving time. The 15 Oct 2026 run is the scar: 8.1 mi stored over
/// 10h24m — 77:00/mi, 42 spm — while its own distance samples show about 1h41m of moving.
/// The watch was left recording for the rest of the day. Pace, load, the projection, the
/// coach's context and `/plan` all read the 10h24m.
///
/// The distance samples can tell a stop from a slow mile; the stored durations cannot. So
/// at ingest, a new workout whose samples say it was standing still for a long, large share
/// of its duration gets its two clocks put in the right columns: sample moving time in
/// `duration_s`, the wall clock in `elapsed_duration_s`. That is what the columns already
/// mean — today ingest just fills both with the same number.
///
/// Pure: the caller turns `HKQuantitySample`s into `Sample`s, nothing here touches
/// HealthKit, and the Run Detail page reads the same function, so the speed tile and the
/// stored moving time cannot draw the line between moving and stopped in two places.
enum SampleMovingTime {

    /// One distance sample, as seconds from the workout start and the metres it covered.
    struct Sample: Equatable {
        let start: Double
        let end: Double
        let meters: Double
    }

    /// Slower than this over a sample counts as stopped, not moving: about 60:00/mi.
    ///
    /// Moved here from `RunDetailLoader.compute`, where it was an inline `0.45` deciding the
    /// detail page's moving time (#237). Low on purpose: a hike up a steep hill or a walk
    /// break is still moving at 1 mph; a watch on a wrist at a café table is not. The run
    /// recorder splits its clocks on the same line (`TrackMath.stoppedSpeedMps`) so a run
    /// recorded in Tempo and one imported from a watch agree about what stopping is.
    static let stoppedSpeedMps = 0.45

    /// Seconds spent moving, by the samples. Nil when there are no samples to judge by —
    /// that is "unknown", and it must never read as "never moved".
    ///
    /// A gap *between* samples (a paused watch, or one that simply wrote nothing) adds no
    /// distance and no moving time. A sample's own span is floored at 10 ms so a zero-length
    /// sample cannot divide by zero; that floor is the same one the detail page always used.
    static func movingSeconds(_ samples: [Sample]) -> Double? {
        guard !samples.isEmpty else { return nil }
        var moving = 0.0
        for s in samples {
            let dt = max(s.end - s.start, 0.01)
            if s.meters / dt > stoppedSpeedMps { moving += dt }
        }
        return moving
    }

    // MARK: - When the samples outrank the stored duration

    /// The samples must account for at least this much *more* stopped time than the stored
    /// duration admits before ingest acts on it.
    ///
    /// The 4-minute café stop on a 1h40m run is the case this protects: a pause-less source
    /// overstates moving time by those four minutes, and that is real but small, well inside
    /// the noise of how a watch writes samples. Rewriting a run's clocks for it would trade a
    /// slightly slow pace for a number that depends on sample spacing. Ten minutes is a stop
    /// nobody forgets, and a wall-clock duration that long is not rounding.
    static let minimumUnrecordedStopS = 600

    /// …and that extra stopped time must be more than this share of the stored duration.
    ///
    /// The 3-hour long run with a 12-minute bathroom-and-bottle stop clears the ten-minute bar
    /// but is still overwhelmingly a run; its pace reads a few percent slow, not absurd. The
    /// failure #229 describes is the opposite shape — most of the stored time was not running
    /// at all. A quarter keeps the correction for that shape and leaves real long runs alone.
    static let minimumUnrecordedStopShare = 0.25

    /// The two clocks a workout should be stored with, or nil when the stored one stands.
    ///
    /// - Parameters:
    ///   - stored: the duration the workout reports, in seconds (what ingest would write as
    ///     moving time).
    ///   - sampleMoving: `movingSeconds` for the same workout, rounded; nil when it had no
    ///     distance samples.
    /// - Returns: `moving` is the sample moving time, `elapsed` the stored duration — which,
    ///   for a source that wrote no pauses, *is* the wall clock. Nil unless the gap is both
    ///   more than `minimumUnrecordedStopS` and more than `minimumUnrecordedStopShare` of
    ///   `stored`. Both comparisons are strict.
    static func correctedDurations(stored: Int, sampleMoving: Int?) -> (moving: Int, elapsed: Int)? {
        // Zero moving from samples that exist means every sample was slower than a walk —
        // a watch that wrote distance noise, not a run that never moved. That is not a
        // number to put under a run's pace.
        guard let sampleMoving, sampleMoving > 0, stored > sampleMoving else { return nil }
        let unrecordedStop = stored - sampleMoving
        guard unrecordedStop > minimumUnrecordedStopS,
              Double(unrecordedStop) > minimumUnrecordedStopShare * Double(stored) else { return nil }
        return (moving: sampleMoving, elapsed: stored)
    }

    /// `run` with its clocks corrected by its samples, or nil when the stored ones stand.
    ///
    /// Elapsed is the longer of the wall clock the run already carries and the stored
    /// duration: a source that wrote *some* pauses has a wall clock longer than its duration,
    /// and that wall clock is still the honest answer to "how long were you out".
    static func corrected(_ run: RunSummary, sampleMoving: Int?) -> RunSummary? {
        guard let fixed = correctedDurations(stored: run.durationS, sampleMoving: sampleMoving) else { return nil }
        return RunSummary(
            id: run.id,
            start: run.start,
            distanceM: run.distanceM,
            durationS: fixed.moving,
            elapsedS: max(run.elapsedS ?? fixed.elapsed, fixed.elapsed),
            avgHR: run.avgHR,
            corrected: run.corrected,
            source: run.source,
            externalID: run.externalID,
            journal: run.journal
        )
    }

    // MARK: - Which new runs get a sample read

    /// How many sample reads one sync may make. A normal refresh writes one or two runs; a
    /// first sync on a new phone writes the whole archive, and that archive is part 2's
    /// review card, not something to re-read here run by run (#37's lesson: no step after
    /// the write may scale with the size of the archive).
    static let ingestCheckLimit = 10

    /// The runs a sync just wrote that are worth one distance-sample read, newest first.
    ///
    /// Only rows this pass actually wrote — `SyncPass.confirmedWrites` — so the archive is
    /// never re-read: a run already stored is never a candidate again. Runs too short to
    /// clear `minimumUnrecordedStopS` cannot be corrected and cost nothing, and corrected
    /// runs are the athlete's word.
    static func ingestTargets(written: [RunSummary], limit: Int = ingestCheckLimit) -> [RunSummary] {
        written
            .filter { !$0.corrected && $0.source == WorkoutRow.source && $0.durationS > minimumUnrecordedStopS }
            .sorted { $0.start > $1.start }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
