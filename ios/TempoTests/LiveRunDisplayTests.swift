import XCTest
@testable import Tempo

/// The live run screen (#127): what each slot says, and what each stage offers.
///
/// Mid-run the screen is read in a half-second glance with a heart rate of 170. A number that
/// jumps backwards, a "1.00" the voice hasn't confirmed, or a Pause button that does nothing
/// won't crash anything; he'll just stop trusting the screen, on the one run where it
/// matters. Each test here pins one of those.
final class LiveRunDisplayTests: XCTestCase {

    typealias State = RecorderState

    private let t0 = ISO8601DateFormatter().date(from: "2026-10-14T07:00:00Z")!
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private let tempo = State.SessionTarget(sessionID: UUID(), type: "tempo", title: "6 mi tempo",
                                            distanceM: 9656, paceSecPerMile: 450)

    private func running(kind: State.RunKind = .outdoor, target: State.SessionTarget? = nil,
                         showTarget: Bool = true, autoPause: Bool = false) -> State {
        [RecorderEvent.start(State.Setup(kind: kind, target: target, showTarget: showTarget, autoPause: autoPause),
                             at: t(-3)),
         .countdownDone(at: t(0))].reduce(State(), State.reduce)
    }

    /// `secPerUnit` steady from 0 to `seconds`, a point a second.
    private func steady(secPerUnit: Double, units: Units, seconds: Double) -> [BestEfforts.Point] {
        stride(from: 0.0, through: seconds, by: 1).map { BestEfforts.Point(t: $0, m: $0 * units.meters / secPerUnit) }
    }

    private func snapshot(_ state: State, at seconds: TimeInterval, timeline: [BestEfforts.Point] = [],
                          units: Units = .mi, heartRate: RecorderSnapshot.HeartRate? = nil,
                          gpsLocked: Bool = true) -> RecorderSnapshot {
        RecorderSnapshot.make(state: state, at: t(seconds), timeline: timeline, units: units,
                              heartRate: heartRate, gpsLocked: gpsLocked)
    }

    // MARK: - TIME is the elapsed clock

    func testElapsedClockReadsLikeAWatch() {
        XCTAssertEqual(LiveRunDisplay.elapsedClock(0), "0:00")
        XCTAssertEqual(LiveRunDisplay.elapsedClock(59), "0:59")
        XCTAssertEqual(LiveRunDisplay.elapsedClock(3_599), "59:59")
        XCTAssertEqual(LiveRunDisplay.elapsedClock(3_600), "1:00:00")
        XCTAssertEqual(LiveRunDisplay.elapsedClock(11_142), "3:05:42", "a marathon is h:mm:ss, not 185:42")
        XCTAssertEqual(LiveRunDisplay.elapsedClock(-4), "0:00")
    }

    /// The EM decision on #127, from #113: auto-pause backdates its pause to where the stop
    /// began, so moving time steps back when one confirms. At 9:59 he is still moving; at
    /// 10:00 auto-pause decides he stopped at 9:52 and moving time drops seven seconds. The
    /// big clock must keep going forward through it.
    func testTheBigClockNeverStepsBackWhenAnAutoPauseIsBackdated() {
        let state = running(autoPause: true)
        let before = snapshot(state, at: 599)
        let paused = State.reduce(state, .pause(.auto, at: t(592)))
        let after = snapshot(paused, at: 600)

        XCTAssertLessThan(after.movingS, before.movingS, "the scenario: moving time does step back")
        XCTAssertEqual(LiveRunDisplay(before).time, "9:59")
        XCTAssertEqual(LiveRunDisplay(after).time, "10:00")
    }

    // MARK: - Distance agrees with the voice

