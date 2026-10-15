import XCTest
@testable import Tempo

/// The Chicago 2026 block, read back (#100): plan start Monday 22 Jun, race Sunday 11 Oct,
/// sixteen weeks. There is **no race run** — David ran it with no watch and Strava paused
/// mid-race — so every number here has to stand up with race day empty.
///
/// The shape of every past bug in this layer is a plausible number, quietly wrong. The ones
/// most likely here: a 20-miler that doesn't count because of how metres are stored; a race
/// week that reads as the peak because the race got counted; adherence that punishes rest days.
final class BlockReviewTests: XCTestCase {

    private let cal = Calendar.current
    private let marathon = RaceRecap.marathonMeters

    private func at(_ iso: String, _ hour: Int = 7) -> Date {
        cal.date(byAdding: .hour, value: hour, to: PlanDates.day.date(from: iso)!)!
    }

    private var planStart: Date { at("2026-06-22", 0) }
    private var raceDay: Date { at("2026-10-11", 0) }

    private func run(_ iso: String, miles: Double, hour: Int = 7) -> RunSummary {
        RunSummary(id: UUID(), start: at(iso, hour), distanceM: Int(miles * 1609.34),
                   durationS: Int(miles * 480), avgHR: nil)
    }

    private func run(_ iso: String, meters: Int) -> RunSummary {
        RunSummary(id: UUID(), start: at(iso), distanceM: meters, durationS: meters / 3, avgHR: nil)
    }

    private func session(_ iso: String, _ type: String, _ status: String) -> BlockReview.PlannedSession {
        BlockReview.PlannedSession(day: at(iso, 0), type: type, status: status)
    }

    private func week(_ index: Int, _ target: Double?) -> PlanWeekInfo {
        PlanWeekInfo(id: UUID(), week_index: index, phase: "build", target_mileage: target, focus: nil)
    }

    private func review(
        _ runs: [RunSummary],
        weeks: [PlanWeekInfo] = [],
        sessions: [BlockReview.PlannedSession] = [],
        raceMeters: Double? = nil
    ) -> BlockReview.Review {
        BlockReview.review(runs: runs, planStart: planStart, raceDay: raceDay,
                           raceMeters: raceMeters ?? marathon, planWeeks: weeks, sessions: sessions, calendar: cal)
    }

    // MARK: - 20+ mi runs

    /// 20 miles is 32,186.8 m, and ingest truncates to whole metres — so a run Garmin wrote as
    /// exactly 20.00 mi is stored as 32,186. A `>= 20.0 mi` test on the stored value misses it
    /// by 0.8 m and the tile says he did one fewer 20-miler than he did. 19.95 mi is not 20.
    func testTwentyPlusCountsTwentyAsStoredAndNotNineteenNinetyFive() {
        let twenty = run("2026-09-20", meters: Int(20 * 1609.34))        // 32,186
        let short = run("2026-09-13", meters: Int(19.95 * 1609.34))      // 32,106
        let long = run("2026-09-27", miles: 21.3)
        XCTAssertEqual(twenty.distanceM, 32_186)
        XCTAssertLessThan(twenty.miles, 20.0, "the stored value really is under 20.0 — that's the trap")
        XCTAssertTrue(BlockReview.isTwentyPlus(twenty))
        XCTAssertFalse(BlockReview.isTwentyPlus(short))
        XCTAssertFalse(BlockReview.isTwentyPlus(run("2026-09-13", meters: 32_185)), "one metre short")

        XCTAssertEqual(review([twenty, short, long]).twentyPlusCount, 2)
    }

    /// The race is the result of the block, not part of it. Had Chicago been recorded, it
    /// must not be the block's longest run, its third 20-miler, or a 26-mile race week.
    func testRaceDayIsExcludedFromEveryVolumeNumber() {
        let long = run("2026-09-20", miles: 20.2)
        let race = run("2026-10-11", miles: 26.6)
        let r = review([long, race])
        XCTAssertEqual(r.twentyPlusCount, 1)
        XCTAssertEqual(r.longest?.id, long.id)
        XCTAssertEqual(r.runCount, 1)
        XCTAssertEqual(r.weeks.last?.actualMiles ?? -1, 0, accuracy: 0.001)
    }

