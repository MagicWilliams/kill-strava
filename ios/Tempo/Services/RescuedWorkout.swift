import CoreLocation
import Foundation
import HealthKit

/// "Save what we have" (#115): a workout built after the fact from the in-progress snapshot,
/// for the kill no workout session survived.
///
/// When iOS kills Tempo and `recoverActiveWorkoutSession` comes back empty, the live builder
/// went with the session — and with it every distance sample and route point written during
/// the run. What is left is the snapshot on disk. This rebuilds the workout from it with a
/// plain `HKWorkoutBuilder`, which takes dates in the past, so the recorder can adopt it in
/// the session's place and run its ordinary end-of-run path through it: the distance curve
/// goes in as the same `DistanceChunks` a live run writes, and the workout is finished the
/// same way. One save path, whichever way the run got there.
///
/// What it cannot get back is what the snapshot does not carry: the route (only the last few
/// fixes survive, not a map) and heart rate. A run with a hole in its map, saved, beats a run
/// with a map, lost.
///
/// Pauses go in as workout events at `stop`, so HealthKit's own duration — the moving time
/// ingest reads off `HKWorkout.duration` — is the moving time he watched, not wall time.
@MainActor
final class RescuedWorkout: WorkoutSessionDriving {

    var onSignal: ((WorkoutSessionSignal) -> Void)?

    private let builder: HKWorkoutBuilder
    private let pauses: [RecorderState.Pause]

    init(store: HKHealthStore, state: RecorderState) {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = state.kind == .treadmill ? .indoor : .outdoor
        builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        pauses = state.pauses
    }

    func prepare() throws {}

    func begin(at date: Date, metadata: [String: Any]) async throws {
        try await builder.beginCollection(at: date)
        try await builder.addMetadata(metadata)
    }

    /// Nothing is live: a rescued run is only ever ended or thrown away.
    func pause(at date: Date) {}
    func resume(at date: Date) {}

    func stop(at date: Date) async throws {
        let events = Self.pauseEvents(pauses, endingBy: date)
        if !events.isEmpty { try await builder.addWorkoutEvents(events) }
        try await builder.endCollection(at: date)
    }

    /// Not carried by the snapshot; see the type's note.
    func addRoute(_ locations: [CLLocation]) async throws {}

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
        return FinishedWorkout(id: workout.uuid, row: WorkoutRow.Workout(workout))
    }

    func discard() async {
        builder.discardWorkout()
    }

    /// One pause/resume pair per stop. A pause still open when the run ended — he was
    /// stopped when Tempo died and the run is being saved from there — runs to the end.
    private static func pauseEvents(_ pauses: [RecorderState.Pause], endingBy end: Date) -> [HKWorkoutEvent] {
        pauses.flatMap { p -> [HKWorkoutEvent] in
            let resumed = min(p.end ?? end, end)
            guard resumed > p.start else { return [] }
            return [
                HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: p.start, duration: 0), metadata: nil),
                HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: resumed, duration: 0), metadata: nil),
            ]
        }
    }
}
