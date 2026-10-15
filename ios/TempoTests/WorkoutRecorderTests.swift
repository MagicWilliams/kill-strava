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
        private var began: Date?
        private var stopped: Date?

        struct Refused: Error {}

        func prepare() throws {
            if failPrepare { throw Refused() }
            calls.append(.prepare)
        }
        func begin(at date: Date, metadata: [String: Any]) async throws {
            beginMetadata = metadata
            began = date
            calls.append(.begin(date))
        }
        func pause(at date: Date) { calls.append(.pause(date)) }
        func resume(at date: Date) { calls.append(.resume(date)) }
        func stop(at date: Date) async throws { stopped = date; calls.append(.stop(date)) }
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
            let start = began ?? .distantPast, end = stopped ?? start
            return FinishedWorkout(id: workoutID, row: WorkoutRow.Workout(
                uuid: workoutID, start: start, end: end, distanceM: distanceWritten,
                movingS: end.timeIntervalSince(start), avgHR: nil))
        }
        func discard() async { calls.append(.discard) }

        var finishes: Int { calls.filter { $0 == .finish }.count }
        var endedOrThrownAway: Bool {
            calls.contains { if case .stop = $0 { true } else { $0 == .finish || $0 == .discard } }
        }
    }

    @MainActor
    final class FakeMotion: RunMotionStreaming {
        var onSample: ((AutoPause.Sample) -> Void)?
        var isOn = false
        func start(from date: Date) { isOn = true }
        func stop() { isOn = false }
        func step(at: Date, speed: Double) { onSample?(AutoPause.Sample(at: at, speed: speed, source: .pedometer)) }
    }

    @MainActor
    final class FakeCues: RunCueSpeaking {
        var isEnabled = true
        var splits: [TrackMath.Split] = []
        var decisions: [AutoPause.Decision] = []
        var stops = 0
        func speakSplit(_ split: TrackMath.Split, averagePaceS: Double?, units: Units) {
            guard isEnabled else { return }
            splits.append(split)
        }
        func speak(_ decision: AutoPause.Decision) { decisions.append(decision) }
        /// Race-distance cues (#117): the distance said and the race clock at that moment.
        var races: [(meters: Double, elapsedS: Double)] = []
        func speakRaceDistance(meters: Double, elapsedS: Double, averagePaceS: Double?, units: Units) {
            races.append((meters, elapsedS))
        }
        func stop() { stops += 1 }
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
    private var motion: FakeMotion!
    private var cues: FakeCues!
    /// Every telemetry event name, #131 lines and diagnostics alike, in order.
    private var logged: [String] = []
    private var lines: [RecorderTelemetry.Line] = []
    /// What the recorder wrote for kill recovery (#115); nil is a clear.
    private var persisted: [InProgressRun?] = []
    /// What reached `RecordedRunSaver.save` (#122), and what it answers, in turn.
    private var saved: [(workout: WorkoutRow.Workout, journal: RunJournalEntry)] = []
    private var tempoAnswers: [RecordedRunSaver.Outcome] = []
    private let runID = UUID()
    private var autoPauses: [AutoPause.Decision] = []
    private var kindsMade: [RecorderState.RunKind] = []
    /// Kill recovery (#115): the workout "save what we have" rebuilds into (nil: none can be
    /// made), the states it was asked for, and what Health says a recording already became.
    private var rescue: FakeSession?
    private var rescuedFor: [RecorderState] = []
    private var inHealth: FinishedWorkout?
    /// Race mode (#117): the active goal the recorder reads, the links it asked to write, and
    /// the phase the run was in when each was asked for.
    private var goal: GoalInfo?
    private var links: [RaceFinish.Link] = []
    private var phaseAtLink: [RecorderState.Phase] = []
    private weak var current: WorkoutRecorder?

    private let tempo = RecorderState.SessionTarget(sessionID: UUID(), type: "tempo", title: "6 mi tempo",
                                                    distanceM: 9656, paceSecPerMile: 450)

    override func setUp() async throws {
        now = t(-3)
        session = FakeSession()
        location = FakeLocation()
        motion = FakeMotion()
        cues = FakeCues()
        logged = []
        lines = []
        persisted = []
        saved = []
        tempoAnswers = []
        autoPauses = []
        kindsMade = []
        rescue = nil
        rescuedFor = []
        inHealth = nil
        goal = nil
        links = []
        phaseAtLink = []
    }

    private func makeRecorder(units: @escaping () -> Units = { .km },
                              recovery: RecoverySources = .none()) -> WorkoutRecorder {
        let recorder = WorkoutRecorder(
            makeSession: { [unowned self] kind in kindsMade.append(kind); return session! },
            location: location,
            motion: motion,
            cues: { [unowned self] in cues! },
            units: units,
            saveToTempo: { [unowned self] workout, journal, _ in
                saved.append((workout, journal))
                return tempoAnswers.isEmpty ? .saved(runID: runID) : tempoAnswers.removeFirst()
            },
            goal: { [unowned self] in goal },
            linkRace: { [unowned self] link in
                links.append(link)
                if let phase = current?.state.phase { phaseAtLink.append(phase) }
            },
            clock: { [unowned self] in now },
            tickInterval: nil,
            report: { [unowned self] in lines += $0; logged += $0.map(\.event.rawValue) },
            log: { [unowned self] event, _ in logged.append(event) },
            persist: { [unowned self] in persisted.append($0) },
            recovery: recovery
        )
        recorder.onAutoPause = { [unowned self] in autoPauses.append($0) }
        current = recorder
        return recorder
    }

    private func started(_ kind: RecorderState.RunKind = .outdoor, target: RecorderState.SessionTarget? = nil,
                         units: Units = .km, autoPause: Bool = false) async -> WorkoutRecorder {
        let recorder = makeRecorder(units: { units })
        now = t(-3)
        recorder.send(.start(RecorderState.Setup(kind: kind, target: target ?? tempo, autoPause: autoPause), at: now))
        now = t(0)
        recorder.send(.countdownDone(at: now))
        await recorder.settled()
        return recorder
    }

    private let lat0 = 41.8756, lon0 = -87.6244
    private var mPerDegLat: Double { TrackMath.earthRadiusM * .pi / 180 }

    /// One fix a second heading north from `north0` metres, `east` metres east, at a steady
    /// pace, each carrying that speed the way Core Location reports it.
    private func line(from s0: Double, seconds: Double, secPerKm: Double,
                      north0: Double = 0, east: Double = 0) -> [CLLocation] {
        stride(from: 0.0, through: seconds, by: 1).map { s in
            fix(at: s0 + s, north: north0 + s * 1000 / secPerKm, east: east, speed: 1000 / secPerKm)
        }
    }

    /// One fix. `speed` negative is Core Location's "unknown".
    private func fix(at s: Double, north: Double, east: Double = 0, speed: Double) -> CLLocation {
        let lon = lon0 + east / (mPerDegLat * cos(lat0 * .pi / 180))
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat0 + north / mPerDegLat, longitude: lon),
                          altitude: 180, horizontalAccuracy: 5, verticalAccuracy: 4,
                          course: 0, speed: speed, timestamp: t(s))
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
        XCTAssertEqual(cues.stops, 1, "ending cuts off any cue and gives the music back")
        XCTAssertEqual(cues.splits.map(\.index), [1, 2], "one cue per finished kilometre; the third finishes with the run, unsaid")
        await recorder.settled()
        XCTAssertEqual(session.calls.last, .stop(t(1023)), "collection ends after the last distance and route")
        XCTAssertFalse(session.calls.contains(.finish), "the save screen saves nothing until he says so")
        XCTAssertEqual((persisted.last ?? nil)?.state.phase, .ending(.review),
                       "a run on the save screen is still written down (#115)")

        let shown = recorder.snapshot.distanceM
        XCTAssertEqual(shown, 3000, accuracy: 10, "2 km + 1 km, not the walk")
        XCTAssertEqual(session.distanceWritten, shown, accuracy: 0.01, "Health gets the distance he watched")
        XCTAssertEqual(recorder.snapshot.elapsedS, 1023)
        XCTAssertEqual(recorder.snapshot.movingS, 1023 - 121)

        // The route is every fix the distance used: both legs, not the walk or the cached fix.
        XCTAssertEqual(session.route.count, leg1.count + leg2.count)
        XCTAssertFalse(session.route.contains { $0.timestamp < t(0) })
        XCTAssertFalse(session.route.contains { $0.timestamp > t(601) && $0.timestamp < t(722) })

        let journal = RunJournalEntry(rpe: 6, feelTags: ["strong"], title: "Fountain loop")
        recorder.confirmSave(journal: journal)
        await recorder.settled()
        XCTAssertEqual(session.finishes, 1)
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: session.workoutID))
        XCTAssertEqual(session.finishMetadata[RecordingMetadata.targetShownKey] as? Bool, true)

        // Health first, then Tempo, with the workout as HealthKit saved it and his journal.
        let handed = try XCTUnwrap(saved.first, "the save path (#122) gets the run")
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(handed.workout.uuid, session.workoutID)
        XCTAssertEqual(handed.workout.distanceM ?? 0, shown, accuracy: 0.01)
        XCTAssertEqual(handed.journal, journal)
        XCTAssertEqual(recorder.savedRunID, runID, "what a race result links to (#117)")
        XCTAssertEqual(recorder.saveOutcome, .saved(runID: runID))

        XCTAssertEqual(Array(logged.prefix(1)), ["recorder.started"])
        XCTAssertTrue(logged.contains("recorder.saved"))
        XCTAssertTrue(persisted.contains { $0?.state.phase == .paused }, "every state change is written down (#115)")
        XCTAssertEqual(persisted.last, .some(nil), "in Health: the recovery snapshot is cleared")
        let savedLine = try XCTUnwrap(lines.first { $0.event == .saved }, "one line once both halves answered")
        XCTAssertNotNil(savedLine.context["tempo_outcome"])
        XCTAssertEqual(savedLine.context["moving_s"], "902")

        recorder.reset()
        XCTAssertEqual(recorder.state, RecorderState())
        XCTAssertNil(recorder.recordingID)
        XCTAssertNil(recorder.savedRunID)
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
        XCTAssertEqual(recorder.savedRunID, runID)
        XCTAssertEqual(saved.first?.journal, RunJournalEntry(), "the journal can follow the recap")
    }

    // MARK: - Race mode (#117)

    /// A goal race on the morning `t0` falls on. Custom 3 km by default: only `distance_m`
    /// knows how far that is (the label alone reads as a marathon), and it keeps the run short.
    private func raceGoal(distance: String = "custom", meters: Int? = 3_000, closed: Bool = false) -> GoalInfo {
        var goal = GoalInfo(id: UUID(), race_name: "Lakefront 3K", race_date: "2026-10-11",
                            goal_time_seconds: 720, distance: distance)
        goal.distance_m = meters
        if closed {
            goal.completed_at = t(-86_400)
            goal.outcome = "raced"
        }
        return goal
    }

    /// The watch reaches the race distance: said once, at the goal's own distance, with the
    /// race clock — and in place of the split that lands on the same update, not after it.
    func testARaceSaysItsDistanceOnceAtTheGoalsDistance() async throws {
        goal = raceGoal()
        let recorder = await started(.race, units: .km)
        run(recorder, line(from: 0, seconds: 900, secPerKm: 240))

        let race = try XCTUnwrap(cues.races.first, "a race in race mode hears its distance")
        XCTAssertEqual(cues.races.count, 1, "once, at the mark; not again every second past it")
        XCTAssertEqual(race.meters, 3_000, "the goal's distance_m, not a marathon read off the label")
        XCTAssertEqual(race.elapsedS, 720, accuracy: 10, "the race clock at the mark")
        XCTAssertEqual(cues.splits.map(\.index), [1, 2],
                       "km 3 lands on the same update; 'Kilometer three' then 'Three kilometers' is noise")
    }

    /// The same goal, the same morning, an ordinary outdoor run: splits only. The race cue
    /// is Race mode's, not race day's.
    func testAnOrdinaryRunOnRaceDayHearsOnlySplits() async {
        goal = raceGoal()
        let recorder = await started(.outdoor, units: .km)
        run(recorder, line(from: 0, seconds: 900, secPerKm: 240))
        XCTAssertTrue(cues.races.isEmpty)
        XCTAssertEqual(cues.splits.map(\.index), [1, 2, 3])
    }

    /// The race files itself as the block's race before the save is reported, so the recap
    /// it lands on and the close-out both read the link. And the landing outlives the reset
    /// the save screen does the moment the run is in Tempo (#129).
    func testARaceFilesItselfAsTheGoalsRaceBeforeTheSaveIsReported() async throws {
        let goal = raceGoal()
        self.goal = goal
        let recorder = await started(.race)
        run(recorder, line(from: 0, seconds: 120, secPerKm: 240))
        now = t(121)
        recorder.send(.endRequested(.liveScreen, at: now))
        await recorder.settled()

        XCTAssertEqual(recorder.state.phase, .saved(workoutID: session.workoutID))
        XCTAssertEqual(links, [RaceFinish.Link(goalID: goal.id, runID: runID)])
        XCTAssertEqual(phaseAtLink, [.ending(.saving)], "linked while the race was still saving")
        let landed = RaceFinish.SavedRun(recordingID: try XCTUnwrap(recorder.recordingID), kind: .race, runID: runID)
        XCTAssertEqual(recorder.lastSaved, landed)

        recorder.reset()
        XCTAssertEqual(recorder.lastSaved, landed, "the root still knows where to land after the cover resets")
    }

    /// No row, no race, or no open block: nothing is linked. The run is still saved, and the
    /// recap's date-and-distance guess still finds a race that lands later.
    func testOnlyARaceWithARowOnAnOpenBlockIsLinked() async {
        let cases: [(label: String, kind: RecorderState.RunKind, answer: RecordedRunSaver.Outcome, closed: Bool)] = [
            ("an ordinary run on race day", .outdoor, .saved(runID: runID), false),
            ("a race saved in a dead spot: no row yet", .race, .queued, false),
            ("a race too short to be a run", .race, .tooShort, false),
            ("a race on a block already closed", .race, .saved(runID: runID), true),
        ]
        for c in cases {
            session = FakeSession()
            links = []
            goal = raceGoal(closed: c.closed)
            tempoAnswers = [c.answer]
            let recorder = await started(c.kind)
            run(recorder, line(from: 0, seconds: 60, secPerKm: 240))
            now = t(61)
            recorder.send(.endRequested(.liveScreen, at: now))
            if c.kind != .race { recorder.confirmSave() }
            await recorder.settled()
            XCTAssertEqual(recorder.state.phase, .saved(workoutID: session.workoutID), c.label)
            XCTAssertTrue(links.isEmpty, c.label)
            XCTAssertEqual(recorder.lastSaved?.kind, c.kind, c.label)
        }
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
        XCTAssertTrue(logged.contains("recorder.session_error"))
        XCTAssertTrue(logged.contains("recorder.interrupted"))
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

    /// Pause and Resume on the Lock Screen (#119) reach the workout session exactly as the
    /// live screen's do, so HealthKit's own duration leaves the stop out.
    func testLockScreenPauseAndResumeReachTheSession() async {
        let recorder = await started()
        now = t(300)
        recorder.send(RunActivityCommand.pause.event(at: now))
        XCTAssertEqual(recorder.state.phase, .paused)
        XCTAssertEqual(session.calls.last, .pause(t(300)))
        now = t(330)
        recorder.send(RunActivityCommand.resume.event(at: now))
        await recorder.settled()
        XCTAssertEqual(recorder.state.phase, .running)
        XCTAssertEqual(session.calls.last, .resume(t(330)))
        XCTAssertFalse(session.endedOrThrownAway)
    }

    /// The Live Activity (#119) hears every refresh, and from it exists exactly from the
    /// countdown's end to the save: never during the 3-2-1, never after the run is in Health.
    func testTheLiveActivityFollowsTheRunFromTheCountdownsEndToTheSave() async {
        let recorder = makeRecorder()
        var heard: [(RunActivityState?, UUID?)] = []
        recorder.onRefresh = { state, snapshot, id in
            heard.append((RunActivityPlan.content(state: state, snapshot: snapshot), id))
        }
        recorder.send(.start(RecorderState.Setup(kind: .outdoor, target: tempo), at: now))
        XCTAssertNil(heard.last?.0, "the countdown has no activity")
        now = t(0)
        recorder.send(.countdownDone(at: now))
        XCTAssertEqual(heard.last?.0?.stage, .running)
        XCTAssertEqual(heard.last?.0?.startedAt, t(0))
        XCTAssertEqual(heard.last?.1, recorder.recordingID)
        XCTAssertEqual(heard.last?.0?.units, .km, "the unit the run started in")

        let before = heard.count
        run(recorder, line(from: 0, seconds: 10, secPerKm: 300))
        XCTAssertEqual(heard.count - before, 11, "once a tick: the plan, not the recorder, throttles")

        now = t(20)
        recorder.send(.pause(.manual(.liveScreen), at: now))
        XCTAssertEqual(heard.last?.0?.stage, .paused)
        recorder.send(.endRequested(.liveScreen, at: now))
        XCTAssertEqual(heard.last?.0?.stage, .ended)
        XCTAssertEqual(heard.last?.0?.endedAt, t(20))
        recorder.confirmSave()
        await recorder.settled()
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: session.workoutID))
        XCTAssertNil(heard.last?.0, "saved: the activity goes")
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
        XCTAssertTrue(saved.isEmpty, "nothing goes to Tempo until Health has it")
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
        XCTAssertTrue(logged.contains("recorder.session_error"))
        XCTAssertTrue(logged.contains("recorder.interrupted"))
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
        XCTAssertEqual(saved.first?.workout.uuid, session.workoutID)
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
        let recorder = makeRecorder(units: { units })
        now = t(-3)
        recorder.send(.start(RecorderState.Setup(kind: .outdoor), at: now))
        now = t(0)
        recorder.send(.countdownDone(at: now))
        units = .km
        run(recorder, line(from: 0, seconds: 400, secPerKm: 300))
        XCTAssertEqual(recorder.snapshot.units, .mi)
        XCTAssertEqual(recorder.snapshot.completedSplits, 0, "1.3 km is not yet a mile")
    }

    /// Kill recovery (#115): the snapshot is rewritten every ten seconds mid-run, carries the
    /// curve and the recording id, round-trips through JSON, and is a run `InProgressRun.recover`
    /// gives back when the session survived the kill.
    func testTheRecoverySnapshotIsWrittenEveryTenSecondsAndRecovers() async throws {
        let recorder = await started()
        let before = persisted.count
        run(recorder, line(from: 0, seconds: 60, secPerKm: 300))
        XCTAssertEqual(persisted.count - before, 6, "one write per ten seconds of running")

        let last = try XCTUnwrap(persisted.last ?? nil)
        XCTAssertEqual(last.savedAt, t(60))
        XCTAssertEqual(last.workoutSessionID, recorder.recordingID, "matches the recovered session's metadata")
        XCTAssertEqual(last.distanceM, recorder.snapshot.distanceM, accuracy: 0.1)
        XCTAssertFalse(last.lastFixes.isEmpty)
        let decoded = try JSONDecoder().decode(InProgressRun.self, from: JSONEncoder().encode(last))
        XCTAssertEqual(decoded, last)

        let back = InProgressRun.recover(snapshot: decoded, session: .init(isPaused: false), now: t(90))
        XCTAssertEqual(back.state?.phase, .running)
    }

    /// Once the run is in Health the snapshot goes, or the next launch would offer to rescue
    /// a run already saved, and one run would become two.
    func testTheSnapshotIsClearedOnceSavedOrDiscarded() async {
        let recorder = await started(.race)
        run(recorder, line(from: 0, seconds: 30, secPerKm: 240))
        now = t(31)
        recorder.send(.endRequested(.liveScreen, at: now))
        await recorder.settled()
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: session.workoutID))
        XCTAssertEqual(persisted.last, .some(nil), "cleared")
        XCTAssertEqual(persisted.filter { $0 == nil }.count, 1, "and only once")

        session = FakeSession()
        persisted = []
        let other = await started()
        now = t(10)
        other.send(.pause(.manual(.liveScreen), at: now))
        other.send(.discard(.liveScreen))
        XCTAssertEqual(persisted.last, .some(nil))
    }

    // MARK: - Tempo's half of the save (#122)

    /// Health has the run; Tempo refused the row. The save screen stays up with Retry, and
    /// Retry is Tempo's half only: the HealthKit workout is never finished twice.
    func testTempoRefusingTheRowKeepsTheSaveScreenAndRetryNeverSavesToHealthTwice() async {
        let recorder = await started()
        run(recorder, line(from: 0, seconds: 200, secPerKm: 300))
        tempoAnswers = [.dropped]
        now = t(201)
        recorder.send(.endRequested(.liveScreen, at: now))
        recorder.confirmSave()
        await recorder.settled()

        guard case .ending(.failed) = recorder.state.phase else {
            return XCTFail("expected Retry, got \(recorder.state.phase)")
        }
        XCTAssertEqual(recorder.saveOutcome, .dropped)
        XCTAssertNil(recorder.savedRunID)

        recorder.confirmSave()
        await recorder.settled()
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: session.workoutID))
        XCTAssertEqual(session.finishes, 1, "one workout in Health, however many retries")
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(recorder.savedRunID, runID)
    }

    /// Giving up after Tempo refused the row does not reach into Health: the workout is
    /// already there, and the sync will ingest it.
    func testDiscardingAfterHealthHasItLeavesItInHealth() async {
        let recorder = await started()
        run(recorder, line(from: 0, seconds: 200, secPerKm: 300))
        tempoAnswers = [.dropped]
        now = t(201)
        recorder.send(.endRequested(.liveScreen, at: now))
        recorder.confirmSave()
        await recorder.settled()
        recorder.send(.discard(.liveScreen))
        await recorder.settled()

        XCTAssertEqual(recorder.state.phase, .discarded)
        XCTAssertFalse(session.calls.contains(.discard))
    }

    /// Queued (no signal) and too short (a blip) are both done as far as the run goes: it is
    /// in Health either way, and a queued row lands on the next refresh by itself.
    func testOnlyARefusedRowIsAFailedSave() {
        let id = UUID()
        XCTAssertEqual(WorkoutRecorder.saveEvent(for: .saved(runID: UUID()), workoutID: id), .saveSucceeded(workoutID: id))
        XCTAssertEqual(WorkoutRecorder.saveEvent(for: .queued, workoutID: id), .saveSucceeded(workoutID: id))
        XCTAssertEqual(WorkoutRecorder.saveEvent(for: .tooShort, workoutID: id), .saveSucceeded(workoutID: id))
        guard case .saveFailed = WorkoutRecorder.saveEvent(for: .dropped, workoutID: id) else {
            return XCTFail("a refused row keeps the save screen up")
        }
    }

    // MARK: - Auto-pause (#113)

    /// A red light with auto-pause on: two minutes of running, standing still, running on.
    /// The pause is backdated to when he stopped and the restart to when he started, the
    /// cue hook fires for each, and the seconds he ran before the restart was confirmed are
    /// still measured.
    func testAutoPauseAtALightPausesAndResumesAndLosesNoDistance() async {
        let recorder = await started(autoPause: true)
        XCTAssertTrue(motion.isOn, "step speed backs up GPS once auto-pause is on")
        let speed = 1000.0 / 300
        run(recorder, line(from: 0, seconds: 120, secPerKm: 300))
        let light = 120 * speed
        run(recorder, (121...140).map { fix(at: Double($0), north: light, speed: 0) })

        XCTAssertEqual(recorder.state.openPause?.reason, .auto)
        XCTAssertEqual(recorder.state.openPause?.start, t(121), "backdated to the first still second")
        XCTAssertTrue(session.calls.contains(.pause(t(121))))

        run(recorder, (141...200).map { fix(at: Double($0), north: light + Double($0 - 141) * speed, speed: speed) })
        XCTAssertEqual(recorder.state.phase, .running)
        XCTAssertEqual(recorder.state.pauses.last?.end, t(141), "backdated to the first running second")
        XCTAssertEqual(autoPauses, [.pause(at: t(121)), .resume(at: t(141))])
        XCTAssertEqual(cues.decisions, autoPauses, "an auto pause is never silent (#118)")
        XCTAssertEqual(lines.filter { $0.context["trigger"] == "auto" }.map(\.event), [.paused, .resumed],
                       "auto decisions are reported as the pause and resume they became, once each")

        now = t(201)
        recorder.send(.endRequested(.liveScreen, at: now))
        XCTAssertEqual(recorder.snapshot.distanceM, light + 59 * speed, accuracy: 5,
                       "the three seconds before the restart was confirmed are not lost")
        XCTAssertFalse(motion.isOn)
    }

    /// Lower Wacker: GPS stuck in place reporting no speed. Silence is not stopping.
    func testAGPSDropoutNeverAutoPauses() async {
        let recorder = await started(autoPause: true)
        run(recorder, line(from: 0, seconds: 60, secPerKm: 300))
        run(recorder, (61...120).map { fix(at: Double($0), north: 200, speed: -1) })
        XCTAssertEqual(recorder.state.phase, .running)
        XCTAssertTrue(autoPauses.isEmpty)
    }

    /// Off by default (David, 2026-10-12): standing still for a minute changes nothing, and
    /// Motion & Fitness is never asked for.
    func testAutoPauseOffNeverPausesAndNeverAsksForMotion() async {
        let recorder = await started()
        XCTAssertFalse(motion.isOn)
        run(recorder, line(from: 0, seconds: 60, secPerKm: 300))
        run(recorder, (61...120).map { fix(at: Double($0), north: 200, speed: 0) })
        XCTAssertEqual(recorder.state.phase, .running)
        XCTAssertTrue(autoPauses.isEmpty)
    }

    /// He paused; running again doesn't lift it. Only he does.
    func testAutoResumeNeverLiftsHisOwnPause() async {
        let recorder = await started(autoPause: true)
        run(recorder, line(from: 0, seconds: 60, secPerKm: 300))
        now = t(61)
        recorder.send(.pause(.manual(.liveScreen), at: now))
        run(recorder, line(from: 62, seconds: 30, secPerKm: 300, north0: 200))
        XCTAssertEqual(recorder.state.openPause?.reason, .manual)
        XCTAssertTrue(autoPauses.isEmpty)
    }

    /// A treadmill: the pedometer is the only speed, and it goes quiet when he steps off.
    /// Quiet past `PedometerSilence.quietAfterS` reads as standing; steps again resume.
    func testATreadmillAutoPausesWhenThePedometerGoesQuiet() async {
        let recorder = await started(.treadmill, autoPause: true)
        XCTAssertTrue(motion.isOn)
        for s in 1...100 {
            now = t(Double(s))
            let running = s <= 60 || s >= 90
            if running, s % 2 == 0 || s >= 90 { motion.step(at: now, speed: 3) }
            recorder.tick()
            if s == 85 {
                XCTAssertEqual(recorder.state.openPause?.reason, .auto)
                XCTAssertEqual(recorder.state.openPause?.start, t(66),
                               "the first zero after five quiet seconds starts the stop")
            }
        }
        XCTAssertEqual(recorder.state.phase, .running)
        XCTAssertEqual(autoPauses, [.pause(at: t(66)), .resume(at: t(90))])
    }

    /// A pedometer that never reports (Motion denied, phone on the console) proves nothing,
    /// so it never pauses a treadmill run.
    func testATreadmillWithASilentPedometerNeverPauses() async {
        let recorder = await started(.treadmill, autoPause: true)
        for s in 1...120 {
            now = t(Double(s))
            recorder.tick()
        }
        XCTAssertEqual(recorder.state.phase, .running)
        XCTAssertTrue(autoPauses.isEmpty)
    }

    func testPedometerSilenceFillsOnlyAfterAReadingAndFiveQuietSeconds() {
        XCTAssertNil(PedometerSilence.filler(lastReadingAt: nil, now: t(60)), "never reported: no evidence")
        XCTAssertNil(PedometerSilence.filler(lastReadingAt: t(55), now: t(60)), "its last reading is still current")
        XCTAssertEqual(PedometerSilence.filler(lastReadingAt: t(54), now: t(60)),
                       AutoPause.Sample(at: t(60), speed: 0, source: .pedometer))
    }

    // MARK: - Voice cues (#118)

    /// A split is said once, when it finishes, with its own pace. The distance hook (#117's
    /// race-distance cue) sees every step forward.
    func testEachSplitIsSaidOnceWithItsPace() async throws {
        let recorder = await started(units: .km)
        var advanced: [(Double, Double)] = []
        recorder.onDistanceAdvanced = { advanced.append(($0, $1)) }
        run(recorder, line(from: 0, seconds: 650, secPerKm: 300))

        XCTAssertEqual(cues.splits.map(\.index), [1, 2])
        XCTAssertEqual(try XCTUnwrap(cues.splits.first).paceS, 300, accuracy: 3)
        XCTAssertFalse(advanced.isEmpty)
        XCTAssertTrue(advanced.allSatisfy { $0.1 > $0.0 })
    }

    /// Voice cues switched off: nothing is said, not a split and not an auto pause.
    func testCuesOffSaysNothing() async {
        cues.isEnabled = false
        let recorder = await started(units: .km, autoPause: true)
        run(recorder, line(from: 0, seconds: 400, secPerKm: 300))
        run(recorder, (401...420).map { fix(at: Double($0), north: 400 * 1000 / 300, speed: 0) })
        XCTAssertEqual(recorder.state.openPause?.reason, .auto)
        XCTAssertTrue(cues.splits.isEmpty)
        XCTAssertTrue(cues.decisions.isEmpty)
    }

    func testDiscardCutsOffTheVoice() async {
        let recorder = await started()
        now = t(30)
        recorder.send(.pause(.manual(.liveScreen), at: now))
        recorder.send(.discard(.liveScreen))
        XCTAssertEqual(cues.stops, 1)
    }

    // MARK: - Kill recovery at launch (#115)

    /// iOS killed Tempo. A new process, a new recorder, fresh GPS and voice — everything the
    /// old process held in memory is gone, and the telemetry starts from the relaunch.
    private func relaunched(units: Units = .km) -> WorkoutRecorder {
        location = FakeLocation()
        motion = FakeMotion()
        cues = FakeCues()
        lines = []
        logged = []
        persisted = []
        saved = []
        return makeRecorder(units: { units }, recovery: RecoverySources(
            loadSnapshot: { nil },
            recoverSession: { nil },
            rescue: { [unowned self] state in rescuedFor.append(state); return rescue },
            savedWorkout: { [unowned self] _ in inHealth }
        ))
    }

    /// What `recoverActiveWorkoutSession` hands back for this snapshot's run.
    private func survivor(of snapshot: InProgressRun, paused: Bool = false,
                          healthHas meters: Double?) -> (RecoveredSession, FakeSession) {
        let fake = FakeSession()
        let info = InProgressRun.SessionRecovery(id: snapshot.workoutSessionID, isPaused: paused, distanceM: meters)
        return (RecoveredSession(driver: fake, recordingID: snapshot.workoutSessionID, info: info), fake)
    }

    private func lastSnapshot() throws -> InProgressRun {
        try XCTUnwrap(persisted.last ?? nil, "the recorder wrote the run down")
    }

    /// The case #115 exists for: killed 2 km in, he runs on for two minutes with nothing
    /// listening, and Tempo comes back to the same run — same recording, same clock, the
    /// live screen up again — and Health ends up with every metre on screen exactly once.
    func testAKilledRunWhoseSessionSurvivedPicksUpWhereItWas() async throws {
        let before = await started()
        run(before, line(from: 0, seconds: 600, secPerKm: 300))
        let killed = try lastSnapshot()
        XCTAssertEqual(killed.savedAt, t(600))
        let inHealthBefore = session.distanceWritten
        let recordingID = before.recordingID

        now = t(720)
        let recorder = relaunched()
        var lockScreen: [(RunActivityState?, UUID?)] = []
        recorder.onRefresh = { state, snapshot, id in
            lockScreen.append((RunActivityPlan.content(state: state, snapshot: snapshot), id))
        }
        let (recovered, survivor) = survivor(of: killed, healthHas: inHealthBefore)
        await recorder.adopt(snapshot: killed, session: recovered)
        await recorder.settled()

        XCTAssertEqual(recorder.state.phase, .running)
        XCTAssertEqual(recorder.recovered, .resume(recorder.state),
                       "the state the recorder reached is the one the decision table decided")
        XCTAssertEqual(recorder.recordingID, recordingID)
        XCTAssertEqual(recorder.state.startedAt, t(0), "the run's clock, not the relaunch's")
        XCTAssertEqual(recorder.snapshot.elapsedS, 720, "wall time kept counting while Tempo was dead")
        XCTAssertEqual(recorder.snapshot.movingS, 720, "the session was running, so the gap was running")
        XCTAssertEqual(recorder.snapshot.distanceM, killed.distanceM, accuracy: 0.2)
        XCTAssertTrue(location.isOn, "GPS is back on")
        XCTAssertEqual(survivor.calls, [], "the session is adopted as it is: nothing prepared, begun or resumed")
        XCTAssertEqual(lines.first { $0.event == .recovered }?.context["outcome"], "resumed")
        // The Lock Screen comes back with it (#119): the same recording's activity, the same clock.
        XCTAssertEqual(lockScreen.last?.1, recordingID)
        XCTAssertEqual(lockScreen.last?.0?.stage, .running)
        XCTAssertEqual(lockScreen.last?.0?.startedAt, t(0))
        XCTAssertEqual(lines.first { $0.event == .interrupted }?.context["reason"], "app_terminated")
        XCTAssertEqual((persisted.last ?? nil)?.savedAt, t(720), "rewritten at once: a second kill costs no more")

        // He is 400 m further up the road by now. The next kilometre is measured from there.
        run(recorder, line(from: 720, seconds: 300, secPerKm: 300, north0: 720 * 1000 / 300))
        now = t(1021)
        recorder.send(.endRequested(.liveScreen, at: now))
        recorder.confirmSave()
        await recorder.settled()

        XCTAssertEqual(recorder.state.phase, .saved(workoutID: survivor.workoutID))
        XCTAssertEqual(survivor.finishes, 1)
        let shown = recorder.snapshot.distanceM
        XCTAssertEqual(shown, killed.distanceM + 1000, accuracy: 20)
        XCTAssertEqual(inHealthBefore + survivor.distanceWritten, shown, accuracy: 0.5,
                       "Health gets every metre on screen, and none of them twice")
        XCTAssertEqual(saved.first?.workout.uuid, survivor.workoutID)
        XCTAssertEqual(persisted.last, .some(nil), "in Health: the snapshot is gone")
    }

    /// The session was paused when Tempo died, so the gap was a stop — and only he lifts it.
    func testASessionPausedThroughTheGapComesBackPausedUntilHeResumes() async throws {
        let before = await started()
        run(before, line(from: 0, seconds: 300, secPerKm: 300))
        let killed = try lastSnapshot()

        now = t(900)
        let recorder = relaunched()
        let (recovered, survivor) = survivor(of: killed, paused: true, healthHas: nil)
        await recorder.adopt(snapshot: killed, session: recovered)

        XCTAssertEqual(recorder.state.phase, .paused)
        XCTAssertEqual(recorder.state.openPause?.reason, .recoveryGap)
        XCTAssertEqual(recorder.state.openPause?.start, t(300))
        XCTAssertEqual(recorder.snapshot.movingS, 300, "the session says he stopped; the clock agrees")

        run(recorder, line(from: 900, seconds: 30, secPerKm: 300, north0: 1000))
        XCTAssertEqual(recorder.state.phase, .paused, "moving again doesn't lift it; we didn't see him start")
        now = t(931)
        recorder.send(.resume(.manual(.liveScreen), at: now))
        await recorder.settled()
        XCTAssertEqual(survivor.calls, [.resume(t(931))])
    }

    /// No session survived. The run waits on "Save what we have", and saving it rebuilds the
    /// workout in Health from the snapshot: from the start, to the last instant Tempo knew
    /// it was recording, with every metre on the curve and the stop at the fountain.
    func testWhenNoSessionSurvivedSaveWhatWeHaveRebuildsTheRunInHealth() async throws {
        let before = await started()
        run(before, line(from: 0, seconds: 300, secPerKm: 300))
        now = t(301)
        before.send(.pause(.manual(.liveScreen), at: now))
        now = t(361)
        before.send(.resume(.manual(.liveScreen), at: now))
        run(before, line(from: 361, seconds: 300, secPerKm: 300, north0: 1000))
        let killed = try lastSnapshot()

        rescue = FakeSession()
        now = t(4000)
        let recorder = relaunched()
        await recorder.adopt(snapshot: killed, session: nil)
        await recorder.settled()
        let rescued = try XCTUnwrap(rescue)

        XCTAssertEqual(recorder.state.phase, .recovering(since: killed.savedAt))
        XCTAssertEqual(recorder.recovered, .rescue(recorder.state))
        XCTAssertEqual(rescued.calls, [.begin(t(0))], "the rebuilt workout starts when the run did")
        XCTAssertEqual(rescued.beginMetadata[RecordingMetadata.recordingIDKey] as? String,
                       killed.workoutSessionID?.uuidString)
        XCTAssertEqual(rescuedFor.first?.pauses.count, 1, "the stop goes into the workout as a pause")
        XCTAssertFalse(location.isOn, "nothing is recording until he says what to do with it")
        XCTAssertEqual(lines.first { $0.event == .recoveryFailed }?.context["outcome"], "rescue_offered")

        recorder.send(.endRequested(.liveScreen, at: now))
        recorder.confirmSave()
        await recorder.settled()

        XCTAssertEqual(recorder.state.endedAt, killed.savedAt, "ended where our knowledge does, not at the relaunch")
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: rescued.workoutID))
        XCTAssertEqual(rescued.distanceWritten, killed.distanceM, accuracy: 0.01, "every metre he watched")
        let samples = rescued.calls.filter { if case .distance = $0 { true } else { false } }
        XCTAssertGreaterThan(samples.count, 30, "in ten-second stretches, so Health's splits are his")
        XCTAssertEqual(rescued.calls.last { if case .stop = $0 { true } else { false } }, .stop(killed.savedAt))
        XCTAssertEqual(saved.first?.workout.uuid, rescued.workoutID, "and on into Tempo, like any run")
        XCTAssertEqual(persisted.last, .some(nil))
    }

    func testDiscardingARescueThrowsAwayTheRebuiltWorkoutAndTheSnapshot() async throws {
        let before = await started()
        run(before, line(from: 0, seconds: 120, secPerKm: 300))
        let killed = try lastSnapshot()
        rescue = FakeSession()
        now = t(600)
        let recorder = relaunched()
        await recorder.adopt(snapshot: killed, session: nil)
        recorder.send(.discard(.liveScreen))
        await recorder.settled()

        XCTAssertEqual(recorder.state.phase, .discarded)
        XCTAssertEqual(rescue?.calls.last, .discard)
        XCTAssertFalse(rescue?.calls.contains(.finish) ?? true)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(persisted.last, .some(nil), "asked and answered: never offered again")
    }

    /// No session and no way to make a workout: Save says so and keeps the run, rather
    /// than sit on "saving" forever.
    func testSaveWhatWeHaveWithNoWayIntoHealthSaysSoAndKeepsTheRun() async throws {
        let before = await started()
        run(before, line(from: 0, seconds: 120, secPerKm: 300))
        let killed = try lastSnapshot()
        now = t(600)
        let recorder = relaunched()
        await recorder.adopt(snapshot: killed, session: nil)
        recorder.send(.endRequested(.liveScreen, at: now))
        recorder.confirmSave()
        await recorder.settled()

        guard case .ending(.failed) = recorder.state.phase else {
            return XCTFail("expected Retry, got \(recorder.state.phase)")
        }
        XCTAssertNotNil(persisted.last ?? nil, "still written down for the next launch")
    }

    /// Killed on the save screen: the session comes back stopped, the run comes back whole
    /// on the save screen, and Save finishes the workout once.
    func testKilledOnTheSaveScreenComesBackToSaveWithTheRunWhole() async throws {
        let before = await started()
        run(before, line(from: 0, seconds: 300, secPerKm: 300))
        now = t(301)
        before.send(.endRequested(.liveScreen, at: now))
        await before.settled()
        let killed = try lastSnapshot()
        XCTAssertEqual(killed.state.phase, .ending(.review))

        now = t(500)
        let recorder = relaunched()
        let (recovered, survivor) = survivor(of: killed, healthHas: session.distanceWritten)
        await recorder.adopt(snapshot: killed, session: recovered)
        await recorder.settled()

        XCTAssertEqual(recorder.state.phase, .ending(.review))
        XCTAssertEqual(recorder.recovered, .unfinished(recorder.state))
        XCTAssertEqual(survivor.calls, [.stop(t(301))], "collection made sure of; nothing written twice")
        XCTAssertFalse(location.isOn)

        recorder.confirmSave()
        await recorder.settled()
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: survivor.workoutID))
        XCTAssertEqual(survivor.finishes, 1)
        XCTAssertTrue(rescuedFor.isEmpty)
    }

    /// Killed between Health saving the workout and Tempo clearing its snapshot. No session
    /// survives a finished workout, so the one place to learn it was saved is Health itself:
    /// Retry is Tempo's half only, and the run is never in Health twice.
    func testKilledAfterHealthHadTheRunRetryNeverSavesItTwice() async throws {
        let before = await started()
        run(before, line(from: 0, seconds: 200, secPerKm: 300))
        now = t(201)
        before.send(.endRequested(.liveScreen, at: now))
        before.confirmSave()
        let killed = try XCTUnwrap(persisted.compactMap { $0 }.last { $0.state.phase == .ending(.saving) })
        await before.settled()
        let row = try XCTUnwrap(saved.first?.workout)
        inHealth = FinishedWorkout(id: session.workoutID, row: row)

        now = t(400)
        let recorder = relaunched()
        await recorder.adopt(snapshot: killed, session: nil)
        XCTAssertEqual(recorder.state.phase, .ending(.failed(reason: "Tempo closed while saving")))
        XCTAssertEqual(recorder.recovered, .unfinished(recorder.state))
        XCTAssertTrue(rescuedFor.isEmpty, "no workout is rebuilt for a run Health already has")

        recorder.confirmSave()
        await recorder.settled()
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: session.workoutID))
        XCTAssertEqual(session.finishes, 1, "one workout in Health")
        XCTAssertEqual(saved.map(\.workout.uuid), [session.workoutID], "Tempo's half, with the workout Health had")
    }

    /// HealthKit's own distance on a treadmill counted the belt while Tempo was dead; the
    /// run comes back with it, and carries on reading it.
    func testATreadmillRunComesBackWithTheSessionsOwnDistance() async throws {
        let before = await started(.treadmill)
        for s in stride(from: 10.0, through: 300, by: 10) {
            now = t(s)
            session.onSignal?(.distance(totalMeters: s * 1000 / 320, at: now))
            before.tick()
        }
        let killed = try lastSnapshot()

        now = t(420)
        let recorder = relaunched()
        let (recovered, survivor) = survivor(of: killed, healthHas: 420 * 1000 / 320)
        await recorder.adopt(snapshot: killed, session: recovered)
        XCTAssertEqual(recorder.snapshot.distanceM, 420 * 1000 / 320, accuracy: 0.2,
                       "the belt kept turning and HealthKit kept counting")
        XCTAssertEqual(location.starts, 0, "a treadmill never asks for location, recovered or not")

        now = t(430)
        survivor.onSignal?(.distance(totalMeters: 430 * 1000 / 320, at: now))
        recorder.tick()
        XCTAssertEqual(recorder.snapshot.distanceM, 430 * 1000 / 320, accuracy: 0.2)

        recorder.send(.endRequested(.liveScreen, at: now))
        recorder.confirmSave()
        await recorder.settled()
        XCTAssertEqual(survivor.distanceWritten, 0, "HealthKit already has a treadmill's distance")
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: survivor.workoutID))
    }

    /// A session with no run of ours behind it — the snapshot was already cleared for a run
    /// he saved or discarded — is ended, not saved, and there is nothing to show him.
    func testASessionWithNoRunBehindItIsEndedNotSaved() async {
        let recorder = relaunched()
        let stray = FakeSession()
        await recorder.adopt(snapshot: nil, session: RecoveredSession(
            driver: stray, recordingID: UUID(), info: .init(isPaused: false)))
        XCTAssertEqual(stray.calls, [.discard])
        XCTAssertNil(recorder.recovered)
        XCTAssertEqual(recorder.state, RecorderState())
        XCTAssertEqual(lines.map { $0.context["outcome"] }, ["orphan_session"])
    }

    /// A session that is some other recording's never has its distance spliced onto this run.
    func testASessionFromAnotherRecordingIsNeverSplicedOntoThisRun() async throws {
        let before = await started()
        run(before, line(from: 0, seconds: 120, secPerKm: 300))
        let killed = try lastSnapshot()
        rescue = FakeSession()
        now = t(600)
        let recorder = relaunched()
        let other = FakeSession()
        await recorder.adopt(snapshot: killed, session: RecoveredSession(
            driver: other, recordingID: UUID(), info: .init(isPaused: false, distanceM: 10_000)))

        XCTAssertEqual(recorder.state.phase, .recovering(since: killed.savedAt), "offered as a rescue, alone")
        XCTAssertEqual(recorder.snapshot.distanceM, killed.distanceM, accuracy: 0.2, "none of the other run's 10 km")
        XCTAssertEqual(other.calls, [.discard])
        XCTAssertTrue(logged.contains("recorder.recovery_failed"))
    }

    /// A clean launch: nothing read, nothing written, nothing said, and only once.
    func testACleanLaunchDoesNothingAndRecoveryRunsOnce() async {
        var loads = 0
        let recorder = makeRecorder(recovery: RecoverySources(
            loadSnapshot: { loads += 1; return nil },
            recoverSession: { nil }, rescue: { _ in nil }, savedWorkout: { _ in nil }))
        await recorder.recoverAtLaunch()
        await recorder.recoverAtLaunch()
        XCTAssertEqual(loads, 1)
        XCTAssertNil(recorder.recovered)
        XCTAssertTrue(lines.isEmpty)
        XCTAssertTrue(persisted.isEmpty)
    }

    /// One recorder, not two (#126 and #115 both reach for it): the instance that recovers a
    /// killed run at launch is the one the cover shows and the live screen's buttons drive.
    /// A session adopted by a recorder the screens can't see would be a run nobody can end.
    func testTheRecorderThatRecoversIsTheOneTheLiveScreenDrives() async throws {
        let before = await started()
        run(before, line(from: 0, seconds: 300, secPerKm: 300))
        let killed = try lastSnapshot()
        let (recovered, survivor) = survivor(of: killed, healthHas: session.distanceWritten)

        now = t(360)
        location = FakeLocation()
        motion = FakeMotion()
        cues = FakeCues()
        let recorder = makeRecorder(recovery: RecoverySources(
            loadSnapshot: { killed }, recoverSession: { recovered },
            rescue: { _ in nil }, savedWorkout: { _ in nil }))
        await recorder.recoverAtLaunch()

        func screen() -> PreRun.Screen {
            PreRun.screen(for: recorder.state.phase, recovered: recorder.recovered != nil)
        }
        XCTAssertEqual(screen(), .recovered, "the cover comes up with \"We kept your run\"")
        recorder.acknowledgeRecovery()
        XCTAssertEqual(screen(), .live, "Keep going: the same cover, now the live screen")

        // The live screen's buttons and the GPS reach the recovered session through this
        // same instance.
        let atRecovery = recorder.snapshot.distanceM
        run(recorder, line(from: 360, seconds: 120, secPerKm: 300, north0: 2000))
        XCTAssertGreaterThan(recorder.snapshot.distanceM, atRecovery + 300)
        now = t(481)
        recorder.send(.pause(.manual(.liveScreen), at: now))
        XCTAssertTrue(survivor.calls.contains(.pause(t(481))), "the pause button reaches the recovered session")
        recorder.send(.endRequested(.liveScreen, at: now))
        recorder.confirmSave()
        await recorder.settled()
        XCTAssertEqual(recorder.state.phase, .saved(workoutID: survivor.workoutID))
        recorder.reset()
        XCTAssertEqual(screen(), .none, "reset closes the cover")
    }

    /// Nothing on disk outranks the run in front of him.
    func testAdoptNeverReplacesARunAlreadyUnderway() async throws {
        let recorder = await started()
        run(recorder, line(from: 0, seconds: 60, secPerKm: 300))
        let stale = try lastSnapshot()
        let before = recorder.state
        await recorder.adopt(snapshot: stale, session: nil)
        XCTAssertEqual(recorder.state, before)
        XCTAssertNil(recorder.recovered)
    }
}