    /// Rounded down: 0.995 mi is not "1.00" until the cue says "Mile one".
    func testDistanceRoundsDownSoItNeverClaimsASplitEarly() {
        XCTAssertEqual(LiveRunDisplay.distance(meters: 1_609.33, units: .mi), "0.99")
        XCTAssertEqual(LiveRunDisplay.distance(meters: 1_609.34, units: .mi), "1.00")
        XCTAssertEqual(LiveRunDisplay.distance(meters: 999.99, units: .km), "0.99")
        XCTAssertEqual(LiveRunDisplay.distance(meters: 5_000, units: .km), "5.00")
        XCTAssertEqual(LiveRunDisplay.distance(meters: 0, units: .mi), "0.00")
        XCTAssertEqual(LiveRunDisplay.distance(meters: -3, units: .mi), "0.00")
        XCTAssertEqual(LiveRunDisplay.distance(meters: .nan, units: .km), "0.00")
    }

    /// At every boundary of a marathon, in both units, the whole number on screen is the split
    /// count the voice cue uses, a centimetre before it and on it.
    func testWholeNumberOnScreenIsTheSplitTheVoiceHasAnnounced() {
        for units in Units.allCases {
            for k in 1...42 {
                let boundary = Double(k) * units.splitMeters
                for m in [boundary - 0.01, boundary] {
                    let shown = LiveRunDisplay.distance(meters: m, units: units)
                    let whole = Int(shown.split(separator: ".")[0])
                    XCTAssertEqual(whole, units.completedSplits(meters: m), "\(units) at \(m) m shows \(shown)")
                }
            }
        }
    }

    func testPaceIsAClockOrADash() {
        XCTAssertEqual(LiveRunDisplay.pace(461), "7:41")
        XCTAssertEqual(LiveRunDisplay.pace(479.6), "8:00")
        XCTAssertEqual(LiveRunDisplay.pace(nil), Units.missing)
    }

    /// Paused: the current pace slot goes blank instead of holding the last number.
    func testPausedShowsNoCurrentPaceButKeepsTheAverage() {
        let paused = State.reduce(running(), .pause(.manual(.liveScreen), at: t(600)))
        let display = LiveRunDisplay(snapshot(paused, at: 610, timeline: steady(secPerUnit: 480, units: .mi, seconds: 600)))
        XCTAssertEqual(display.currentPace, Units.missing)
        XCTAssertEqual(display.averagePace, "8:00")
        XCTAssertEqual(display.time, "10:10", "the elapsed clock keeps going through a pause")
    }

    // MARK: - The secondary tile: heart rate, else the last split (#125)

    func testSecondaryTileIsHeartRateThenLastSplitThenAnEmptySplit() {
        let timeline = steady(secPerUnit: 461, units: .mi, seconds: 1_000)
        let withStrap = LiveRunDisplay(snapshot(running(), at: 1_000, timeline: timeline,
                                                heartRate: .init(bpm: 151.6, at: t(995))))
        XCTAssertEqual(withStrap.secondary, .init(label: "Heart rate", value: "152", detail: "bpm"))

        let noStrap = LiveRunDisplay(snapshot(running(), at: 1_000, timeline: timeline))
        XCTAssertEqual(noStrap.secondary, .init(label: "Last split", value: "7:41", detail: "mi 2"))

        let firstMile = LiveRunDisplay(snapshot(running(), at: 300, timeline: steady(secPerUnit: 461, units: .mi, seconds: 300)))
        XCTAssertEqual(firstMile.secondary, .init(label: "Last split", value: Units.missing, detail: nil))
    }

    // MARK: - Target

    func testVsTargetSaysWhichWayAndByHowMuch() {
        func vs(_ delta: Double?) -> LiveRunDisplay.VsTarget? {
            LiveRunDisplay.vsTarget(.init(title: nil, type: "tempo", distanceM: nil, paceS: 450, deltaS: delta), units: .mi)
        }
        XCTAssertEqual(vs(18), .init(tile: .init(label: "Vs target", value: "+0:18", detail: "target 7:30"), trend: .behind))
        XCTAssertEqual(vs(-8.4)?.tile.value, "-0:08")
        XCTAssertEqual(vs(-8.4)?.trend, .ahead)
        XCTAssertEqual(vs(0.3)?.tile.value, "on pace")
        XCTAssertEqual(vs(0.3)?.trend, .onPace)
        XCTAssertEqual(vs(nil)?.tile.value, Units.missing, "no average yet")
        XCTAssertEqual(vs(nil)?.trend, .unknown)
    }

