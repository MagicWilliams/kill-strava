import XCTest
@testable import Tempo

/// Chicago, Sunday 11 Oct 2026: the recording of the marathon stopped and the run was lost
/// (#111). #115 is the other half of that lesson — iOS killing the app mid-run must cost the
/// tail of the curve and nothing else.
///
/// The three things pinned here are the three that can only be checked on a real force-quit
/// otherwise: the snapshot comes back as exactly what went in, the decision table covers every
/// combination of (session recovered × snapshot present × snapshot age) with no silent drop,
/// and the merge after a gap keeps the clocks honest and the distance monotone.
final class InProgressRunTests: XCTestCase {

    typealias State = RecorderState
    typealias Snapshot = InProgressRun
    typealias Curve = InProgressRun.DistanceCurve
    typealias Session = InProgressRun.SessionRecovery

    // Chicago's 7:30 CDT gun.
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-11T12:30:00Z")!
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// 8:00/mi — the pace every curve in this file is built at.
    private let mps = 3.35

    private let target = State.SessionTarget(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000115"),
        type: "long", title: "20 mi long run", distanceM: 32187, paceSecPerMile: 525
    )

    private func apply(_ state: State, _ events: RecorderEvent...) -> State {
        events.reduce(state, State.reduce)
    }

    private func started(_ kind: State.RunKind = .outdoor, autoPause: Bool = false) -> State {
        apply(State(),
              .start(State.Setup(kind: kind, target: target, autoPause: autoPause), at: t(-3)),
              .countdownDone(at: t(0)))
    }

    /// A steady curve over `[0, seconds]`, one credited point every 10 s.
    private func steady(to seconds: Double, every step: Double = 10) -> Curve {
        var points = [BestEfforts.Point(t: 0, m: 0)]
        var s = step
        while s <= seconds {
            points.append(BestEfforts.Point(t: s, m: mps * s))
            s += step
        }
        return Curve(points)
    }

    /// The snapshot the recorder would have written at `savedAt` seconds into a live run.
    private func snapshot(
        _ state: State? = nil,
        savedAtS: Double = 600,
        curveTo: Double? = nil
    ) -> Snapshot {
        Snapshot(
            savedAt: t(savedAtS),
            state: state ?? started(),
            workoutSessionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000CC"),
            curve: steady(to: curveTo ?? savedAtS),
            movingS: savedAtS,
            elevationGainM: 42,
            elevationLossM: 17,
            lastFixes: (0..<4).map {
                Snapshot.CarriedFix(TrackMath.Fix(
                    timestamp: t(savedAtS - Double(3 - $0)),
                    latitude: 41.8781 + Double($0) * 0.0001,
                    longitude: -87.6298,
                    horizontalAccuracy: 5
                ))
            }
        )
    }