    // MARK: - Missing race run

    /// Chicago as it actually is in the database: nothing on race day. The review must still
    /// produce every number — none of them depends on the race existing as a run.
    func testABlockWithNoRaceRunStillReviews() {
        let runs = [
            run("2026-06-22", miles: 5, hour: 0),     // first minute of the block: in
            run("2026-06-21", miles: 10, hour: 23),   // the evening before: out
            run("2026-09-06", miles: 18),
            run("2026-09-20", miles: 20.1),
            run("2026-10-08", miles: 4),
            run("2026-10-12", miles: 3),              // the shakeout after: out
        ]
        let r = review(runs)
        XCTAssertEqual(r.runCount, 4)
        XCTAssertEqual(r.totalMiles, (5 + 18 + 20.1 + 4) * 1609.34 / 1609.34, accuracy: 0.01)
        XCTAssertEqual(r.weeks.count, 16, "22 Jun → 11 Oct is sixteen plan weeks")
        XCTAssertTrue(r.weeks.last!.isRaceWeek)
        XCTAssertEqual(r.weeks.last!.start, at("2026-10-05", 0))
        XCTAssertNotNil(r.projectedRaceMorningS, "a 20-miler inside six weeks projects a finish")
        XCTAssertEqual(r.twentyPlusCount, 1)
    }

    // MARK: - Weeks

    /// Planned bars line up with `plan_weeks.week_index`, counted from the plan's start date.
    /// A week with no row has no target — not a target of zero.
    func testWeeksCarryPlannedTargetsByIndex() {
        let r = review([run("2026-06-23", miles: 6), run("2026-06-30", miles: 8)],
                       weeks: [week(0, 30), week(1, 34), week(15, 18)])
        XCTAssertEqual(r.weeks[0].plannedMiles, 30)
        XCTAssertEqual(r.weeks[1].plannedMiles, 34)
        XCTAssertNil(r.weeks[2].plannedMiles)
        XCTAssertEqual(r.weeks[15].plannedMiles, 18)
        XCTAssertEqual(r.weeks[0].actualMiles, 6 * 1609.34 / 1609.34, accuracy: 0.01)
        XCTAssertEqual(r.weeks[1].runCount, 1)
    }

    // MARK: - Taper

    /// Peak 50 mi in week 13, race week 20 mi (Mon–Sat; the race excluded): a 60% taper.
    /// Counting the race would have made it 46.6 mi — a 7% "taper" off a block that cut hard.
    func testTaperIsRaceWeekAgainstTheBuildPeak() {
        let runs = [
            run("2026-09-14", miles: 20), run("2026-09-16", miles: 10), run("2026-09-20", miles: 20),
            run("2026-09-28", miles: 30),
            run("2026-10-06", miles: 10), run("2026-10-08", miles: 10),
            run("2026-10-11", miles: 26.6),   // the race, if it had been recorded
        ]
        let r = review(runs)
        let taper = r.taper!
        XCTAssertEqual(taper.peakMiles, 50, accuracy: 0.01)
        XCTAssertEqual(taper.raceWeekMiles, 20, accuracy: 0.01)
        XCTAssertEqual(taper.drop, 0.6, accuracy: 0.001)
        XCTAssertEqual(r.peakWeek?.index, 12)
    }

    func testNoTaperWithoutABuildToTaperFrom() {
        XCTAssertNil(review([]).taper, "nothing run, nothing to compare")
        XCTAssertNil(review([run("2026-10-06", miles: 5)]).taper, "only race week has miles")
        XCTAssertNil(review([]).peakWeek, "an empty block has no peak week, not a 0-mile one")
    }

    // MARK: - Adherence

