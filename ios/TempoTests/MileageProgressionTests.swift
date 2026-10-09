import XCTest
@testable import Tempo

/// The 12-week chart on Today is the athlete's answer to "am I running more or less than I
/// have been?" Every way it can be wrong is quiet: a dropped empty week draws a smooth line
/// across an injury, a Sunday-night long run filed under Monday moves 15 miles between two
/// bars, and averaging in a two-day-old week makes every Tuesday look like a cutback. None
/// of those crash. They just get believed. Hence: pinned.
final class MileageProgressionTests: XCTestCase {

    /// Fixed calendar + fixed "now" so nothing here depends on when the suite runs.
    private let cal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// A Thursday. The current week opened Monday 2026-08-24; the 12-week window opens
    /// Monday 2026-06-08.
    private var now: Date { date("2026-08-27 07:30") }

    private func date(_ stamp: String, in calendar: Calendar? = nil) -> Date {
        let c = calendar ?? cal
        let f = DateFormatter()
        f.calendar = c
        f.timeZone = c.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = stamp.count > 10 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return f.date(from: stamp)!
    }

    private func run(_ stamp: String, miles: Double, in calendar: Calendar? = nil) -> RunSummary {
        RunSummary(
            id: UUID(),
            start: date(stamp, in: calendar),
            distanceM: Int((miles * 1609.34).rounded()),
            durationS: Int(miles * 540),
            avgHR: nil
        )
    }

    private func progression(_ runs: [RunSummary]) -> MileageProgression.Progression {
        MileageProgression.progression(runs: runs, now: now, calendar: cal)
    }

    // MARK: - Shape of the window

    func testAlwaysTwelvePointsWhateverTheArchive() {
        let empty = MileageProgression.last12Weeks(runs: [], now: now, calendar: cal)
        let ancient = MileageProgression.last12Weeks(runs: [run("2021-03-02", miles: 6)], now: now, calendar: cal)
        // Five years of near-daily running, the shape of David's real archive.
        let big = (0..<2_000).map { i in
            RunSummary(id: UUID(), start: now.addingTimeInterval(-Double(i) * 86_400 * 0.9),
                       distanceM: 8_000, durationS: 2_700, avgHR: nil)
        }
        let full = MileageProgression.last12Weeks(runs: big, now: now, calendar: cal)

        XCTAssertEqual(empty.count, 12, "no runs is still twelve weeks — a flat zero line")
        XCTAssertEqual(ancient.count, 12, "an archive that ends long ago is twelve empty weeks, not none")
        XCTAssertEqual(full.count, 12)
    }

    func testWeeksAreConsecutiveMondaysOldestFirst() {
        let weeks = MileageProgression.last12Weeks(runs: [], now: now, calendar: cal)
        XCTAssertEqual(weeks.first?.weekStart, date("2026-06-08"))
        XCTAssertEqual(weeks.last?.weekStart, date("2026-08-24"))
        for (a, b) in zip(weeks, weeks.dropFirst()) {
            XCTAssertEqual(cal.dateComponents([.day], from: a.weekStart, to: b.weekStart).day, 7)
        }
        XCTAssertTrue(weeks.allSatisfy { cal.component(.weekday, from: $0.weekStart) == 2 }, "every week opens on a Monday")
        XCTAssertEqual(weeks.last?.weekEnd, date("2026-08-30"), "and closes on the Sunday")
    }

    /// The reason this rule exists: an injury fortnight has to read as a hole in the line.
    func testZeroWeeksArePresentNotSkipped() {
        let weeks = MileageProgression.last12Weeks(
            runs: [run("2026-08-04", miles: 8), run("2026-08-18", miles: 6)],
            now: now, calendar: cal
        )
        let gap = weeks.first { $0.weekStart == date("2026-08-10") }

        XCTAssertNotNil(gap, "the run-free week between two training weeks is a point on the chart")
        XCTAssertEqual(gap?.miles, 0)
        XCTAssertEqual(gap?.runCount, 0)
        XCTAssertEqual(gap?.longestRunMiles, 0)
        XCTAssertEqual(weeks.filter { $0.runCount == 0 }.count, 10)
    }

