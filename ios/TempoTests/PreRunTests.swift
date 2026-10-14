import XCTest
@testable import Tempo

/// Pins the decisions between Today's Start button and the first second of a run (#126).
///
/// Chicago, 11 Oct 2026, is the run this whole recorder is built around: the marathon a
/// block was aimed at, lost by a recorder that stopped. These tests are about the minute
/// *before* such a run, where the ways to lose it are quieter: a Start button that judges a
/// recovery jog against a tempo pace, a Race option that files an ordinary Tuesday as the
/// marathon's result, a GPS pill that says "strong" about a fix `TrackMath` will throw away,
/// a location prompt fired before the athlete knows why (iOS never shows it twice), and a
/// screen that decides by itself that a run is over. The decisions were signed off with the
/// frames on 2026-10-12 (#125).
final class PreRunTests: XCTestCase {

    private func session(
        _ type: String = "tempo", meters: Int? = 9_656, pace: Int? = 465, title: String? = "Tempo run"
    ) -> RecorderState.SessionTarget {
        RecorderState.SessionTarget(sessionID: UUID(), type: type, title: title, distanceM: meters, paceSecPerMile: pace)
    }

    // MARK: - The Start button (frames 1a, 1b, 1c)

    /// Frame 1a, to the letter: a 6-mile tempo at 7:45 names itself, in volt, and carries
    /// the session into the run.
    func testAPlannedSessionNamesItselfInVolt() {
        let s = session()
        let cta = PreRun.startButton(mode: .training, session: s, status: "planned", units: .mi)
        XCTAssertEqual(cta.title, "Start today's 6 mi tempo")
        XCTAssertEqual(cta.style, .primary)
        XCTAssertEqual(cta.target, s)
    }

    /// The plan stores 6 miles as 9,656 m, which is 5.9998 mi. "6.0 mi tempo" reads like a
    /// measurement and "5.9 mi tempo" is wrong; the name rounds to a tenth and drops ".0".
    func testTheNameRoundsLikeAPersonWouldSayIt() {
        XCTAssertEqual(PreRun.name(of: session(meters: 9_656), units: .mi), "6 mi tempo")
        XCTAssertEqual(PreRun.name(of: session(meters: 10_000), units: .mi), "6.2 mi tempo")
        XCTAssertEqual(PreRun.name(of: session(meters: 10_000), units: .km), "10 km tempo")
        XCTAssertEqual(PreRun.name(of: session("long", meters: 32_187), units: .mi), "20 mi long run")
    }

    /// A km athlete is never told a session in miles (#109). The plan's `title` is prose in
    /// miles ("Marathon-pace blocks: 2×3 mi"), so the button is built from distance and type.
    func testTheNameFollowsTheAthletesUnitNotThePlansTitle() {
        let s = session(meters: 9_656, title: "6 mi tempo")
        XCTAssertEqual(PreRun.startButton(mode: .training, session: s, status: "planned", units: .km).title,
                       "Start today's 9.7 km tempo")
    }

    func testASessionWithNoDistanceIsNamedByItsType() {
        XCTAssertEqual(PreRun.name(of: session("interval", meters: nil), units: .mi), "intervals")
        XCTAssertEqual(PreRun.name(of: session("easy", meters: 0), units: .mi), "easy run")
        XCTAssertEqual(PreRun.name(of: session("fartlek", meters: nil), units: .mi), "fartlek run")
    }

    /// Frame 1c: on a rest day Start is still one tap, but Secondary, and with no target.
    /// A rest day comes two ways: no session row, or a row typed `rest`.
    func testARestDayGetsAQuietStartWithNoTarget() {
        for (s, status) in [(nil, nil), (session("rest", meters: nil, pace: nil), "planned")] as [(RecorderState.SessionTarget?, String?)] {
            let cta = PreRun.startButton(mode: .training, session: s, status: status, units: .mi)
            XCTAssertEqual(cta.title, "Start a run")
            XCTAssertEqual(cta.style, .secondary)
            XCTAssertNil(cta.target, "a rest-day run has nothing to be judged against")
        }
    }

