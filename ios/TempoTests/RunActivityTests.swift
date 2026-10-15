import XCTest
@testable import Tempo

/// The Lock Screen Live Activity and Dynamic Island (#119): what they say, when they exist,
/// and what their one button can do.
///
/// The phone is in a pocket or an armband for most of a run, so this is the screen he reads
/// pace from. None of it can be watched without a phone on a run, and every failure here is
/// silent: a Lock Screen that reads "3.43" while the app reads "3.42", a clock still ticking
/// for a run that was saved an hour ago, a button in a pocket that ends the run. Each test
/// pins one.
final class RunActivityTests: XCTestCase {

    typealias State = RecorderState

    private let t0 = ISO8601DateFormatter().date(from: "2026-10-14T07:00:00Z")!
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private let tempo = State.SessionTarget(sessionID: UUID(), type: "tempo", title: "6 mi tempo",
                                            distanceM: 9656, paceSecPerMile: 450)

    private func running(target: State.SessionTarget? = nil, showTarget: Bool = true) -> State {
        [RecorderEvent.start(State.Setup(kind: .outdoor, target: target, showTarget: showTarget), at: t(-3)),
         .countdownDone(at: t(0))].reduce(State(), State.reduce)
    }

    private func steady(secPerUnit: Double, units: Units, seconds: Double) -> [BestEfforts.Point] {
        stride(from: 0.0, through: seconds, by: 1).map { BestEfforts.Point(t: $0, m: $0 * units.meters / secPerUnit) }
    }

    private func snapshot(_ state: State, at seconds: TimeInterval, timeline: [BestEfforts.Point] = [],
                          units: Units = .mi) -> RecorderSnapshot {
        RecorderSnapshot.make(state: state, at: t(seconds), timeline: timeline, units: units,
                              heartRate: nil, gpsLocked: true)
    }

    private func content(_ state: State, at seconds: TimeInterval, timeline: [BestEfforts.Point] = [],
                         units: Units = .mi) -> RunActivityState? {
        RunActivityPlan.content(state: state, snapshot: snapshot(state, at: seconds, timeline: timeline, units: units))
    }

    private func sample(_ stage: RunActivityState.Stage = .running, distanceM: Double = 5_000,
                        paceS: Double? = 461, endedAt: Date? = nil, units: Units = .mi) -> RunActivityState {
        RunActivityState(stage: stage, startedAt: t(0), endedAt: endedAt, distanceM: distanceM,
                         currentPaceS: paceS, targetPaceS: nil, vsTargetS: nil, units: units)
    }

    // MARK: - The Lock Screen and the live screen never disagree

    /// The same run, the same instant, every slot both screens show — in both units, from
    /// the first metre past a marathon, a centimetre either side of every split boundary.
    /// The Lock Screen restates the live screen's rules because the extension can't compile
    /// `LiveRunDisplay`; this is what keeps the restatement honest.
    func testTheLockScreenReadsWhatTheLiveScreenReads() throws {
        for units in Units.allCases {
            let boundaries = (1...43).flatMap { k -> [Double] in
                let b = Double(k) * units.splitMeters
                return [b - 0.01, b, b + 0.01]
            }
            for meters in [0, 3, 804.67, 7_777.7] + boundaries {
                let timeline = [BestEfforts.Point(t: 0, m: 0), BestEfforts.Point(t: meters / 3.4, m: meters)]
                let snap = snapshot(running(target: tempo), at: meters / 3.4, timeline: timeline, units: units)
                let live = LiveRunDisplay(snap)
                let lock = RunActivityDisplay(try XCTUnwrap(RunActivityPlan.content(state: running(target: tempo), snapshot: snap)))
                XCTAssertEqual(lock.distance, live.distance, "\(units) at \(meters) m")
                XCTAssertEqual(lock.pace, live.currentPace, "\(units) at \(meters) m")
                XCTAssertEqual(lock.paceSuffix, live.paceSuffix)
                XCTAssertEqual(lock.vsTarget, live.vsTarget?.tile.value, "\(units) at \(meters) m")
            }
        }
    }

    func testVsTargetSaysWhatTheLiveScreenTileSays() {
        for delta in [18, -8.4, 0.3, -0.49, 0.5, 125] as [Double?] + [nil] {
            let target = RecorderSnapshot.Target(title: nil, type: "tempo", distanceM: nil, paceS: 450, deltaS: delta)
            let live = LiveRunDisplay.vsTarget(target, units: .mi)
            let (text, trend) = RunActivityDisplay.vsTarget(paceS: 450, deltaS: delta)
            XCTAssertEqual(text, live?.tile.value, "delta \(String(describing: delta))")
            XCTAssertEqual("\(trend)", "\(live?.trend ?? .unknown)")
        }
        XCTAssertEqual(RunActivityDisplay.vsTarget(paceS: 450, deltaS: 18).0, "+0:18")
        XCTAssertEqual(RunActivityDisplay.vsTarget(paceS: 450, deltaS: 0.3).0, "on pace")
    }

