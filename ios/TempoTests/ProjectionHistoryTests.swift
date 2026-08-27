import XCTest
@testable import Tempo

/// The projection is the single number on Progress that the athlete reads as a verdict on
/// whether the block is working. It is also the jumpiest thing in the app — one fast
/// parkrun moves it by minutes — so a quiet arithmetic drift here would look exactly like
/// fitness, and be believed.
///
/// These pin the rule itself, because `recomputeProjection` now reads it from here: if the
/// engine and the card ever disagreed, the chart would be documenting a formula the app
/// isn't using.
final class ProjectionHistoryTests: XCTestCase {

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

    // MARK: - The 42-day window

    /// The boundary is inclusive and exact: a run 42 days back still counts, 43 does not.
    /// Both halves are pinned, because an off-by-one here silently swaps which run the
    /// whole projection rests on.
    func testTheWindowBoundaryIsInclusiveAtFortyTwoDays() {
        // 2026-08-27 minus 42 days is 2026-07-16.
        let onTheEdge = run("2026-07-16", miles: 6, paceSec: 480)
        let oneDayTooOld = run("2026-07-15", miles: 6, paceSec: 360)   // much faster, but stale

        let best = ProjectionHistory.settingRun([oneDayTooOld, onTheEdge], asOf: now, calendar: cal)
        XCTAssertEqual(best?.id, onTheEdge.id, "42 days back is still inside the window")
    }

    func testARunOneDayOutsideTheWindowCannotSetTheProjection() {
        let stale = run("2026-07-15", miles: 6, paceSec: 360)
        XCTAssertNil(
            ProjectionHistory.settingRun([stale], asOf: now, calendar: cal),
            "43 days back is out; with nothing else on file there is no projection at all"
        )
    }

    func testTheSameRunCountsAgainWhenAskedOneDayEarlier() {
        let fast = run("2026-07-15", miles: 6, paceSec: 360)
        let slow = run("2026-07-16", miles: 6, paceSec: 480)
        // 2026-08-26 minus 42 days is 2026-07-15 — the fast run is back inside.
        let best = ProjectionHistory.settingRun([slow, fast], asOf: date("2026-08-26"), calendar: cal)
        XCTAssertEqual(best?.id, fast.id)
    }

    /// Replay is only honest if it cannot cheat. Asking what the projection was in the past
    /// must not be answered by a run that had not happened yet.
    func testReplayCannotSeeTheFuture() {
        let past = run("2026-08-01", miles: 6, paceSec: 480)
        let future = run("2026-08-20", miles: 6, paceSec: 360)
        let best = ProjectionHistory.settingRun([past, future], asOf: date("2026-08-10"), calendar: cal)
        XCTAssertEqual(best?.id, past.id)
    }

    // MARK: - The 2.5-mile floor

    func testShortRunsCannotSetTheProjection() {
        // A blistering 2.4 miles is not evidence you can hold that shape for 26.2.
        let strides = run("2026-08-24", miles: 2.4, paceSec: 300)
        let steady = run("2026-08-22", miles: 6, paceSec: 480)

        let best = ProjectionHistory.settingRun([strides, steady], asOf: now, calendar: cal)
        XCTAssertEqual(best?.id, steady.id, "the sprint is below the floor and never enters the pool")
    }

    func testJustOverTheFloorQualifies() {
        // The floor is measured on `RunSummary.miles`, which is derived from stored metres,
        // so 2.51 clears it and 2.49 does not. Both sides pinned.
        let justOver = run("2026-08-24", miles: 2.51, paceSec: 300)
        let justUnder = run("2026-08-23", miles: 2.49, paceSec: 280)

        XCTAssertEqual(
            ProjectionHistory.settingRun([justUnder, justOver], asOf: now, calendar: cal)?.id,
            justOver.id
        )
    }

    func testNothingQualifyingMeansNoProjectionRatherThanZero() {
        let onlyStrides = [run("2026-08-24", miles: 1.2, paceSec: 300)]
        XCTAssertNil(ProjectionHistory.projection(onlyStrides, asOf: now, calendar: cal))
    }

    // MARK: - The extrapolation

    /// A known effort to a known marathon time. Ten miles at 7:00/mi — the shape of a
    /// solid tempo — Riegels out to just under 3:15, which is why David's goal is 3:15.
    func testKnownEffortExtrapolatesToKnownMarathonTime() {
        let tempo = run("2026-08-24", miles: 10, paceSec: 420)
        let projected = ProjectionHistory.projection([tempo], asOf: now, calendar: cal)?.finishS

        XCTAssertNotNil(projected)
        XCTAssertEqual(projected ?? 0, 11_667, accuracy: 2, "3:14:27")
    }

    func testFastestPaceWinsNotTheLongestRun() {
        let long = run("2026-08-16", miles: 20, paceSec: 540)
        let quick = run("2026-08-22", miles: 3.1, paceSec: 380)

        XCTAssertEqual(
            ProjectionHistory.settingRun([long, quick], asOf: now, calendar: cal)?.id,
            quick.id,
            "the projection is an extrapolated best effort, not a fitness average"
        )
    }