    /// Cross-training is not a run to start with a target on.
    func testACrossTrainingDayIsTreatedLikeRest() {
        let cta = PreRun.startButton(mode: .training, session: session("cross", meters: nil, pace: nil), status: "planned", units: .mi)
        XCTAssertEqual(cta.style, .secondary)
        XCTAssertNil(cta.target)
    }

    /// The session is banked. A second run is his call, so the button stays — but a shakeout
    /// after the tempo must not run against the tempo's 7:45 for its whole length.
    func testADoneSessionStopsOfferingItself() {
        let cta = PreRun.startButton(mode: .training, session: session(), status: "done", units: .mi)
        XCTAssertEqual(cta.title, "Start a run")
        XCTAssertEqual(cta.style, .secondary)
        XCTAssertNil(cta.target)
    }

    /// Frame 1b: Just running mode (#101) has no session, and Start is always there, in volt.
    /// After the race (#100) the feed is the same, and so is the button.
    func testJustRunningAlwaysOffersAFreeRunInVolt() {
        for mode in [TodayMode.justRunning, .racePassed] {
            let cta = PreRun.startButton(mode: mode, session: session(), status: "planned", units: .mi)
            XCTAssertEqual(cta, PreRun.StartButton(title: "Start a run", style: .primary, target: nil), "\(mode)")
        }
    }

    // MARK: - The sheet's words (frames 2a, 2c)

    func testTheSheetHeaderReadsLikeTheFrame() {
        XCTAssertEqual(PreRun.sheetTitle(session(), units: .mi), "6 mi tempo")
        XCTAssertEqual(PreRun.sheetTitle(session("interval", meters: nil), units: .mi), "Intervals")
        XCTAssertEqual(PreRun.sheetTitle(nil, units: .mi), "Free run")
        XCTAssertEqual(PreRun.targetLine(session(), units: .mi), "6 mi @ 7:45 /mi")
        XCTAssertEqual(PreRun.targetLine(session(pace: nil), units: .mi), "6 mi")
        XCTAssertEqual(PreRun.targetLine(session(meters: nil), units: .mi), "@ 7:45 /mi")
        XCTAssertNil(PreRun.targetLine(nil, units: .mi))
    }

    /// The pace is stored per mile; a km athlete reads it per km.
    func testTheTargetLineConvertsThePace() {
        XCTAssertEqual(PreRun.targetLine(session(), units: .km), "9.7 km @ 4:49 /km")
    }

    func testTheTargetToggleSaysWhatHidingItMeans() {
        XCTAssertEqual(PreRun.targetToggleDetail(session(), shown: true, units: .mi),
                       "7:45 /mi on screen and in your ear. Hide it mid-run with one tap.")
        XCTAssertEqual(PreRun.targetToggleDetail(session(), shown: false, units: .mi),
                       "Off — running free. No pace target on screen or in your ear.")
        XCTAssertEqual(PreRun.targetToggleDetail(session(pace: nil), shown: true, units: .mi),
                       "6 mi on screen and in your ear. Hide it mid-run with one tap.")
    }

    // MARK: - Race mode (#117)

