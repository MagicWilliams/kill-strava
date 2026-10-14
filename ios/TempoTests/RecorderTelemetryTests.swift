import XCTest
@testable import Tempo

/// Chicago, Sunday 11 Oct 2026: Strava paused itself during the marathon and the recording was
/// lost, and afterwards nobody could say when it stopped or why. Tempo's recorder reports on
/// itself so that question always has an answer in `app_events` (#131).
///
/// What these tests hold down is the shape of that answer: the names and keys the EM's queries
/// are written against, that a step the reducer ignored reports nothing, that each stop says who
/// made it, and that no line can carry where he ran or what he wrote. A key renamed by accident
/// would not crash anything — it would quietly split a trend line in two across app versions,
/// which is the failure this file exists to make loud.
final class RecorderTelemetryTests: XCTestCase {

    typealias State = RecorderState
    typealias Event = RecorderEvent
    typealias Line = RecorderTelemetry.Line

    // Chicago's 7:30 CDT gun.
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-11T12:30:00Z")!
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private let tempo = State.SessionTarget(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000131"),
        type: "tempo", title: "6 mi tempo", distanceM: 9656, paceSecPerMile: 450
    )

    /// One reducer step, the way the service (#114) takes it: dispatch, then report.
    private func step(_ state: State, _ event: Event) -> (State, [Line]) {
        let next = State.reduce(state, event)
        return (next, RecorderTelemetry.lines(from: state, on: event, to: next))
    }

    /// Runs `events` from `state`, returning where it ended and every line reported on the way.
    private func walk(_ state: State, _ events: Event...) -> (State, [Line]) {
        events.reduce((state, [Line]())) { acc, event in
            let (next, lines) = step(acc.0, event)
            return (next, acc.1 + lines)
        }
    }

    /// Running since `t0`, with the given setup.
    private func running(kind: State.RunKind = .outdoor, target: State.SessionTarget? = nil,
                         showTarget: Bool = true, autoPause: Bool = false) -> State {
        let setup = State.Setup(kind: kind, target: target, showTarget: showTarget, autoPause: autoPause)
        return walk(State(), .start(setup, at: t(-3)), .countdownDone(at: t(0))).0
    }

    // MARK: - The vocabulary

    /// These are the strings the EM's queries are written against. Changing one is a decision,
    /// not a refactor.
    func testEventNamesArePinned() {
        XCTAssertEqual(RecorderTelemetry.Event.allCases.map(\.rawValue), [
            "recorder.started", "recorder.paused", "recorder.resumed", "recorder.interrupted",
            "recorder.recovered", "recorder.recovery_failed", "recorder.saved",
            "recorder.save_failed", "recorder.discarded",
        ])
    }

    func testKeysAreSnakeCaseAndUnique() {
        let keys = RecorderTelemetry.Key.allCases.map(\.rawValue)
        XCTAssertEqual(Set(keys).count, keys.count)
        for key in keys {
            XCTAssertNotNil(key.range(of: "^[a-z][a-z_]*$", options: .regularExpression), key)
        }
    }

    // MARK: - Started

    func testStartReportsKindTargetAndAutoPauseWhenTheClocksStart() {
        let (_, atStart) = step(State(), .start(State.Setup(kind: .race, target: tempo, autoPause: true), at: t(-3)))
        XCTAssertEqual(atStart, [], "the countdown is not the run; a cancelled one must not read as a start")

        let counting = State.reduce(State(), .start(State.Setup(kind: .race, target: tempo, autoPause: true), at: t(-3)))
        let (_, lines) = step(counting, .countdownDone(at: t(0)))
        XCTAssertEqual(lines, [Line(event: .started, level: .info, context: [
            "kind": "race", "target": "shown", "session_type": "tempo", "auto_pause": "on",
        ])])
    }

