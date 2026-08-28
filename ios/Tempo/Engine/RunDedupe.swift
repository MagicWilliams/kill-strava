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
/// **Not every near-simultaneous pair is waste.** A third case hides inside layer 2: one run
/// exported against both of its clocks, moving time on one record and elapsed on the other.
/// Those are still one run, so one row is still correct — but the second record carries a
/// number the first does not, and the old rule threw it away. `reconcile` folds it in
/// instead. See `TimeAccounting`.
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
        reconcile(candidates: candidates, existing: existing, window: window).inserts
    }

    /// What a batch of HealthKit candidates means for what we already hold.
    struct Reconciliation: Equatable {
        /// Genuinely new runs, with any second clock in the same batch already folded in.
        var inserts: [RunSummary] = []
        /// Existing row id → the elapsed seconds it was missing, learned from a dropped twin.
        var elapsedPatches: [UUID: Int] = [:]
        /// Existing rows whose stored duration is *longer* than the twin that just arrived —
        /// meaning the row holds elapsed time in the moving-time column, and its pace has
        /// been reading slow. Reported, never auto-corrected: see below.
        var suspectedElapsedStored: [UUID] = []

        /// Candidates dropped that we already hold under that exact HealthKit uuid. The
        /// boring majority of every single refresh — ~1,690 of 2,038 on David's phone — and
        /// the reason the drop count on its own says nothing. Counted, not reported.
        var droppedAlreadyStored: Int = 0

        /// Candidates dropped by the start-time window while carrying a uuid that has never
        /// been stored. This, and only this, is the Garmin re-export signal: the same run
        /// wearing a new id. `SyncPass.reExportSignal` decides when it is worth an event.
        var droppedUnknownUUID: Int = 0

        /// Which of the two buckets a dropped candidate belongs in.
        fileprivate mutating func countDrop(_ candidate: RunSummary, knownIDs: Set<String>) {
            if let ext = candidate.externalID, knownIDs.contains(ext) {
                droppedAlreadyStored += 1
            } else {
                droppedUnknownUUID += 1
            }
        }
    }

    /// Dedupe, but keep the information the old rule threw away.
    ///
    /// The original rule dropped every near-simultaneous candidate on the floor. That is
    /// right for a Garmin re-export — the copy is identical and carries nothing new — but
    /// wrong for the case where the *same run's two clocks* arrive as two workouts: moving
    /// time on one, elapsed on the other, same distance to the meter. Dropping one there
    /// discards a real number and, worse, keeps whichever of the two HealthKit happened to
    /// return first. That is how a run ends up displaying its elapsed time as its pace.
    ///
    /// So a dropped candidate is now inspected before it is discarded, and if it is the
    /// other clock of a run we are keeping, its duration is folded in — shorter becomes
    /// moving, longer becomes elapsed. See `TimeAccounting.isSameRunTwoClocks` for why the
    /// test is exact-distance rather than approximate.
    ///
    /// One case is deliberately left for a human: if the row already in the database holds
    /// the *longer* duration, then history has been storing elapsed as moving, and fixing it
    /// means rewriting a number the athlete has been looking at for years. This reports it
    /// and changes nothing.
    static func reconcile(
        candidates: [RunSummary],
        existing: [RunSummary],
        window: TimeInterval = windowSeconds
    ) -> Reconciliation {
        var result = Reconciliation()
        // Which candidates are already ours by uuid. The DB's unique constraint catches
        // these anyway; knowing *which* drops they were is what keeps the re-export signal
        // from firing on a perfectly healthy refresh.
        let knownIDs = Set(existing.compactMap(\.externalID))

        for candidate in candidates {
            let isNear = { (other: RunSummary) in
                abs(other.start.timeIntervalSince(candidate.start)) < window
            }

            if let match = existing.first(where: isNear) {
                // Already in the database. Learn the other clock from it if that's what this is.
                if isOtherClock(match, candidate) && !match.corrected {
                    if candidate.durationS > match.durationS {
                        result.elapsedPatches[match.id] = candidate.durationS
                    } else {
                        result.suspectedElapsedStored.append(match.id)
                    }
                }
                result.countDrop(candidate, knownIDs: knownIDs)
                continue
            }

            if let i = result.inserts.firstIndex(where: isNear) {
                // Both copies arrived in this batch — merge rather than drop.
                if isOtherClock(result.inserts[i], candidate) {
                    result.inserts[i] = merged(result.inserts[i], candidate)
                }
                result.countDrop(candidate, knownIDs: knownIDs)
                continue
            }

            result.inserts.append(candidate)
        }
        return result
    }

    /// Same run, two clocks — and neither already carries an elapsed time of its own.
    private static func isOtherClock(_ a: RunSummary, _ b: RunSummary) -> Bool {
        a.elapsedS == nil && b.elapsedS == nil
            && TimeAccounting.isSameRunTwoClocks(
                distanceA: a.distanceM, startA: a.start, durationA: a.durationS,
                distanceB: b.distanceM, startB: b.start, durationB: b.durationS
            )
    }

    /// One run from two records of it: the shorter clock is moving, the longer is elapsed.
    private static func merged(_ a: RunSummary, _ b: RunSummary) -> RunSummary {
        let moving = min(a.durationS, b.durationS)
        let elapsed = max(a.durationS, b.durationS)
        return RunSummary(
            id: a.id,
            start: a.start,
            distanceM: a.distanceM,
            durationS: moving,
            elapsedS: elapsed,
            avgHR: a.avgHR ?? b.avgHR,      // whichever record actually carried heart rate
            corrected: a.corrected,
            source: a.source,
            externalID: a.externalID
        )
    }
}
