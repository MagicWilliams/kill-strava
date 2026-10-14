import XCTest
@testable import Tempo

/// Session-RPE load (#123): what the athlete said a run cost, feeding the same fitness and
/// fatigue curves the pace model feeds.
///
/// The first thing pinned here is the thing that must *not* change. 2,000+ runs predate the
/// journal and will never carry an RPE. The readiness on Today, the CTL chart and the numbers
/// the coach reasons from are all built from them, so adding a second way to score a run must
/// not move any of those by a single bit.
final class LoadModelRPETests: XCTestCase {

    // MARK: - Fixture

    /// 2026-10-12 07:30 in the test process's own calendar. Every run is a whole number of
    /// calendar days before it at the same wall-clock time, so the day buckets — and with
    /// them the numbers — do not depend on the machine's time zone.
    static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 12; c.hour = 7; c.minute = 30
        return Calendar.current.date(from: c)!
    }()

    /// 150 days of irregular training, deterministic: easy days, workouts, long runs, rest
    /// days, a few doubles, a zero-distance treadmill entry, and history older than the
    /// model's 120-day window. `journal` is handed each run's index, so a test can put an
    /// entry on some runs and leave the rest exactly as they were.
    static func history(journal: (Int) -> RunJournalEntry = { _ in RunJournalEntry() }) -> [RunSummary] {
        let cal = Calendar.current
        var seed: UInt64 = 0x7E3A_2026_1012_0123
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var runs: [RunSummary] = []
        for offset in 0..<150 {
            let roll = next(10)
            if roll < 2 { continue }                              // rest day
            let day = cal.date(byAdding: .day, value: -offset, to: now)!
            let meters: Int, pace: Int
            switch roll {
            case 2...6: meters = 6_000 + next(6_000); pace = 520 + next(60)      // easy
            case 7:     meters = 10_000 + next(4_000); pace = 420 + next(40)     // workout
            case 8:     meters = 24_000 + next(10_000); pace = 500 + next(40)    // long
            default:    meters = 0; pace = 0                                     // treadmill, no distance
            }
            let duration = meters == 0 ? 2_400 : Int(Double(meters) / 1609.34 * Double(pace))
            runs.append(RunSummary(id: UUID(), start: day, distanceM: meters,
                                   durationS: duration, avgHR: nil,
                                   journal: journal(runs.count)))
            if next(8) == 0 {                                     // a double, same day
                runs.append(RunSummary(id: UUID(), start: day.addingTimeInterval(3_600 * 9),
                                       distanceM: 5_000, durationS: 1_650, avgHR: nil,
                                       journal: journal(runs.count)))
            }
        }
        return runs
    }

    // MARK: - No RPE, no change

    /// Recorded from `LoadModel` at 63a81ce, before session-RPE existed (and checked under
    /// four time zones, which agree), and asserted with exact equality: approximate
    /// equality would wave through a reordered multiplication, and that is a different
    /// number on Today.
    func testFitnessForRunsWithoutRPEIsPinned() throws {
        let runs = Self.history()
        XCTAssertEqual(runs.count, 138, "the fixture itself moved; the pins below mean nothing")
        let m = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil, now: Self.now))
        XCTAssertEqual(m.ctl, 5.876972275089662)
        XCTAssertEqual(m.ctl.bitPattern, 0x4017_8205_0524_0906)
        XCTAssertEqual(m.atl, 6.800303533141753)
        XCTAssertEqual(m.readiness, 41)
        XCTAssertEqual(m.ctlSeries.count, 56)
        XCTAssertEqual(m.ctlSeries.first?.ctl, 5.685928530353314)
        XCTAssertEqual(m.ctlSeries.map(\.ctl).reduce(0, +), 318.46039715137306)
    }

    func testJournalWithoutRPELeavesFitnessBitIdentical() throws {
        // Feel tags, notes, a title, a shoe — everything the post-run screen asks except
        // effort — say nothing about load. A run that has them must score as it always did.
        let plain = try XCTUnwrap(LoadModel.compute(runs: Self.history(), checkInOK: nil, now: Self.now))
        let journaled = try XCTUnwrap(LoadModel.compute(
            runs: Self.history(journal: { i in
                i.isMultiple(of: 2)
                    ? RunJournalEntry(feelTags: ["heavy legs"], notes: "Windy.", title: "Loop", shoeID: UUID())
                    : RunJournalEntry()
            }),
            checkInOK: nil, now: Self.now))
        XCTAssertEqual(journaled.ctl, plain.ctl)
        XCTAssertEqual(journaled.atl, plain.atl)
        XCTAssertEqual(journaled.readiness, plain.readiness)
        XCTAssertEqual(journaled.ctlSeries.map(\.ctl), plain.ctlSeries.map(\.ctl))
    }

    // MARK: - One run's load

    /// 9:00/mi median, for the per-run arithmetic below.
    private let baseline = 540.0

    private func run(miles: Double, paceSecPerMile: Int, rpe: Int? = nil,
                     on start: Date = LoadModelRPETests.now) -> RunSummary {
        RunSummary(id: UUID(), start: start, distanceM: Int((miles * 1609.34).rounded()),
                   durationS: Int(miles * Double(paceSecPerMile)), avgHR: nil,
                   journal: RunJournalEntry(rpe: rpe))
    }

    func testWithoutRPEALoadIsMilesTimesIntensitySquared() throws {
        let r = run(miles: 6, paceSecPerMile: 480)
        let intensity = baseline / Double(try XCTUnwrap(r.paceSecPerMile))
        XCTAssertEqual(LoadModel.load(of: r, baseline: baseline), r.miles * intensity * intensity)
    }

    func testSessionRPEIsEffortTimesMinutesInMedianPacedMiles() throws {
        // 54 minutes at RPE 6: Foster's 324 AU. At a 9:00 median that is 6 median-paced
        // miles, scaled by 6 / 4.
        let r = RunSummary(id: UUID(), start: Self.now, distanceM: 9_656, durationS: 3_240,
                           avgHR: nil, journal: RunJournalEntry(rpe: 6))
        XCTAssertEqual(try XCTUnwrap(LoadModel.load(of: r, baseline: baseline)), 9.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(LoadModel.load(of: r, baseline: baseline)),
                       6.0 * 54.0 / (LoadModel.referenceRPE * 9.0), accuracy: 1e-9)
    }

    func testRPEAtTheReferenceOnAMedianPacedRunScoresWhatPaceWould() throws {
        // The exchange rate: a run at exactly the median pace rated `referenceRPE` is worth
        // the same either way, so the two scores can share one fitness curve.
        let byPace = try XCTUnwrap(LoadModel.load(of: run(miles: 5, paceSecPerMile: 540), baseline: baseline))
        let byRPE = try XCTUnwrap(LoadModel.load(of: run(miles: 5, paceSecPerMile: 540, rpe: 4), baseline: baseline))
        // Within 1 %, not exactly: pace is whole seconds per mile (truncated), so a "9:00"
        // run built from rounded meters scores at 8:59 by pace, and RPE uses the clock.
        XCTAssertEqual(byRPE, byPace, accuracy: byPace * 0.01)
    }

    func testAnEasyPaceThatFeltHardCountsAsHard() throws {
        // The case RPE exists for: 6 miles at a pace that reads easy, on a day it felt like
        // a 9 (heat, a cold, a bad night). Pace calls it light; his word says otherwise.
        let byPace = try XCTUnwrap(LoadModel.load(of: run(miles: 6, paceSecPerMile: 600), baseline: baseline))
        let felt = try XCTUnwrap(LoadModel.load(of: run(miles: 6, paceSecPerMile: 600, rpe: 9), baseline: baseline))
        XCTAssertLessThan(byPace, 6, "pace alone scores a slow run below its mileage")
        XCTAssertGreaterThan(felt, 2 * byPace, "RPE 9 must outweigh the pace estimate, not average with it")
    }

    func testOutOfRangeRPEFallsBackToPace() throws {
        let byPace = LoadModel.load(of: run(miles: 6, paceSecPerMile: 540), baseline: baseline)
        for bad in [0, -1, 11, 99] {
            XCTAssertEqual(LoadModel.load(of: run(miles: 6, paceSecPerMile: 540, rpe: bad), baseline: baseline),
                           byPace, "rpe \(bad) is not a rating; the run keeps its pace score")
        }
    }

    func testRPEScoresARunThatHasNoDistance() throws {
        // A treadmill session logged with time and effort but no distance has no pace, so it
        // was skipped. With an RPE it has a load.
        let treadmill = RunSummary(id: UUID(), start: Self.now, distanceM: 0, durationS: 2_700,
                                   avgHR: nil, journal: RunJournalEntry(rpe: 5))
        XCTAssertNil(LoadModel.load(of: RunSummary(id: UUID(), start: Self.now, distanceM: 0,
                                                   durationS: 2_700, avgHR: nil), baseline: baseline))
        XCTAssertEqual(try XCTUnwrap(LoadModel.load(of: treadmill, baseline: baseline)),
                       5.0 / 4.0 * 2_700.0 / 540.0, accuracy: 1e-9)
    }

    func testRPEWithNoTimeIsNotALoad() {
        let r = RunSummary(id: UUID(), start: Self.now, distanceM: 0, durationS: 0, avgHR: nil,
                           journal: RunJournalEntry(rpe: 7))
        XCTAssertNil(LoadModel.load(of: r, baseline: baseline))
    }

    // MARK: - Mixed history

    func testMixedHistoryMovesOnlyWithTheRatedRuns() throws {
        // Every third run rated: at the reference effort the curve barely moves, rated hard
        // it climbs, rated easy it falls. The unrated two-thirds anchor all three.
        func metrics(rpe: Int) throws -> FitnessMetrics {
            try XCTUnwrap(LoadModel.compute(
                runs: Self.history(journal: { i in
                    i.isMultiple(of: 3) ? RunJournalEntry(rpe: rpe, feelTags: ["smooth"]) : RunJournalEntry()
                }),
                checkInOK: nil, now: Self.now))
        }
        let plain = try XCTUnwrap(LoadModel.compute(runs: Self.history(), checkInOK: nil, now: Self.now))
        let easy = try metrics(rpe: 2), reference = try metrics(rpe: 4), hard = try metrics(rpe: 8)

        XCTAssertLessThan(easy.ctl, reference.ctl)
        XCTAssertLessThan(reference.ctl, hard.ctl)
        XCTAssertLessThan(easy.atl, reference.atl)
        XCTAssertLessThan(reference.atl, hard.atl)
        XCTAssertGreaterThan(hard.ctl, plain.ctl, "runs rated hard must add fitness the pace model didn't see")
        XCTAssertLessThan(easy.ctl, plain.ctl)
    }

    func testTypicalSessionsScoreAlikeEitherWay() throws {
        // Why the reference is 4: on the sessions most weeks are made of, an honest rating
        // lands within ~10 % of the pace score, so a block that starts logging RPE mid-way
        // doesn't put a step into the CTL chart.
        let sessions: [(pace: Int, rpe: Int, label: String)] = [
            (583, 3, "easy, 8 % slower than the median"),
            (459, 7, "threshold, 15 % faster"),
        ]
        for s in sessions {
            let byPace = try XCTUnwrap(LoadModel.load(of: run(miles: 6, paceSecPerMile: s.pace), baseline: baseline))
            let byRPE = try XCTUnwrap(LoadModel.load(of: run(miles: 6, paceSecPerMile: s.pace, rpe: s.rpe), baseline: baseline))
            XCTAssertEqual(byRPE / byPace, 1, accuracy: 0.1, s.label)
        }
    }

    func testOneHardRatedRunTodayRaisesFatigueAndLowersReadiness() throws {
        // A recorder run today, rated 9, on top of an unrated history.
        var runs = Self.history()
        let plain = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil, now: Self.now))
        runs.append(run(miles: 6, paceSecPerMile: 560, rpe: 9, on: Self.now.addingTimeInterval(3_600)))
        var unrated = Self.history()
        unrated.append(run(miles: 6, paceSecPerMile: 560, on: Self.now.addingTimeInterval(3_600)))

        let rated = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil, now: Self.now))
        let paceOnly = try XCTUnwrap(LoadModel.compute(runs: unrated, checkInOK: nil, now: Self.now))
        XCTAssertGreaterThan(rated.atl, paceOnly.atl)
        XCTAssertGreaterThan(paceOnly.atl, plain.atl)
        XCTAssertLessThanOrEqual(rated.readiness, paceOnly.readiness)
    }

    // MARK: - What the coach sees

    func testCoachJournalOmitsWhatWasNotSaid() {
        let empty = CoachJournal(RunJournalEntry())
        XCTAssertNil(empty.rpe)
        XCTAssertNil(empty.feelTags, "an empty list would read as 'nothing felt off'")
        XCTAssertNil(empty.notes)

        let blank = CoachJournal(RunJournalEntry(feelTags: ["  ", ""], notes: " \n "))
        XCTAssertNil(blank.feelTags)
        XCTAssertNil(blank.notes)
    }

    func testCoachJournalCarriesRPEFeelAndNotes() {
        let j = CoachJournal(RunJournalEntry(rpe: 7, feelTags: ["heavy legs", " hot "],
                                             notes: "  Calves tight from mile 3. ", title: "Tempo",
                                             shoeID: UUID()))
        XCTAssertEqual(j, CoachJournal(RunJournalEntry(rpe: 7, feelTags: ["heavy legs", "hot"],
                                                       notes: "Calves tight from mile 3.")),
                       "title and shoe say nothing about how the run went")
        XCTAssertEqual(j.rpe, 7)
        XCTAssertEqual(j.feelTags, ["heavy legs", "hot"])
        XCTAssertEqual(j.notes, "Calves tight from mile 3.")
    }

    func testCoachJournalDropsAnImpossibleRPE() {
        XCTAssertNil(CoachJournal(RunJournalEntry(rpe: 0)).rpe)
        XCTAssertNil(CoachJournal(RunJournalEntry(rpe: 11)).rpe)
    }

    func testCoachJournalCutsAVeryLongNote() throws {
        let long = String(repeating: "a", count: CoachJournal.notesLimit + 200)
        let notes = try XCTUnwrap(CoachJournal(RunJournalEntry(notes: long)).notes)
        XCTAssertEqual(notes.count, CoachJournal.notesLimit + 1)
        XCTAssertTrue(notes.hasSuffix("…"))
    }

    func testRecentRunsCarryTheJournalKeysOnlyWhenPresent() throws {
        // Synthesized Encodable drops nil optionals, which is what keeps an unrated run's
        // payload exactly as it was.
        func json(_ entry: RunJournalEntry) throws -> [String: Any] {
            let j = CoachJournal(entry)
            let ctx = CoachContext.RunCtx(id: "x", date: "Oct 12, 2026", miles: 6, pace_per_mile: "9:00",
                                          stopped_min: nil, avg_hr: nil, corrected: false,
                                          rpe: j.rpe, feel_tags: j.feelTags, notes: j.notes)
            let data = try JSONEncoder().encode(ctx)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let bare = try json(RunJournalEntry())
        XCTAssertNil(bare["rpe"]); XCTAssertNil(bare["feel_tags"]); XCTAssertNil(bare["notes"])

        let full = try json(RunJournalEntry(rpe: 8, feelTags: ["heavy legs"], notes: "Third day of this."))
        XCTAssertEqual(full["rpe"] as? Int, 8)
        XCTAssertEqual(full["feel_tags"] as? [String], ["heavy legs"])
        XCTAssertEqual(full["notes"] as? String, "Third day of this.")
    }
}
