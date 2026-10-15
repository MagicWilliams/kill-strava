import CoreLocation
import Foundation
import HealthKit

/// The real `WorkoutSessionDriving`: an iPhone-native `HKWorkoutSession` with its
/// `HKLiveWorkoutBuilder` and a route builder (#114).
///
/// iOS 26 is the first release where an iPhone app can run its own workout session (before
/// it, iPhone only saw sessions mirrored from a Watch), and it is Tempo's minimum (#145).
/// The running session is also what keeps a treadmill run alive in the background, where
/// there are no location updates to do it.
///
/// Distance is always Tempo's: the data source's own distance collection is turned off and
/// Tempo writes its curve instead (`DistanceChunks`), so the run in Health is the run the
/// athlete watched. Outdoors that is `TrackMath`'s GPS curve, as he runs. On a treadmill it
/// is his step count from Core Motion, written once at Save, after the console has had its
/// say (#116, `TreadmillDistance`) — a sample in the builder can never be taken back out.
/// Heart rate is collected when a Watch or strap is paired, reported up when it arrives,
/// and never waited for.
@MainActor
final class HealthWorkoutSession: NSObject, WorkoutSessionDriving {

    var onSignal: ((WorkoutSessionSignal) -> Void)?

    private let store: HKHealthStore
    private let session: HKWorkoutSession
    private let builder: HKLiveWorkoutBuilder
    private let indoor: Bool
    private var route: HKWorkoutRouteBuilder?
    /// Whether `route` belongs to the workout builder (finished with the workout) or stands
    /// alone (finished against the saved workout afterwards).
    private var routeIsAssociated = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    /// How long `stop` waits for the session to report it has stopped before ending
    /// collection anyway. Ending the run must not hang on a callback that never comes.
    static let stopTimeout: Duration = .seconds(5)

    init(store: HKHealthStore, kind: RecorderState.RunKind) throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = kind == .treadmill ? .indoor : .outdoor

