import CoreLocation
import HealthKit
import XCTest
@testable import Tempo

/// The recorder service end to end, with HealthKit and GPS replaced by fakes (#114).
///
/// What these pin is the wiring: that the reducer's transitions reach the workout session in
/// the right order, that the distance in Health is the distance the athlete watched, that
/// the route is the fixes the distance used, and above all that nothing HealthKit or Core
/// Location does on its own (a failed session, revoked location) stops, saves or discards a
/// run. Chicago, 11 Oct 2026, was lost to a recorder that stopped by itself.
@MainActor
final class WorkoutRecorderTests: XCTestCase {

    // MARK: - Fakes

    @MainActor
    final class FakeSession: WorkoutSessionDriving {
        enum Call: Equatable {
            case prepare, begin(Date), pause(Date), resume(Date), stop(Date)
            case route(Int), distance(Double), finish, discard
        }
        var onSignal: ((WorkoutSessionSignal) -> Void)?
        var calls: [Call] = []
        var beginMetadata: [String: Any] = [:]
        var finishMetadata: [String: Any] = [:]
        var route: [CLLocation] = []
        var distanceWritten = 0.0
        var failPrepare = false
        var failFinishes = 0
        let workoutID = UUID()

        struct Refused: Error {}

        func prepare() throws {
            if failPrepare { throw Refused() }
            calls.append(.prepare)
        }
        func begin(at date: Date, metadata: [String: Any]) async throws {
            beginMetadata = metadata
            calls.append(.begin(date))
        }
        func pause(at date: Date) { calls.append(.pause(date)) }
        func resume(at date: Date) { calls.append(.resume(date)) }
        func stop(at date: Date) async throws { calls.append(.stop(date)) }
        func addRoute(_ locations: [CLLocation]) async throws {
            route += locations
            calls.append(.route(locations.count))
        }
        func addDistance(meters: Double, from start: Date, to end: Date) async throws {
            XCTAssertLessThanOrEqual(start, end)
            distanceWritten += meters
            calls.append(.distance(meters))
        }
        func finish(metadata: [String: Any]) async throws -> FinishedWorkout {
            calls.append(.finish)
            if failFinishes > 0 { failFinishes -= 1; throw Refused() }
            finishMetadata = metadata
            return FinishedWorkout(id: workoutID, workout: nil)
        }
        func discard() async { calls.append(.discard) }

        var finishes: Int { calls.filter { $0 == .finish }.count }
        var endedOrThrownAway: Bool {
            calls.contains { if case .stop = $0 { true } else { $0 == .finish || $0 == .discard } }
        }
    }

    @MainActor
    final class FakeLocation: RunLocationStreaming {
        var onLocations: (([CLLocation]) -> Void)?
        var onAccess: ((LocationAccess) -> Void)?
        var isOn = false
        var starts = 0
        func start() { isOn = true; starts += 1 }
        func stop() { isOn = false }
        func deliver(_ locations: [CLLocation]) { onLocations?(locations) }
    }

    // MARK: - Fixtures

    private let t0 = ISO8601DateFormatter().date(from: "2026-10-11T12:30:00Z")!
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private var now = Date.distantPast
    private var session: FakeSession!
    private var location: FakeLocation!
    private var logged: [String] = []
    private var checkpoints: [RecorderCheckpoint] = []
    private var saved: [RecordedRun] = []
    private var kindsMade: [RecorderState.RunKind] = []

    private let tempo = RecorderState.SessionTarget(sessionID: UUID(), type: "tempo", title: "6 mi tempo",
                                                    distanceM: 9656, paceSecPerMile: 450)

    override func setUp() async throws {
        now = t(-3)
        session = FakeSession()
        location = FakeLocation()
        logged = []
        checkpoints = []
        saved = []
        kindsMade = []
    }

