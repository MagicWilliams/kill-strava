import XCTest
@testable import Tempo

/// The Progress header spent the whole beta counting down to a `static let` — 2026-10-11,
/// shipped with the comment "fixed race target until Goal Setup is wired" (#36). Goal Setup
/// got wired, the constant stayed, and the two agreed by coincidence. Nothing on screen
/// would have looked wrong the day they stopped agreeing: the header would simply have
/// counted down, in the same confident voice, to a race the athlete was no longer running.
///
/// These pin the replacement. Every case in the first half is one the old code could not
/// express — no goal, no date, race day itself, a race already run — and each one used to
/// render as a plausible number of weeks to Chicago.
///
/// The second half is #230: on 15 Oct 2026 at 12:52, with the race on 27 Nov, Plan said
/// **42 days**, You said **6 weeks** and Progress said **7 weeks**. One date, three answers,
/// because Plan and You each counted from `.now` and You then floored the result into weeks.
/// The right answer is 43 days and 7 weeks, and it is one measurement now: the week count
/// is divided out of the day count rather than taken again.
final class RaceCountdownTests: XCTestCase {

    /// Fixed calendar + fixed "now" so nothing here depends on when the suite runs.
    private let cal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// A Thursday, mid-afternoon: the time of day matters, because the count is over
    /// calendar days and must not shift with it.
    private var now: Date { date("2026-08-27", hour: 15) }