        self.store = store
        self.indoor = kind == .treadmill
        session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        builder = session.associatedWorkoutBuilder()
        builder.dataSource = Self.dataSource(store: store, configuration: configuration)
        super.init()
        session.delegate = self
        builder.delegate = self
    }

    /// Adopts a session handed back by `recoverActiveWorkoutSession`.
    private init(store: HKHealthStore, recovered: HKWorkoutSession) {
        self.store = store
        session = recovered
        builder = recovered.associatedWorkoutBuilder()
        indoor = recovered.workoutConfiguration.locationType == .indoor
        // A recovered builder comes back without a data source (Apple's iPhone workout
        // sample sets it again); without one, heart rate stops.
        builder.dataSource = Self.dataSource(store: store, configuration: recovered.workoutConfiguration)
        super.init()
        session.delegate = self
        builder.delegate = self
        if !indoor { attachRoute() }
    }

    // MARK: - Recovery hook (#115)

    /// The workout session that was running when iOS killed Tempo, if there is one. Nil when
    /// nothing was running. Kill recovery (#115) calls this on launch
    /// (`WorkoutRecorder.recoverAtLaunch`) and matches the session to its snapshot by
    /// `recordingID`.
    static func recoverActive(store: HKHealthStore) async throws -> HealthWorkoutSession? {
        guard let session = try await store.recoverActiveWorkoutSession() else { return nil }
        return HealthWorkoutSession(store: store, recovered: session)
    }

    /// The Tempo recording this session belongs to, from the metadata written at `begin`.
    var recordingID: UUID? {
        (builder.metadata[RecordingMetadata.recordingIDKey] as? String).flatMap(UUID.init(uuidString:))
    }

    /// Whether the recovered session was paused when it was recovered — `.recovered`'s
    /// argument.
    var isPaused: Bool { session.state == .paused }

    /// The builder's cumulative distance in metres, if it has one: exactly the samples Tempo
    /// wrote before the kill. Outdoors, the run so far; on a treadmill, nothing until Save.
    var distanceM: Double? {
        builder.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter())
    }

    /// What `InProgressRun.recover` needs to know about this session.
    var recovery: InProgressRun.SessionRecovery {
        InProgressRun.SessionRecovery(id: recordingID, isPaused: isPaused, distanceM: distanceM)
    }

    /// The workout a Tempo recording became, if it is already in Health.
    ///
    /// For the one kill no session survives with the run already saved: Tempo died between
    /// `finishWorkout` and clearing its snapshot, and comes back on the save screen with
    /// Retry. Without this, Retry would save the run to Health a second time.
    static func savedWorkout(recordingID: UUID, store: HKHealthStore) async -> FinishedWorkout? {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: RecordingMetadata.recordingIDKey,
            allowedValues: [recordingID.uuidString])
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)], sortDescriptors: [], limit: 1)
        guard let workout = try? await query.result(for: store).first else { return nil }
        return FinishedWorkout(id: workout.uuid, row: WorkoutRow.Workout(workout))
    }

    // MARK: - WorkoutSessionDriving

    func prepare() throws {
        session.prepare()
    }

    func begin(at date: Date, metadata: [String: Any]) async throws {
        session.startActivity(with: date)
        try await builder.beginCollection(at: date)
        try await builder.addMetadata(metadata)
        if !indoor { attachRoute() }
    }

    func pause(at date: Date) {
        session.pause()
    }

    func resume(at date: Date) {
        session.resume()
    }

    func stop(at date: Date) async throws {
        if session.state != .stopped && session.state != .ended {
            session.stopActivity(with: date)
            await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
                Task { [weak self] in
                    try? await Task.sleep(for: Self.stopTimeout)
                    self?.releaseStopWaiters()
                }
            }
        }
        // A session recovered on the save screen (#115) may already have ended collection
        // before the kill; ending it twice throws, and the save would read that as a failure.
        if builder.endDate == nil {
            try await builder.endCollection(at: date)
        }
    }

    func addRoute(_ locations: [CLLocation]) async throws {
        guard let route, !locations.isEmpty else { return }
        try await route.insertRouteData(locations)
    }

    func addDistance(meters: Double, from start: Date, to end: Date) async throws {
        let sample = HKQuantitySample(
            type: HKQuantityType(.distanceWalkingRunning),
            quantity: HKQuantity(unit: .meter(), doubleValue: meters),
            start: start, end: end
        )
        try await builder.addSamples([sample])
    }

    func finish(metadata: [String: Any]) async throws -> FinishedWorkout {
        if !metadata.isEmpty { try await builder.addMetadata(metadata) }
        guard let workout = try await builder.finishWorkout() else {
            throw RecorderSaveError.noWorkout
        }
        session.end()
        if let route, !routeIsAssociated {
            // The workout is saved; a route that fails to attach costs the map, not the run.
            do {
                try await route.finishRoute(with: workout, metadata: nil)
            } catch {
                Telemetry.error("recorder.route_finish_failed", error)
            }
        }
        return FinishedWorkout(id: workout.uuid, row: WorkoutRow.Workout(workout))
    }

    func discard() async {
        builder.discardWorkout()
        session.end()
    }

    // MARK: - Private

    private static func dataSource(store: HKHealthStore, configuration: HKWorkoutConfiguration) -> HKLiveWorkoutDataSource {
        let source = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        // Tempo writes the distance, indoors and out; HealthKit's own estimate alongside it
        // would count every metre twice. Indoors it matters twice over: whatever the data
        // source added could not be taken back when the console disagrees (#116).
        source.disableCollection(for: HKQuantityType(.distanceWalkingRunning))
        return source
    }

    /// The route builder that belongs to the workout builder, so the route is saved with the
    /// workout and survives with the builder when a killed session is recovered (#115). A
    /// standalone builder, finished against the saved workout, is the fallback.
    private func attachRoute() {
        guard route == nil else { return }
        if let associated = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder {
            route = associated
            routeIsAssociated = true
        } else {
            route = HKWorkoutRouteBuilder(healthStore: store, device: nil)
            routeIsAssociated = false
        }
    }

    private func releaseStopWaiters() {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func signal(_ s: WorkoutSessionSignal) {
        onSignal?(s)
    }
}

enum RecorderSaveError: Error {
    /// `finishWorkout` returned no workout and no error.
    case noWorkout
}

// MARK: - HealthKit callbacks

extension HealthWorkoutSession: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        guard toState == .stopped || toState == .ended else { return }
        Task { @MainActor in self.releaseStopWaiters() }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let reason = String(describing: error)
        Task { @MainActor in self.signal(.failed(reason: reason)) }
    }
}

extension HealthWorkoutSession: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let now = Date()
        var signals: [WorkoutSessionSignal] = []

        let heartRate = HKQuantityType(.heartRate)
        if collectedTypes.contains(heartRate),
           let stats = workoutBuilder.statistics(for: heartRate),
           let latest = stats.mostRecentQuantity() {
            let bpm = latest.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            signals.append(.heartRate(bpm: bpm, at: stats.mostRecentQuantityDateInterval()?.end ?? now))
        }

        guard !signals.isEmpty else { return }
        Task { @MainActor in signals.forEach(self.signal) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