    /// Rest days are not sessions you can miss, the race is the result rather than a session,
    /// and skipping is not doing. Sessions outside the block don't count either way.
    func testAdherenceCountsSessionsNotRestOrRace() {
        let sessions = [
            session("2026-06-23", "easy", "done"),
            session("2026-06-24", "easy", "done"),
            session("2026-06-25", "easy", "planned"),   // missed
            session("2026-06-26", "easy", "done"),
            session("2026-06-27", "tempo", "done"),
            session("2026-07-01", "interval", "skipped"),
            session("2026-06-28", "long", "done"),
            session("2026-07-05", "long", "done"),
            session("2026-06-29", "rest", "planned"),
            session("2026-10-11", "race", "planned"),
            session("2026-06-20", "long", "planned"),   // before the block
        ]
        let r = review([], sessions: sessions)
        XCTAssertEqual(r.all, BlockReview.Adherence(done: 6, planned: 8))
        XCTAssertEqual(r.all.fraction ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(r.quality, BlockReview.Adherence(done: 1, planned: 2))
        XCTAssertEqual(r.long, BlockReview.Adherence(done: 2, planned: 2))
        XCTAssertEqual(r.long.fraction, 1)
    }

    /// No quality planned reads as "—", not 0% — a block that never had intervals didn't
    /// skip them all.
    func testAdherenceWithNothingPlannedHasNoFraction() {
        let r = review([], sessions: [session("2026-06-23", "easy", "done")])
        XCTAssertEqual(r.quality.planned, 0)
        XCTAssertNil(r.quality.fraction)
    }

    // MARK: - Distance

    /// Races run from the mile to the marathon (#102). The 20+ tile belongs to half and
    /// marathon blocks. The projection belongs to every block, at the block's own distance:
    /// it used to be marathon-only, so a 10K block had none (#185).
    func testDistanceDecidesWhatTheBlockShows() {
        let long = run("2026-09-20", miles: 20)
        XCTAssertTrue(review([long]).showsLongRunCount)
        XCTAssertTrue(review([long], raceMeters: RaceRecap.raceMeters(goalDistance: "half")).showsLongRunCount)
        let tenKMeters = RaceRecap.raceMeters(goalDistance: "10k")
        let tenK = review([long], raceMeters: tenKMeters)
        XCTAssertFalse(tenK.showsLongRunCount)
        XCTAssertEqual(tenK.longest?.id, long.id, "short blocks still show their longest run")
        XCTAssertEqual(
            tenK.projectedRaceMorningS,
            ProjectionHistory.projection([long], asOf: raceDay.addingTimeInterval(-1), raceMeters: tenKMeters)?.finishS
        )
        XCTAssertLessThan(tenK.projectedRaceMorningS ?? .max, review([long]).projectedRaceMorningS ?? 0,
                          "a 10K projection, not the marathon one")
    }

    func testRaceDistanceIsReadOffTheGoalNeverAssumed() {
        XCTAssertEqual(RaceRecap.raceMeters(goalDistance: "1mi"), 1_609.34, accuracy: 0.001)
        XCTAssertEqual(RaceRecap.raceMeters(goalDistance: "5k"), 5_000)
        XCTAssertEqual(RaceRecap.raceMeters(goalDistance: "15k"), 15_000)
        XCTAssertEqual(RaceRecap.raceMeters(goalDistance: "10mi"), 16_093.4, accuracy: 0.001)
        XCTAssertEqual(RaceRecap.raceMeters(goalDistance: "half"), 21_097.5)
        XCTAssertEqual(BlockReview.distanceLabel("half"), "Half marathon")
    }

    // MARK: - Projection

    /// Block start reads the projection as of the morning the block began; race morning as of
    /// the morning of the race. A fast 10K in August moves the second and not the first.
    func testProjectionAtBlockStartAndRaceMorning() {
        let june = RunSummary(id: UUID(), start: at("2026-06-10"), distanceM: Int(10 * 1609.34),
                              durationS: 10 * 480, avgHR: nil)                // 8:00/mi
        let sept = RunSummary(id: UUID(), start: at("2026-09-20"), distanceM: Int(10 * 1609.34),
                              durationS: 10 * 420, avgHR: nil)                // 7:00/mi
        let r = review([june, sept])
        let start = ProjectionHistory.projection([june, sept], asOf: planStart.addingTimeInterval(-1), raceMeters: marathon)?.finishS
        let morning = ProjectionHistory.projection([june, sept], asOf: raceDay.addingTimeInterval(-1), raceMeters: marathon)?.finishS
        XCTAssertEqual(r.projectedAtStartS, start)
        XCTAssertEqual(r.projectedRaceMorningS, morning)
        XCTAssertLessThan(r.projectionChangeS ?? 0, 0, "the block made the projection faster")
    }
}