    private func date(_ iso: String, hour: Int = 0, minute: Int = 0) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd"
        let midnight = f.date(from: iso)!
        return cal.date(byAdding: .minute, value: hour * 60 + minute, to: midnight)!
    }

    private func state(_ name: String?, _ raceDay: Date?, now: Date? = nil) -> RaceCountdown.State {
        RaceCountdown.state(raceName: name, raceDay: raceDay, now: now ?? self.now, calendar: cal)
    }

    // MARK: - A race in the future

    /// Chicago 2026 from the fixed "now": 45 days out, so 7 weeks rounded up.
    func testCountsWholeWeeksToARaceAhead() {
        XCTAssertEqual(state("Chicago", date("2026-10-11")), .ahead(race: "Chicago", days: 45, weeks: 7))
        XCTAssertEqual(state("Chicago", date("2026-10-11")).subtitle(), "Chicago · 45 days · 7 weeks")
    }

    /// The name comes off the goal now. This is the whole point of #36: a different race
    /// must stop saying Chicago.
    func testRaceNameComesFromTheGoal() {
        XCTAssertEqual(
            state("Berlin", date("2026-09-27")).subtitle(), "Berlin · 31 days · 5 weeks",
            "the goal names the race, not the header"
        )
    }

    /// Rounded up, so the final week never reads as zero and the day before the race is
    /// still a week away rather than "0 weeks to Chicago".
    func testPartialWeeksRoundUp() {
        XCTAssertEqual(RaceCountdown.weeksRemaining(from: now, to: date("2026-09-03"), calendar: cal), 1, "exactly 7 days")
        XCTAssertEqual(RaceCountdown.weeksRemaining(from: now, to: date("2026-09-04"), calendar: cal), 2, "8 days")
        XCTAssertEqual(RaceCountdown.weeksRemaining(from: now, to: date("2026-08-28"), calendar: cal), 1, "tomorrow")
    }

    /// Counted start-of-day to start-of-day: the number ticks over at midnight, not at
    /// whatever hour the app was opened. Same race, three launch times, one answer.
    func testTimeOfDayDoesNotMoveTheCount() {
        let race = date("2026-10-11")
        for hour in [0, 9, 23] {
            XCTAssertEqual(
                RaceCountdown.weeksRemaining(from: date("2026-08-27", hour: hour), to: race, calendar: cal), 7,
                "opened at \(hour):00"
            )
        }
    }

    // MARK: - Race day

    /// Not "0 weeks to Chicago", and not "1 week" either — it's today.
    func testRaceDayIsItsOwnState() {
        XCTAssertEqual(state("Chicago", date("2026-08-27")), .raceDay(race: "Chicago"))
        XCTAssertEqual(state("Chicago", date("2026-08-27")).subtitle(), "Race day — Chicago")
    }

    /// Race day starts at midnight and lasts all day; a 6am launch is still race day.
    func testRaceDayHoldsAllDay() {
        XCTAssertEqual(state("Chicago", date("2026-08-27"), now: date("2026-08-27", hour: 6)), .raceDay(race: "Chicago"))
        XCTAssertEqual(state("Chicago", date("2026-08-27"), now: date("2026-08-27", hour: 23)), .raceDay(race: "Chicago"))
    }

    // MARK: - A race already run

    /// Product call: past race day, the header stops counting entirely. A countdown that has
    /// run out is the same defect as the hardcoded date — a number that reads as current
    /// and isn't — and "0 weeks to Chicago" says the race is *this week*. The header states
    /// the fact and points at the only move left: pick the next race.
    func testARaceAlreadyRunStopsCountingAndAsksForTheNextGoal() {
        XCTAssertEqual(state("Chicago", date("2026-08-26")), .past(race: "Chicago"))
        XCTAssertEqual(
            state("Chicago", date("2025-10-12")).subtitle(),
            "Chicago is behind you — set the next goal with the coach"
        )
    }

    /// Yesterday and last year read the same. Nothing here degrades into a count that
    /// could be mistaken for a countdown.
    func testPastNeverProducesACount() {
        for iso in ["2026-08-26", "2026-08-01", "2024-04-15"] {
            guard case .past = state("Chicago", date(iso)) else {
                return XCTFail("\(iso) is behind 2026-08-27")
            }
            let past = state("Chicago", date(iso))
            XCTAssertFalse(past.subtitle().contains("week"), "\(iso) counts nothing")
            XCTAssertNil(past.days, "\(iso) has no days left")
            XCTAssertNil(past.countdown(), "\(iso) has nothing to count")
            XCTAssertNil(past.hero, "and no hero number to print")
        }
    }

    // MARK: - No goal

    /// Progress renders before a plan exists. It says so, rather than inventing a race:
    /// the deleted constant was exactly that invention, and it looked authoritative.
    ///
    /// And it says so neutrally (#101). "No goal yet — the coach proposes one" read as a
    /// to-do list; between blocks, not training for anything is a choice, not a gap.
    func testNoGoalSaysSoRatherThanGuessingARace() {
        XCTAssertEqual(state(nil, nil), .noGoal)
        XCTAssertEqual(state(nil, nil).subtitle(), "No race on the calendar — just running")
        XCTAssertFalse(state(nil, nil).subtitle().contains("Chicago"), "no fallback race survived the deletion")
        XCTAssertFalse(state(nil, nil).subtitle().contains("propose"), "no nudge toward a goal")
        XCTAssertNil(state(nil, nil).race, "nothing to name")
    }

    /// A goal row can carry a name with a null `race_date`. There is nothing to count,
    /// so it counts nothing.
    func testGoalWithoutARaceDateCountsNothing() {
        XCTAssertEqual(state("Chicago", nil), .undated(race: "Chicago"))
        XCTAssertEqual(state("Chicago", nil).subtitle(), "Chicago — no race date yet")
        XCTAssertNil(state("Chicago", nil).hero)
    }

    /// `race_name` is nullable too. A dated goal with no name still counts down; the
    /// primitive borrows the "Race" placeholder the block review and the recap still use.
    /// The three countdown headers never reach this path — they name the race first, and
    /// `raceLabel` always has a distance to fall back on.
    func testUnnamedGoalStillCountsDown() {
        XCTAssertEqual(state(nil, date("2026-10-11")), .ahead(race: "Race", days: 45, weeks: 7))
        XCTAssertEqual(state("", date("2026-10-11")).subtitle(), "Race · 45 days · 7 weeks", "an empty name is no name")
    }

    // MARK: - One rule for three tabs (#230)

    /// The incident, pinned. 15 Oct 2026 12:52 → 27 Nov 2026 is 43 days and 7 weeks, and
    /// that is what every tab now says. Plan said 42, You said 6 weeks.
    func testTheFifteenthOfOctoberReadsFortyThreeDaysAndSevenWeeks() {
        let header = state("Turkey Trot · 5K", date("2026-11-27"), now: date("2026-10-15", hour: 12, minute: 52))
        XCTAssertEqual(header, .ahead(race: "Turkey Trot · 5K", days: 43, weeks: 7))
        XCTAssertEqual(header.subtitle(), "Turkey Trot · 5K · 43 days · 7 weeks")
        XCTAssertEqual(header.subtitle(.compact), "Turkey Trot · 5K · 43 days")
        XCTAssertEqual(header.countdown(), "43 days · 7 weeks")
        XCTAssertEqual(header.countdown(.compact), "43 days")
        XCTAssertEqual(header.hero?.number, "43")
        XCTAssertEqual(header.hero?.caption, "days to go · 7 weeks")
    }

    /// The bug Plan had: `dateComponents` from the current *instant* is 42 days at 12:52 and
    /// 43 at 00:01, so the count shrank every afternoon and grew back overnight. Measured
    /// start-of-day to start-of-day it is the same number all day.
    func testTheDayCountIsIdenticalAtOneMinutePastMidnightAndAtTwoToMidnight() {
        let race = date("2026-11-27")
        let readings = [
            state("Turkey Trot", race, now: date("2026-10-15", hour: 0, minute: 1)),
            state("Turkey Trot", race, now: date("2026-10-15", hour: 12, minute: 52)),
            state("Turkey Trot", race, now: date("2026-10-15", hour: 23, minute: 59)),
        ]
        for header in readings {
            XCTAssertEqual(header.days, 43, "one calendar day, one answer")
        }
        XCTAssertEqual(Set(readings.map { $0.subtitle() }).count, 1, "and one line of copy")
    }

    /// The week count is derived from the day count, not measured again. That is the only
    /// reason the two can't drift apart the way the three tabs did — so it is checked over a
    /// run of days rather than at one point.
    func testWeeksAreAlwaysTheDayCountDividedAndRoundedUp() {
        for day in 1...70 {
            let race = cal.date(byAdding: .day, value: day, to: date("2026-08-27"))!
            let header = state("Chicago", race)
            XCTAssertEqual(header.days, day, "day \(day)")
            XCTAssertEqual(
                RaceCountdown.weeksRemaining(from: now, to: race, calendar: cal),
                Int((Double(day) / 7.0).rounded(.up)),
                "day \(day)"
            )
        }
    }

    /// Inside the final week a week count adds nothing a day count hasn't said, so both
    /// widths drop it. Seven days out is the first day it is worth printing.
    func testTheFinalWeekIsCountedInDaysOnly() {
        func countdown(_ days: Int, _ width: RaceCountdown.Width = .full) -> String? {
            state("Chicago", cal.date(byAdding: .day, value: days, to: date("2026-08-27"))!).countdown(width)
        }
        XCTAssertEqual(countdown(7), "7 days · 1 week", "the first day the week count earns its place")
        XCTAssertEqual(countdown(6), "6 days")
        XCTAssertEqual(countdown(6, .compact), "6 days", "already as short as it goes")
        XCTAssertEqual(countdown(1), "1 day", "singular")
        XCTAssertEqual(countdown(1, .compact), "1 day")
        XCTAssertNil(state("Chicago", cal.date(byAdding: .day, value: 6, to: date("2026-08-27"))!).weeks,
                     "no week count inside the last week")
    }

    /// Plan's hero loses the week count on the same line, and its unit goes singular with
    /// the number: "1 day to go", not "1 days to go".
    func testHeroCaptionFollowsTheSameWeekRule() {
        func hero(_ days: Int) -> (number: String, caption: String)? {
            state("Chicago", cal.date(byAdding: .day, value: days, to: date("2026-08-27"))!).hero
        }
        XCTAssertEqual(hero(7)?.caption, "days to go · 1 week")
        XCTAssertEqual(hero(6)?.caption, "days to go")
        XCTAssertEqual(hero(1)?.number, "1")
        XCTAssertEqual(hero(1)?.caption, "day to go")
    }

    // MARK: - The race label (#230 item 3)

    private func goal(
        name: String?,
        distance: String? = nil,
        meters: Int? = nil,
        role: String? = nil
    ) -> GoalInfo {
        var g = GoalInfo(id: UUID(), race_name: name, race_date: "2026-11-27", goal_time_seconds: nil, distance: distance)
        g.distance_m = meters
        if let role {
            var p = GoalPreferences()
            p.race_role = role
            g.preferences = p
        }
        return g
    }

    private func label(_ goal: GoalInfo?, units: Units = .mi, includingRole: Bool = false) -> String? {
        RaceCountdown.raceLabel(goal: goal, units: units, includingRole: includingRole)
    }

    /// The header's whole job in #215: say what distance the plan is built for. A 27 Nov
    /// marathon with no name sat on three screens for two weeks reading "Race", a word that
    /// is equally true of the 5K David thought he had entered.
    func testTheDistanceIsNamedEvenWhenTheRaceIsNot() {
        XCTAssertEqual(label(goal(name: "Turkey Trot", meters: 5_000)), "Turkey Trot · 5K")
        XCTAssertEqual(label(goal(name: nil, meters: 42_195)), "Marathon race", "not a bare \"Race\"")
        XCTAssertEqual(label(goal(name: "   ", meters: 5_000)), "5K race", "whitespace is no name")
        XCTAssertNil(label(nil), "no goal, nothing to name")
    }

    /// Read off the same metres the projection uses (`RaceRecap.raceMeters`), so the header
    /// cannot name one race while the number answers for another (#184). `distance_m` first,
    /// the label only for a goal written before 0014.
    func testTheDistanceComesFromTheMetresTheProjectionUses() {
        XCTAssertEqual(label(goal(name: "Race", distance: "custom", meters: 5_000)), "Race · 5K",
                       "metres outrank a label saying custom")
        XCTAssertEqual(label(goal(name: "Berlin", distance: "half")), "Berlin · Half", "pre-0014: the label")
        XCTAssertEqual(label(goal(name: "Berlin", meters: 21_097)), "Berlin · Half",
                       "21,097 and 21,098 are both the half")
        XCTAssertEqual(label(goal(name: "Boston", distance: nil)), "Boston · Marathon",
                       "a goal with no distance at all reads as the marathon, as the projection does")
    }

    /// A custom distance has no name to borrow, so it is spelled out — and in the athlete's
    /// own unit, since nothing else on their screen is in the other one (#109).
    func testACustomDistanceIsSpelledOutInTheAthletesUnit() {
        XCTAssertEqual(label(goal(name: "Comrades", meters: 30_000), units: .km), "Comrades · 30.0 km")
        XCTAssertEqual(label(goal(name: "Comrades", meters: 30_000), units: .mi), "Comrades · 18.6 mi")
    }

    /// "Chicago Marathon · Marathon" is what naming the distance unconditionally produces.
    /// Case doesn't matter: the athlete types the name.
    func testTheDistanceIsLeftOffANameThatAlreadyCarriesIt() {
        XCTAssertEqual(label(goal(name: "Chicago Marathon", meters: 42_195)), "Chicago Marathon")
        XCTAssertEqual(label(goal(name: "chicago marathon", meters: 42_195)), "chicago marathon")
        XCTAssertEqual(label(goal(name: "Brooklyn Half", meters: 21_098)), "Brooklyn Half")
        XCTAssertEqual(label(goal(name: "Turkey Trot 5K", meters: 5_000)), "Turkey Trot 5K")
    }

    /// The role (#238) is You's line and nobody else's, so it is asked for rather than
    /// assumed. An ordinary goal race has no role word — "goal" on a goal would be noise.
    func testTheRoleRidesOnTheLabelOnlyWhenAskedFor() {
        let tuneUp = goal(name: "Turkey Trot", meters: 5_000, role: "tune_up")
        XCTAssertEqual(label(tuneUp), "Turkey Trot · 5K", "Plan and Progress ask without it")
        XCTAssertEqual(label(tuneUp, includingRole: true), "Turkey Trot · 5K · tune-up")
        XCTAssertEqual(label(goal(name: "Chicago", meters: 42_195), includingRole: true), "Chicago · Marathon",
                       "an ordinary goal race says nothing")
    }

    /// The whole header, built from a goal row the way the three tabs build it. `raceDay`
    /// parses `race_date` in the device's zone, so this counts in that zone too.
    func testAGoalRowBecomesTheWholeHeader() {
        var local = Calendar(identifier: .iso8601)
        local.timeZone = .current
        let today = local.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12, minute: 52))!
        let header = RaceCountdown.state(
            goal: goal(name: "Turkey Trot", meters: 5_000, role: "tune_up"),
            now: today, units: .mi, includingRole: true, calendar: local
        )
        XCTAssertEqual(header.subtitle(), "Turkey Trot · 5K · tune-up · 43 days · 7 weeks")
        XCTAssertEqual(header.subtitle(.compact), "Turkey Trot · 5K · tune-up · 43 days")
        XCTAssertEqual(
            RaceCountdown.state(goal: nil, now: today, units: .mi, calendar: local), .noGoal,
            "no goal row is still no goal"
        )
    }
}