    func testCurrentWeekIsLastAndPartial() {
        let weeks = MileageProgression.last12Weeks(
            runs: [run("2026-08-24 06:00", miles: 5), run("2026-08-26 06:00", miles: 7)],
            now: now, calendar: cal
        )
        let current = weeks.last!

        XCTAssertTrue(current.isCurrent)
        XCTAssertEqual(weeks.filter(\.isCurrent).count, 1, "exactly one current week")
        XCTAssertEqual(current.weekStart, date("2026-08-24"))
        XCTAssertLessThan(now, cal.date(byAdding: .day, value: 1, to: current.weekEnd)!,
                          "the current week is still open — Fri, Sat, Sun are to come")
        XCTAssertEqual(current.miles, 12, accuracy: 0.01, "Mon + Wed so far")
        XCTAssertEqual(current.runCount, 2)
    }

    // MARK: - Week boundaries

    /// A long run that finishes late on Sunday belongs to the week it closed, not the one
    /// starting a few minutes later — otherwise a 16-mile week reads as 0 and the next as 16
    /// before it has begun.
    func testSundayNightRunLandsInTheWeekItCloses() {
        let weeks = MileageProgression.last12Weeks(
            runs: [run("2026-08-23 23:40", miles: 16), run("2026-08-24 00:10", miles: 3)],
            now: now, calendar: cal
        )
        let previous = weeks[weeks.count - 2]
        let current = weeks[weeks.count - 1]

        XCTAssertEqual(previous.weekStart, date("2026-08-17"))
        XCTAssertEqual(previous.miles, 16, accuracy: 0.01, "Sunday 23:40 closes the week of the 17th")
        XCTAssertEqual(current.miles, 3, accuracy: 0.01, "Monday 00:10 opens the current week")
    }

    /// Weeks are Monday-first in the athlete's own time zone, and a clock change inside the
    /// window must not shift a boundary or produce a duplicate week. US clocks fall back on
    /// Sunday 2026-11-01; this window spans it.
    func testDaylightSavingChangeKeepsMondayBoundaries() {
        var ny = Calendar(identifier: .iso8601)
        ny.firstWeekday = 2
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let now = date("2026-11-12 08:00", in: ny)

        let weeks = MileageProgression.last12Weeks(
            runs: [run("2026-11-01 22:30", miles: 14, in: ny), run("2026-11-02 06:00", miles: 4, in: ny)],
            now: now, calendar: ny
        )

        XCTAssertEqual(Set(weeks.map(\.weekStart)).count, 12, "no week appears twice across the clock change")
        XCTAssertTrue(weeks.allSatisfy {
            ny.component(.weekday, from: $0.weekStart) == 2 && ny.component(.hour, from: $0.weekStart) == 0
        }, "every week opens at local midnight on a Monday, either side of the change")
        let closing = weeks.first { $0.weekStart == date("2026-10-26", in: ny) }
        let opening = weeks.first { $0.weekStart == date("2026-11-02", in: ny) }
        XCTAssertEqual(closing?.miles ?? 0, 14, accuracy: 0.01, "the fall-back Sunday's evening run stays in its week")
        XCTAssertEqual(opening?.miles ?? 0, 4, accuracy: 0.01)
    }

    func testRunsOutsideTheWindowAreIgnored() {
        let p = progression([
            run("2026-06-07 09:00", miles: 20),   // Sunday before the window opens
            run("2026-06-08 09:00", miles: 5),    // first day of the window
        ])
        XCTAssertEqual(p.weeks.first?.miles ?? 0, 5, accuracy: 0.01)
        XCTAssertEqual(p.weeks.reduce(0) { $0 + $1.miles }, 5, accuracy: 0.01)
    }

    // MARK: - Same rules as History

