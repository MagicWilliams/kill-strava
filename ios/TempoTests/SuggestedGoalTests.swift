import XCTest
@testable import Tempo

/// The goal time Tempo suggests for a "PR" or "Not sure" goal (#239, from #207's rule 3).
///
/// Until 2026-10-29 that number was whatever the coach proposed "from the data", and it went
/// straight into `create_plan.goal_time_s`: the pace basis for every training pace in the
/// block. These pin the code that replaced the guess. A wrong number here would not crash;
/// it would be a target the athlete trains toward for months, quoted to them as the data's.
final class SuggestedGoalTests: XCTestCase {

    private let marathon = 42_195.0
    private let fiveK = 5_000.0

    /// 3:30:00, a marathon projection.
    private let projection = 12_600.0

    private let cal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    private func run(_ iso: String, miles: Double, paceSec: Int) -> RunSummary {
        RunSummary(
            id: UUID(),
            start: date(iso),
            distanceM: Int(miles * 1609.34),
            durationS: Int(miles * Double(paceSec)),
            avgHR: nil
        )
    }

    private func suggest(weeks: Int, projectionS: Double? = 12_600, meters: Double = 42_195)
        -> (target: Int, range: ClosedRange<Int>)? {
        SuggestedGoal.suggestedGoalTime(projectionS: projectionS, weeksToRace: weeks, distanceM: meters)
    }

    // MARK: - No projection, no target

    /// The case the intake used to fill with a made-up number: nothing run far enough in six
    /// weeks to project from (David's first intake after Chicago). Nil, so the coach proposes
    /// no time and the plan engine paces from current fitness.
    func testNoProjectionSuggestsNothing() {
        XCTAssertNil(suggest(weeks: 12, projectionS: nil))
    }

    func testANonsenseProjectionOrDistanceSuggestsNothing() {
        XCTAssertNil(suggest(weeks: 12, projectionS: 0))
        XCTAssertNil(suggest(weeks: 12, projectionS: -1))
        XCTAssertNil(suggest(weeks: 12, projectionS: .infinity))
        XCTAssertNil(suggest(weeks: 12, meters: 0))
    }

    // MARK: - Block length

    /// A longer block earns a bigger improvement: 6, 12 and 20 weeks are three different,
    /// strictly faster targets, and every one is faster than the projection itself.
    func testLongerBlocksSuggestStrictlyFasterTargets() throws {
        let six = try XCTUnwrap(suggest(weeks: 6)).target
        let twelve = try XCTUnwrap(suggest(weeks: 12)).target
        let twenty = try XCTUnwrap(suggest(weeks: 20)).target
        XCTAssertLessThan(six, Int(projection))
        XCTAssertLessThan(twelve, six)
        XCTAssertLessThan(twenty, twelve)
    }

    /// Pinned at the placeholder rate, so a change to it is a deliberate diff in this file and
    /// not a silent shift in every PR target: 12 weeks × 0.25% = 3.0% off 3:30:00 is 3:23:42.
    func testTwelveWeeksOffAThreeThirtyProjectionIsThreeTwentyThreeFortyTwo() throws {
        XCTAssertEqual(SuggestedGoal.improvementPerWeek, 0.0025)
        XCTAssertEqual(try XCTUnwrap(suggest(weeks: 12)).target, 12_222)
    }

    /// The rate is a fraction, so it scales to the race: the same 12 weeks takes ~36 s off a
    /// 20:00 5K, not the six-odd minutes it takes off a marathon.
    func testTheImprovementScalesWithTheRace() throws {
        XCTAssertEqual(try XCTUnwrap(suggest(weeks: 12, projectionS: 1_200, meters: fiveK)).target, 1_164)
    }

    /// Past `maxImprovementWeeks` the line stops: a 40-week runway is not credited as 10%.
    func testImprovementIsCappedForVeryLongRunways() {
        let cap = SuggestedGoal.maxImprovementWeeks
        XCTAssertGreaterThanOrEqual(cap, 20, "the cap must leave 20 weeks on the slope")
        XCTAssertEqual(suggest(weeks: 40)?.target, suggest(weeks: cap)?.target)
    }

    /// A race this week (or a nonsense negative count) earns nothing: the target is today's
    /// projection, never slower.
    func testNoWeeksLeftMeansNoImprovement() {
        XCTAssertEqual(suggest(weeks: 0)?.target, Int(projection))
        XCTAssertEqual(suggest(weeks: -3)?.target, Int(projection))
    }

    // MARK: - The range

    /// The range is what lets the coach say "call it 3:25" without inventing a number, so it
    /// must actually contain the target, on both sides, at every block length.
    func testTheRangeBracketsTheTarget() throws {
        for weeks in [0, 6, 12, 20, 30] {
            let s = try XCTUnwrap(suggest(weeks: weeks))
            XCTAssertTrue(s.range.contains(s.target), "\(weeks) weeks")
            XCTAssertLessThan(s.range.lowerBound, s.target, "\(weeks) weeks: room to be more ambitious")
            XCTAssertGreaterThan(s.range.upperBound, s.target, "\(weeks) weeks: room to be more cautious")
        }
    }

    /// ±2% of the target. On 3:23:42 that is 3:19:38 to 3:27:46 — wide enough for a round
    /// number either way, narrow enough that nothing in it is a different goal.
    func testTheRangeIsTwoPercentEitherSide() throws {
        let s = try XCTUnwrap(suggest(weeks: 12))
        XCTAssertEqual(s.range, 11_978...12_466)
    }