    func testRunningFreeIsHiddenAndNoPlanIsNone() {
        let free = walk(State(), .start(State.Setup(kind: .outdoor, target: tempo, showTarget: false), at: t(-3)),
                        .countdownDone(at: t(0))).1
        XCTAssertEqual(free.first?.context["target"], "hidden")
        XCTAssertEqual(free.first?.context["session_type"], "tempo")

        let unplanned = walk(State(), .start(State.Setup(kind: .treadmill), at: t(-3)),
                             .countdownDone(at: t(0))).1
        XCTAssertEqual(unplanned.first?.context, [
            "kind": "treadmill", "target": "none", "session_type": "none", "auto_pause": "off",
        ])
    }

    // MARK: - Pause and resume say who stopped the clock

    func testAnAutoPauseDecisionIsReportedAsAuto() {
        var auto = AutoPause()
        var state = running(autoPause: true)
        var decision: AutoPause.Decision?
        // Standing at the light at mile 13 for ten seconds.
        for s in stride(from: 4_000.0, through: 4_010, by: 1) where decision == nil {
            decision = auto.ingest(AutoPause.Sample(at: t(s), speed: 0.1, source: .gps), recorder: state)
        }
        guard let pause = decision else { return XCTFail("ten seconds standing still never paused") }
        let (paused, lines) = step(state, pause.event)
        XCTAssertEqual(lines, [Line(event: .paused, level: .info, context: [
            "trigger": "auto", "elapsed_s": "4000", "pauses": "1",
        ])], "stamped where the stop began, not where it was confirmed")
        state = paused

        let (_, resumed) = step(state, .resume(.auto, at: t(4_030)))
        XCTAssertEqual(resumed, [Line(event: .resumed, level: .info, context: [
            "trigger": "auto", "pause_reason": "auto", "paused_s": "30", "elapsed_s": "4030",
        ])])
    }

    func testAManualPauseSaysWhichScreenItCameFrom() {
        let (paused, lines) = step(running(), .pause(.manual(.lockScreen), at: t(600)))
        XCTAssertEqual(lines, [Line(event: .paused, level: .info, context: [
            "trigger": "manual", "control": "lock_screen", "elapsed_s": "600", "pauses": "1",
        ])])

        let (_, resumed) = step(paused, .resume(.manual(.liveScreen), at: t(645.4)))
        XCTAssertEqual(resumed.first?.context, [
            "trigger": "manual", "control": "live_screen", "pause_reason": "manual",
            "paused_s": "45", "elapsed_s": "645",
        ])
    }

    /// Chicago's failure was a recorder that paused on its own. With auto-pause off the reducer
    /// ignores the request — and a request that changed nothing must not read as a pause.
    func testWhatTheReducerIgnoredIsNotReported() {
        let off = running(autoPause: false)
        XCTAssertEqual(step(off, .pause(.auto, at: t(100))).1, [])
        XCTAssertEqual(step(off, .endRequested(.lockScreen, at: t(100))).1, [], "the Lock Screen cannot end a run")

        let heStopped = State.reduce(running(autoPause: true), .pause(.manual(.liveScreen), at: t(100)))
        XCTAssertEqual(step(heStopped, .resume(.auto, at: t(110))).1, [],
                       "auto-resume cannot lift his pause, so it must not be reported as lifting it")

        let saved = walk(running(), .endRequested(.liveScreen, at: t(900)), .endConfirmed,
                         .saveSucceeded(workoutID: nil)).0
        XCTAssertEqual(step(saved, .pause(.manual(.lockScreen), at: t(950))).1, [])
        XCTAssertEqual(step(saved, .interrupted(.phoneCall, at: t(950))).1, [])
    }

    // MARK: - Interruptions

    func testAKilledAppIsAWarningThatCostTheRecording() {
        let (_, lines) = step(running(kind: .race), .interrupted(.appTerminated, at: t(7_200)))
        XCTAssertEqual(lines, [Line(event: .interrupted, level: .warn, context: [
            "reason": "app_terminated", "stops_recording": "true", "phase": "running",
            "kind": "race", "elapsed_s": "7200",
        ])])
    }