    private func roundTrip(_ snapshot: Snapshot) throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: try JSONEncoder().encode(snapshot))
    }

    // MARK: - The codec

    func testSnapshotRoundTripsExactly() throws {
        let original = snapshot()
        XCTAssertEqual(try roundTrip(original), original,
                       "a snapshot has to come back as exactly what went in — every instant in it is one a clock gets rebuilt from")
    }

    /// Each phase carries different associated values, and `.ending`/`.saved`/`.recovering`
    /// are the ones a crash lands in. A phase that fails to round-trip is a run that comes
    /// back as the wrong kind of problem.
    func testEveryPhaseRoundTrips() throws {
        let phases: [(String, State.Phase)] = [
            ("idle", .idle),
            ("countdown", .countdown(startedAt: t(-3))),
            ("running", .running),
            ("paused", .paused),
            ("ending.review", .ending(.review)),
            ("ending.saving", .ending(.saving)),
            ("ending.failed", .ending(.failed(reason: "Tempo closed while saving"))),
            ("saved", .saved(workoutID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"))),
            ("savedWithoutID", .saved(workoutID: nil)),
            ("discarded", .discarded),
            ("recovering", .recovering(since: t(600))),
        ]
        for (name, phase) in phases {
            var state = started()
            state.phase = phase
            let original = snapshot(state)
            XCTAssertEqual(try roundTrip(original), original, "\(name) did not survive the codec")
        }
    }

    /// A snapshot written while he is stopped is the one that matters most: the open pause is
    /// what the recovery gap gets measured against, and a pause that came back closed would
    /// hand him a run whose moving time swallowed the stop.
    func testPausesAndInterruptionsSurviveTheCodec() throws {
        let state = apply(
            started(),
            .pause(.manual(.lockScreen), at: t(300)),
            .resume(.manual(.liveScreen), at: t(340)),
            .interrupted(.phoneCall, at: t(500)),
            .pause(.auto, at: t(560)),
            .pause(.manual(.liveScreen), at: t(580))
        )
        XCTAssertEqual(state.pauses.count, 2, "auto-pause is off by default, so .pause(.auto) never happened")

        let back = try roundTrip(snapshot(state))
        XCTAssertEqual(back.state.pauses, state.pauses)
        XCTAssertEqual(back.state.interruptions.map(\.kind), [.phoneCall],
                       "the call it ran through is logged, not a pause")
        XCTAssertEqual(back.state.openPause?.reason, .manual)
        XCTAssertEqual(back.state.openPause?.start, t(580), "still stopped, and stopped since exactly then")
        XCTAssertEqual(back.state.clocks(at: t(700)).movingS, state.clocks(at: t(700)).movingS)
    }

    /// The curve is written as two flat arrays of numbers, which is the only reason carrying
    /// a marathon's worth of it every ten seconds is affordable.
    func testCurveIsWrittenAsFlatArraysOfNumbers() throws {
        let json = String(data: try JSONEncoder().encode(Curve([
            BestEfforts.Point(t: 10, m: 33.5), BestEfforts.Point(t: 20, m: 67),
        ])), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"t\":["), "one array per axis, got \(json)")
        XCTAssertTrue(json.contains("\"m\":["), "one array per axis, got \(json)")
        XCTAssertEqual(json.filter { $0 == "{" }.count, 1,
                       "no per-point objects — eight thousand of those is three times the bytes: \(json)")
    }

    /// Rounding happens when the curve is built, not when it is written, so there is never a
    /// stored copy and an in-memory copy of the same curve that disagree in the sixth decimal.
    func testCurveRoundsToATenthAtConstructionSoThereIsOnlyOneCopy() throws {
        let curve = Curve([BestEfforts.Point(t: 1.2345, m: 4.5678)])
        XCTAssertEqual(curve.t, [1.2])
        XCTAssertEqual(curve.m, [4.6], "a tenth of a metre is far finer than any GPS fix is true to")
        XCTAssertEqual(try roundTrip(snapshot(curveTo: 600)).curve, steady(to: 600))
    }

    func testCurvePairsOnlyAsFarAsBothArraysReach() {
        var curve = steady(to: 100)
        curve.m.removeLast()
        XCTAssertEqual(curve.points.count, curve.m.count,
                       "a truncated write must never produce a point with a time and no distance")
    }

    // MARK: - When it is written

    func testFirstSnapshotOfALiveRunIsWrittenImmediately() {
        XCTAssertTrue(Snapshot.shouldSave(last: nil, state: started(), now: t(0)))
    }

    func testStateChangeIsWrittenAtOnceAndOtherwiseEveryTenSeconds() {
        let running = started()
        let last = snapshot(running, savedAtS: 600)

        XCTAssertFalse(Snapshot.shouldSave(last: last, state: running, now: t(609.9)),
                       "nothing changed and the interval has not elapsed")
        XCTAssertTrue(Snapshot.shouldSave(last: last, state: running, now: t(610)),
                      "ten seconds is the most a crash is allowed to cost")

        let paused = apply(running, .pause(.manual(.liveScreen), at: t(601)))
        XCTAssertTrue(Snapshot.shouldSave(last: last, state: paused, now: t(601)),
                      "a pause has to be on disk before the next tick — it is what makes the gap a stop")
    }

    func testNothingIsWrittenOnceTheRunHasAHome() {
        for phase in [State.Phase.idle, .saved(workoutID: UUID()), .discarded] {
            var state = started()
            state.phase = phase
            XCTAssertFalse(Snapshot.shouldSave(last: nil, state: state, now: t(900)))
            XCTAssertTrue(Snapshot.shouldClear(state), "the snapshot must go, or one run becomes two")
        }
    }

    func testAFailedSaveKeepsItsSnapshot() {
        var state = started()
        state.phase = .ending(.failed(reason: "network"))
        XCTAssertFalse(Snapshot.shouldClear(state),
                       "the run is still only in Tempo's hands — clearing now loses it on the next kill")
    }

    // MARK: - The decision table

    /// Session recovered × snapshot present × snapshot age, every combination, with the
    /// outcome spelled out. A new case has to be added here on purpose.
    func testRecoveryDecisionTable() {
        let live = snapshot()                                  // running, written at 10:00
        let now = t(630)                                       // reopened 30 s later
        let stale = t(630 + Snapshot.maxRescueAge)             // reopened the next day

        // Killed part-way through the write to Health.
        let saving = apply(started(), .endRequested(.liveScreen, at: t(1200)), .endConfirmed)
        let countdown = apply(State(), .start(State.Setup(kind: .outdoor, target: target), at: t(-3)))
        var finished = started()
        finished.phase = .saved(workoutID: UUID())

        let running = Session(isPaused: false, distanceM: mps * 630)
        let heldPaused = Session(isPaused: true, distanceM: mps * 600)

        let table: [(name: String, snapshot: Snapshot?, session: Session?, now: Date, expected: String)] = [
            ("nothing at all",            nil,                      nil,        now,   "nothing"),
            ("session, no snapshot",      nil,                      running,    now,   "orphan_session"),
            ("snapshot + session",        live,                     running,    now,   "resumed"),
            ("snapshot + paused session", live,                     heldPaused, now,   "resumed"),
            ("snapshot, no session",      live,                     nil,        now,   "rescue_offered"),
            ("stale snapshot, no session", live,                    nil,        stale, "expired"),
            ("stale snapshot + session",  live,                     running,    stale, "resumed"),
            ("killed mid-save",           snapshot(saving),         nil,        now,   "unfinished"),
            ("killed in the countdown",   snapshot(countdown),      nil,        now,   "nothing"),
            ("snapshot of a saved run",   snapshot(finished),       nil,        now,   "nothing"),
            ("saved run + live session",  snapshot(finished),       running,    now,   "orphan_session"),
        ]

        for row in table {
            let outcome = Snapshot.recover(snapshot: row.snapshot, session: row.session, now: row.now)
            XCTAssertEqual(outcome.label, row.expected, row.name)
        }
    }

    /// A snapshot too old to be a run in progress is still a run. The one thing recovery may
    /// never do is drop it on the floor.
    func testAnExpiredSnapshotStillHandsTheRunBack() {
        let outcome = Snapshot.recover(
            snapshot: snapshot(), session: nil, now: t(630 + Snapshot.maxRescueAge))
        guard case .expired(let state) = outcome else { return XCTFail("expected .expired, got \(outcome)") }
        XCTAssertEqual(state.phase, .recovering(since: t(600)))
        XCTAssertEqual(state.target, target, "including what it was run against")
    }

    func testRescueCanOnlyEndOrBeDiscarded() {
        guard case .rescue(let state) = Snapshot.recover(snapshot: snapshot(), session: nil, now: t(630))
        else { return XCTFail("expected .rescue") }

        // "Save what we have": the run ends where our knowledge ends, not where he reopened.
        let saved = apply(state, .endRequested(.liveScreen, at: t(99_999)))
        XCTAssertEqual(saved.endedAt, t(600),
                       "the run ended at the last instant we know it was recording")
        XCTAssertEqual(saved.phase, .ending(.review))

        XCTAssertEqual(apply(state, .discard(.liveScreen)).phase, .discarded)
        XCTAssertFalse(state.accepts(.endRequested(.lockScreen, at: t(700))),
                       "the Lock Screen still cannot end a run")
    }

    func testKilledMidSaveComesBackOnTheSaveScreenWithTheRunIntact() {
        let saving = apply(started(), .endRequested(.liveScreen, at: t(1200)), .endConfirmed)
        guard case .unfinished(let state) = Snapshot.recover(
            snapshot: snapshot(saving, savedAtS: 1200), session: nil, now: t(1260))
        else { return XCTFail("expected .unfinished") }

        XCTAssertEqual(state.phase, .ending(.failed(reason: "Tempo closed while saving")))
        XCTAssertEqual(state.endedAt, t(1200), "the clock stopped before the kill; it stays stopped there")
        XCTAssertEqual(state.interruptions.map(\.kind), [.appTerminated])
    }

    func testAnOrphanSessionIsReportedRatherThanIgnored() {
        XCTAssertEqual(
            Snapshot.recover(snapshot: nil, session: Session(isPaused: false), now: t(0)),
            .orphanSession,
            "HealthKit knows about a run Tempo does not; #114 decides what to do, but it is never silent")
    }

    // MARK: - The merge after a gap

    /// The session came back running. Wall time kept counting through the kill; none of it
    /// becomes a pause, because the session says he never stopped.
    func testRecoveredRunningSessionCountsTheGapAsRunning() {
        guard case .resume(let state) = Snapshot.recover(
            snapshot: snapshot(savedAtS: 600), session: Session(isPaused: false), now: t(720))
        else { return XCTFail("expected .resume") }

        XCTAssertEqual(state.phase, .running)
        XCTAssertEqual(state.pauses, [], "the session was running; the gap was running")
        let clocks = state.clocks(at: t(720))
        XCTAssertEqual(clocks.elapsedS, 720, "wall time keeps counting across the kill")
        XCTAssertEqual(clocks.movingS, 720)
    }

    /// The session came back paused. The gap is a `.recoveryGap` pause — and only he can lift
    /// it, because we were not there to see him start running again.
    func testRecoveredPausedSessionTurnsTheGapIntoAPauseOnlyHeCanLift() {
        // Auto-pause on, so the last assertion is about the recovery gap and not about the
        // setting being off.
        guard case .resume(let state) = Snapshot.recover(
            snapshot: snapshot(started(autoPause: true), savedAtS: 600),
            session: Session(isPaused: true), now: t(720))
        else { return XCTFail("expected .resume") }

        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.openPause?.reason, .recoveryGap)
        XCTAssertEqual(state.openPause?.start, t(600))

        let clocks = state.clocks(at: t(720))
        XCTAssertEqual(clocks.elapsedS, 720)
        XCTAssertEqual(clocks.movingS, 600, "moving time loses exactly the gap, to the second")

        var autoPause = AutoPause()
        let resumed = (0..<10).compactMap {
            autoPause.ingest(.init(at: t(720 + Double($0)), speed: mps, source: .gps), recorder: state)
        }
        XCTAssertTrue(resumed.isEmpty, "auto-resume may not lift a recovery gap")
    }

    /// He paused at a light, then the app died. The pause stays open across the kill and the
    /// session agrees it was paused.
    func testAPauseHeMadeBeforeTheKillStaysHis() {
        let paused = apply(started(), .pause(.manual(.liveScreen), at: t(540)))
        guard case .resume(let state) = Snapshot.recover(
            snapshot: snapshot(paused, savedAtS: 600), session: Session(isPaused: true), now: t(720))
        else { return XCTFail("expected .resume") }

        XCTAssertEqual(state.pauses.count, 1, "no second pause stacked on the one already open")
        XCTAssertEqual(state.openPause?.reason, .manual)
        XCTAssertEqual(state.openPause?.start, t(540))
        XCTAssertEqual(state.clocks(at: t(720)).movingS, 540)
    }

    /// Our snapshot said paused, the recovered session says running: he resumed from the Lock
    /// Screen in a moment we were not alive for. The session wins, and the pause ends where
    /// our knowledge of it does.
    func testSessionOutranksTheSnapshotOnWhetherHeWasStopped() {
        let paused = apply(started(), .pause(.manual(.liveScreen), at: t(540)))
        guard case .resume(let state) = Snapshot.recover(
            snapshot: snapshot(paused, savedAtS: 600), session: Session(isPaused: false), now: t(720))
        else { return XCTFail("expected .resume") }

        XCTAssertEqual(state.phase, .running)
        XCTAssertEqual(state.pauses.first?.end, t(600))
        XCTAssertEqual(state.clocks(at: t(720)).movingS, 660, "only the 60 s we knew about is lost")
    }

    // MARK: - Splicing the curve

    func testSplicedCurveMatchesTheRunThatWasNeverInterrupted() {
        let continuous = steady(to: 1800)
        let carried = steady(to: 600)
        // Tempo was dead from 10:00 to 12:00; the fresh track starts crediting at 12:10 and
        // its metres restart at zero.
        let after = Curve((73...180).map { BestEfforts.Point(t: Double($0) * 10, m: mps * (Double($0) * 10 - 720)) })

        let spliced = Snapshot.splice(
            carried: carried,
            after: after,
            gapMetersM: Snapshot.gapMeters(carried: carried, session: Session(isPaused: false, distanceM: mps * 720)),
            resumedAtS: 720
        )

        XCTAssertEqual(spliced.lastMeters, continuous.lastMeters, accuracy: 0.2,
                       "the metres he ran while Tempo was dead are the session's to report, and they are not lost")

        let unit = Units.metersPerMile
        let expected = TrackMath.splits(timeline: continuous.points, splitMeters: unit)
        let actual = TrackMath.splits(timeline: spliced.points, splitMeters: unit)
        XCTAssertEqual(actual.count, expected.count)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.paceS, e.paceS, accuracy: 1.0, "split \(e.index) drifted across the splice")
        }
    }

    func testSplicedCurveIsMonotoneEvenWhenTheSessionReportsLessThanWeRecorded() {
        let carried = steady(to: 600)
        let after = Curve([BestEfforts.Point(t: 0, m: 0), BestEfforts.Point(t: 610, m: 33.5)])
        let spliced = Snapshot.splice(
            carried: carried,
            after: after,
            // A session statistic below our own curve is one we trust less than the curve —
            // never a reason to take metres back off a screen he is looking at.
            gapMetersM: Snapshot.gapMeters(carried: carried, session: Session(isPaused: false, distanceM: 100)),
            resumedAtS: 605
        )
        XCTAssertGreaterThanOrEqual(spliced.lastMeters, carried.lastMeters)
        XCTAssertEqual(zip(spliced.t, spliced.t.dropFirst()).filter { $0 >= $1 }.count, 0, "time never goes back")
        XCTAssertEqual(zip(spliced.m, spliced.m.dropFirst()).filter { $0 > $1 }.count, 0, "distance never goes back")
    }

    func testTheGapIsCreditedOnceAtTheInstantRecordingCameBack() {
        let carried = steady(to: 600)
        let spliced = Snapshot.splice(carried: carried, after: Curve([]), gapMetersM: 402, resumedAtS: 720)
        XCTAssertEqual(spliced.lastMeters, carried.lastMeters + 402, accuracy: 0.2)
        XCTAssertEqual(spliced.t.last, 720, "credited where our knowledge resumes, not spread over a gap we did not see")
    }

    func testNoSessionDistanceCreditsNoGap() {
        let carried = steady(to: 600)
        XCTAssertEqual(Snapshot.gapMeters(carried: carried, session: nil), 0)
        XCTAssertEqual(Snapshot.gapMeters(carried: carried, session: Session(isPaused: false)), 0)
    }

    // MARK: - Picking the run back up

    /// A session that survived the kill: the curve carries on from the snapshot, the
    /// two minutes nobody measured are credited from the session's own distance at the
    /// moment recording came back, and Health's bookmark sits at what the session holds —
    /// which, outdoors, is exactly the distance Tempo had written into it.
    func testAResumedRunCarriesTheSessionsGapAndWritesOnlyWhatHealthLacks() throws {
        let live = snapshot(savedAtS: 600)
        // The last ten seconds of chunks landed after the last snapshot; then he ran on for
        // two minutes with nothing listening.
        let session = Session(isPaused: false, distanceM: mps * 610)
        let seed = Snapshot.resumption(snapshot: live, session: session, resumedAt: t(720))

        XCTAssertEqual(Array(seed.curve.points.prefix(live.curve.t.count)), live.curve.points, "history intact")
        XCTAssertEqual(seed.curve.t.last, 720, "the curve reaches the instant recording came back")
        XCTAssertEqual(seed.curve.lastMeters, mps * 610, accuracy: 0.2,
                       "Health had ten seconds more than the snapshot: that is real running, credited")
        XCTAssertEqual(seed.inHealth.m, seed.curve.lastMeters, accuracy: 0.2, "and it is already in Health")
    }

    func testARescuedRunHasEverythingStillToWriteAndGainsNothing() {
        let live = snapshot(savedAtS: 600)
        let seed = Snapshot.resumption(snapshot: live, session: nil, resumedAt: nil)
        XCTAssertEqual(seed.curve, live.curve, "no session, no gap: the run ends where our knowledge does")
        XCTAssertEqual(seed.inHealth, BestEfforts.Point(t: 0, m: 0), "the live builder died with the session")
    }

    /// A session that came back without a distance statistic: we cannot tell what Health
    /// holds. Writing the whole run again would double it; the bookmark goes at the end of
    /// what we carried, and the worst case is ten seconds short.
    func testASessionWithNoDistanceStatisticIsNeverWrittenTwice() {
        let live = snapshot(savedAtS: 600)
        let seed = Snapshot.resumption(snapshot: live, session: Session(isPaused: true), resumedAt: t(700))
        XCTAssertEqual(seed.inHealth.m, live.distanceM, accuracy: 0.001)
        XCTAssertEqual(seed.curve.lastMeters, live.distanceM, accuracy: 0.001, "paused through the gap: flat")
        XCTAssertEqual(seed.curve.t.last, 700)
    }

    func testOnlyASessionFromAnotherRecordingIsAMismatch() {
        let live = snapshot()
        XCTAssertTrue(Snapshot.matches(snapshot: live, sessionRecordingID: live.workoutSessionID))
        XCTAssertTrue(Snapshot.matches(snapshot: live, sessionRecordingID: nil),
                      "killed before the metadata landed: still ours")
        XCTAssertFalse(Snapshot.matches(snapshot: live, sessionRecordingID: UUID()), "another run: never spliced on")
        var anonymous = live
        anonymous.workoutSessionID = nil
        XCTAssertTrue(Snapshot.matches(snapshot: anonymous, sessionRecordingID: UUID()))
    }

    // MARK: - Telemetry

    func testRecoveryReportsItselfWithoutLeakingHealthData() {
        let live = snapshot()
        let resumed = Snapshot.recover(snapshot: live, session: Session(isPaused: true), now: t(720))
        guard let line = Snapshot.telemetry(for: resumed, snapshot: live, session: Session(isPaused: true), now: t(720))
        else { return XCTFail("a recovery has to report itself") }

        XCTAssertEqual(line.event, "recorder.recovered")
        XCTAssertEqual(line.context["outcome"], "resumed")
        XCTAssertEqual(line.context["gap_s"], "120")
        XCTAssertEqual(line.context["session_paused"], "true")
        XCTAssertEqual(line.context["kind"], "outdoor")
        XCTAssertNil(line.context["distance_m"], "how far he ran is health data; the report does not need it")
    }

    func testEveryFailureToGetTheRunBackReportsTheSameKey() {
        let live = snapshot()
        let cases: [(InProgressRun.Recovery, String)] = [
            (Snapshot.recover(snapshot: live, session: nil, now: t(630)), "rescue_offered"),
            (Snapshot.recover(snapshot: live, session: nil, now: t(630 + Snapshot.maxRescueAge)), "expired"),
            (Snapshot.recover(snapshot: nil, session: Session(isPaused: false), now: t(0)), "orphan_session"),
        ]
        for (outcome, label) in cases {
            let line = Snapshot.telemetry(for: outcome, snapshot: live, session: nil, now: t(630))
            XCTAssertEqual(line?.event, "recorder.recovery_failed", label)
            XCTAssertEqual(line?.context["outcome"], label)
        }
    }

    func testAClearLaunchReportsNothing() {
        let outcome = Snapshot.recover(snapshot: nil, session: nil, now: t(0))
        XCTAssertNil(Snapshot.telemetry(for: outcome, snapshot: nil, session: nil, now: t(0)),
                     "a launch with no run to recover is not an event")
    }
}
