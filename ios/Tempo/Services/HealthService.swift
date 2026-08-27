import Foundation
import HealthKit

/// Reads runs from Apple Health and syncs them to Supabase.
///
/// v1 is HealthKit-only: this captures runs recorded by Apple Watch and most
/// Garmin/Coros devices that write into Health. Direct Strava/Garmin sync comes later.
@MainActor
final class HealthService {
    static let isAvailable = HKHealthStore.isHealthDataAvailable()

    private let store = HKHealthStore()

    /// Ask for read access to workouts + the quantities we derive metrics from.
    func requestAuthorization() async throws {
        guard Self.isAvailable else { return }
        let read: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning),
            // Run Detail page:
            HKSeriesType.workoutRoute(),          // GPS route → map + elevation
            HKQuantityType(.stepCount),           // cadence
            HKQuantityType(.activeEnergyBurned),  // calories
        ]
        try await store.requestAuthorization(toShare: [], read: read)
    }

    /// Fetch running workouts, newest first. `since: nil` = full history.
    func fetchRuns(since: Date? = nil) async throws -> [HKWorkout] {
        var predicates = [HKQuery.predicateForWorkouts(with: .running)]
        if let since {
            predicates.append(HKQuery.predicateForSamples(withStart: since, end: nil, options: []))
        }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    /// Compact summaries for the UI. Avg HR comes from the workout's own statistics
    /// (present for Apple Watch and Garmin-written workouts alike, when HR was recorded).
    func fetchSummaries(since: Date? = nil) async throws -> [RunSummary] {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return try await fetchRuns(since: since)
            .map { workout in
                let meters = Int(workout.totalDistance?.doubleValue(for: .meter()) ?? 0)
                let hr = workout.statistics(for: HKQuantityType(.heartRate))?
                    .averageQuantity()?.doubleValue(for: bpm)
                // Two clocks, both straight off the workout record: `duration` is the time
                // the workout was actually running (HealthKit excludes paused stretches),
                // and start→end is the wall clock. They differ only when the athlete
                // stopped. See TimeAccounting.
                return RunSummary(
                    id: workout.uuid,
                    start: workout.startDate,
                    distanceM: meters,
                    durationS: Int(workout.duration),
                    elapsedS: Int(workout.endDate.timeIntervalSince(workout.startDate)),
                    avgHR: hr.map { Int($0.rounded()) },
                    externalID: workout.uuid.uuidString
                )
            }
            .filter { $0.distanceM > 200 }   // drop GPS blips / accidental starts
    }

    /// Ingest into Supabase — INSERT-ONLY (dedupe on user/source/HK-uuid, existing rows
    /// untouched) so user corrections in `runs` survive every re-sync.
    ///
    /// Second dedupe layer: Garmin re-exports the SAME run as a brand-new HKWorkout
    /// (new uuid) whenever its Health settings change — uuid dedupe can't catch that,
    /// so any candidate starting within ±5 min of an already-recorded run is skipped.
    @discardableResult
    func sync(_ summaries: [RunSummary], existing: [RunSummary]) async throws -> Int {
        guard let userID = Supa.userID?.uuidString, !summaries.isEmpty else { return 0 }

        // Dedupe rule lives in RunDedupe (pure + unit-tested) — see that file for why
        // the uuid constraint alone is not enough.
        let reconciled = RunDedupe.reconcile(candidates: summaries, existing: existing)
        var kept = reconciled.inserts

        // The Garmin re-export signature: a large batch collapsing to almost nothing.
        // Silent when healthy (a normal refresh drops everything it already has); the
        // agent looks for the shape where many candidates arrive and many are dropped,
        // which is what a settings-change re-export looks like from in here.
        let dropped = summaries.count - kept.count
        if dropped > 0 && summaries.count >= 5 {
            Telemetry.info("sync.dedupe_dropped", "re-export suspected",
                           context: ["candidates": "\(summaries.count)",
                                     "dropped": "\(dropped)",
                                     "kept": "\(kept.count)"])
        }

        // A dropped twin sometimes carries the run's other clock. Enriching an existing row
        // with it is safe — it only fills a column that was empty.
        await patchElapsed(reconciled.elapsedPatches)

        // The mirror case is not safe and is not automated: the stored row holds the LONGER
        // duration, so its "moving time" is really elapsed and its pace has been reading
        // slow. Correcting it rewrites history, so it gets reported and left alone.
        if !reconciled.suspectedElapsedStored.isEmpty {
            Telemetry.info("sync.elapsed_stored_as_moving", "rows whose duration looks like elapsed time",
                           context: ["count": "\(reconciled.suspectedElapsedStored.count)",
                                     "ids": reconciled.suspectedElapsedStored.prefix(10)
                                        .map(\.uuidString).joined(separator: ",")])
        }

        guard !kept.isEmpty else { return 0 }

        // Garmin doesn't associate HR with its workouts — enrich new rows from the
        // time window before they're written (kept is small: only new runs).
        for i in kept.indices where kept[i].avgHR == nil {
            let end = kept[i].start.addingTimeInterval(TimeInterval(kept[i].durationS))
            kept[i].avgHR = await windowAverageHR(start: kept[i].start, end: end)
        }

        let inserts = kept.map { run in
            RunInsert(
                user_id: userID,
                source: "healthkit",
                external_id: run.id.uuidString,
                start_time: run.start,
                distance_m: run.distanceM,
                duration_s: run.durationS,
                elapsed_duration_s: run.elapsedS,
                avg_pace_sec: run.paceSecPerMile,
                avg_hr: run.avgHR
            )
        }
        try await Supa.client
            .from("runs")
            .upsert(inserts, onConflict: "user_id,source,external_id", ignoreDuplicates: true)
            .execute()
        return inserts.count
    }

    /// Fill `elapsed_duration_s` on rows that were ingested before it existed.
    ///
    /// Purely additive: only ever writes a column that is currently null, never touches
    /// `duration_s`, and skips corrected rows (the athlete's edit is the record). Failures
    /// are ignored on purpose — a missing elapsed time costs a line on the detail page,
    /// and the next refresh tries again.
    private func patchElapsed(_ patches: [UUID: Int]) async {
        guard !patches.isEmpty else { return }
        struct Patch: Encodable { let elapsed_duration_s: Int }
        for (id, seconds) in patches {
            _ = try? await Supa.client
                .from("runs")
                .update(Patch(elapsed_duration_s: seconds))
                .eq("id", value: id.uuidString)
                .is("elapsed_duration_s", value: nil)
                .execute()
        }
    }

    /// Backfill elapsed time for the archive, from the workouts this refresh already read.
    ///
    /// The sync reads every workout in Health on every refresh anyway (that is its own
    /// problem — see issue #37), so the wall clock for a five-year-old run is already in
    /// memory here. Matching it to the stored row by HealthKit uuid costs nothing extra:
    /// no additional HealthKit queries, one small update per row that is missing it.
    ///
    /// Capped per refresh so a first run doesn't fire two thousand updates; a handful of
    /// refreshes clear the backlog and then it never does anything again.
    func backfillElapsed(_ dbRuns: [RunSummary], from summaries: [RunSummary], limit: Int = 200) async -> [UUID: Int] {
        let byExternalID = Dictionary(
            summaries.compactMap { s in s.externalID.map { ($0, s) } },
            uniquingKeysWith: { first, _ in first }
        )
        var patches: [UUID: Int] = [:]
        for run in dbRuns where run.elapsedS == nil && !run.corrected && run.source == "healthkit" {
            if patches.count >= limit { break }
            guard let ext = run.externalID, let match = byExternalID[ext],
                  let elapsed = match.elapsedS, elapsed > run.durationS else { continue }
            patches[run.id] = elapsed
        }
        await patchElapsed(patches)
        return patches
    }

    /// Repair pass: recent DB rows that predate HR enrichment get their avg HR filled
    /// from HealthKit's time window. Capped per refresh so sync stays snappy; a few
    /// refreshes clear the backlog. Corrected rows are never touched (coach-set values).
    func backfillMissingHR(_ dbRuns: [RunSummary], limit: Int = 25) async -> [UUID: Int] {
        guard Self.isAvailable else { return [:] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .now
        var updated: [UUID: Int] = [:]
        for run in dbRuns where run.avgHR == nil && !run.corrected
            && run.source == "healthkit" && run.start >= cutoff {
            if updated.count >= limit { break }
            let end = run.start.addingTimeInterval(TimeInterval(run.durationS))
            guard let bpm = await windowAverageHR(start: run.start, end: end) else { continue }
            struct Patch: Encodable { let avg_hr: Int }
            if (try? await Supa.client.from("runs").update(Patch(avg_hr: bpm))
                .eq("id", value: run.id.uuidString).execute()) != nil {
                updated[run.id] = bpm
            }
        }
        return updated
    }

    /// Average HR over a time window — how Garmin-written runs get their number.
    private func windowAverageHR(start: Date, end: Date) async -> Int? {
        await withCheckedContinuation { cont in
            let query = HKStatisticsQuery(
                quantityType: HKQuantityType(.heartRate),
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                options: .discreteAverage
            ) { _, stats, _ in
                let bpm = stats?.averageQuantity()?
                    .doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                cont.resume(returning: bpm.map { Int($0.rounded()) })
            }
            store.execute(query)
        }
    }
}