    private let cal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func day(_ iso: String, hour: Int = 0) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return cal.date(byAdding: .hour, value: hour, to: f.date(from: iso)!)!
    }

    private func raceEligible(_ now: Date, raceDay: Date? = nil, closed: Bool = false) -> Bool {
        PreRun.raceEligible(raceDay: raceDay ?? day("2026-10-11"), blockClosed: closed, now: now, calendar: cal)
    }

    /// Chicago was Sunday 11 Oct. Race is offered the day before, the day, and the day after
    /// — in calendar days, so 6 a.m. on race morning counts the same as 11 p.m.
    func testRaceIsOfferedWithinADayOfRaceDay() {
        XCTAssertTrue(raceEligible(day("2026-10-11", hour: 6)), "race morning")
        XCTAssertTrue(raceEligible(day("2026-10-11", hour: 23)), "race night")
        XCTAssertTrue(raceEligible(day("2026-10-10", hour: 7)), "the day before")
        XCTAssertTrue(raceEligible(day("2026-10-12", hour: 22)), "the day after")
    }

    /// Off the window it is hidden, not disabled: a race run auto-saves and links itself as
    /// the block's result, so on an ordinary day the option is a trap.
    func testRaceIsHiddenOnAnyOtherDay() {
        XCTAssertFalse(raceEligible(day("2026-10-09", hour: 23)), "two days out")
        XCTAssertFalse(raceEligible(day("2026-10-13", hour: 1)), "two days after")
        XCTAssertFalse(raceEligible(day("2026-06-02")), "mid-block")
        XCTAssertEqual(PreRun.kinds(raceEligible: false), [.outdoor, .treadmill])
        XCTAssertEqual(PreRun.kinds(raceEligible: true), [.outdoor, .treadmill, .race])
    }

    /// Only the open block's race. A closed block already has its result; a goal with no
    /// date has no race day to be near.
    func testRaceNeedsAnOpenBlockWithADate() {
        XCTAssertFalse(raceEligible(day("2026-10-11"), closed: true))
        XCTAssertFalse(PreRun.raceEligible(raceDay: nil, blockClosed: false, now: day("2026-10-11"), calendar: cal))
    }

    // MARK: - Location (#110)

    /// The system prompt appears once, ever. It is only ever reached through the explainer.
    func testANeverAskedOutdoorRunExplainsBeforeAsking() {
        XCTAssertEqual(PreRun.gate(kind: .outdoor, access: .notDetermined), .explain)
        XCTAssertEqual(PreRun.gate(kind: .race, access: .notDetermined), .explain)
    }

    /// The treadmill needs no location, and nothing about location may block it — it is
    /// the way out offered by every refusal message.
    func testTheTreadmillIsNeverBlockedByLocation() {
        for access in [LocationAccess.notDetermined, .denied, .restricted, .reducedAccuracy, .whenInUse, .always] {
            XCTAssertEqual(PreRun.gate(kind: .treadmill, access: access), .ready, "\(access)")
        }
    }

    /// Refused, restricted, or Precise Location off: an outdoor start is blocked, with the
    /// reason, rather than recording a run measured from fixes kilometres off.
    func testARefusalBlocksOutdoorStartsWithTheReason() {
        for access in [LocationAccess.denied, .restricted, .reducedAccuracy] {
            XCTAssertEqual(PreRun.gate(kind: .outdoor, access: access), .blocked(access.blocker!), "\(access)")
            XCTAssertEqual(PreRun.gate(kind: .race, access: access), .blocked(access.blocker!), "\(access)")
        }
        XCTAssertEqual(PreRun.gate(kind: .outdoor, access: .whenInUse), .ready)
        XCTAssertEqual(PreRun.gate(kind: .outdoor, access: .always), .ready)
    }

    // MARK: - GPS signal

    /// Frame 2a: "GPS strong · Locked, ±5 m. Ready when you are."
    func testATightFreshFixIsStrong() {
        let signal = PreRun.signal(access: .whenInUse, accuracyM: 4.6, age: 1)
        XCTAssertEqual(signal, .strong(accuracyM: 5))
        XCTAssertEqual(signal.label, "GPS strong")
        XCTAssertEqual(signal.caption, "Locked, \u{00B1}5 m. Ready when you are.")
        XCTAssertEqual(signal.bars, 3)
    }

    /// The pill must never be more confident than `TrackMath`. Past its 25 m limit a fix is
    /// thrown away, so the pill is still finding GPS, whatever Core Location says.
    func testThePillAgreesWithWhatTrackMathWillUse() {
        XCTAssertEqual(PreRun.signal(access: .whenInUse, accuracyM: 10, age: 0), .strong(accuracyM: 10))
        XCTAssertEqual(PreRun.signal(access: .whenInUse, accuracyM: 18, age: 0), .weak(accuracyM: 18))
        XCTAssertEqual(PreRun.signal(access: .whenInUse, accuracyM: TrackMath.maxHorizontalAccuracyM, age: 0), .weak(accuracyM: 25))
        XCTAssertEqual(PreRun.signal(access: .whenInUse, accuracyM: 65, age: 0), .searching)
    }

    /// No fix yet, no position, or a fix from before the phone came out of the bag.
    func testNoUsableFixIsStillSearching() {
        XCTAssertEqual(PreRun.signal(access: .whenInUse, accuracyM: nil, age: nil), .searching)
        XCTAssertEqual(PreRun.signal(access: .whenInUse, accuracyM: -1, age: 0), .searching)
        XCTAssertEqual(PreRun.signal(access: .whenInUse, accuracyM: 5, age: 30), .searching)
    }

    /// Start before the lock is allowed (David, #125), and the caption says so.
    func testSearchingSaysYouCanStartAnyway() {
        XCTAssertEqual(PreRun.Signal.searching.caption, "You can start now. Distance fills in once GPS locks.")
        XCTAssertEqual(PreRun.Signal.searching.label, "Finding GPS\u{2026}")
    }

    func testNoPermissionIsLocationOffWhateverTheLastFixSaid() {
        for access in [LocationAccess.notDetermined, .denied, .restricted, .reducedAccuracy] {
            XCTAssertEqual(PreRun.signal(access: access, accuracyM: 3, age: 0), .off, "\(access)")
        }
        XCTAssertEqual(PreRun.Signal.off.bars, 0)
    }

    // MARK: - Countdown (frame 3)

    func testCountsThreeTwoOneThenGo() {
        XCTAssertEqual(PreRun.Countdown.showing(elapsed: 0), 3)
        XCTAssertEqual(PreRun.Countdown.showing(elapsed: 0.99), 3)
        XCTAssertEqual(PreRun.Countdown.showing(elapsed: 1), 2)
        XCTAssertEqual(PreRun.Countdown.showing(elapsed: 2.5), 1)
        XCTAssertEqual(PreRun.Countdown.showing(elapsed: 3), 0)
        XCTAssertEqual(PreRun.Countdown.showing(elapsed: 40), 0, "a phone asleep through the countdown")
        XCTAssertEqual(PreRun.Countdown.showing(elapsed: -0.2), 3, "a clock a hair behind the start")
    }

    func testTheRingSweepsOncePerSecond() {
        XCTAssertEqual(PreRun.Countdown.sweep(elapsed: 0), 0)
        XCTAssertEqual(PreRun.Countdown.sweep(elapsed: 0.25), 0.25, accuracy: 1e-9)
        XCTAssertEqual(PreRun.Countdown.sweep(elapsed: 1.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PreRun.Countdown.sweep(elapsed: 3), 1)
    }

    // MARK: - Which screen covers the app

    /// The live screen follows the recorder, not a view's opinion. Every phase after the
    /// countdown keeps it up, including `.recovering` (#115) and a save that failed — a
    /// screen that went away there would hide a run that is still on the line.
    func testTheCoverFollowsTheRecordersPhase() {
        XCTAssertEqual(PreRun.screen(for: .idle), .none)
        XCTAssertEqual(PreRun.screen(for: .countdown(startedAt: .now)), .countdown)
        let live: [RecorderState.Phase] = [
            .running, .paused, .recovering(since: .now),
            .ending(.review), .ending(.saving), .ending(.failed(reason: "x")),
            .saved(workoutID: nil), .discarded,
        ]
        for phase in live { XCTAssertEqual(PreRun.screen(for: phase), .live, "\(phase)") }
    }

    /// The sheet's answers become exactly the run the reducer starts: a hidden target is
    /// still carried (hiding is reversible mid-run), just not shown.
    func testCancellingTheCountdownLeavesNothingRecorded() {
        let setup = RecorderState.Setup(kind: .outdoor, target: session(), showTarget: false, autoPause: false)
        let counting = RecorderState.reduce(RecorderState(), .start(setup, at: .now))
        XCTAssertEqual(PreRun.screen(for: counting.phase), .countdown)
        XCTAssertNotNil(counting.target)
        XCTAssertFalse(counting.showsTarget)
        let cancelled = RecorderState.reduce(counting, .discard(.liveScreen))
        XCTAssertEqual(cancelled, RecorderState(), "back to idle, not a discarded run that never existed")
        XCTAssertEqual(PreRun.screen(for: cancelled.phase), .none)
    }
}