    /// `recomputeProjection` picks with `min(by:)` over the newest-first store, which keeps
    /// the first of equals — the newer run. This screen names that run out loud, so it has
    /// to name the same one.
    func testTiesBreakToTheMoreRecentEffort() {
        let older = run("2026-08-01", miles: 5, paceSec: 420)
        let newer = run("2026-08-20", miles: 5, paceSec: 420)

        XCTAssertEqual(
            ProjectionHistory.settingRun([older, newer], asOf: now, calendar: cal)?.id,
            newer.id
        )
    }

    // MARK: - The replay

    func testSeriesIsAscendingAndAnchoredOnTheEndDate() {
        let runs = (0..<12).map { week in
            run(iso(weeksBefore: week), miles: 6, paceSec: 470 + week)
        }
        let points = ProjectionHistory.series(
            runs: runs, from: date("2026-06-01"), to: now, calendar: cal
        )

        XCTAssertEqual(points.last?.date, now, "the right edge has to be the moment asked for")
        XCTAssertEqual(points.map(\.date), points.map(\.date).sorted(), "oldest first")
    }

    /// The rule this engine exists to protect: a window with nothing in it produces nothing.
    /// A carried-forward value would be a fitness reading nobody took.
    func testAnEmptyWindowProducesNoPointRatherThanAFabricatedOne() {
        let single = run("2026-06-01", miles: 6, paceSec: 420)
        let points = ProjectionHistory.series(
            runs: [single], from: date("2026-06-01"), to: now, calendar: cal
        )

        XCTAssertFalse(points.isEmpty)
        XCTAssertEqual(points.first?.date, date("2026-06-04"))
        XCTAssertEqual(points.last?.date, date("2026-07-09"),
                       "the window closes 42 days after the run and the line simply stops")
        XCTAssertTrue(points.allSatisfy { $0.runID == single.id })
        XCTAssertEqual(Set(points.map(\.projectedFinishS)).count, 1, "one effort, one value")
    }

    func testAnArchiveWithNoRunsPlotsNothing() {
        XCTAssertTrue(
            ProjectionHistory.series(runs: [], from: date("2020-01-01"), to: now, calendar: cal).isEmpty
        )
        XCTAssertNil(ProjectionHistory.settingRun([], asOf: now, calendar: cal))
    }

    func testDistantPastClampsToTheOldestRun() {
        let runs = [run("2026-06-01", miles: 6, paceSec: 420)]
        let points = ProjectionHistory.series(runs: runs, from: .distantPast, to: now, calendar: cal)

        XCTAssertFalse(points.isEmpty, "an unbounded start is the 'All' range, not an error")
        XCTAssertGreaterThanOrEqual(points[0].date, date("2026-06-01"))
    }

    // MARK: - Segments (so the chart cannot interpolate across a gap)

    func testSegmentsSplitAtEveryGap() {
        let runs = [
            run("2026-01-05", miles: 6, paceSec: 420),
            run("2026-06-01", miles: 6, paceSec: 430),
        ]
        let points = ProjectionHistory.series(
            runs: runs, from: date("2026-01-05"), to: now, calendar: cal
        )
        let stretches = ProjectionHistory.segments(points, calendar: cal)

        XCTAssertEqual(stretches.count, 2, "two islands of readings, five months apart")
        XCTAssertTrue(stretches.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(stretches.flatMap { $0 }.count, points.count, "splitting loses nothing")
    }

    func testAContinuousSeriesIsOneSegment() {
        let runs = (0..<10).map { run(iso(weeksBefore: $0), miles: 6, paceSec: 470) }
        let points = ProjectionHistory.series(
            runs: runs, from: date("2026-07-01"), to: now, calendar: cal
        )
        XCTAssertEqual(ProjectionHistory.segments(points, calendar: cal).count, 1)
    }

    func testNoPointsMeansNoSegments() {
        XCTAssertTrue(ProjectionHistory.segments([], calendar: cal).isEmpty)
    }

    // MARK: - The jumpiness the screen warns about

    /// The detail page tells the athlete that one fast effort moves the number and that it
    /// climbs back six weeks later with no change in fitness. That claim is a behaviour of
    /// the rule, so it gets pinned like any other.
    func testOneFastEffortMovesTheProjectionAndTheWindowMovesItBack() {
        var runs = (0..<32).map { run(iso(weeksBefore: $0), miles: 6, paceSec: 480) }
        let parkrun = run("2026-06-15", miles: 3.2, paceSec: 380)
        runs.append(parkrun)

        let during = ProjectionHistory.projection(runs, asOf: date("2026-06-22"), calendar: cal)
        let after = ProjectionHistory.projection(runs, asOf: date("2026-08-03"), calendar: cal)
        let before = ProjectionHistory.projection(runs, asOf: date("2026-06-08"), calendar: cal)

        XCTAssertEqual(during?.run.id, parkrun.id)
        XCTAssertLessThan(during?.finishS ?? 0, before?.finishS ?? 0, "the parkrun drops it")
        XCTAssertNotEqual(after?.run.id, parkrun.id, "42 days later it has aged out")
        XCTAssertEqual(after?.finishS, before?.finishS,
                       "and the number is exactly back where it was — the step was the window, not fitness")
    }

    // MARK: - Helpers

    private func iso(weeksBefore weeks: Int) -> String {
        let day = cal.date(byAdding: .day, value: -7 * weeks, to: date("2026-08-24"))!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }
}
