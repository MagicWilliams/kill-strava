import Foundation

/// What happens to a run recorded in Tempo once Apple Health has it (#122).
///
/// Before the recorder, a run reached Tempo only when the HealthKit sync next ran. A run
/// recorded *here* should be on Today the moment it is saved, so the recorder writes the
/// `runs` row itself — and writes **exactly the row the sync would have written**, through the
/// same `WorkoutRow` mapping and the same `RunDedupe` rule. That is what makes the shortcut
/// safe: when the sync later reads the same workout out of Health, it finds the row already
/// there and drops it as `droppedAlreadyStored`, the boring case, instead of inserting it again.
///
/// **Apple Health is the source of truth.** The row is a convenience and the queue below is
/// a convenience on top of it. If both are lost, the sync still ingests the run from Health,
/// a refresh later. What only the queue can save is the journal — the athlete's RPE, notes
/// and photo exist nowhere else until a row exists to hang them on.
///
/// Pure. `Services/RecordedRunSaver.swift` does the reads, the write and the disk.
enum RecordedRunSave {

    /// What writing this workout means, given the live rows that start near it.
    enum Decision: Equatable {
        /// New: write this row. It is the row the sync would write.
        case insert(RunInsert)
        /// The row for this exact workout already exists — the sync, or an earlier attempt
        /// whose answer was lost, got there first. Nothing to write; the journal goes here.
        case alreadyStored(rowID: UUID)
        /// Another run already holds this start time — say a Garmin on the wrist recorded the
        /// same outing and its copy synced first. The sync would drop this workout as the same
        /// run, so the recorder does too, and the journal goes on the run that is there.
        case sameRunAs(rowID: UUID)
        /// At or under `WorkoutRow.minimumDistanceM`: the sync would never write it, so
        /// neither does the recorder. It stays in Apple Health.
        case tooShort
    }

    /// Decide against `nearby`: live rows (not superseded) starting within the dedupe window
    /// of the workout. Rows further away cannot change the answer, which is why the service
    /// only reads a ten-minute slice of the archive rather than all of it.
    ///
    /// The dedupe is `RunDedupe.reconcile` itself, not a copy of its rule: a recorded run must
    /// be dropped in precisely the cases the sync would drop it, or the two would disagree
    /// about whether the run exists.
    static func decide(
        _ workout: WorkoutRow.Workout,
        nearby: [RunSummary],
        userID: String
    ) -> Decision {
        let summary = WorkoutRow.summary(workout)
        guard WorkoutRow.isRun(summary) else { return .tooShort }

        if let same = nearby.first(where: {
            $0.source == WorkoutRow.source && $0.externalID == summary.externalID
        }) {
            return .alreadyStored(rowID: same.id)
        }
        if let kept = RunDedupe.reconcile(candidates: [summary], existing: nearby).inserts.first {
            return .insert(WorkoutRow.corrected(WorkoutRow.insert(kept, userID: userID), by: workout))
        }
        // reconcile drops a lone candidate only when a row sits inside the window, so this
        // finds one — the first, the same scan order reconcile matched it in.
        if let twin = nearby.first(where: {
            abs($0.start.timeIntervalSince(summary.start)) < RunDedupe.windowSeconds
        }) {
            return .sameRunAs(rowID: twin.id)
        }
        return .insert(WorkoutRow.corrected(WorkoutRow.insert(summary, userID: userID), by: workout))
    }

    /// What to write onto a row that was already there (`.alreadyStored`) when the workout
    /// carries a console correction (#116), or nil when there is nothing to add.
    ///
    /// The case this is for: a treadmill run saved with no signal in a basement gym. It is
    /// queued, and by the time the retry runs the sync has ingested the same workout from
    /// Health — with the console's distance, because that is what is in the workout, but
    /// unmarked, because the sync reads no journal and no correction. Without this the run
    /// would read as the phone's own number that happened to be right.
    ///
    /// The service applies it only where `corrected` is still false, so a row the coach has
    /// amended since keeps his correction and its `original`.
    static func correctionPatch(for workout: WorkoutRow.Workout) -> CorrectionPatch? {
        guard let c = workout.correction else { return nil }
        let row = WorkoutRow.insert(WorkoutRow.summary(workout), userID: "")
        return CorrectionPatch(
            distance_m: row.distance_m,
            avg_pace_sec: row.avg_pace_sec,
            correction_note: c.note,
            original: WorkoutRow.original(row, estimateM: c.estimateM)
        )
    }

    struct CorrectionPatch: Encodable, Equatable {
        let distance_m: Int
        let avg_pace_sec: Int?
        var corrected = true
        let correction_note: String
        let original: RunInsert.Original
    }

    /// The slice of the archive `decide` needs: from one window before the start to one after.
    static func nearbyRange(for workout: WorkoutRow.Workout) -> ClosedRange<Date> {
        workout.start.addingTimeInterval(-RunDedupe.windowSeconds)
            ... workout.start.addingTimeInterval(RunDedupe.windowSeconds)
    }

    // MARK: - The retry queue

    /// A recorded run whose row has not landed yet, persisted until it does.
    ///
    /// Written to disk *before* the first attempt, not after a failure: if iOS kills the app
    /// between the Health save and the row write, the next launch still has the journal.
    struct Pending: Codable, Equatable {
        var workout: WorkoutRow.Workout
        var journal: RunJournalEntry
        /// The photo, already resized for upload — a `UIImage` does not survive a relaunch.
        var photoJPEG: Data?
        var queuedAt: Date
    }

    /// Add or replace. One entry per workout: saving the same workout twice (a retry tap, a
    /// relaunch mid-save) keeps the newer journal and never queues two writes.
    static func enqueue(_ pending: Pending, into queue: [Pending]) -> [Pending] {
        queue.filter { $0.workout.uuid != pending.workout.uuid } + [pending]
    }

    static func removing(_ uuid: UUID, from queue: [Pending]) -> [Pending] {
        queue.filter { $0.workout.uuid != uuid }
    }

    /// After a failed attempt: keep it for the next try, or let it go.
    ///
    /// Same line as the journal's retries (`RunJournalPayload.isRetryable`): no answer, 408,
    /// 429 and 5xx are "not now" — the dead spot at the end of a run this queue exists for —
    /// and stay queued with no expiry, because the journal has nowhere else to live. Any other
    /// 4xx is a "no" that will still be a "no" next launch; retrying it forever would make
    /// every refresh fail the same way. Dropping one loses only the journal: the run itself is
    /// in Health and the sync ingests it.
    static func keepsAfterFailure(statusCode: Int?) -> Bool {
        RunJournalPayload.isRetryable(statusCode: statusCode)
    }
}
