import XCTest
@testable import Tempo

/// Chicago, Sunday 11 Oct 2026. Strava paused itself during the race and the recording was
/// lost (#111). Tempo's recorder is being built so that cannot happen again, and this file is
/// where "cannot" gets pinned: only the athlete, from the live screen, can end a run.
///
/// The first test walks every phase against every event and fails on any transition it was
/// not told about, so a new path into `.ending` or `.discarded` has to be added here on
/// purpose. The rest are the decisions behind that table (#125): auto-pause off by default,
/// Lock Screen pause/resume only, race finish saves itself, the crash gap is a pause only if
/// the session was paused, the target hides and comes back.
final class RecorderStateTests: XCTestCase {

    typealias State = RecorderState
    typealias Event = RecorderEvent

    // Chicago's 7:30 CDT gun.
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-11T12:30:00Z")!
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private let tempo = State.SessionTarget(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000111"),
        type: "tempo", title: "6 mi tempo", distanceM: 9656, paceSecPerMile: 450
    )
    private let workoutID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    private func apply(_ state: State, _ events: Event...) -> State {
        events.reduce(state, State.reduce)
    }

    private func started(_ kind: State.RunKind = .outdoor, autoPause: Bool = false,
                         showTarget: Bool = true, target: State.SessionTarget?? = nil) -> State {
        let setup = State.Setup(kind: kind, target: target ?? tempo, showTarget: showTarget,
                                autoPause: autoPause)
        return apply(State(), .start(setup, at: t(-3)), .countdownDone(at: t(0)))
    }

    // MARK: - Fixtures: one state per phase, reached the way the app reaches it

    private var fixtures: [(name: String, state: State)] {
        let running = started(autoPause: true)
        let saving = apply(running, .endRequested(.liveScreen, at: t(1200)), .endConfirmed)
        return [
            ("idle", State()),
            ("countdown", apply(State(), .start(State.Setup(kind: .outdoor, target: tempo, autoPause: true), at: t(-3)))),
            ("running", running),
            ("runningRace", started(.race, autoPause: true)),
            ("pausedManual", apply(running, .pause(.manual(.liveScreen), at: t(600)))),
            ("pausedAuto", apply(running, .pause(.auto, at: t(600)))),
            ("review", apply(running, .endRequested(.liveScreen, at: t(1200)))),
            ("saving", saving),
            ("failed", apply(saving, .saveFailed(reason: "disk full"))),
            ("saved", apply(saving, .saveSucceeded(workoutID: workoutID))),
            ("discarded", apply(running, .pause(.manual(.liveScreen), at: t(600)), .discard(.liveScreen))),
            ("recovering", apply(running, .interrupted(.appTerminated, at: t(900)))),
        ]
    }

    private var events: [(name: String, event: Event)] {
        let at = t(1500)
        return [
            ("start", .start(State.Setup(kind: .treadmill), at: at)),
            ("countdownDone", .countdownDone(at: at)),
            ("pause.live", .pause(.manual(.liveScreen), at: at)),
            ("pause.lock", .pause(.manual(.lockScreen), at: at)),
            ("pause.auto", .pause(.auto, at: at)),
            ("resume.live", .resume(.manual(.liveScreen), at: at)),
            ("resume.lock", .resume(.manual(.lockScreen), at: at)),
            ("resume.auto", .resume(.auto, at: at)),
            ("end.live", .endRequested(.liveScreen, at: at)),
            ("end.lock", .endRequested(.lockScreen, at: at)),
            ("endConfirmed", .endConfirmed),
            ("discard.live", .discard(.liveScreen)),
            ("discard.lock", .discard(.lockScreen)),
            ("saveSucceeded", .saveSucceeded(workoutID: workoutID)),
            ("saveFailed", .saveFailed(reason: "network")),
            ("int.phoneCall", .interrupted(.phoneCall, at: at)),
            ("int.location", .interrupted(.locationRevoked, at: at)),
            ("int.sessionFailed", .interrupted(.sessionFailed, at: at)),
            ("int.appTerminated", .interrupted(.appTerminated, at: at)),
            ("recovered.paused", .recovered(sessionPaused: true)),
            ("recovered.running", .recovered(sessionPaused: false)),
            ("hideTarget", .setTargetVisible(false)),
        ]
    }