    private func makeRecorder(units: Units = .km) -> WorkoutRecorder {
        let recorder = WorkoutRecorder(
            makeSession: { [unowned self] kind in kindsMade.append(kind); return session! },
            location: location,
            units: { units },
            clock: { [unowned self] in now },
            tickInterval: nil,
            log: { [unowned self] event, _ in logged.append(event) }
        )
        recorder.onCheckpoint = { [unowned self] in checkpoints.append($0) }
        recorder.onSaved = { [unowned self] in saved.append($0) }
        return recorder
    }

    private func started(_ kind: RecorderState.RunKind = .outdoor, target: RecorderState.SessionTarget? = nil,
                         units: Units = .km) async -> WorkoutRecorder {
        let recorder = makeRecorder(units: units)
        now = t(-3)
        recorder.send(.start(RecorderState.Setup(kind: kind, target: target ?? tempo), at: now))
        now = t(0)
        recorder.send(.countdownDone(at: now))
        await recorder.settled()
        return recorder
    }

    private let lat0 = 41.8756, lon0 = -87.6244
    private var mPerDegLat: Double { TrackMath.earthRadiusM * .pi / 180 }

    /// One fix a second heading north from `north0` metres, `east` metres east, at a steady pace.
    private func line(from s0: Double, seconds: Double, secPerKm: Double,
                      north0: Double = 0, east: Double = 0) -> [CLLocation] {
        stride(from: 0.0, through: seconds, by: 1).map { s in
            let north = north0 + s * 1000 / secPerKm
            let lon = lon0 + east / (mPerDegLat * cos(lat0 * .pi / 180))
            return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat0 + north / mPerDegLat, longitude: lon),
                              altitude: 180, horizontalAccuracy: 5, verticalAccuracy: 4,
                              timestamp: t(s0 + s))
        }
    }

    /// Deliver fixes one at a time, ticking the recorder's clock with each, like a real run.
    private func run(_ recorder: WorkoutRecorder, _ fixes: [CLLocation]) {
        for fix in fixes {
            now = fix.timestamp
            location.deliver([fix])
            recorder.tick()
        }
    }

    // MARK: - A whole run

    /// A 10 K-ish morning: 2 km, a two-minute stop at a fountain 300 m off the route, 1 km
    /// more, end, save. Every HealthKit call in order, and Health's distance equal to the
    /// number on screen.
    func testAnOutdoorRunFromStartToHealth() async throws {
        let recorder = makeRecorder()

        recorder.send(.start(RecorderState.Setup(kind: .outdoor, target: tempo), at: now))
        XCTAssertEqual(session.calls, [.prepare])
        XCTAssertEqual(kindsMade, [.outdoor])
        XCTAssertTrue(location.isOn, "GPS warms up during the countdown")
        let recordingID = try XCTUnwrap(recorder.recordingID)

        // A cached fix from before the gun is never measured.
        location.deliver(line(from: -60, seconds: 0, secPerKm: 300, north0: -900))
        now = t(0)
        recorder.send(.countdownDone(at: now))
        await recorder.settled()
        XCTAssertEqual(session.calls.last, .begin(t(0)))
        XCTAssertEqual(session.beginMetadata[RecordingMetadata.recordingIDKey] as? String, recordingID.uuidString,
                       "the recording identifies itself to HealthKit from the start (#115)")
        XCTAssertEqual(session.beginMetadata[HKMetadataKeyIndoorWorkout] as? Bool, false)

        let leg1 = line(from: 0, seconds: 600, secPerKm: 300)
        run(recorder, leg1)
        XCTAssertEqual(recorder.snapshot.distanceM, 2000, accuracy: 15)
        XCTAssertEqual(try XCTUnwrap(recorder.snapshot.currentPaceS), 300, accuracy: 5)
        XCTAssertEqual(recorder.snapshot.completedSplits, 1)
        XCTAssertTrue(recorder.snapshot.gpsLocked)

        now = t(601)
        recorder.send(.pause(.manual(.liveScreen), at: now))
        XCTAssertEqual(session.calls.last, .pause(t(601)))
        XCTAssertTrue(location.isOn, "GPS stays on through a pause; restarting it in the background isn't allowed")
        let atPause = recorder.snapshot.distanceM

        // Walks 300 m east to a fountain and stands there. None of it is running.
        let walk = (1...120).map { s -> CLLocation in
            let east = min(Double(s) * 1.5, 300)
            return line(from: 601 + Double(s), seconds: 0, secPerKm: 300, north0: 2000, east: east)[0]
        }
        run(recorder, walk)
        XCTAssertEqual(recorder.snapshot.distanceM, atPause, "nothing accrues while paused")
        XCTAssertNil(recorder.snapshot.currentPaceS)

        now = t(722)
        recorder.send(.resume(.manual(.liveScreen), at: now))
        XCTAssertEqual(session.calls.last, .resume(t(722)))
        let leg2 = line(from: 722, seconds: 300, secPerKm: 300, north0: 2000, east: 300)
        run(recorder, leg2)

        now = t(1023)
        recorder.send(.endRequested(.liveScreen, at: now))
        XCTAssertFalse(location.isOn, "ending stops GPS")
        await recorder.settled()
        XCTAssertEqual(session.calls.last, .stop(t(1023)), "collection ends after the last distance and route")
        XCTAssertFalse(session.calls.contains(.finish), "the save screen saves nothing until he says so")

        let shown = recorder.snapshot.distanceM
        XCTAssertEqual(shown, 3000, accuracy: 10, "2 km + 1 km, not the walk")
        XCTAssertEqual(session.distanceWritten, shown, accuracy: 0.01, "Health gets the distance he watched")
        XCTAssertEqual(recorder.snapshot.elapsedS, 1023)
        XCTAssertEqual(recorder.snapshot.movingS, 1023 - 121)

        // The route is every fix the distance used: both legs, not the walk or the cached fix.
        XCTAssertEqual(session.route.count, leg1.count + leg2.count)
        XCTAssertFalse(session.route.contains { $0.timestamp < t(0) })
        XCTAssertFalse(session.route.contains { $0.timestamp > t(601) && $0.timestamp < t(722) })

        recorder.send(.endConfirmed)
        await recorder.settled()
        XCTAssertEqual(session.finishes, 1)
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: session.workoutID))
        XCTAssertEqual(session.finishMetadata[RecordingMetadata.targetShownKey] as? Bool, true)

        let handed = try XCTUnwrap(saved.first, "the save path (#122) gets the run")
        XCTAssertEqual(handed.workoutID, session.workoutID)
        XCTAssertEqual(handed.recordingID, recordingID)
        XCTAssertEqual(handed.distanceM, shown, accuracy: 0.001)
        XCTAssertEqual(handed.clocks, TimeAccounting.Clocks(movingS: 902, elapsedS: 1023))
        XCTAssertEqual(handed.splits.filter { !$0.isPartial }.count, 3)
        XCTAssertEqual(handed.target, tempo)

        XCTAssertEqual(Array(logged.prefix(1)), ["recorder.started"])
        XCTAssertTrue(logged.contains("recorder.saved"))
        XCTAssertTrue(checkpoints.contains { $0.state.phase == .paused }, "every state change is checkpointed (#115)")

        recorder.reset()
        XCTAssertEqual(recorder.state, RecorderState())
        XCTAssertNil(recorder.recordingID)
    }

    /// Race mode saves itself at the finish (#125), stop then save, with no save screen.
    func testARaceSavesItselfAtTheFinish() async {
        let recorder = await started(.race)
        run(recorder, line(from: 0, seconds: 120, secPerKm: 240))
        now = t(121)
        recorder.send(.endRequested(.liveScreen, at: now))
        await recorder.settled()
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: session.workoutID))
        let stop = session.calls.firstIndex(of: .stop(t(121)))
        let finish = session.calls.firstIndex(of: .finish)
        XCTAssertNotNil(stop)
        XCTAssertLessThan(stop ?? .max, finish ?? .min, "collection ends before the workout is finished")
        XCTAssertEqual(session.beginMetadata[RecordingMetadata.raceKey] as? Bool, true)
    }

    // MARK: - Nothing ends a run but the athlete

    /// HealthKit failing underneath the run: the recorder goes to recovering and keeps
    /// everything. No stop, no save, no discard.
    func testASessionFailureNeverEndsTheRun() async {
        let recorder = await started()
        run(recorder, line(from: 0, seconds: 300, secPerKm: 300))
        now = t(301)
        session.onSignal?(.failed(reason: "HKErrorWorkoutSessionFailed"))
        await recorder.settled()

        XCTAssertEqual(recorder.state.phase, .recovering(since: t(301)))
        XCTAssertFalse(session.endedOrThrownAway, "nothing stopped or discarded: \(session.calls)")
        XCTAssertNotNil(recorder.lastFailure)
        XCTAssertTrue(logged.contains("recorder.session_failed"))
    }

    /// The Lock Screen can't end a run, so the session never hears about it.
    func testTheLockScreenCannotEndARun() async {
        let recorder = await started()
        now = t(600)
        recorder.send(.endRequested(.lockScreen, at: now))
        await recorder.settled()
        XCTAssertEqual(recorder.state.phase, .running)
        XCTAssertFalse(session.endedOrThrownAway)
        XCTAssertTrue(location.isOn)
    }

    /// Location turned off mid-run is logged, not a stop. The clock keeps going.
    func testRevokedLocationIsLoggedAndTheRunGoesOn() async {
        let recorder = await started()
        now = t(400)
        location.onAccess?(.denied)
        XCTAssertEqual(recorder.state.phase, .running)
        XCTAssertEqual(recorder.state.interruptions.map(\.kind), [.locationRevoked])
        XCTAssertFalse(session.endedOrThrownAway)
    }

    // MARK: - Saving

    /// A save that fails keeps the run on the save screen; Retry saves it.
    func testAFailedSaveKeepsTheRunAndRetrySavesIt() async {
        let recorder = await started()
        run(recorder, line(from: 0, seconds: 200, secPerKm: 300))
        session.failFinishes = 1
        now = t(201)
        recorder.send(.endRequested(.liveScreen, at: now))
        recorder.send(.endConfirmed)
        await recorder.settled()

        guard case .ending(.failed) = recorder.state.phase else {
            return XCTFail("expected a failed save, got \(recorder.state.phase)")
        }
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(logged.contains("recorder.save_failed"))

        recorder.send(.endConfirmed)
        await recorder.settled()
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: session.workoutID))
        XCTAssertEqual(session.finishes, 2)
        XCTAssertEqual(saved.count, 1)
    }

    func testDiscardThrowsTheWorkoutAwayAndSavesNothing() async {
        let recorder = await started()
        run(recorder, line(from: 0, seconds: 60, secPerKm: 300))
        now = t(61)
        recorder.send(.pause(.manual(.liveScreen), at: now))
        recorder.send(.discard(.liveScreen))
        await recorder.settled()

        XCTAssertEqual(recorder.state.phase, .discarded)
        XCTAssertTrue(session.calls.contains(.discard))
        XCTAssertFalse(session.calls.contains(.finish))
        XCTAssertFalse(location.isOn)
        XCTAssertTrue(saved.isEmpty)
    }

    // MARK: - Starting

    /// No session, no run: back to idle with the reason, and GPS never turned on.
    func testASessionThatWontPrepareReturnsToIdle() async {
        session.failPrepare = true
        let recorder = makeRecorder()
        recorder.send(.start(RecorderState.Setup(kind: .outdoor), at: now))
        await recorder.settled()

        XCTAssertEqual(recorder.state.phase, .idle)
        XCTAssertNotNil(recorder.lastFailure)
        XCTAssertEqual(location.starts, 0)
        XCTAssertTrue(logged.contains("recorder.session_failed"))
    }

    func testCancellingTheCountdownDiscardsThePreparedSession() async {
        let recorder = makeRecorder()
        recorder.send(.start(RecorderState.Setup(kind: .outdoor), at: now))
        recorder.send(.discard(.liveScreen))
        await recorder.settled()
        XCTAssertEqual(recorder.state.phase, .idle)
        XCTAssertEqual(session.calls, [.prepare, .discard])
        XCTAssertFalse(location.isOn)
    }

    // MARK: - Treadmill and heart rate

    /// No GPS on a treadmill: the distance is HealthKit's, nothing is written on top of it,
    /// and there is no route.
    func testATreadmillRunUsesHealthKitsDistanceAndNoGPS() async throws {
        let recorder = await started(.treadmill)
        XCTAssertEqual(location.starts, 0, "a treadmill never asks for location")
        XCTAssertEqual(session.beginMetadata[HKMetadataKeyIndoorWorkout] as? Bool, true)

        for s in stride(from: 10.0, through: 400, by: 10) {
            now = t(s)
            session.onSignal?(.distance(totalMeters: s * 1000 / 320, at: now))
            recorder.tick()
        }
        XCTAssertEqual(recorder.snapshot.distanceM, 1250, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(recorder.snapshot.currentPaceS), 320, accuracy: 1)
        XCTAssertEqual(recorder.snapshot.completedSplits, 1)

        now = t(401)
        recorder.send(.endRequested(.liveScreen, at: now))
        recorder.send(.endConfirmed)
        await recorder.settled()
        XCTAssertEqual(session.distanceWritten, 0, "HealthKit already has the treadmill's distance")
        XCTAssertTrue(session.route.isEmpty)
        XCTAssertEqual(saved.first?.distanceM ?? 0, 1250, accuracy: 0.001)
    }

    /// Heart rate shows when a strap sends it; when it stops, the tile becomes the last split.
    func testHeartRateWhenPresentLastSplitWhenNot() async {
        let recorder = await started(units: .km)
        run(recorder, line(from: 0, seconds: 330, secPerKm: 300))
        session.onSignal?(.heartRate(bpm: 158, at: now))
        recorder.refresh()
        XCTAssertEqual(recorder.snapshot.secondary, .heartRate(bpm: 158))

        now = now.addingTimeInterval(45)
        recorder.refresh()
        guard case .lastSplit(let split) = recorder.snapshot.secondary else {
            return XCTFail("strap gone: expected the last split, got \(recorder.snapshot.secondary)")
        }
        XCTAssertEqual(split.index, 1)
    }

    /// The split unit is fixed when the run starts. Changing the setting mid-run must not
    /// re-cut a run in progress.
    func testUnitsAreFixedAtTheStart() async {
        var units = Units.mi
        let recorder = WorkoutRecorder(
            makeSession: { [unowned self] _ in session! }, location: location,
            units: { units }, clock: { [unowned self] in now }, tickInterval: nil, log: { _, _ in })
        now = t(-3)
        recorder.send(.start(RecorderState.Setup(kind: .outdoor), at: now))
        now = t(0)
        recorder.send(.countdownDone(at: now))
        units = .km
        run(recorder, line(from: 0, seconds: 400, secPerKm: 300))
        XCTAssertEqual(recorder.snapshot.units, .mi)
        XCTAssertEqual(recorder.snapshot.completedSplits, 0, "1.3 km is not yet a mile")
    }

    /// A checkpoint round-trips through JSON: #115 persists exactly this.
    func testCheckpointsAreCodable() async throws {
        let recorder = await started()
        run(recorder, line(from: 0, seconds: 30, secPerKm: 300))
        let last = try XCTUnwrap(checkpoints.last)
        let decoded = try JSONDecoder().decode(RecorderCheckpoint.self, from: JSONEncoder().encode(last))
        XCTAssertEqual(decoded, last)
        XCTAssertEqual(last.recordingID, recorder.recordingID)
    }
}
