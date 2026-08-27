import XCTest
@testable import Tempo

/// The history layer is pure arithmetic over 2,000+ real runs, and every number it
/// produces is one the athlete will read as a fact about his own training — a wrong
/// "longest run" or a streak that silently resets is the kind of bug that looks like
/// a design choice rather than a defect. Hence: pinned.
final class RunHistoryTests: XCTestCase {

    /// Fixed calendar + fixed "now" so nothing here depends on when the suite runs.
    private let cal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var now: Date { date("2026-08-27") }

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    private func run(_ iso: String, miles: Double, paceSec: Int = 540) -> RunSummary {
        RunSummary(
            id: UUID(),
            start: date(iso),
            distanceM: Int(miles * 1609.34),
            durationS: Int(miles * Double(paceSec)),
            avgHR: nil
        )
    }

    // MARK: - Grouping

    func testGroupsIntoMonthsNewestFirst() {
        let runs = [run("2026-08-02", miles: 5), run("2026-07-30", miles: 6), run("2026-08-20", miles: 4)]
        let months = RunHistory.byMonth(runs, calendar: cal)

        XCTAssertEqual(months.count, 2)
        XCTAssertEqual(months[0].runCount, 2, "August holds two runs")
        XCTAssertEqual(months[0].miles, 9, accuracy: 0.01)
        XCTAssertEqual(months[1].runCount, 1)
        XCTAssertGreaterThan(months[0].start, months[1].start, "newest month leads")
    }

    func testRunsWithinAMonthAreNewestFirst() {
        let runs = [run("2026-08-02", miles: 5), run("2026-08-20", miles: 4), run("2026-08-11", miles: 3)]
        let august = RunHistory.byMonth(runs, calendar: cal)[0]
        XCTAssertEqual(
            august.runs.map(\.start),
            [date("2026-08-20"), date("2026-08-11"), date("2026-08-02")],
            "descending by date"
        )
    }

    func testMonthMaxMilesScalesTheBar() {
        let month = RunHistory.byMonth([run("2026-08-02", miles: 5), run("2026-08-09", miles: 18)], calendar: cal)[0]
        XCTAssertEqual(month.maxMiles, 18, accuracy: 0.01)
    }

    func testEmptyArchiveGroupsToNothing() {
        XCTAssertTrue(RunHistory.byMonth([], calendar: cal).isEmpty)
    }

    // MARK: - Weeks

    func testWeeksRunMondayToSunday() {
        // 2026-08-24 is a Monday; the 23rd is the Sunday closing the week before.
        let weeks = RunHistory.byWeek([run("2026-08-23", miles: 10), run("2026-08-24", miles: 4)], calendar: cal)
        XCTAssertEqual(weeks.count, 2, "a Sunday and the following Monday are different training weeks")
    }

    // MARK: - Records

    func testLongestRunWins() {
        let runs = [run("2026-08-02", miles: 5), run("2026-08-09", miles: 22), run("2026-08-16", miles: 13)]
        XCTAssertEqual(RunHistory.records(runs, now: now, calendar: cal).longestRun?.miles ?? 0, 22, accuracy: 0.01)
    }

    func testLongestRunTieBreaksToTheEarlierRun() {
        let first = run("2026-06-01", miles: 20)
        let second = run("2026-08-01", miles: 20)
        let r = RunHistory.records([second, first], now: now, calendar: cal)
        XCTAssertEqual(r.longestRun?.id, first.id, "the first time you went that far is the record")
    }

    /// The whole point of banding: a fast short run must not outrank a fast long one.
    func testFastestRunIsScopedByDistanceBand() {
        let sprint = run("2026-08-02", miles: 3.1, paceSec: 360)    // 6:00/mi, but only a 5K
        let strongHalf = run("2026-08-09", miles: 13.5, paceSec: 450) // 7:30/mi over a half
        let r = RunHistory.records([sprint, strongHalf], now: now, calendar: cal)

        XCTAssertEqual(r.fastestRun[.threeMile]?.id, sprint.id, "the 3 mi+ band is the sprint's to win")
        XCTAssertEqual(r.fastestRun[.half]?.id, strongHalf.id, "the sprint cannot hold the half record")
        XCTAssertNil(r.fastestRun[.marathon], "no run went 26.2 — the band stays empty rather than inventing one")
    }