    /// An easy day judged on distance: the plan's "6 mi" is 9656 m, which is 5.99997 mi. The
    /// tile must say 6.0, not the 5.99 the live distance's round-down would give.
    func testADistanceOnlyTargetShowsTheDistanceThePlanSet() {
        let easy = RecorderSnapshot.Target(title: "Easy 6", type: "easy", distanceM: 9_656, paceS: nil, deltaS: nil)
        XCTAssertEqual(LiveRunDisplay.vsTarget(easy, units: .mi)?.tile,
                       .init(label: "Target", value: "6.0", detail: Units.mi.tileName))
        let nothing = RecorderSnapshot.Target(title: nil, type: "easy", distanceM: nil, paceS: nil, deltaS: nil)
        XCTAssertNil(LiveRunDisplay.vsTarget(nothing, units: .mi))
    }

    func testTargetLineNamesTheSessionInTheRunnersUnit() {
        let shown = LiveRunDisplay(snapshot(running(target: tempo), at: 60))
        XCTAssertEqual(shown.targetLine, "6 mi tempo · 7:30 /mi")
        let km = LiveRunDisplay(snapshot(running(target: tempo), at: 60, units: .km))
        XCTAssertEqual(km.targetLine, "6 mi tempo · 4:40 /km")
        let untitled = State.SessionTarget(sessionID: nil, type: "tempo", title: nil, distanceM: nil, paceSecPerMile: nil)
        XCTAssertEqual(LiveRunDisplay(snapshot(running(target: untitled), at: 60)).targetLine, "Tempo")
    }

    /// David, #125: hide it "in favor of free running whenever", and bring it back the same
    /// way. One tap is one `.setTargetVisible`, and the chip comes back flipped.
    func testOneChipTapHidesTheTargetAndOneBringsItBack() throws {
        XCTAssertEqual(LiveRunDisplay(snapshot(running(), at: 60)).targetChip, .none,
                       "a run with no target has nothing to show or hide")

        var state = running(target: tempo)
        var display = LiveRunDisplay(snapshot(state, at: 60))
        XCTAssertEqual(display.targetChip, .shown)
        XCTAssertNotNil(display.vsTarget)

        state = State.reduce(state, .setTargetVisible(try XCTUnwrap(display.targetChip.toggled)))
        display = LiveRunDisplay(snapshot(state, at: 61))
        XCTAssertEqual(display.targetChip, .hidden, "running free still offers the chip back")
        XCTAssertNil(display.vsTarget)
        XCTAssertNil(display.targetLine)

        state = State.reduce(state, .setTargetVisible(try XCTUnwrap(display.targetChip.toggled)))
        XCTAssertEqual(LiveRunDisplay(snapshot(state, at: 62)).targetChip, .shown)
    }

    /// Started with "run free" on the pre-run sheet: the target is there to bring back.
    func testStartingFreeStillOffersTheTarget() {
        XCTAssertEqual(LiveRunDisplay(snapshot(running(target: tempo, showTarget: false), at: 60)).targetChip, .hidden)
    }

    // MARK: - Controls are exactly what the reducer accepts