    /// Running free (David, #125: hide the target whenever he likes) means nothing to be
    /// "vs", on the Lock Screen too. So does an easy day with a distance but no pace.
    func testNoVsTargetRunningFreeOrWithoutATargetPace() throws {
        let free = running(target: tempo, showTarget: false)
        let timeline = steady(secPerUnit: 470, units: .mi, seconds: 600)
        XCTAssertNil(RunActivityDisplay(try XCTUnwrap(content(free, at: 600, timeline: timeline))).vsTarget)

        let easy = State.SessionTarget(sessionID: nil, type: "easy", title: nil, distanceM: 9656, paceSecPerMile: nil)
        XCTAssertNil(RunActivityDisplay(try XCTUnwrap(content(running(target: easy), at: 600, timeline: timeline))).vsTarget)

        let withTarget = RunActivityDisplay(try XCTUnwrap(content(running(target: tempo), at: 600, timeline: timeline)))
        XCTAssertEqual(withTarget.vsTarget, "+0:20")
        XCTAssertEqual(withTarget.trend, .behind)
    }

    /// Rounded down, like the live screen: 0.995 mi is not "1.00" until the cue says "Mile
    /// one". The minimal island's ring is the same hundredths, so it empties on that metre.
    func testDistanceAndTheRingRollOverOnTheSplitTheVoiceAnnounces() {
        let before = RunActivityDisplay(sample(distanceM: 1_609.33))
        XCTAssertEqual(before.distance, "0.99")
        XCTAssertEqual(before.splitProgress, 0.99, accuracy: 1e-9)
        let on = RunActivityDisplay(sample(distanceM: 1_609.34))
        XCTAssertEqual(on.distance, "1.00")
        XCTAssertEqual(on.splitProgress, 0)
        XCTAssertEqual(RunActivityDisplay(sample(distanceM: 2_500, units: .km)).splitProgress, 0.5, accuracy: 1e-9)
        XCTAssertEqual(RunActivityDisplay(sample(distanceM: 2_500, units: .km)).distanceUnit, "km")
        for bad in [0, -3, Double.nan, .infinity] {
            XCTAssertEqual(RunActivityDisplay(sample(distanceM: bad)).distance, "0.00")
            XCTAssertEqual(RunActivityDisplay(sample(distanceM: bad)).splitProgress, 0)
        }
    }

    // MARK: - The clock

    /// Elapsed, wall clock, from the countdown's end: the live screen's TIME. It keeps going
    /// through a pause (it does on the live screen too) and stops where he ended the run.
    func testTheClockIsTheElapsedClockAndStopsWhereTheRunEnded() throws {
        let paused = State.reduce(running(), .pause(.manual(.lockScreen), at: t(600)))
        let whilePaused = RunActivityDisplay(try XCTUnwrap(content(paused, at: 700)))
        XCTAssertEqual(whilePaused.clock.lowerBound, t(0))
        XCTAssertEqual(whilePaused.clock.upperBound, .distantFuture)
        XCTAssertNil(whilePaused.clockStoppedAt, "a pause doesn't stop the elapsed clock")

        let ended = State.reduce(paused, .endRequested(.liveScreen, at: t(900)))
        let afterEnd = RunActivityDisplay(try XCTUnwrap(content(ended, at: 1_200)))
        XCTAssertEqual(afterEnd.clock, t(0)...t(900))
        XCTAssertEqual(afterEnd.clockStoppedAt, t(900), "frozen at the end, not at the save screen's now")
    }

    // MARK: - When there is an activity

    /// It starts when the countdown finishes, stays through the save screen, and is gone once
    /// the run is saved or discarded.
    func testTheActivityLivesFromTheCountdownsEndToTheSaveOrDiscard() throws {
        XCTAssertNil(content(State(), at: 0))
        let countdown = State.reduce(State(), .start(State.Setup(kind: .outdoor, target: nil), at: t(-3)))
        XCTAssertNil(content(countdown, at: -1), "not during the 3-2-1: nothing is being recorded")

        let run = running()
        XCTAssertEqual(content(run, at: 10)?.stage, .running)
        let paused = State.reduce(run, .pause(.manual(.liveScreen), at: t(60)))
        XCTAssertEqual(content(paused, at: 70)?.stage, .paused)
        let lost = State.reduce(run, .interrupted(.sessionFailed, at: t(80)))
        XCTAssertEqual(content(lost, at: 90)?.stage, .interrupted)
        let ending = State.reduce(paused, .endRequested(.liveScreen, at: t(100)))
        XCTAssertEqual(content(ending, at: 110)?.stage, .ended, "still up on the save screen")

        let saving = State.reduce(ending, .endConfirmed)
        XCTAssertEqual(content(saving, at: 111)?.stage, .ended)
        XCTAssertNil(content(State.reduce(saving, .saveSucceeded(workoutID: UUID())), at: 112))
        XCTAssertNil(content(State.reduce(ending, .discard(.liveScreen)), at: 112))
        XCTAssertNil(content(State.reduce(paused, .discard(.liveScreen)), at: 112))
    }