    func testShortRunsNeverQualify() {
        let r = RunHistory.records([run("2026-08-02", miles: 2, paceSec: 300)], now: now, calendar: cal)
        XCTAssertNil(r.fastestRun[.threeMile], "a 2-mile run is below every band")
        XCTAssertTrue(r.recordRunIDs.contains(r.longestRun!.id), "it is still the longest run on file")
    }

    func testBiggestWeekAndMonth() {
        let runs = [
            run("2026-08-03", miles: 10), run("2026-08-05", miles: 12),  // week of Aug 3 → 22
            run("2026-08-10", miles: 5),                                  // week of Aug 10 → 5
            run("2026-07-06", miles: 8),
        ]
        let r = RunHistory.records(runs, now: now, calendar: cal)
        XCTAssertEqual(r.biggestWeek?.miles ?? 0, 22, accuracy: 0.01)
        XCTAssertEqual(r.biggestMonth?.miles ?? 0, 27, accuracy: 0.01, "August: 10 + 12 + 5")
    }

    func testTotalsCoverTheWholeArchive() {
        let r = RunHistory.records([run("2026-08-02", miles: 5), run("2025-01-02", miles: 7)], now: now, calendar: cal)
        XCTAssertEqual(r.totalRuns, 2)
        XCTAssertEqual(r.totalMiles, 12, accuracy: 0.01)
        XCTAssertEqual(r.firstRun, date("2025-01-02"), "the archive starts at the oldest run, not the newest")
    }

    func testEmptyArchiveHasNoRecords() {
        let r = RunHistory.records([], now: now, calendar: cal)
        XCTAssertEqual(r.totalRuns, 0)
        XCTAssertNil(r.longestRun)
        XCTAssertTrue(r.recordRunIDs.isEmpty)
        XCTAssertEqual(r.currentStreakDays, 0)
    }

    // MARK: - Streaks

    func testCurrentStreakCountsBackFromToday() {
        let runs = [run("2026-08-27", miles: 4), run("2026-08-26", miles: 5), run("2026-08-25", miles: 6)]
        XCTAssertEqual(RunHistory.streaks(runs, now: now, calendar: cal).current, 3)
    }

    /// The reason the streak doesn't count from today alone: an evening runner would
    /// otherwise see "0" every morning and watch it snap back after dinner.
    func testTodayNotRunYetDoesNotBreakTheStreak() {
        let runs = [run("2026-08-26", miles: 5), run("2026-08-25", miles: 6)]
        XCTAssertEqual(RunHistory.streaks(runs, now: now, calendar: cal).current, 2)
    }

    func testStreakBreaksOnceYesterdayIsAlsoEmpty() {
        let runs = [run("2026-08-24", miles: 5), run("2026-08-23", miles: 6)]
        XCTAssertEqual(RunHistory.streaks(runs, now: now, calendar: cal).current, 0, "two rest days ends it")
    }

    func testTwoRunsInOneDayCountAsOneDay() {
        let morning = run("2026-08-27", miles: 4)
        let evening = run("2026-08-27", miles: 3)
        XCTAssertEqual(RunHistory.streaks([morning, evening], now: now, calendar: cal).current, 1)
    }

    func testLongestStreakFindsTheBestRunInHistory() {
        let runs = ["2026-03-01", "2026-03-02", "2026-03-03", "2026-03-04",   // 4 days
                    "2026-05-01", "2026-05-02"]                                // 2 days
            .map { run($0, miles: 5) }
        XCTAssertEqual(RunHistory.streaks(runs, now: now, calendar: cal).longest, 4)
    }

    func testLongestIsNeverLessThanCurrent() {
        let runs = [run("2026-08-27", miles: 4), run("2026-08-26", miles: 5)]
        let s = RunHistory.streaks(runs, now: now, calendar: cal)
        XCTAssertGreaterThanOrEqual(s.longest, s.current)
    }
}
