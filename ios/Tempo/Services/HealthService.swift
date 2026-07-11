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
                return RunSummary(
                    id: workout.uuid,
                    start: workout.startDate,
                    distanceM: meters,
                    durationS: Int(workout.duration),
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

        var kept: [RunSummary] = []
        for var candidate in summaries {
            let dupOfExisting = existing.contains {
                abs($0.start.timeIntervalSince(candidate.start)) < 300
            }
            let dupInBatch = kept.contains {
                abs($0.start.timeIntervalSince(candidate.start)) < 300
            }
            guard !dupOfExisting && !dupInBatch else { continue }
            // Garmin doesn't associate HR with its workouts — enrich new rows from the
            // time window before they're written (kept is small: only new runs).
            if candidate.avgHR == nil {
                let end = candidate.start.addingTimeInterval(TimeInterval(candidate.durationS))
                candidate.avgHR = await windowAverageHR(start: candidate.start, end: end)
            }
            kept.append(candidate)
        }
        guard !kept.isEmpty else { return 0 }

        let inserts = kept.map { run in
            RunInsert(
                user_id: userID,
                source: "healthkit",
                external_id: run.id.uuidString,
                start_time: run.start,
                distance_m: run.distanceM,
                duration_s: run.durationS,
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