    func testACallIsLoggedButTheRunKeepsRecording() {
        let paused = State.reduce(running(), .pause(.manual(.liveScreen), at: t(300)))
        let (_, lines) = step(paused, .interrupted(.phoneCall, at: t(320)))
        XCTAssertEqual(lines, [Line(event: .interrupted, level: .info, context: [
            "reason": "phone_call", "stops_recording": "false", "phase": "paused",
            "kind": "outdoor", "elapsed_s": "320",
        ])])
    }

    func testAnInterruptedCountdownReportsTheCountdownNotTheResetState() {
        let counting = State.reduce(State(), .start(State.Setup(kind: .treadmill), at: t(-3)))
        let (after, lines) = step(counting, .interrupted(.sessionFailed, at: t(-1)))
        XCTAssertEqual(after, State())
        XCTAssertEqual(lines.first?.context["phase"], "countdown")
        XCTAssertEqual(lines.first?.context["kind"], "treadmill")
        XCTAssertEqual(lines.first?.context["elapsed_s"], "0")
    }

    func testEveryInterruptionHasASnakeCaseReason() {
        let all: [State.Interruption] = [.phoneCall, .locationRevoked, .sessionFailed, .appTerminated]
        XCTAssertEqual(all.map(RecorderTelemetry.label),
                       ["phone_call", "location_revoked", "session_failed", "app_terminated"])
    }

    // MARK: - Recovery is reported once, by #115

    func testTheReducersRecoveryStepIsNotReportedTwice() {
        let lost = State.reduce(running(), .interrupted(.appTerminated, at: t(1_000)))
        let (back, lines) = step(lost, .recovered(sessionPaused: false))
        XCTAssertEqual(back.phase, .running)
        XCTAssertEqual(lines, [], "#115 reports recorder.recovered with the outcome only it knows")
    }

    // MARK: - Ending

    func testAFailedSaveIsAnErrorCarryingTheReasonAsDetail() {
        let saving = walk(running(), .endRequested(.liveScreen, at: t(2_700)), .endConfirmed).0
        let (_, lines) = step(saving, .saveFailed(reason: "HKError 3"))
        XCTAssertEqual(lines, [Line(event: .saveFailed, level: .error, detail: "HKError 3", context: [
            "kind": "outdoor", "elapsed_s": "2700",
        ])])
    }

    func testDiscardingALostRunIsReportedThroughTheLastKnownInstant() {
        let lost = State.reduce(running(), .interrupted(.sessionFailed, at: t(1_500)))
        let (after, lines) = step(lost, .discard(.liveScreen))
        XCTAssertEqual(after.phase, .discarded)
        XCTAssertEqual(lines, [Line(event: .discarded, level: .info, context: [
            "phase": "recovering", "kind": "outdoor", "pauses": "0", "interruptions": "1",
            "elapsed_s": "1500",
        ])])
    }

    func testSaveSucceededWaitsForTheTempoRow() {
        let saving = walk(running(), .endRequested(.liveScreen, at: t(2_700)), .endConfirmed).0
        XCTAssertEqual(step(saving, .saveSucceeded(workoutID: UUID())).1, [],
                       "recorder.saved is sent once, by saved(…), with both halves of the save")
    }

    // MARK: - Saved

