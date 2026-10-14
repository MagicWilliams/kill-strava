import XCTest
@testable import Tempo

/// What the recorder does to HealthKit and GPS on each transition (#114).
///
/// `RecorderStateTests` pins that only the athlete can end a run. That rule is only as good
/// as the I/O behind it: a reducer that refuses to end a run is no help if the service stops
/// the workout session anyway. This file pins the other half. The first test walks every
/// phase against every event and fails if anything other than the athlete's own live-screen
/// action produces an effect that stops, saves or throws away a workout.
final class RecorderEffectsTests: XCTestCase {

    typealias State = RecorderState
    typealias Event = RecorderEvent

    // Chicago's 7:30 CDT gun, the run the reducer was built for.
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-11T12:30:00Z")!
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private let tempo = State.SessionTarget(sessionID: UUID(), type: "tempo", title: "6 mi tempo",
                                            distanceM: 9656, paceSecPerMile: 450)

    private func apply(_ state: State, _ events: Event...) -> State {
        events.reduce(state, State.reduce)
    }

    private func started(_ kind: State.RunKind = .outdoor) -> State {
        apply(State(), .start(State.Setup(kind: kind, target: tempo, autoPause: true), at: t(-3)),
              .countdownDone(at: t(0)))
    }

    /// Step `state` through `event`, returning the new state and the effects.
    private func step(_ state: State, _ event: Event) -> (State, [RecorderEffect]) {
        let next = State.reduce(state, event)
        return (next, RecorderEffect.between(state, next))
    }

    // MARK: - The guarantee

    func testOnlyTheAthleteFromTheLiveScreenStopsSavesOrDiscardsAWorkout() {
        let running = started()
        let saving = apply(running, .endRequested(.liveScreen, at: t(1200)), .endConfirmed)
        let fixtures: [(String, State)] = [
            ("idle", State()),
            ("countdown", apply(State(), .start(State.Setup(kind: .outdoor, target: tempo, autoPause: true), at: t(-3)))),
            ("running", running),
            ("runningRace", started(.race)),
            ("pausedManual", apply(running, .pause(.manual(.liveScreen), at: t(600)))),
            ("pausedAuto", apply(running, .pause(.auto, at: t(600)))),
            ("review", apply(running, .endRequested(.liveScreen, at: t(1200)))),
            ("saving", saving),
            ("failed", apply(saving, .saveFailed(reason: "disk full"))),
            ("saved", apply(saving, .saveSucceeded(workoutID: UUID()))),
            ("discarded", apply(running, .pause(.manual(.liveScreen), at: t(600)), .discard(.liveScreen))),
            ("recovering", apply(running, .interrupted(.appTerminated, at: t(900)))),
        ]
        let at = t(1500)
        let events: [Event] = [
            .start(State.Setup(kind: .treadmill), at: at), .countdownDone(at: at),
            .pause(.manual(.liveScreen), at: at), .pause(.manual(.lockScreen), at: at), .pause(.auto, at: at),
            .resume(.manual(.liveScreen), at: at), .resume(.manual(.lockScreen), at: at), .resume(.auto, at: at),
            .endRequested(.liveScreen, at: at), .endRequested(.lockScreen, at: at), .endConfirmed,
            .discard(.liveScreen), .discard(.lockScreen),
            .saveSucceeded(workoutID: UUID()), .saveFailed(reason: "network"),
            .interrupted(.phoneCall, at: at), .interrupted(.locationRevoked, at: at),
            .interrupted(.sessionFailed, at: at), .interrupted(.appTerminated, at: at),
            .recovered(sessionPaused: true), .recovered(sessionPaused: false),
            .setTargetVisible(false), .setTargetVisible(true),
        ]

        for (name, state) in fixtures {
            for event in events {
                let (_, effects) = step(state, event)
                let athleteEnds = event == .endRequested(.liveScreen, at: at) || event == .endConfirmed
                if effects.contains(where: { if case .stop = $0 { true } else { false } }) || effects.contains(.save) {
                    XCTAssertTrue(athleteEnds, "\(name) + \(event) stopped or saved the workout: \(effects)")
                }
                if effects.contains(.discard) {
                    // A countdown lost to a crash has recorded nothing; anything else is his call.
                    let nothingRecorded = state.phase == .countdown(startedAt: t(-3))
                    XCTAssertTrue(event == .discard(.liveScreen) || nothingRecorded,
                                  "\(name) + \(event) discarded the workout: \(effects)")
                }
            }
        }
    }

    // MARK: - The lifecycle, effect by effect

