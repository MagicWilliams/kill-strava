import XCTest
@testable import Tempo

/// Chicago, Sunday 11 Oct 2026: Strava's auto-pause decided David had stopped in the middle of
/// the marathon and the recording was lost (#111). Tempo's auto-pause is off unless he turns
/// it on (#113), and when it is on these tests are what it has to survive: a stoplight pauses
/// and resumes; the GPS going dark under Lower Wacker does not; a stuck GPS fix cannot outvote
/// a pedometer that is still counting strides; and nothing it does can end a run.
///
/// Every test drives the real reducer with what auto-pause decides, the way the service will,
/// so a pause that "fires" here is a pause that lands on the run.
final class AutoPauseTests: XCTestCase {

    typealias State = RecorderState
    typealias Sample = AutoPause.Sample

    private let t0 = ISO8601DateFormatter().date(from: "2026-10-11T12:30:00Z")!
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// 8:00/mi.
    private let running = 3.35

    private func started(autoPause: Bool = true) -> State {
        let setup = State.Setup(kind: .outdoor, target: nil, autoPause: autoPause)
        return [RecorderEvent.start(setup, at: t(-3)), .countdownDone(at: t(0))]
            .reduce(State(), State.reduce)
    }

    /// One reading per second over `[from, to)`.
    private func gps(_ speed: Double, from: Int, to: Int) -> [Sample] {
        (from..<to).map { Sample(at: t(TimeInterval($0)), speed: speed, source: .gps) }
    }

    private struct Drive {
        var state: State
        var detector: AutoPause
        var decisions: [AutoPause.Decision] = []
    }

    /// Feeds samples in order, dispatching every decision into the reducer as #114 will.
    private func drive(_ state: State, _ samples: [Sample], detector: AutoPause = AutoPause()) -> Drive {
        var d = Drive(state: state, detector: detector)
        for s in samples {
            if let decision = d.detector.ingest(s, recorder: d.state) {
                d.decisions.append(decision)
                d.state = State.reduce(d.state, decision.event)
            }
        }
        return d
    }

    // MARK: - The stoplight

    func testStoplightWaitPausesAndResumesAndMovingTimeLosesExactlyTheWait() {
        // Ten minutes running, 40 s at the light on Halsted, then off again.
        let samples = gps(running, from: 0, to: 600) + gps(0, from: 600, to: 640) + gps(running, from: 640, to: 900)
        let d = drive(started(), samples)

        XCTAssertEqual(d.decisions, [.pause(at: t(600)), .resume(at: t(640))],
                       "both stamped at the first sample of the streak that proved them")
        XCTAssertEqual(d.state.phase, .running)
        XCTAssertEqual(d.state.pauses, [State.Pause(start: t(600), end: t(640), reason: .auto)])
        let clocks = d.state.clocks(at: t(900))
        XCTAssertEqual(clocks.elapsedS, 900)
        XCTAssertEqual(clocks.movingS, 860)
    }

    func testThePauseLandsOnlyOnceTheStopHasLastedEightSeconds() {
        var detector = AutoPause()
        var state = started()
        for s in gps(running, from: 0, to: 60) { XCTAssertNil(detector.ingest(s, recorder: state)) }
        // 60…67 is seven seconds of standing: not yet.
        for s in gps(0, from: 60, to: 68) { XCTAssertNil(detector.ingest(s, recorder: state)) }
        // The sample at 68 makes it eight.
        let decision = detector.ingest(Sample(at: t(68), speed: 0, source: .gps), recorder: state)
        XCTAssertEqual(decision, .pause(at: t(60)))
        state = State.reduce(state, decision!.event)

        // Resume needs three seconds of running: 100, 101, 102 is two, 103 makes three.
        for s in gps(0, from: 69, to: 100) { XCTAssertNil(detector.ingest(s, recorder: state)) }
        for s in gps(running, from: 100, to: 103) { XCTAssertNil(detector.ingest(s, recorder: state)) }
        XCTAssertEqual(detector.ingest(Sample(at: t(103), speed: running, source: .gps), recorder: state),
                       .resume(at: t(100)))
    }

    func testASevenSecondStopToTieAShoeDoesNotPause() {
        let samples = gps(running, from: 0, to: 300) + gps(0.1, from: 300, to: 307) + gps(running, from: 307, to: 600)
        XCTAssertEqual(drive(started(), samples).decisions, [])
    }

    func testAWalkThroughAnAidStationIsNeitherAStopNorAResume() {
        // 0.8 m/s sits in the band between the thresholds.
        let walking = drive(started(), gps(running, from: 0, to: 60) + gps(0.8, from: 60, to: 180))
        XCTAssertEqual(walking.decisions, [], "walking is not stopping")

        // Paused at a light, then walking off: still paused until he actually runs.
        let paused = drive(started(), gps(0, from: 0, to: 20) + gps(0.8, from: 20, to: 120))
        XCTAssertEqual(paused.decisions, [.pause(at: t(0))])
        XCTAssertEqual(paused.state.phase, .paused)
    }