    /// Superseded rows (migration 0008's retired Garmin re-exports) are dropped at the read —
    /// `RunStore.fetchFromSupabase` selects `superseded_by is null` — and `RunSummary` has no
    /// flag left to filter on. What *can* break here is a second, slightly different weekly
    /// total. So this pins the chart to `byWeek`, number for number: if one ever counts a run
    /// the other doesn't, History and Today disagree about the same week, and this fails.
    func testWeeklyTotalsMatchHistoryExactly() {
        var runs: [RunSummary] = []
        var day = date("2026-06-01")
        var miles = 3.1
        while day < now {
            runs.append(RunSummary(id: UUID(), start: day.addingTimeInterval(19 * 3_600 + 50 * 60),
                                   distanceM: Int(miles * 1609.34), durationS: Int(miles * 540), avgHR: nil))
            day = day.addingTimeInterval(86_400 * 1.5)
            miles = miles >= 18 ? 3.1 : miles + 2.3
        }
        let history = Dictionary(uniqueKeysWithValues: RunHistory.byWeek(runs, calendar: cal).map { ($0.weekStart, $0) })
        let weeks = MileageProgression.last12Weeks(runs: runs, now: now, calendar: cal)

        for week in weeks {
            let expected = history[week.weekStart]
            XCTAssertEqual(week.miles, expected?.miles ?? 0, accuracy: 1e-9, "\(week.weekStart)")
            XCTAssertEqual(week.runCount, expected?.runCount ?? 0, "\(week.weekStart)")
        }
    }

    func testLongestRunIsTheBiggestSingleRunInTheWeek() {
        let weeks = MileageProgression.last12Weeks(
            runs: [run("2026-08-17", miles: 5), run("2026-08-22", miles: 14.2), run("2026-08-19", miles: 8)],
            now: now, calendar: cal
        )
        let week = weeks.first { $0.weekStart == date("2026-08-17") }
        XCTAssertEqual(week?.longestRunMiles ?? 0, 14.2, accuracy: 0.01)
        XCTAssertEqual(week?.miles ?? 0, 27.2, accuracy: 0.01)
    }

    // MARK: - Average

    /// Thursday morning, five miles in: against an average of 30 the week is 25 short, and
    /// that is a fact about the calendar, not the training. Folding it into the average would
    /// drag the reference line itself down to ~27.9 and make the shortfall look smaller.
    func testAverageExcludesTheCurrentPartialWeek() {
        var runs = (1...11).map { back in
            run(stamp(cal.date(byAdding: .weekOfYear, value: -back, to: date("2026-08-26"))!), miles: 30)
        }
        runs.append(run("2026-08-25", miles: 5))
        let p = progression(runs)

        XCTAssertEqual(p.average, 30, accuracy: 0.001, "eleven completed weeks of 30")
        XCTAssertEqual(p.current?.miles ?? 0, 5, accuracy: 0.01)
        XCTAssertEqual(p.currentVsAverage, -25, accuracy: 0.01)
    }

    /// An empty week drags the average down. That's correct — a week off is part of what
    /// you have been running.
    func testAverageCountsZeroWeeks() {
        let runs = (2...11).map { back in
            run(stamp(cal.date(byAdding: .weekOfYear, value: -back, to: date("2026-08-26"))!), miles: 33)
        }
        let p = progression(runs)
        XCTAssertEqual(p.weeks[10].miles, 0, "last week was a week off")
        XCTAssertEqual(p.average, 30, accuracy: 0.001, "330 miles over 11 completed weeks")
    }

    func testEmptyArchiveIsAFlatZeroLine() {
        let p = progression([])
        XCTAssertEqual(p.weeks.count, 12)
        XCTAssertTrue(p.weeks.allSatisfy { $0.miles == 0 && $0.runCount == 0 })
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.average, 0)
        XCTAssertEqual(p.peak, 0)
        XCTAssertEqual(p.currentVsAverage, 0)
    }

    // MARK: - Other window sizes

    /// The widget asks for fewer weeks; the rules cannot change with the count.
    func testShorterWindowIsTheTailOfTheLongerOne() {
        let runs = [run("2026-08-04", miles: 8), run("2026-08-18", miles: 6), run("2026-08-25", miles: 4)]
        let twelve = MileageProgression.last12Weeks(runs: runs, now: now, calendar: cal)
        let four = MileageProgression.weeks(4, runs: runs, now: now, calendar: cal)

        XCTAssertEqual(four, Array(twelve.suffix(4)))
        XCTAssertTrue(MileageProgression.weeks(0, runs: runs, now: now, calendar: cal).isEmpty)
    }

    private func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}