    private func label(_ phase: State.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .countdown: "countdown"
        case .running: "running"
        case .paused: "paused"
        case .ending(.review): "ending.review"
        case .ending(.saving): "ending.saving"
        case .ending(.failed): "ending.failed"
        case .saved: "saved"
        case .discarded: "discarded"
        case .recovering: "recovering"
        }
    }

    // MARK: - The whole table

    /// Every legal transition, written out. Anything absent must leave the state *identical*:
    /// an illegal event is a no-op, never a crash and never a partial change.
    func testEveryPhaseAgainstEveryEvent() {
        let loggedOnly = ["int.phoneCall", "int.location"]
        let stopping = ["int.sessionFailed", "int.appTerminated"]
        func same(_ phase: String, _ names: [String]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: names.map { ($0, phase) })
        }
        let live: (String) -> [String: String] = { phase in
            same(phase, loggedOnly).merging(["hideTarget": phase]) { $1 }
        }

        let legal: [String: [String: String]] = [
            "idle": ["start": "countdown"],
            "countdown": live("countdown").merging([
                "countdownDone": "running",
                "discard.live": "idle",
                "int.sessionFailed": "idle",
                "int.appTerminated": "idle",
            ]) { $1 },
            "running": live("running").merging(same("paused", ["pause.live", "pause.lock", "pause.auto"]))
                { $1 }.merging(same("recovering", stopping)) { $1 }
                .merging(["end.live": "ending.review"]) { $1 },
            "runningRace": live("running").merging(same("paused", ["pause.live", "pause.lock", "pause.auto"]))
                { $1 }.merging(same("recovering", stopping)) { $1 }
                .merging(["end.live": "ending.saving"]) { $1 },
            "pausedManual": live("paused").merging(same("running", ["resume.live", "resume.lock"]))
                { $1 }.merging(same("recovering", stopping)) { $1 }
                .merging(["end.live": "ending.review", "discard.live": "discarded"]) { $1 },
            "pausedAuto": live("paused").merging(same("running", ["resume.live", "resume.lock", "resume.auto"]))
                { $1 }.merging(same("recovering", stopping)) { $1 }
                .merging(["end.live": "ending.review", "discard.live": "discarded"]) { $1 },
            "review": same("ending.review", loggedOnly + stopping)
                .merging(["endConfirmed": "ending.saving", "discard.live": "discarded"]) { $1 },
            "saving": same("ending.saving", loggedOnly).merging(same("ending.failed", stopping)) { $1 }
                .merging(["saveSucceeded": "saved", "saveFailed": "ending.failed"]) { $1 },
            "failed": same("ending.failed", loggedOnly + stopping)
                .merging(["endConfirmed": "ending.saving", "discard.live": "discarded"]) { $1 },
            "saved": [:],
            "discarded": [:],
            "recovering": live("recovering").merging(same("recovering", stopping)) { $1 }.merging([
                "end.live": "ending.review",
                "discard.live": "discarded",
                "recovered.paused": "paused",
                "recovered.running": "running",
            ]) { $1 },
        ]

        for (fixtureName, state) in fixtures {
            let table = legal[fixtureName]!
            for (eventName, event) in events {
                let next = State.reduce(state, event)
                if let expected = table[eventName] {
                    XCTAssertEqual(label(next.phase), expected, "\(fixtureName) + \(eventName)")
                    XCTAssertTrue(state.accepts(event), "\(fixtureName) should accept \(eventName)")
                } else {
                    XCTAssertEqual(next, state, "\(fixtureName) + \(eventName) must be a no-op")
                    XCTAssertFalse(state.accepts(event), "\(fixtureName) should refuse \(eventName)")
                }
            }
        }
    }

    // MARK: - Only the athlete ends a run

    /// The Chicago rule, stated as a property: nothing but the athlete's own live-screen
    /// end or discard can move a run into `.ending`, `.saved` or `.discarded`.
    func testNothingButTheLiveScreenCanFinishOrDiscardARun() {
        let athlete: Set = ["end.live", "endConfirmed", "discard.live", "saveSucceeded", "saveFailed"]
        func finished(_ s: State) -> Bool {
            switch s.phase {
            case .ending, .saved, .discarded: true
            default: false
            }
        }
        for (fixtureName, state) in fixtures where !finished(state) {
            for (eventName, event) in events where !athlete.contains(eventName) {
                XCTAssertFalse(finished(State.reduce(state, event)), "\(fixtureName) + \(eventName)")
            }
        }
    }

    func testInterruptionsNeverDiscard() {
        for (fixtureName, state) in fixtures {
            for kind in [State.Interruption.phoneCall, .locationRevoked, .sessionFailed, .appTerminated] {
                let next = State.reduce(state, .interrupted(kind, at: t(1500)))
                if state.phase != .discarded {
                    XCTAssertNotEqual(next.phase, .discarded, "\(fixtureName) + \(kind)")
                }
                if state.startedAt != nil {
                    XCTAssertEqual(next.startedAt, state.startedAt, "a recorded start survives \(kind)")
                    XCTAssertEqual(next.pauses.count, state.pauses.count, "\(kind) must not invent or drop a stop")
                }
            }
        }
    }

    /// Auto-pause standing in for a GPS-confused runner for a whole marathon: ten thousand
    /// stop/start decisions, plus Lock Screen taps and phone calls, never end the run, and the
    /// pause list stays well-formed the whole way. Seeded, so a failure reproduces.
    func testAutoPauseCannotEndARunHoweverLongItFlaps() {
        var rng = SeededGenerator(seed: 11_10_2026)
        let noise: [(TimeInterval) -> Event] = [
            { .pause(.auto, at: self.t($0)) },
            { .resume(.auto, at: self.t($0)) },
            { .pause(.manual(.lockScreen), at: self.t($0)) },
            { .resume(.manual(.lockScreen), at: self.t($0)) },
            { .endRequested(.lockScreen, at: self.t($0)) },
            { _ in .discard(.lockScreen) },
            { .interrupted(.phoneCall, at: self.t($0)) },
            { .interrupted(.locationRevoked, at: self.t($0)) },
            { .setTargetVisible(Int($0) % 2 == 0) },
        ]
        var state = started(autoPause: true)
        var clock: TimeInterval = 0
        for _ in 0..<10_000 {
            // Mostly forward, occasionally stamped a few seconds in the past.
            clock += Double(Int.random(in: -3...20, using: &rng))
            let event = noise[Int.random(in: 0..<noise.count, using: &rng)](clock)
            state = State.reduce(state, event)

            XCTAssertTrue(state.phase == .running || state.phase == .paused, "\(event) moved to \(state.phase)")
            XCTAssertEqual(state.phase == .paused, state.openPause != nil)
            XCTAssertLessThanOrEqual(state.pauses.filter { $0.end == nil }.count, 1)
            for (a, b) in zip(state.pauses, state.pauses.dropFirst()) {
                XCTAssertLessThanOrEqual(a.end!, b.start, "pauses overlap")
            }
            let now = t(max(clock, 0) + 30)
            XCTAssertLessThanOrEqual(state.stopped(at: now), state.elapsed(at: now))
        }
    }

    // MARK: - Auto-pause

    func testAutoPauseIsOffByDefault() {
        XCTAssertFalse(State.Setup(kind: .outdoor).autoPause)
        let running = started()
        XCTAssertEqual(State.reduce(running, .pause(.auto, at: t(600))), running,
                       "with auto-pause off, standing at a water station is still running time")
    }

    /// He paused to tie a shoe, then started jogging in place: the motion must not resume a
    /// pause he asked for. The athlete's word outranks the math.
    func testAutoResumeNeverLiftsAPauseTheAthleteAskedFor() {
        let paused = apply(started(autoPause: true), .pause(.manual(.lockScreen), at: t(600)))
        XCTAssertEqual(State.reduce(paused, .resume(.auto, at: t(610))), paused)
        XCTAssertEqual(paused.openPause?.reason, .manual)
    }

    func testTheAthleteCanLiftAnAutoPause() {
        let paused = apply(started(autoPause: true), .pause(.auto, at: t(600)))
        XCTAssertEqual(paused.openPause?.reason, .auto)
        let resumed = apply(paused, .resume(.manual(.lockScreen), at: t(640)))
        XCTAssertEqual(resumed.phase, .running)
        XCTAssertEqual(resumed.pauses, [State.Pause(start: t(600), end: t(640), reason: .auto)])
    }

    // MARK: - Controls

    /// David, #125: hold-to-end on the live screen; the Lock Screen pauses and resumes only.
    func testLockScreenPausesAndResumesButCannotEndOrDiscard() {
        let running = started()
        let paused = apply(running, .pause(.manual(.lockScreen), at: t(600)))
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(apply(paused, .resume(.manual(.lockScreen), at: t(660))).phase, .running)

        XCTAssertFalse(running.accepts(.endRequested(.lockScreen, at: t(700))))
        XCTAssertFalse(paused.accepts(.endRequested(.lockScreen, at: t(700))))
        XCTAssertFalse(paused.accepts(.discard(.lockScreen)))
        XCTAssertTrue(running.accepts(.endRequested(.liveScreen, at: t(700))), "hold-to-end, no pause needed")
    }

    /// Discard lives on the paused screen behind a second confirmation (frame 5b). A running
    /// run can't be thrown away in one gesture.
    func testDiscardNeedsThePauseScreen() {
        let running = started()
        XCTAssertEqual(State.reduce(running, .discard(.liveScreen)), running)
        XCTAssertEqual(apply(running, .pause(.manual(.liveScreen), at: t(60)), .discard(.liveScreen)).phase, .discarded)
    }

    /// A pocket double-tap on Start, or a stale button, must not reset a run in progress.
    func testASecondStartCannotWipeARunInProgress() {
        let running = apply(started(), .pause(.manual(.liveScreen), at: t(600)))
        XCTAssertEqual(State.reduce(running, .start(State.Setup(kind: .treadmill), at: t(700))), running)
    }

    // MARK: - Ending and saving

    func testAnOutdoorRunEndsOnTheSaveScreen() {
        let ended = apply(started(), .endRequested(.liveScreen, at: t(2400)))
        XCTAssertEqual(ended.phase, .ending(.review))
        XCTAssertEqual(ended.endedAt, t(2400))
        let saved = apply(ended, .endConfirmed, .saveSucceeded(workoutID: workoutID))
        XCTAssertEqual(saved.phase, .saved(workoutID: workoutID))
    }

    /// David, #125: a race finish saves itself and goes straight to the recap. No save screen
    /// between the finish mat and the result.
    func testARaceFinishSavesWithoutTheSaveScreen() {
        let finished = apply(started(.race), .endRequested(.liveScreen, at: t(11_700)))
        XCTAssertEqual(finished.phase, .ending(.saving))
        XCTAssertFalse(finished.accepts(.discard(.liveScreen)), "nothing to discard mid-write")
        XCTAssertEqual(apply(finished, .saveSucceeded(workoutID: workoutID)).phase, .saved(workoutID: workoutID))
    }

    func testAFailedSaveKeepsEverythingAndCanBeRetried() {
        let saving = apply(started(), .pause(.manual(.liveScreen), at: t(600)),
                           .resume(.manual(.liveScreen), at: t(660)),
                           .endRequested(.liveScreen, at: t(2400)), .endConfirmed)
        let failed = apply(saving, .saveFailed(reason: "Health unavailable"))
        XCTAssertEqual(failed.phase, .ending(.failed(reason: "Health unavailable")))
        XCTAssertEqual(failed.pauses, saving.pauses)
        XCTAssertEqual(failed.endedAt, saving.endedAt)
        XCTAssertEqual(apply(failed, .endConfirmed).phase, .ending(.saving))
    }

    // MARK: - Clocks: the pause list is moving time

    /// The pause list has to land in `TimeAccounting` as a pair it accepts unchanged, or the
    /// recorded run and its Health re-import would disagree about moving time.
    func testThePauseListRoundTripsThroughTimeAccounting() {
        let s = apply(started(autoPause: true),
                      .pause(.manual(.liveScreen), at: t(1200)), .resume(.manual(.liveScreen), at: t(1290)),
                      .pause(.auto, at: t(2100)), .resume(.auto, at: t(2145)),
                      .endRequested(.liveScreen, at: t(3000)))
        let c = s.clocks(at: t(9999))
        XCTAssertEqual(c.elapsedS, 3000)
        XCTAssertEqual(c.stoppedS, 135)
        XCTAssertEqual(c.movingS, 2865)
        XCTAssertEqual(TimeAccounting.resolve(movingS: c.movingS, elapsedS: c.elapsedS), c)
        XCTAssertTrue(c.hasMeaningfulStop)
        XCTAssertEqual(TimeAccounting.paceSecPerMile(seconds: c.movingS, miles: 6), 477)
    }

    func testMovingTimeFreezesWhilePaused() {
        let paused = apply(started(), .pause(.manual(.liveScreen), at: t(1200)))
        XCTAssertEqual(paused.clocks(at: t(1260)).movingS, 1200)
        XCTAssertEqual(paused.clocks(at: t(1290)).movingS, 1200)
        XCTAssertEqual(paused.clocks(at: t(1290)).elapsedS, 1290)
    }

    /// Ending from the pause screen: the trailing stop is stopped time, and both clocks stop
    /// at the end rather than ticking on while the save screen sits open.
    func testEndingWhilePausedClosesThePauseAndFreezesBothClocks() {
        let ended = apply(started(), .pause(.manual(.liveScreen), at: t(1800)),
                          .endRequested(.liveScreen, at: t(1860)))
        XCTAssertEqual(ended.pauses.last?.end, t(1860))
        XCTAssertEqual(ended.clocks(at: t(1860)), ended.clocks(at: t(86_400)))
        XCTAssertEqual(ended.clocks(at: t(1860)).movingS, 1800)
    }

    /// A 20 s stop at a light is recorded, honestly, and still reads as noise on screen.
    func testShortStopsAreRecordedButReadAsNoise() {
        let s = apply(started(), .pause(.manual(.liveScreen), at: t(600)),
                      .resume(.manual(.liveScreen), at: t(620)), .endRequested(.liveScreen, at: t(2400)))
        let c = s.clocks(at: t(2400))
        XCTAssertEqual(c.stoppedS, 20)
        XCTAssertFalse(c.hasMeaningfulStop)
    }

    /// A HealthKit callback queued behind a tap can arrive stamped earlier than the tap. A
    /// resume stamped before its pause must not make moving time exceed elapsed.
    func testOutOfOrderTimestampsCannotRunTheClockBackwards() {
        let s = apply(started(), .pause(.manual(.liveScreen), at: t(600)),
                      .resume(.manual(.liveScreen), at: t(590)),
                      .endRequested(.liveScreen, at: t(580)))
        XCTAssertEqual(s.pauses, [State.Pause(start: t(600), end: t(600), reason: .manual)])
        XCTAssertEqual(s.endedAt, t(600))
        let c = s.clocks(at: t(700))
        XCTAssertEqual(c.movingS, c.elapsedS)
    }

    // MARK: - Interruptions and crash recovery

    /// A call during a long run: the run records straight through it. Pausing here is the
    /// Chicago failure in a different coat.
    func testAPhoneCallIsLoggedAndTheClockKeepsRunning() {
        let s = apply(started(), .interrupted(.phoneCall, at: t(3600)))
        XCTAssertEqual(s.phase, .running)
        XCTAssertTrue(s.pauses.isEmpty)
        XCTAssertEqual(s.interruptions, [State.InterruptionRecord(kind: .phoneCall, at: t(3600))])
        XCTAssertEqual(s.clocks(at: t(3900)).movingS, 3900)
    }

    /// Killed at 30:00 while running, reopened at 34:00, the workout session still running:
    /// he was running the whole time, so the gap is moving time (#115).
    func testCrashWhileRunningWithTheSessionRunningCountsTheGap() {
        let recovering = apply(started(), .interrupted(.appTerminated, at: t(1800)))
        XCTAssertEqual(recovering.phase, .recovering(since: t(1800)))
        XCTAssertEqual(recovering.clocks(at: t(2040)).elapsedS, 2040, "wall time keeps counting")
        let back = apply(recovering, .recovered(sessionPaused: false))
        XCTAssertEqual(back.phase, .running)
        XCTAssertEqual(back.clocks(at: t(2040)).stoppedS, 0)
    }

    /// Same crash, but the session was paused: the gap is a pause from the last instant we
    /// knew about, and only he can lift it.
    func testCrashWithTheSessionPausedCountsTheGapAsAPause() {
        let back = apply(started(autoPause: true), .interrupted(.appTerminated, at: t(1800)),
                         .recovered(sessionPaused: true))
        XCTAssertEqual(back.phase, .paused)
        XCTAssertEqual(back.openPause, State.Pause(start: t(1800), end: nil, reason: .recoveryGap))
        XCTAssertEqual(State.reduce(back, .resume(.auto, at: t(2050))), back, "auto-resume can't lift it")
        let resumed = apply(back, .resume(.manual(.liveScreen), at: t(2050)))
        XCTAssertEqual(resumed.clocks(at: t(2100)).stoppedS, 250)
    }

    /// Paused at 28:20 to refill a bottle, killed at 30:00. The pause he started is the pause
    /// that continues — not a second, overlapping one.
    func testCrashWhilePausedKeepsTheOriginalPause() {
        let recovering = apply(started(), .pause(.manual(.liveScreen), at: t(1700)),
                               .interrupted(.appTerminated, at: t(1800)))
        let stillPaused = apply(recovering, .recovered(sessionPaused: true))
        XCTAssertEqual(stillPaused.pauses, [State.Pause(start: t(1700), end: nil, reason: .manual)])

        // The session says running: it resumed somewhere we couldn't hear. The session wins,
        // and the pause ends where our knowledge does.
        let running = apply(recovering, .recovered(sessionPaused: false))
        XCTAssertEqual(running.pauses, [State.Pause(start: t(1700), end: t(1800), reason: .manual)])
    }

    /// The session didn't survive. "Save what we have" ends the run at the last instant it
    /// was recorded — not hours later when he reopened the app.
    func testSaveWhatWeHaveEndsAtTheLastKnownInstant() {
        let ended = apply(started(), .interrupted(.appTerminated, at: t(1800)),
                          .endRequested(.liveScreen, at: t(9000)))
        XCTAssertEqual(ended.phase, .ending(.review))
        XCTAssertEqual(ended.endedAt, t(1800))
        XCTAssertEqual(ended.clocks(at: t(9000)).elapsedS, 1800)
    }

    func testASecondCrashWhileRecoveringKeepsTheFirstGap() {
        let s = apply(started(), .interrupted(.appTerminated, at: t(1800)),
                      .interrupted(.appTerminated, at: t(2500)))
        XCTAssertEqual(s.phase, .recovering(since: t(1800)))
        XCTAssertEqual(s.interruptions.count, 2)
    }

    /// Killed mid-write: we don't know whether Health has it. The run is kept for a retry.
    func testCrashDuringSaveKeepsTheRunForARetry() {
        let saving = apply(started(), .endRequested(.liveScreen, at: t(2400)), .endConfirmed)
        let after = apply(saving, .interrupted(.appTerminated, at: t(2401)))
        guard case .ending(.failed) = after.phase else { return XCTFail("\(after.phase)") }
        XCTAssertEqual(after.endedAt, t(2400))
        XCTAssertEqual(apply(after, .endConfirmed).phase, .ending(.saving))
    }

    // MARK: - The target

    /// David, #125: today's target on screen, with the option to hide it and run free — and
    /// change his mind.
    func testTheTargetHidesAndComesBackMidRun() {
        var s = started()
        XCTAssertTrue(s.showsTarget)
        s = apply(s, .setTargetVisible(false))
        XCTAssertFalse(s.showsTarget)
        XCTAssertEqual(s.target, tempo, "hiding is not forgetting")
        s = apply(s, .pause(.manual(.liveScreen), at: t(60)), .setTargetVisible(true))
        XCTAssertTrue(s.showsTarget)
    }

    func testStartingWithTheTargetHiddenCanStillShowIt() {
        let s = started(.treadmill, showTarget: false)
        XCTAssertFalse(s.showsTarget)
        XCTAssertTrue(apply(s, .setTargetVisible(true)).showsTarget)
    }

    func testARunWithNoTargetHasNothingToShow() {
        let free = started(target: .some(nil))
        XCTAssertFalse(free.showsTarget)
        XCTAssertEqual(State.reduce(free, .setTargetVisible(true)), free)
    }

    // MARK: - The crash snapshot (#115)

    /// #115 persists this struct every ten seconds and rehydrates it after iOS kills the app.
    /// Every phase, and a messy mid-run state, must come back exactly — and read the same clocks.
    func testEveryStateSurvivesTheSnapshotCodec() throws {
        let messy = apply(started(.race, autoPause: true),
                          .pause(.auto, at: t(600)), .resume(.auto, at: t(640)),
                          .interrupted(.phoneCall, at: t(900)), .setTargetVisible(false),
                          .pause(.manual(.lockScreen), at: t(1700)),
                          .interrupted(.appTerminated, at: t(1800)), .recovered(sessionPaused: true))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for (name, state) in fixtures + [("messy", messy)] {
            let data = try encoder.encode(state)
            let back = try decoder.decode(State.self, from: data)
            XCTAssertEqual(back, state, name)
            XCTAssertEqual(back.clocks(at: t(5000)), state.clocks(at: t(5000)), name)
        }
    }
}

/// SplitMix64: a fixed seed gives the same ten thousand events on every machine.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