    func testTwoStridesAtTheLightDoNotResume() {
        // Shuffling forward to the curb: two fast readings inside a stop.
        let samples = gps(0, from: 0, to: 20) + gps(running, from: 20, to: 22) + gps(0, from: 22, to: 60)
        let d = drive(started(), samples)
        XCTAssertEqual(d.decisions, [.pause(at: t(0))])
        XCTAssertEqual(d.state.phase, .paused)
    }

    // MARK: - GPS dropout is not a stop

    func testGPSDroppingOutCompletelyNeverPauses() {
        // Under Lower Wacker: running, two minutes of nothing at all, running.
        let samples = gps(running, from: 0, to: 600) + gps(running, from: 720, to: 900)
        let d = drive(started(), samples)
        XCTAssertEqual(d.decisions, [])
        XCTAssertEqual(d.state.phase, .running)
        XCTAssertEqual(d.state.clocks(at: t(900)).movingS, 900)
    }

    func testCoreLocationsInvalidSpeedIsNoReadingNotZero() {
        // In the tunnel Core Location still calls back, with speed −1.
        let samples = gps(running, from: 0, to: 60) + gps(-1, from: 60, to: 180)
            + gps(.nan, from: 180, to: 200) + gps(running, from: 200, to: 300)
        XCTAssertEqual(drive(started(), samples).decisions, [])
    }

    func testSlowReadingsEitherSideOfADropoutDoNotAddUpToAStop() {
        // A slow fix going in, a slow fix coming out, 30 s of silence between. Each side alone
        // is too short; the silence is not evidence, so the two must not be stitched together.
        let samples = gps(running, from: 0, to: 60) + gps(0.2, from: 60, to: 65)
            + gps(0.2, from: 95, to: 100) + gps(running, from: 100, to: 200)
        XCTAssertEqual(drive(started(), samples).decisions, [])
    }

    func testAfterADropoutTheEightSecondsStartFromTheFirstReadingBack() {
        // He really did stop, but the stop is only provable from when the GPS came back.
        let samples = gps(running, from: 0, to: 60) + gps(0, from: 90, to: 120)
        XCTAssertEqual(drive(started(), samples).decisions, [.pause(at: t(90))])
    }

    func testADropoutWhileAutoPausedNeitherResumesNorLosesThePause() {
        let samples = gps(0, from: 0, to: 20) + gps(running, from: 120, to: 122) + gps(0, from: 122, to: 140)
        let d = drive(started(), samples)
        XCTAssertEqual(d.decisions, [.pause(at: t(0))])
        XCTAssertEqual(d.state.phase, .paused)
    }

    // MARK: - Two sources

    func testAPedometerStillCountingStridesOutvotesAGPSFixStuckAtZero() {
        // Between the towers on LaSalle the fix freezes and GPS speed reads zero for a
        // minute, while the pedometer keeps reporting him at pace.
        var samples = gps(running, from: 0, to: 60)
        for s in 60..<120 {
            samples.append(Sample(at: t(TimeInterval(s)), speed: 0, source: .gps))
            if s % 2 == 0 { samples.append(Sample(at: t(TimeInterval(s) + 0.5), speed: 3.3, source: .pedometer)) }
        }
        samples += gps(running, from: 120, to: 200)
        XCTAssertEqual(drive(started(), samples).decisions, [])
    }

    func testWhenBothSourcesGoQuietOnTheMoveTheStaleStrideStopsCountingAndTheStopIsFound() {
        // At the light the pedometer stops calling back; its last "running" reading must age
        // out rather than hold the clock forever.
        var samples: [Sample] = []
        for s in 0..<60 {
            samples.append(Sample(at: t(TimeInterval(s)), speed: running, source: .gps))
            samples.append(Sample(at: t(TimeInterval(s) + 0.5), speed: running, source: .pedometer))
        }
        samples += gps(0, from: 60, to: 90)
        let d = drive(started(), samples)
        // The pedometer's 59.5 reading is fresh until 64.5, so the stop is provable from 65.
        XCTAssertEqual(d.decisions, [.pause(at: t(65))])
    }

    func testALatePedometerUpdateIsTakenButNeverMovesTimeBackwards() {
        var detector = AutoPause()
        let state = started()
        for s in gps(0, from: 0, to: 5) { _ = detector.ingest(s, recorder: state) }
        // A pedometer reading stamped behind the latest GPS fix says he was moving at 3.5 s.
        XCTAssertNil(detector.ingest(Sample(at: t(3.5), speed: running, source: .pedometer), recorder: state))
        // It counts: the streak restarted, so eight seconds of stop now run from the next fix.
        var decision: AutoPause.Decision?
        for s in gps(0, from: 5, to: 30) {
            if let d = detector.ingest(s, recorder: state) { decision = d; break }
        }
        // Fresh until 8.5, so the stop is provable from 9.
        XCTAssertEqual(decision, .pause(at: t(9)))
    }

