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

    private let marathon = RaceRecap.marathonMeters
    private let fiveK = 5_000.0

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
        XCTAssertNil(ProjectionHistory.projection(onlyStrides, asOf: now, raceMeters: marathon, calendar: cal))
    }

    // MARK: - The walking ceiling (#227)

    /// The incident itself: on 15 Oct 2026 the only run of 2.5 mi or more in six weeks was
    /// 8.1 mi with a 10h24m wall clock — a watch left recording. "Fastest qualifying run"
    /// picked it because it was the only one, and the marathon projection read 36:06:09.
    func testAWatchLeftRunningCannotSetTheProjection() {
        let leftRunning = RunSummary(
            id: UUID(), start: date("2026-08-20"), distanceM: 13_047, durationS: 37_459, avgHR: nil
        )
        XCTAssertEqual(leftRunning.paceSecPerMile, 4_620, "77:00/mi, as stored")

        XCTAssertNil(ProjectionHistory.settingRun([leftRunning], asOf: now, calendar: cal))
        XCTAssertNil(
            ProjectionHistory.projection([leftRunning], asOf: now, raceMeters: marathon, calendar: cal),
            "no plausible effort means no projection, not a 36-hour one"
        )
    }

    /// Both sides of the ceiling. 20:00/mi exactly still counts — a run-walk is a run.
    func testTheCeilingIsInclusiveAtTwentyMinutesAMile() {
        let atCeiling = run("2026-08-24", miles: 3, paceSec: 1_200)
        let justOver = run("2026-08-25", miles: 3, paceSec: 1_201)

        XCTAssertEqual(ProjectionHistory.settingRun([atCeiling], asOf: now, calendar: cal)?.id, atCeiling.id)
        XCTAssertNil(ProjectionHistory.settingRun([justOver], asOf: now, calendar: cal))
    }

    /// The ceiling only removes a run from the pool; a real run in the same window still wins.
    func testAWalkInTheWindowLeavesTheRealRunInCharge() {
        let walk = run("2026-08-26", miles: 8, paceSec: 1_500)
        let easy = run("2026-08-20", miles: 5, paceSec: 580)

        let replay = ProjectionHistory.series(
            runs: [walk, easy], from: date("2026-08-13"), to: now, raceMeters: marathon, calendar: cal
        )
        XCTAssertFalse(replay.isEmpty)
        XCTAssertTrue(replay.allSatisfy { $0.runID == easy.id }, "the chart never plots the walk either")
    }

    // MARK: - The extrapolation

    /// A known effort to a known marathon time. Ten miles at 7:00/mi — the shape of a
    /// solid tempo — Riegels out to just under 3:15, which is why David's goal is 3:15.
    func testKnownEffortExtrapolatesToKnownMarathonTime() {
        let tempo = run("2026-08-24", miles: 10, paceSec: 420)
        let projected = ProjectionHistory.projection([tempo], asOf: now, raceMeters: marathon, calendar: cal)?.finishS

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
            runs: runs, from: date("2026-06-01"), to: now, raceMeters: marathon, calendar: cal
        )

        XCTAssertEqual(points.last?.date, now, "the right edge has to be the moment asked for")
        XCTAssertEqual(points.map(\.date), points.map(\.date).sorted(), "oldest first")
    }

    /// The rule this engine exists to protect: a window with nothing in it produces nothing.
    /// A carried-forward value would be a fitness reading nobody took.
    func testAnEmptyWindowProducesNoPointRatherThanAFabricatedOne() {
        let single = run("2026-06-01", miles: 6, paceSec: 420)
        let points = ProjectionHistory.series(
            runs: [single], from: date("2026-06-01"), to: now, raceMeters: marathon, calendar: cal
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
            ProjectionHistory.series(runs: [], from: date("2020-01-01"), to: now, raceMeters: marathon, calendar: cal).isEmpty
        )
        XCTAssertNil(ProjectionHistory.settingRun([], asOf: now, calendar: cal))
    }

    func testDistantPastClampsToTheOldestRun() {
        let runs = [run("2026-06-01", miles: 6, paceSec: 420)]
        let points = ProjectionHistory.series(runs: runs, from: .distantPast, to: now, raceMeters: marathon, calendar: cal)

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
            runs: runs, from: date("2026-01-05"), to: now, raceMeters: marathon, calendar: cal
        )
        let stretches = ProjectionHistory.segments(points, calendar: cal)

        XCTAssertEqual(stretches.count, 2, "two islands of readings, five months apart")
        XCTAssertTrue(stretches.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(stretches.flatMap { $0 }.count, points.count, "splitting loses nothing")
    }

    func testAContinuousSeriesIsOneSegment() {
        let runs = (0..<10).map { run(iso(weeksBefore: $0), miles: 6, paceSec: 470) }
        let points = ProjectionHistory.series(
            runs: runs, from: date("2026-07-01"), to: now, raceMeters: marathon, calendar: cal
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

        let during = ProjectionHistory.projection(runs, asOf: date("2026-06-22"), raceMeters: marathon, calendar: cal)
        let after = ProjectionHistory.projection(runs, asOf: date("2026-08-03"), raceMeters: marathon, calendar: cal)
        let before = ProjectionHistory.projection(runs, asOf: date("2026-06-08"), raceMeters: marathon, calendar: cal)

        XCTAssertEqual(during?.run.id, parkrun.id)
        XCTAssertLessThan(during?.finishS ?? 0, before?.finishS ?? 0, "the parkrun drops it")
        XCTAssertNotEqual(after?.run.id, parkrun.id, "42 days later it has aged out")
        XCTAssertEqual(after?.finishS, before?.finishS,
                       "and the number is exactly back where it was — the step was the window, not fitness")
    }

    // MARK: - The goal's own distance (#185)

    private func goal(distance: String?, distanceM: Int? = nil, id: UUID = UUID()) -> GoalInfo {
        GoalInfo(id: id, race_name: "Turkey Trot 2026", race_date: "2026-11-05", goal_time_seconds: nil,
                 distance: distance, distance_m: distanceM)
    }

    /// 15 Oct 2026: with a 5K goal on file, Progress quoted a projected finish of 4:18:04 —
    /// the projection was hardcoded to 26.2. Six miles at 9:00/mi is a 4:17:48 marathon and
    /// a 26:52 5K; asked about a 5K, it has to say the 5K.
    func testAFiveKGoalProjectsToFiveKNotToAMarathon() {
        let effort = run("2026-08-24", miles: 6, paceSec: 540)

        let fiveKFinish = ProjectionHistory.projection([effort], asOf: now, raceMeters: fiveK, calendar: cal)?.finishS
        let marathonFinish = ProjectionHistory.projection([effort], asOf: now, raceMeters: marathon, calendar: cal)?.finishS

        XCTAssertEqual(fiveKFinish ?? 0, 1_612, accuracy: 2, "26:52 — the Riegel 5K equivalent")
        XCTAssertEqual(marathonFinish ?? 0, 15_468, accuracy: 2, "4:17:48 — the number #185 was showing against a 5K")
    }

    /// `distance_m` first, the label after, the marathon only with no goal at all — the same
    /// reading race-day detection uses, so the projection and the recap agree on the race.
    func testTheRaceIsReadOffTheGoalAndOnlyNoGoalMeansMarathon() {
        XCTAssertEqual(ProjectionHistory.raceMeters(goal: goal(distance: "5k")), 5_000)
        XCTAssertEqual(ProjectionHistory.raceMeters(goal: goal(distance: "custom", distanceM: 30_000)), 30_000)
        XCTAssertEqual(ProjectionHistory.raceMeters(goal: goal(distance: "marathon", distanceM: 5_000)), 5_000,
                       "distance_m is the number the math reads")
        XCTAssertEqual(ProjectionHistory.raceMeters(goal: nil), marathon,
                       "just-running mode: no race named, so the projection answers for the marathon")

        let tempo = run("2026-08-24", miles: 10, paceSec: 420)
        XCTAssertEqual(
            ProjectionHistory.projection([tempo], asOf: now, raceMeters: ProjectionHistory.raceMeters(goal: nil), calendar: cal)?.finishS ?? 0,
            11_667, accuracy: 2, "and with no goal it is the same 3:14:27 it always was"
        )
    }

    /// The chart replays every week against the distance passed in, so a 5K goal's chart is
    /// a line of 5K times and agrees, point for point, with the single-moment rule.
    func testReplayedPointsUseThePassedDistance() {
        let runs = (0..<10).map { run(iso(weeksBefore: $0), miles: 6, paceSec: 500 + 3 * $0) }
        let points = ProjectionHistory.series(
            runs: runs, from: date("2026-07-01"), to: now, raceMeters: fiveK, calendar: cal
        )

        XCTAssertFalse(points.isEmpty)
        for point in points {
            XCTAssertEqual(
                point.projectedFinishS,
                ProjectionHistory.projection(runs, asOf: point.date, raceMeters: fiveK, calendar: cal)?.finishS
            )
            XCTAssertLessThan(point.projectedFinishS, 3_600, "a 5K reading, not a 4-hour one")
        }
    }

    /// The device check on #185: with the stored value still the 4:18:04 marathon number, a
    /// refresh rewrites it to the 5K — and the next refresh leaves it there instead of
    /// flipping back.
    func testRefreshRewritesAMarathonNumberToTheFiveKAndThenHoldsIt() {
        let planGoal = UUID()
        let trot = goal(distance: "5k", distanceM: 5_000, id: planGoal)
        let runs = [run("2026-08-24", miles: 6, paceSec: 540)]

        let first = ProjectionHistory.rewrite(storedFinishS: 15_484, planGoalID: planGoal, goal: trot,
                                              runs: runs, asOf: now, calendar: cal)
        XCTAssertEqual(first ?? 0, 1_612, accuracy: 2)

        let second = ProjectionHistory.rewrite(storedFinishS: first, planGoalID: planGoal, goal: trot,
                                               runs: runs, asOf: now, calendar: cal)
        XCTAssertNil(second, "inside the deadband: no write, and certainly not back to 4:18")
    }

    /// `loadPlan` keeps the previous goal when the new one fails to load. Projecting to that
    /// stale goal's distance would overwrite a correct number with another race's.
    func testRefreshWritesNothingWhenTheGoalIsNotThePlansGoal() {
        let runs = [run("2026-08-24", miles: 6, paceSec: 540)]
        let stale = goal(distance: "marathon", distanceM: 42_195)

        XCTAssertNil(ProjectionHistory.rewrite(storedFinishS: 1_612, planGoalID: UUID(), goal: stale,
                                               runs: runs, asOf: now, calendar: cal))
        XCTAssertNil(ProjectionHistory.rewrite(storedFinishS: 1_612, planGoalID: UUID(), goal: nil,
                                               runs: runs, asOf: now, calendar: cal))
    }

    func testRefreshKeepsTheThirtySecondDeadband() {
        let planGoal = UUID()
        let chicago = goal(distance: "marathon", distanceM: 42_195, id: planGoal)
        let runs = [run("2026-08-24", miles: 10, paceSec: 420)]       // 11,667

        XCTAssertNil(ProjectionHistory.rewrite(storedFinishS: 11_697, planGoalID: planGoal, goal: chicago,
                                               runs: runs, asOf: now, calendar: cal), "30 s off: noise")
        XCTAssertEqual(ProjectionHistory.rewrite(storedFinishS: 11_698, planGoalID: planGoal, goal: chicago,
                                                 runs: runs, asOf: now, calendar: cal), 11_667, "31 s off: news")
    }

    /// The detail page names the race from the same metres the number was projected to, so
    /// the copy cannot say "the marathon" over a 5K number.
    func testTheDistanceIsNamedFromTheMetresTheMathUsed() {
        XCTAssertEqual(ProjectionHistory.distanceName(raceMeters: 5_000, units: .mi), "5K")
        XCTAssertEqual(ProjectionHistory.distanceName(raceMeters: marathon, units: .km), "the marathon")
        XCTAssertEqual(ProjectionHistory.distanceName(raceMeters: 21_097, units: .mi), "the half",
                       "distance_m is whole metres")
        XCTAssertEqual(ProjectionHistory.distanceName(raceMeters: 1_609, units: .mi), "the mile")
        XCTAssertEqual(ProjectionHistory.distanceName(raceMeters: 30_000, units: .km), "30.0 km")
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