    /// The button is the one the reducer would accept from the Lock Screen, or none.
    func testTheButtonIsPauseRunningResumePausedAndNothingOtherwise() {
        let running = RunActivityDisplay(sample(.running))
        XCTAssertTrue(running.offersPause)
        XCTAssertFalse(running.offersResume)
        let paused = RunActivityDisplay(sample(.paused))
        XCTAssertFalse(paused.offersPause)
        XCTAssertTrue(paused.offersResume)
        XCTAssertEqual(paused.pace, Units.missing, "paused: no current pace, not the last one")
        for stage in [RunActivityState.Stage.interrupted, .ended] {
            let d = RunActivityDisplay(sample(stage, endedAt: stage == .ended ? t(100) : nil))
            XCTAssertFalse(d.offersPause || d.offersResume, "\(stage)")
        }
    }

    /// Past its stale date the app has stopped updating — most likely iOS killed it — so the
    /// Lock Screen stops passing its numbers off as live.
    func testAStaleActivitySaysToOpenTempo() {
        XCTAssertEqual(RunActivityDisplay(sample(.running)).status, "Running")
        XCTAssertEqual(RunActivityDisplay(sample(.paused)).status, "Paused")
        XCTAssertEqual(RunActivityDisplay(sample(.running), isStale: true).status, "Open Tempo")
        XCTAssertEqual(RunActivityDisplay(sample(.interrupted)).status, "Open Tempo")
        XCTAssertEqual(RunActivityDisplay(sample(.ended, endedAt: t(100)), isStale: true).status,
                       "Run ended · save in Tempo")
    }

    /// ActivityKit carries the content as JSON between the app and the extension.
    func testTheContentSurvivesTheTripToTheExtension() throws {
        var state = sample(.paused, paceS: nil, endedAt: nil, units: .km)
        state.targetPaceS = 279.6
        state.vsTargetS = -4.2
        let back = try JSONDecoder().decode(RunActivityState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state)
    }

    // MARK: - Updates: at most about once a second

    private func shown(_ content: RunActivityState?, at seconds: TimeInterval) -> RunActivityPlan.Shown {
        .init(content: content, at: content == nil ? nil : t(seconds))
    }

    func testStartsWhenWantedAndEndsWhenNot() {
        let want = sample()
        XCTAssertEqual(RunActivityPlan.step(want: want, shown: nil, lastStartAttempt: nil, now: t(0)), .start(want))
        XCTAssertEqual(RunActivityPlan.step(want: nil, shown: shown(want, at: 0), lastStartAttempt: nil, now: t(5)), .end)
        XCTAssertEqual(RunActivityPlan.step(want: nil, shown: nil, lastStartAttempt: nil, now: t(5)), .none)
    }

    /// A start ActivityKit refused (a relaunch in the background) is retried, but not on
    /// every tick.
    func testARefusedStartIsRetriedEveryFewSecondsNotEveryTick() {
        let want = sample()
        XCTAssertEqual(RunActivityPlan.step(want: want, shown: nil, lastStartAttempt: t(0), now: t(1)), .none)
        XCTAssertEqual(RunActivityPlan.step(want: want, shown: nil, lastStartAttempt: t(0), now: t(RunActivityPlan.retryStartS)),
                       .start(want))
    }

    func testNoMoreThanAboutOneUpdateASecond() {
        let was = sample(distanceM: 5_000)
        let moved = sample(distanceM: 5_050)
        XCTAssertEqual(RunActivityPlan.step(want: moved, shown: shown(was, at: 10), lastStartAttempt: nil, now: t(10.4)), .none)
        XCTAssertEqual(RunActivityPlan.step(want: moved, shown: shown(was, at: 10), lastStartAttempt: nil, now: t(11)), .update(moved))
    }

    /// The pause he just pressed flips the button at once, whatever the last update was.
    func testAPauseOrResumeGoesOutAtOnce() {
        let was = sample(.running)
        let paused = sample(.paused, paceS: nil)
        XCTAssertEqual(RunActivityPlan.step(want: paused, shown: shown(was, at: 10), lastStartAttempt: nil, now: t(10.1)),
                       .update(paused))
    }

