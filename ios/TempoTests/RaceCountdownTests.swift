import XCTest
@testable import Tempo

/// The Progress header spent the whole beta counting down to a `static let` — 2026-10-11,
/// shipped with the comment "fixed race target until Goal Setup is wired" (#36). Goal Setup
/// got wired, the constant stayed, and the two agreed by coincidence. Nothing on screen
/// would have looked wrong the day they stopped agreeing: the header would simply have
/// counted down, in the same confident voice, to a race the athlete was no longer running.
///
/// These pin the replacement. Every case here is one the old code could not express —
/// no goal, no date, race day itself, a race already run — and each one used to render as
/// a plausible number of weeks to Chicago.
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

    private func date(_ iso: String, hour: Int = 0) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd"
        return cal.date(byAdding: .hour, value: hour, to: f.date(from: iso)!)!
    }

    private func state(_ name: String?, _ raceDay: Date?, now: Date? = nil) -> RaceCountdown.State {
        RaceCountdown.state(raceName: name, raceDay: raceDay, now: now ?? self.now, calendar: cal)
    }

    // MARK: - A race in the future

    /// Chicago 2026 from the fixed "now": 45 days out, so 7 weeks rounded up.
    func testCountsWholeWeeksToARaceAhead() {
        XCTAssertEqual(state("Chicago", date("2026-10-11")), .ahead(race: "Chicago", weeks: 7))
        XCTAssertEqual(state("Chicago", date("2026-10-11")).subtitle, "7 weeks to Chicago")
    }

    /// The name comes off the goal now. This is the whole point of #36: a different race
    /// must stop saying Chicago.
    func testRaceNameComesFromTheGoal() {
        XCTAssertEqual(
            state("Berlin", date("2026-09-27")).subtitle, "5 weeks to Berlin",
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

    func testOneWeekIsSingular() {
        XCTAssertEqual(state("Chicago", date("2026-09-02")).subtitle, "1 week to Chicago")
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
        XCTAssertEqual(state("Chicago", date("2026-08-27")).subtitle, "Race day — Chicago")
    }

    /// Race day starts at midnight and lasts all day; a 6am launch is still race day.
    func testRaceDayHoldsAllDay() {
        XCTAssertEqual(state("Chicago", date("2026-08-27"), now: date("2026-08-27", hour: 6)), .raceDay(race: "Chicago"))
        XCTAssertEqual(state("Chicago", date("2026-08-27"), now: date("2026-08-27", hour: 23)), .raceDay(race: "Chicago"))
    }

    // MARK: - A race already run

    /// Product call: past race day, Progress stops counting entirely. A countdown that has
    /// run out is the same defect as the hardcoded date — a number that reads as current
    /// and isn't — and "0 weeks to Chicago" says the race is *this week*. The header states
    /// the fact and points at the only move left: pick the next race.
    func testARaceAlreadyRunStopsCountingAndAsksForTheNextGoal() {
        XCTAssertEqual(state("Chicago", date("2026-08-26")), .past(race: "Chicago"))
        XCTAssertEqual(
            state("Chicago", date("2025-10-12")).subtitle,
            "Chicago is behind you — set the next goal with the coach"
        )
    }

    /// Yesterday and last year read the same. Nothing here degrades into a week count that
    /// could be mistaken for a countdown.
    func testPastNeverProducesAWeekCount() {
        for iso in ["2026-08-26", "2026-08-01", "2024-04-15"] {
            guard case .past = state("Chicago", date(iso)) else {
                return XCTFail("\(iso) is behind 2026-08-27")
            }
            XCTAssertFalse(state("Chicago", date(iso)).subtitle.contains("week"), "\(iso) counts nothing")
        }
    }

    // MARK: - No goal

    /// Progress renders before a plan exists. It says so, rather than inventing a race:
    /// the deleted constant was exactly that invention, and it looked authoritative.
    func testNoGoalSaysSoRatherThanGuessingARace() {
        XCTAssertEqual(state(nil, nil), .noGoal)
        XCTAssertEqual(state(nil, nil).subtitle, "No goal yet — the coach proposes one from your runs")
        XCTAssertFalse(state(nil, nil).subtitle.contains("Chicago"), "no fallback race survived the deletion")
    }

    /// A goal row can carry a name with a null `race_date`. There is nothing to count,
    /// so it counts nothing.
    func testGoalWithoutARaceDateCountsNothing() {
        XCTAssertEqual(state("Chicago", nil), .undated(race: "Chicago"))
        XCTAssertEqual(state("Chicago", nil).subtitle, "Chicago — no race date yet")
    }

    /// `race_name` is nullable too. A dated goal with no name still counts down; it just
    /// borrows the same "Race" placeholder PlanView and YouView use.
    func testUnnamedGoalStillCountsDown() {
        XCTAssertEqual(state(nil, date("2026-10-11")), .ahead(race: "Race", weeks: 7))
        XCTAssertEqual(state("", date("2026-10-11")).subtitle, "7 weeks to Race", "an empty name is no name")
    }
}