    // MARK: - Opt-in, and the athlete's word

    func testOffByDefaultAStoplightChangesNothing() {
        XCTAssertFalse(State.Setup(kind: .outdoor).autoPause, "the default is off (David, 2026-10-12)")
        let samples = gps(running, from: 0, to: 600) + gps(0, from: 600, to: 700) + gps(running, from: 700, to: 900)
        let d = drive(started(autoPause: false), samples)
        XCTAssertEqual(d.decisions, [])
        XCTAssertEqual(d.state.pauses, [])
        XCTAssertEqual(d.state.clocks(at: t(900)).movingS, 900)
    }

    func testRunningAwayFromAPauseHeMadeHimselfDoesNotResumeIt() {
        let paused = State.reduce(started(), .pause(.manual(.liveScreen), at: t(60)))
        let d = drive(paused, gps(running, from: 61, to: 300))
        XCTAssertEqual(d.decisions, [])
        XCTAssertEqual(d.state.phase, .paused)
        XCTAssertEqual(d.state.openPause?.reason, .manual)
    }

    func testAStopThatBeganInsideHisPauseDoesNotFireTheMomentHeResumes() {
        // He paused by hand, stood for a minute, tapped resume, and is still standing as he
        // gets his watch sorted. Auto-pause starts counting from the resume, not before it.
        var detector = AutoPause()
        var state = State.reduce(started(), .pause(.manual(.liveScreen), at: t(60)))
        for s in gps(0, from: 60, to: 120) { XCTAssertNil(detector.ingest(s, recorder: state)) }
        state = State.reduce(state, .resume(.manual(.liveScreen), at: t(120)))
        for s in gps(0, from: 120, to: 128) { XCTAssertNil(detector.ingest(s, recorder: state)) }
        XCTAssertEqual(detector.ingest(Sample(at: t(128), speed: 0, source: .gps), recorder: state),
                       .pause(at: t(120)))
    }

    func testAfterHeResumesAnAutoPauseByHandItCanPauseAgainAtTheNextLight() {
        var d = drive(started(), gps(0, from: 0, to: 10))
        XCTAssertEqual(d.decisions, [.pause(at: t(0))])
        d.state = State.reduce(d.state, .resume(.manual(.liveScreen), at: t(10)))
        d = drive(d.state, gps(running, from: 10, to: 300) + gps(0, from: 300, to: 320), detector: d.detector)
        XCTAssertEqual(d.decisions, [.pause(at: t(300))])
    }

    // MARK: - It cannot end a run

    func testNoSampleStreamCanTakeTheRunOutOfRunningOrPaused() {
        // Seeded noise across every regime — standing, walking, running, garbage, silences —
        // fed for an hour per seed. Whatever auto-pause decides, the run is still live.
        var rng = SplitMix64(seed: 0x113)
        let gaps: [TimeInterval] = [0.2, 1, 1, 1, 2, 3, 6, 30]
        let speeds: [Double] = [-1, 0, 0.3, 0.5, 0.9, 1.2, 1.3, 3.3, 6, .nan]
        for _ in 0..<200 {
            var samples: [Sample] = []
            var clock = 0.0
            while clock < 3600 {
                clock += gaps[Int(rng.next() % UInt64(gaps.count))]
                let speed = speeds[Int(rng.next() % UInt64(speeds.count))]
                samples.append(Sample(at: t(clock), speed: speed, source: rng.next() % 3 == 0 ? .pedometer : .gps))
            }
            let d = drive(started(), samples)
            for decision in d.decisions {
                switch decision.event {
                case .pause(.auto, _), .resume(.auto, _): break
                default: XCTFail("auto-pause emitted \(decision.event)")
                }
            }
            XCTAssertTrue(d.state.phase == .running || d.state.phase == .paused, "\(d.state.phase)")
            XCTAssertNil(d.state.endedAt)
            let c = d.state.clocks(at: t(3700))
            XCTAssertLessThanOrEqual(c.movingS, c.elapsedS)
        }
    }

    func testOutsideALiveRunItDecidesNothing() {
        var detector = AutoPause()
        let ending = State.reduce(started(), .endRequested(.liveScreen, at: t(30)))
        for s in gps(0, from: 30, to: 60) { XCTAssertNil(detector.ingest(s, recorder: ending)) }
        for s in gps(running, from: 60, to: 90) { XCTAssertNil(detector.ingest(s, recorder: ending)) }
        let recovering = State.reduce(started(), .interrupted(.appTerminated, at: t(30)))
        for s in gps(0, from: 90, to: 120) { XCTAssertNil(detector.ingest(s, recorder: recovering)) }
    }
}

/// Deterministic noise, so a failure in the fuzz test reproduces.
private struct SplitMix64 {
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