    /// Every surface the screen can be on, and what it offers there, checked against the
    /// reducer. A Pause that the reducer ignores, or a hold-to-end drawn on a run it won't
    /// end, is a button that silently does nothing.
    func testEveryStageOffersExactlyWhatTheReducerAccepts() {
        let live = running()
        let paused = State.reduce(live, .pause(.manual(.liveScreen), at: t(60)))
        let recovering = State.reduce(live, .interrupted(.appTerminated, at: t(60)))
        let ending = State.reduce(live, .endRequested(.liveScreen, at: t(60)))
        let saving = State.reduce(ending, .endConfirmed)
        let saved = State.reduce(saving, .saveSucceeded(workoutID: UUID()))
        let countdown = State.reduce(State(), .start(State.Setup(kind: .outdoor, target: nil), at: t(-3)))
        let raceSaving = State.reduce(running(kind: .race), .endRequested(.liveScreen, at: t(60)))

        let cases: [(String, State, LiveRunDisplay.Stage)] = [
            ("idle", State(), .over), ("countdown", countdown, .countdown), ("running", live, .running),
            ("paused", paused, .paused), ("recovering", recovering, .recovering),
            ("ending", ending, .over), ("saving", saving, .over), ("saved", saved, .over),
            ("race saving", raceSaving, .over),
        ]
        for (name, state, expected) in cases {
            let stage = LiveRunDisplay(snapshot(state, at: 70)).stage
            XCTAssertEqual(stage, expected, name)
            XCTAssertEqual(stage.offersPause, state.accepts(.pause(.manual(.liveScreen), at: t(70))), "\(name): pause")
            XCTAssertEqual(stage.offersResume, state.accepts(.resume(.manual(.liveScreen), at: t(70))), "\(name): resume")
            XCTAssertEqual(stage.offersHoldToEnd, state.accepts(.endRequested(.liveScreen, at: t(70))), "\(name): hold-to-end")
        }
    }

    /// #128: "≈1 s hold, haptic". Long enough to survive a pocket, short enough at a finish.
    func testHoldToEndIsAboutASecond() {
        XCTAssertEqual(LiveRunDisplay.holdToEndS, 1.0)
        XCTAssertGreaterThanOrEqual(LiveRunDisplay.holdToUnlockS, 1.0, "unlocking guards the same pocket")
    }

    // MARK: - Status pill

    func testStatusPillSaysWhatKindOfRunAndWhetherGPSHasHim() {
        XCTAssertEqual(LiveRunDisplay.status(kind: .outdoor, gpsLocked: false), .init(text: "Finding GPS", tone: .waiting))
        XCTAssertEqual(LiveRunDisplay.status(kind: .outdoor, gpsLocked: true), .init(text: "GPS", tone: .good))
        XCTAssertEqual(LiveRunDisplay.status(kind: .race, gpsLocked: true), .init(text: "Race · GPS", tone: .good))
        XCTAssertEqual(LiveRunDisplay.status(kind: .treadmill, gpsLocked: false), .init(text: "Treadmill", tone: .neutral),
                       "a treadmill has no GPS to wait for")
    }

    // MARK: - Split banner (frame 4c)

    /// The banner says what the voice says (#118): "Mile three. Seven forty-one. Average …".
    func testSplitBannerMatchesTheVoiceCue() throws {
        let snap = snapshot(running(), at: 1_400, timeline: steady(secPerUnit: 461, units: .mi, seconds: 1_400))
        XCTAssertEqual(snap.completedSplits, 3)
        let banner = try XCTUnwrap(LiveRunDisplay.splitBanner(seenSplits: 2, snapshot: snap))
        XCTAssertEqual(banner.title, "Mile 3")
        XCTAssertEqual(banner.pace, "7:41 /mi")
        XCTAssertEqual(banner.average, "avg 7:41")
        XCTAssertNil(LiveRunDisplay.splitBanner(seenSplits: 3, snapshot: snap), "already shown")
    }

    /// GPS back after a tunnel, two boundaries in one update: the banner names the latest,
    /// the same rule as the voice.
    func testTwoSplitsAtOnceShowTheLatest() throws {
        let snap = snapshot(running(), at: 1_450, timeline: steady(secPerUnit: 280, units: .km, seconds: 1_450), units: .km)
        XCTAssertEqual(snap.completedSplits, 5)
        XCTAssertEqual(try XCTUnwrap(LiveRunDisplay.splitBanner(seenSplits: 3, snapshot: snap)).title, "Kilometer 5")
    }
}
