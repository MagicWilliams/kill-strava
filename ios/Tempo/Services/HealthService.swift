import Foundation
import HealthKit

/// Reads runs from Apple Health and syncs them to Supabase.
///
/// v1 is HealthKit-only: this captures runs recorded by Apple Watch and most
/// Garmin/Coros devices that write into Health. Direct Strava/Garmin sync comes later.
@MainActor
final class HealthService: ObservableObject {
    static let isAvailable = HKHealthStore.isHealthDataAvailable()

    private let store = HKHealthStore()

    @Published var lastSyncCount: Int = 0

    /// Ask for read access to workouts + the quantities we derive metrics from.
    func requestAuthorization() async throws {
        guard Self.isAvailable else { return }
        let read: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning),
        ]
        try await store.requestAuthorization(toShare: [], read: read)
    }

    /// Fetch running workouts since a date (default: last 18 weeks — a full block).
    func fetchRuns(since: Date? = nil) async throws -> [HKWorkout] {
        let start = since ?? Calendar.current.date(byAdding: .weekOfYear, value: -18, to: .now)
        let typePredicate = HKQuery.predicateForWorkouts(with: .running)
        let datePredicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [typePredicate, datePredicate])
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

    /// Pull from Health and upsert into Supabase. Idempotent on (user, source, HK uuid).
    @discardableResult
    func sync() async throws -> Int {
        guard let userID = Supa.userID?.uuidString else { return 0 }
        let workouts = try await fetchRuns()
        let inserts = workouts.map { map($0, userID: userID) }
        guard !inserts.isEmpty else { lastSyncCount = 0; return 0 }
        try await Supa.client
            .from("runs")
            .upsert(inserts, onConflict: "user_id,source,external_id")
            .execute()
        lastSyncCount = inserts.count
        return inserts.count
    }

    // MARK: - Mapping

    private func map(_ w: HKWorkout, userID: String) -> RunInsert {
        let meters = Int(w.totalDistance?.doubleValue(for: .meter()) ?? 0)
        let seconds = Int(w.duration)
        let miles = Double(meters) / 1609.34
        let pacePerMile = miles > 0 ? Int(Double(seconds) / miles) : nil

        return RunInsert(
            user_id: userID,
            source: "healthkit",
            external_id: w.uuid.uuidString,
            start_time: w.startDate,
            distance_m: meters,
            duration_s: seconds,
            avg_pace_sec: pacePerMile,
            avg_hr: nil   // TODO: derive from heart-rate samples / workout statistics
        )
    }
}