    func testAnOutdoorRunFromCountdownToSaved() {
        var s = State()
        var effects: [RecorderEffect]

        (s, effects) = step(s, .start(State.Setup(kind: .outdoor, target: tempo), at: t(-3)))
        XCTAssertEqual(effects, [.prepare], "the countdown prepares the session and warms GPS")

        (s, effects) = step(s, .countdownDone(at: t(0)))
        XCTAssertEqual(effects, [.begin(at: t(0))], "collection begins when the countdown ends")

        (s, effects) = step(s, .pause(.manual(.liveScreen), at: t(600)))
        XCTAssertEqual(effects, [.pause(at: t(600))])

        (s, effects) = step(s, .resume(.manual(.lockScreen), at: t(660)))
        XCTAssertEqual(effects, [.resume(at: t(660))])

        (s, effects) = step(s, .endRequested(.liveScreen, at: t(1800)))
        XCTAssertEqual(effects, [.stop(at: t(1800))], "the save screen stops collection but saves nothing yet")

        (s, effects) = step(s, .endConfirmed)
        XCTAssertEqual(effects, [.save])

        (s, effects) = step(s, .saveSucceeded(workoutID: UUID()))
        XCTAssertEqual(effects, [.tearDown])
    }

    /// Ending while paused stops at the end instant, and the open pause is closed there.
    func testEndingWhilePausedStopsAtTheEnd() {
        let paused = apply(started(), .pause(.manual(.liveScreen), at: t(900)))
        let (_, effects) = step(paused, .endRequested(.liveScreen, at: t(960)))
        XCTAssertEqual(effects, [.stop(at: t(960))])
    }

    /// Race finish saves itself (#125): stop and save in one step, in that order.
    func testARaceStopsAndSavesInOneStep() {
        let (_, effects) = step(started(.race), .endRequested(.liveScreen, at: t(12_000)))
        XCTAssertEqual(effects, [.stop(at: t(12_000)), .save])
    }

    /// A failed save keeps everything; Retry saves again.
    func testRetryAfterAFailedSaveSavesAgain() {
        let failed = apply(started(), .endRequested(.liveScreen, at: t(1200)), .endConfirmed,
                           .saveFailed(reason: "offline"))
        XCTAssertEqual(RecorderEffect.between(apply(started(), .endRequested(.liveScreen, at: t(1200)), .endConfirmed), failed), [],
                       "a failed save does nothing by itself")
        XCTAssertEqual(step(failed, .endConfirmed).1, [.save])
    }

    func testDiscardEndsTheSessionAndLetsGo() {
        let paused = apply(started(), .pause(.manual(.liveScreen), at: t(300)))
        XCTAssertEqual(step(paused, .discard(.liveScreen)).1, [.discard, .tearDown])
        let review = apply(started(), .endRequested(.liveScreen, at: t(300)))
        XCTAssertEqual(step(review, .discard(.liveScreen)).1, [.discard, .tearDown])
    }

    func testCancellingTheCountdownThrowsAwayThePreparedSession() {
        let countdown = apply(State(), .start(State.Setup(kind: .outdoor), at: t(-3)))
        XCTAssertEqual(step(countdown, .discard(.liveScreen)).1, [.discard, .tearDown])
    }

    /// HealthKit failing underneath a run, or the app dying, is not the end of it. Nothing
    /// is stopped or thrown away; recovery is #115's.
    func testLosingTheSessionHasNoEffectsAtAll() {
        let running = started()
        XCTAssertEqual(step(running, .interrupted(.sessionFailed, at: t(600))).1, [])
        let recovering = apply(running, .interrupted(.appTerminated, at: t(600)))
        XCTAssertEqual(step(recovering, .recovered(sessionPaused: false)).1, [])
        XCTAssertEqual(step(recovering, .recovered(sessionPaused: true)).1, [])
    }

    /// The Lock Screen can pause a run but not end one — so it produces no effect at all.
    func testTheLockScreenCannotStopARun() {
        XCTAssertEqual(step(started(), .endRequested(.lockScreen, at: t(600))).1, [])
        XCTAssertEqual(step(started(), .pause(.manual(.lockScreen), at: t(600))).1, [.pause(at: t(600))])
    }

    /// Auto-pause is off unless he turned it on; when it is off, nothing reaches the session.
    func testAutoPauseWhenOffReachesNothing() {
        let off = apply(State(), .start(State.Setup(kind: .outdoor), at: t(-3)), .countdownDone(at: t(0)))
        XCTAssertEqual(step(off, .pause(.auto, at: t(60))).1, [])
    }
}