    // MARK: - Which race

    private func goal(_ raceDate: String?, distanceM: Int? = 42_195) -> GoalInfo {
        var g = GoalInfo(id: UUID(), race_name: "Chicago", race_date: raceDate, goal_time_seconds: 11_700, distance: "marathon")
        g.distance_m = distanceM
        return g
    }

    func testTheActiveGoalsRaceIsUsedWhenThereIsNoIntake() throws {
        let race = try XCTUnwrap(SuggestedGoal.race(intake: nil, goal: goal("2026-10-11"), now: date("2026-07-19"), calendar: cal))
        XCTAssertEqual(race.meters, marathon)
        XCTAssertEqual(race.raceDate, "2026-10-11")
        XCTAssertEqual(race.weeks, 12)
    }

    /// The intake is the race the next `create_plan` is for. A 5K intake while a marathon goal
    /// is still active must be suggested a 5K time, or the coach is handed a marathon number
    /// to hold a 5K to (#185 again, by another road).
    func testAnIntakesRaceOutranksTheActiveGoal() throws {
        var answers = IntakeAnswers()
        answers.distance = .fiveK
        answers.raceName = "Turkey Trot"
        answers.raceDate = date("2026-11-26")
        answers.course = .flat
        answers.goalType = .pr
        answers.planStyle = .full
        answers.daysPerWeek = 5
        answers.longRunDay = 0
        let stamp = try XCTUnwrap(answers.stamp(today: date("2026-10-29"), calendar: cal))

        let race = try XCTUnwrap(SuggestedGoal.race(intake: stamp, goal: goal("2026-10-11"), now: date("2026-10-29"), calendar: cal))
        XCTAssertEqual(race.meters, fiveK)
        XCTAssertEqual(race.raceDate, "2026-11-26")
        XCTAssertEqual(race.weeks, 4)
    }

    /// A race that is already run, or a goal with no date, has no block left to improve over.
    func testNoRaceAheadMeansNoRace() {
        XCTAssertNil(SuggestedGoal.race(intake: nil, goal: goal("2026-10-11"), now: date("2026-10-12"), calendar: cal))
        XCTAssertNil(SuggestedGoal.race(intake: nil, goal: goal("2026-10-11"), now: date("2026-10-11"), calendar: cal))
        XCTAssertNil(SuggestedGoal.race(intake: nil, goal: goal(nil), now: date("2026-07-19"), calendar: cal))
        XCTAssertNil(SuggestedGoal.race(intake: nil, goal: nil, now: date("2026-07-19"), calendar: cal))
    }

    // MARK: - The coach's copy

    /// What the coach is sent is the same number the engine computed, for the race it names,
    /// from the same projection the Progress card shows.
    func testTheCoachContextCarriesTheEngineNumbersForItsRace() throws {
        let now = date("2026-07-19")
        let runs = [run("2026-07-12", miles: 10, paceSec: 480)]
        let race = (meters: marathon, raceDate: "2026-10-11", weeks: 12)
        let projected = try XCTUnwrap(ProjectionHistory.projection(runs, asOf: now, raceMeters: marathon, calendar: cal))
        let expected = try XCTUnwrap(suggest(weeks: 12, projectionS: Double(projected.finishS)))

        let ctx = try XCTUnwrap(SuggestedGoal.coachContext(runs: runs, race: race, asOf: now, calendar: cal))
        XCTAssertEqual(ctx.target_s, expected.target)
        XCTAssertEqual(ctx.range_s, [expected.range.lowerBound, expected.range.upperBound])
        XCTAssertEqual(ctx.distance_m, 42_195)
        XCTAssertEqual(ctx.race_date, "2026-10-11")
        XCTAssertTrue(ctx.basis.contains(IntakeAnswers.finishTime(projected.finishS)), ctx.basis)
        XCTAssertTrue(ctx.basis.contains("12 weeks"), ctx.basis)
    }

    /// No qualifying run in the window: the key is absent, not a zero, so the coach reads it as
    /// "no target", which is what the prompt tells it to do.
    func testNoQualifyingRunMeansNoSuggestedGoal() {
        let now = date("2026-07-19")
        let stale = [run("2026-05-01", miles: 10, paceSec: 480)]
        let race = (meters: marathon, raceDate: "2026-10-11", weeks: 12)
        XCTAssertNil(SuggestedGoal.coachContext(runs: stale, race: race, asOf: now, calendar: cal))
        XCTAssertNil(SuggestedGoal.coachContext(runs: stale, race: nil, asOf: now, calendar: cal))
    }

    /// The wire shape the coach function's guard reads: snake_case keys, the range as a
    /// two-element [fastest, slowest] array. A rename here silently disables the guard.
    func testTheWireShapeIsWhatTheGuardReads() throws {
        let ctx = SuggestedGoalCoachContext(target_s: 12_222, range_s: [11_978, 12_466], distance_m: 42_195,
                                            race_date: "2026-10-11", basis: "b")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ctx)) as? [String: Any])
        XCTAssertEqual(json["target_s"] as? Int, 12_222)
        XCTAssertEqual(json["range_s"] as? [Int], [11_978, 12_466])
        XCTAssertEqual(json["distance_m"] as? Int, 42_195)
        XCTAssertEqual(json["race_date"] as? String, "2026-10-11")
    }
}