    /// Only a change he could see is sent. A metre more that still reads "3.10" isn't.
    func testNothingIsSentWhenNothingDrawnWouldChange() {
        let was = sample(distanceM: 5_000)
        let sameOnScreen = sample(distanceM: 5_001)
        XCTAssertEqual(RunActivityDisplay(was).distance, RunActivityDisplay(sameOnScreen).distance)
        XCTAssertEqual(RunActivityPlan.step(want: sameOnScreen, shown: shown(was, at: 10), lastStartAttempt: nil, now: t(12)),
                       .none)
    }

    /// A long pause changes nothing drawn, but the activity is refreshed anyway so it doesn't
    /// go stale under him. The save screen's final numbers never go stale, and aren't.
    func testAQuietActivityIsKeptFreshButAnEndedOneIsLeftAlone() {
        let paused = sample(.paused, paceS: nil)
        XCTAssertEqual(RunActivityPlan.step(want: paused, shown: shown(paused, at: 0), lastStartAttempt: nil, now: t(29)), .none)
        XCTAssertEqual(RunActivityPlan.step(want: paused, shown: shown(paused, at: 0), lastStartAttempt: nil,
                                            now: t(RunActivityPlan.keepAliveS)), .update(paused))
        XCTAssertLessThan(RunActivityPlan.keepAliveS, RunActivityPlan.staleAfterS,
                          "refreshed well before it would go stale")
        XCTAssertEqual(RunActivityPlan.staleDate(for: paused, at: t(0)), t(RunActivityPlan.staleAfterS))

        let ended = sample(.ended, endedAt: t(100))
        XCTAssertEqual(RunActivityPlan.step(want: ended, shown: shown(ended, at: 0), lastStartAttempt: nil, now: t(600)), .none)
        XCTAssertNil(RunActivityPlan.staleDate(for: ended, at: t(0)))
    }

    /// One adopted from before a kill: this process never saw what it shows. Bring it up to
    /// date at once.
    func testAnAdoptedActivityIsUpdatedAtOnce() {
        let want = sample()
        XCTAssertEqual(RunActivityPlan.step(want: want, shown: .init(content: nil, at: nil), lastStartAttempt: nil, now: t(0)),
                       .update(want))
    }

    // MARK: - After a kill

    /// iOS killed Tempo mid-run; the Live Activity outlived it. The relaunched app keeps the
    /// one for the run it picked back up, and ends every other — a leftover from a run
    /// that's already over would tick on the Lock Screen for hours.
    func testOnRelaunchTheRecoveredRunsActivityIsKeptAndEveryOtherEnded() {
        let ours = UUID(), old = UUID(), older = UUID()
        let found = RunActivityPlan.reconcile(existing: [old, ours, older], recordingID: ours, wanted: true)
        XCTAssertEqual(found.keep, 1)
        XCTAssertEqual(found.end, [0, 2])

        let nothingRecovered = RunActivityPlan.reconcile(existing: [old, older], recordingID: nil, wanted: false)
        XCTAssertNil(nothingRecovered.keep)
        XCTAssertEqual(nothingRecovered.end, [0, 1])

        let overAlready = RunActivityPlan.reconcile(existing: [ours], recordingID: ours, wanted: false)
        XCTAssertNil(overAlready.keep, "the run is in Health: its activity goes")
        XCTAssertEqual(overAlready.end, [0])
    }

    // MARK: - The Lock Screen's button

    /// Pause and resume, marked as the Lock Screen's, and nothing else exists to send.
    func testTheButtonsSendLockScreenPauseAndResume() {
        XCTAssertEqual(RunActivityCommand.pause.event(at: t(5)), .pause(.manual(.lockScreen), at: t(5)))
        XCTAssertEqual(RunActivityCommand.resume.event(at: t(5)), .resume(.manual(.lockScreen), at: t(5)))
    }

    /// Chicago, 11 Oct 2026: a recorder that stopped by itself lost the race. Pressed from a
    /// pocket any number of times, in any order, from any point in a run, the Lock Screen's
    /// buttons never end, save or discard one.
    func testNoRunOfLockScreenTapsEverEndsARun() {
        let run = running(target: tempo)
        let starts: [State] = [
            run,
            State.reduce(run, .pause(.manual(.liveScreen), at: t(10))),
            State.reduce(run, .interrupted(.sessionFailed, at: t(10))),
            State.reduce(run, .endRequested(.liveScreen, at: t(10))),
        ]
        for start in starts {
            var state = start
            for i in 0..<200 {
                let command: RunActivityCommand = (i * 7 + i / 3) % 3 == 0 ? .resume : .pause
                state = State.reduce(state, command.event(at: t(20 + Double(i))))
                switch state.phase {
                case .running, .paused:
                    break
                default:
                    XCTAssertEqual(state.phase, start.phase, "a Lock Screen tap moved \(start.phase) to \(state.phase)")
                }
                XCTAssertEqual(state.endedAt, start.endedAt)
            }
        }
    }
}