    /// A 5-mile run with one auto pause and a call, the GPS slow to lock and two bad fixes.
    func testSavedCarriesTheWholeSave() {
        let state = walk(
            running(autoPause: true),
            .pause(.auto, at: t(1_200)), .resume(.auto, at: t(1_260)),
            .interrupted(.phoneCall, at: t(1_800)),
            .endRequested(.liveScreen, at: t(2_760)), .endConfirmed, .saveSucceeded(workoutID: nil)
        ).0
        let fixes: [TrackMath.Verdict: Int] = [.accepted: 2_700, .awaitingLock: 40, .inaccurate: 50, .tooFast: 10]

        let line = RecorderTelemetry.saved(state, distanceM: 8_046.72, fixes: fixes,
                                           tempo: .saved(runID: UUID()), saveLatency: 0.84)
        XCTAssertEqual(line, Line(event: .saved, level: .info, context: [
            "kind": "outdoor", "distance_m": "8047", "duration_s": "2760", "moving_s": "2700",
            "save_latency_ms": "840", "tempo_outcome": "saved",
            "pauses": "1", "auto_pauses": "1", "interruptions": "1", "auto_pause": "on",
            "fix_count": "2800", "filtered_fix_pct": "4",
            "fixes_awaiting_lock": "40", "fixes_inaccurate": "50", "fixes_stale": "0",
            "fixes_out_of_order": "0", "fixes_too_fast": "10",
        ]))
    }

    func testATreadmillRunHasNoFixesToFilter() {
        let state = walk(running(kind: .treadmill), .endRequested(.liveScreen, at: t(1_800)),
                         .endConfirmed, .saveSucceeded(workoutID: nil)).0
        let line = RecorderTelemetry.saved(state, distanceM: nil, fixes: [:], tempo: .queued, saveLatency: 3)
        XCTAssertEqual(line.context["fix_count"], "0")
        XCTAssertEqual(line.context["filtered_fix_pct"], "none", "0 of 0 is not 0% filtered")
        XCTAssertEqual(line.context["distance_m"], "none")
        XCTAssertEqual(line.context["tempo_outcome"], "queued")
    }

    func testEveryTempoOutcomeHasALabel() {
        let outcomes: [RecordedRunSaver.Outcome] = [.saved(runID: UUID()), .tooShort, .queued, .dropped]
        XCTAssertEqual(outcomes.map(RecorderTelemetry.label), ["saved", "too_short", "queued", "dropped"])
    }

    // MARK: - Nothing he ran through or wrote

    /// A whole run through a real `TrackMath.Track`, with coordinates no line has any reason to
    /// contain. Every line from it uses only the shared keys, and none carries a coordinate or
    /// the session's title.
    func testNoLineCarriesACoordinateOrTheTargetTitle() {
        var track = TrackMath.Track(start: t0)
        for i in 0..<120 {
            track.ingest(TrackMath.Fix(timestamp: t(Double(i)), latitude: 41.8781136 + Double(i) * 0.00002,
                                       longitude: -87.6297982, horizontalAccuracy: i % 10 == 0 ? 60 : 5))
        }
        XCTAssertGreaterThan(track.distanceM, 0)

        let setup = State.Setup(kind: .race, target: tempo, autoPause: true)
        let (state, lines) = walk(
            State(), .start(setup, at: t(-3)), .countdownDone(at: t(0)),
            .pause(.manual(.lockScreen), at: t(60)), .resume(.manual(.lockScreen), at: t(70)),
            .interrupted(.locationRevoked, at: t(90)),
            .endRequested(.liveScreen, at: t(120)), .saveSucceeded(workoutID: nil)
        )
        let all = lines + [RecorderTelemetry.saved(state, distanceM: track.distanceM, fixes: track.verdicts,
                                                   tempo: .saved(runID: UUID()), saveLatency: 1)]
        XCTAssertEqual(all.map(\.event), [.started, .paused, .resumed, .interrupted, .saved])

        let keys = Set(RecorderTelemetry.Key.allCases.map(\.rawValue))
        for line in all {
            XCTAssertTrue(Set(line.context.keys).isSubset(of: keys), "\(line.event): a key outside the vocabulary")
            for value in line.context.values + [line.detail].compactMap({ $0 }) {
                XCTAssertFalse(value.contains("41.8") || value.contains("87.6"), "\(line.event): \(value)")
                XCTAssertFalse(value.contains("6 mi tempo"), "\(line.event): \(value)")
            }
        }
        XCTAssertEqual(all.last?.context["fix_count"], "120")
        XCTAssertEqual(all.last?.context["fixes_inaccurate"], "12")
    }
}
