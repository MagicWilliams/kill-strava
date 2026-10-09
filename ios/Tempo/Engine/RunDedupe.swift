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

// MARK: - Overlapping runs, for a human (#30)

/// The duplicates no rule may resolve.
///
/// Migrations 0008 and 0009 retired every pair that is a duplicate *by construction* —
/// identical distance to the meter. What is left are live runs that physically overlap in
/// time yet disagree about what happened: two devices recording one outing, a run stored
/// whole and as its splits, a watch left running after the finish. 2023-11-19 is the case
/// that rules out automation: the marathon (26.68 mi / 188 min, 7:03/mi) sits beside the
/// blob of the watch left running afterwards (27.59 mi / 304 min, HR 119), and both "keep
/// the longest" and "keep the one with HR" delete the race.
///
/// So this finds pairs and never ranks them. Which run survives is the athlete's call, made
/// one pair at a time on the review screen; a pair he has already ruled on — including
/// "both are real" — must never come back, or the queue is endless.
extension RunDedupe {

    /// A pair of runs, independent of which one is passed first. `low` < `high` in the
    /// database's uuid ordering, which is what `run_overlap_reviews` is keyed on (its check
    /// constraint enforces `run_a < run_b`). Postgres compares uuids bytewise, which is the
    /// same order as comparing the hex strings, so the string comparison here agrees.
    struct OverlapKey: Hashable {
        let low: UUID
        let high: UUID

        init(_ x: UUID, _ y: UUID) {
            if x.uuidString < y.uuidString {
                low = x; high = y
            } else {
                low = y; high = x
            }
        }
    }

    /// Two live runs whose clocks overlap. `earlier` is the one that started first — the
    /// left column on the review screen. Nothing here says which one is right.
    struct OverlapPair: Identifiable, Equatable {
        let earlier: RunSummary
        let later: RunSummary

        var key: OverlapKey { OverlapKey(earlier.id, later.id) }
        var id: OverlapKey { key }
    }

    /// What the athlete said about a pair.
    enum OverlapVerdict: Equatable {
        /// This run is the record; the other one in the pair is retired.
        case keep(UUID)
        /// Two separate runs that happen to overlap. Nothing is retired.
        case bothReal
    }

    /// A verdict, translated into the writes it implies.
    struct OverlapResolution: Equatable {
        let key: OverlapKey
        /// `run_overlap_reviews.decision`: `kept_a` / `kept_b` name the key's `low` / `high`
        /// side, so the stored row means the same thing however the screen laid it out.
        let decision: String
        /// The row that gets `superseded_by = kept`, or nil for "both are real".
        let retire: UUID?
        let kept: UUID?
    }

    /// The writes a verdict implies — nil if it names a run that is not in the pair, which is
    /// a bug and must never become a write against someone else's run.
    static func resolution(for pair: OverlapPair, _ verdict: OverlapVerdict) -> OverlapResolution? {
        let key = pair.key
        switch verdict {
        case .bothReal:
            return OverlapResolution(key: key, decision: "both_real", retire: nil, kept: nil)
        case .keep(let id):
            guard id == key.low || id == key.high else { return nil }
            let retire = id == key.low ? key.high : key.low
            return OverlapResolution(
                key: key,
                decision: id == key.low ? "kept_a" : "kept_b",
                retire: retire,
                kept: id
            )
        }
    }

    /// Live runs that overlap and have not been reviewed, newest first.
    ///
    /// Overlap: the later run starts before the earlier one ends (`start + durationS`), the
    /// same test as query 4 at the bottom of migration 0009 — with one difference. That query
    /// pairs `a.id < b.id` *and* requires `b` to start no earlier than `a`, so a pair whose
    /// earlier run happens to hold the larger uuid is never found. Here the pair is ordered by
    /// time first and only keyed by id, so every overlap surfaces exactly once.
    ///
    /// - Parameters:
    ///   - runs: the **live** archive — `superseded_by is null`, as `RunStore` reads it. A
    ///     retired row is not a run any more, so it cannot be half of a pair; that is what
    ///     makes a cluster of three collapse correctly once one of them is retired.
    ///   - reviewed: pairs the athlete has already ruled on, from `run_overlap_reviews`.
    ///
    /// Corrected runs are deliberately included. An edit proves the athlete looked at the
    /// numbers on one row; it says nothing about whether a twin of that run also exists.
    static func unresolvedOverlaps(
        in runs: [RunSummary],
        reviewed: Set<OverlapKey>
    ) -> [OverlapPair] {
        let ordered = runs.sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.id.uuidString < $1.id.uuidString
        }
        var pairs: [OverlapPair] = []
        for (i, a) in ordered.enumerated() {
            let end = a.start.addingTimeInterval(TimeInterval(max(a.durationS, 0)))
            var j = i + 1
            // Sorted by start, so the first run starting at or after `end` closes the scan.
            while j < ordered.count, ordered[j].start < end {
                let pair = OverlapPair(earlier: a, later: ordered[j])
                if !reviewed.contains(pair.key) { pairs.append(pair) }
                j += 1
            }
        }
        return pairs.sorted {
            if $0.earlier.start != $1.earlier.start { return $0.earlier.start > $1.earlier.start }
            return $0.later.start > $1.later.start
        }
    }
}
