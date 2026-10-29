import XCTest
@testable import Tempo

/// The expected trajectory for the Drift Detector (PRD-02 item #3, #235, approved by David
/// 2026-10-29). Before this, the only "this week" number Tempo had was planned mileage, so
/// the only thing drift could have been measured against was the goal itself — and against
/// the goal every runner is "off track" in week 2 of a 16-week block (PRD §6.1).
///
/// The failures this pins are all the quiet kind: a curve that hits the goal on race day
/// instead of at taper start makes every correctly tapering runner look behind; a curve
/// that keeps moving in the taper makes the last three weeks read as drift; a curve computed
/// in hours instead of calendar days is off by one on the DST weekend before a November
/// race. None of these would crash. Each would put a confident wrong status on screen.
final class TrajectoryCurveTests: XCTestCase {

    private let marathon = 42_195.0
    private let half = 21_097.0
    private let fiveK = 5_000.0

    /// 3:30:00 at signup, 3:15:00 goal: a sub-3:15 marathon block.
    private let fitness = 12_600.0
    private let goal = 11_700.0

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ iso: String, hour: Int = 0, minute: Int = 0, in cal: Calendar) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        let midnight = f.date(from: iso)!
        return cal.date(byAdding: DateComponents(hour: hour, minute: minute), to: midnight)!
    }

    private func addDays(_ n: Int, to d: Date, in cal: Calendar) -> Date {
        cal.date(byAdding: .day, value: n, to: d)!
    }

    /// Race day is Chicago 2026 (Sunday 2026-10-11); signup is a Sunday `weeks` before it.
    private func curve(
        weeks: Int,
        fitness: Double? = 12_600,
        goal: Double = 11_700,
        meters: Double = 42_195,
        cal: Calendar? = nil
    ) -> TrajectoryCurve {
        let cal = cal ?? calendar()
        let race = date("2026-10-11", in: cal)
        return TrajectoryCurve(
            signupFitness: fitness,
            goalTime: goal,
            signupDate: addDays(-weeks * 7, to: race, in: cal),
            raceDate: race,
            raceMeters: meters,
            calendar: cal
        )
    }

    // MARK: - Shape

    /// The acceptance list from PRD item #3: 8-, 12-, 16- and 20-week blocks all start at
    /// signup fitness and reach the goal on the first day of the taper, not on race day.
    func testBlocksStartAtSignupFitnessAndReachGoalAtTaperStart() {
        let cal = calendar()
        // Marathon taper: 1 week + race week under 10 block weeks, 2 + race week from 10 on.
        for (weeks, taperDays) in [(8, 14), (12, 21), (16, 21), (20, 21)] {
            let c = curve(weeks: weeks)
            XCTAssertEqual(c.eligibility, .eligible, "\(weeks) weeks")
            XCTAssertEqual(c.taperDays, taperDays, "\(weeks) weeks")
            XCTAssertEqual(c.taperStart, addDays(-(taperDays - 1), to: c.raceDate, in: cal), "\(weeks) weeks")
            XCTAssertEqual(c.expectedTime(on: c.signupDate), fitness, "\(weeks) weeks: starts at signup fitness")
            XCTAssertEqual(c.expectedTime(on: c.taperStart), goal, "\(weeks) weeks: goal at taper start")
            let dayBefore = c.expectedTime(on: addDays(-1, to: c.taperStart, in: cal))!
            XCTAssertGreaterThan(dayBefore, goal, "\(weeks) weeks: still ramping the day before the taper")
            XCTAssertLessThan(dayBefore, fitness, "\(weeks) weeks")
        }
    }

    /// For a Sunday race the taper's first day is the Monday the generator starts its taper
    /// phase: three weeks out for a 16-week marathon.
    func testTaperStartsOnTheGeneratorsMonday() {
        let c = curve(weeks: 16)
        XCTAssertEqual(c.taperStart, date("2026-09-21", in: calendar()))
        XCTAssertEqual(calendar().component(.weekday, from: c.taperStart), 2, "Monday")
    }

    /// The taper banks fitness; the expectation must not keep moving, or a runner tapering
    /// exactly as planned reads as drifting every day of it.
    func testFlatThroughTheTaper() {
        let cal = calendar()
        let c = curve(weeks: 16)
        for offset in 0..<c.taperDays {
            let day = addDays(offset, to: c.taperStart, in: cal)
            XCTAssertEqual(c.expectedTime(on: day), goal, "taper day \(offset)")
        }
        XCTAssertEqual(c.expectedTime(on: c.raceDate), goal)
    }

    /// A straight line in time: halfway along the ramp, halfway between fitness and goal.
    /// 16 weeks = 112 days, taper is the last 21 counting race day, so the ramp is 92 days.
    func testStraightLineInTime() {
        let cal = calendar()
        let c = curve(weeks: 16)
        XCTAssertEqual(c.expectedTime(on: addDays(46, to: c.signupDate, in: cal))!, 12_150, accuracy: 1e-9)
        XCTAssertEqual(c.expectedTime(on: addDays(23, to: c.signupDate, in: cal))!, 12_375, accuracy: 1e-9)
        // Week 2 of a 16-week block expects barely any gain — the case PRD §6.2 is about.
        XCTAssertEqual(c.expectedTime(on: addDays(7, to: c.signupDate, in: cal))!, 12_600 - 900 * 7 / 92, accuracy: 1e-9)
    }

    /// Ambitious and conservative goals differ only in slope: same start, same day the goal
    /// is reached.
    func testAmbitiousAndConservativeGoals() {
        let cal = calendar()
        let ambitious = curve(weeks: 16, goal: 10_800)    // 3:30 → 3:00
        let conservative = curve(weeks: 16, goal: 12_300) // 3:30 → 3:25
        let mid = addDays(46, to: ambitious.signupDate, in: cal)
        XCTAssertEqual(ambitious.expectedTime(on: mid)!, 11_700, accuracy: 1e-9)
        XCTAssertEqual(conservative.expectedTime(on: mid)!, 12_450, accuracy: 1e-9)
        XCTAssertEqual(ambitious.expectedTime(on: ambitious.taperStart), 10_800)
        XCTAssertEqual(conservative.expectedTime(on: conservative.taperStart), 12_300)
        XCTAssertEqual(ambitious.expectedTime(on: ambitious.signupDate), fitness)
        XCTAssertEqual(conservative.expectedTime(on: conservative.signupDate), fitness)
    }

    /// A goal slower than current fitness (a comeback race, a pacing job) is still a curve;
    /// it just slopes the other way. Refusing it would leave that runner with no status at all.
    func testGoalSlowerThanFitnessSlopesUpward() {
        let cal = calendar()
        let c = curve(weeks: 16, fitness: 11_400, goal: 12_000) // 3:10 → 3:20
        XCTAssertEqual(c.eligibility, .eligible)
        XCTAssertEqual(c.expectedTime(on: c.signupDate), 11_400)
        XCTAssertEqual(c.expectedTime(on: addDays(46, to: c.signupDate, in: cal))!, 11_700, accuracy: 1e-9)
        XCTAssertEqual(c.expectedTime(on: c.taperStart), 12_000)
        XCTAssertEqual(c.expectedTime(on: c.raceDate), 12_000)
    }

    /// Clamped at both ends: signup fitness before the block, the goal after race day.
    func testClampedOutsideTheBlock() {
        let cal = calendar()
        let c = curve(weeks: 12)
        XCTAssertEqual(c.expectedTime(on: addDays(-30, to: c.signupDate, in: cal)), fitness)
        XCTAssertEqual(c.expectedTime(on: addDays(10, to: c.raceDate, in: cal)), goal)
    }

    // MARK: - Eligibility

    /// PRD §5: at least 8 weeks out. Counted in days, so one day short is too close.
    func testSevenWeeksSixDaysIsTooClose() {
        let cal = calendar()
        let race = date("2026-10-11", in: cal)
        let tooClose = TrajectoryCurve(
            signupFitness: fitness, goalTime: goal,
            signupDate: addDays(-55, to: race, in: cal), raceDate: race,
            raceMeters: marathon, calendar: cal
        )
        XCTAssertEqual(tooClose.eligibility, .ineligible(.tooClose))
        XCTAssertNil(tooClose.expectedTime(on: race))
        XCTAssertNil(tooClose.expectedTime(on: tooClose.signupDate))

        XCTAssertEqual(curve(weeks: 8).eligibility, .eligible, "exactly 8 weeks is in")
    }

    /// A race already behind signup is too close, not a negative-length curve.
    func testRaceBeforeSignupIsTooClose() {
        XCTAssertEqual(curve(weeks: -1).eligibility, .ineligible(.tooClose))
    }

    /// No start point, no line. A default baseline would show drift against a number the
    /// runner never had.
    func testMissingSignupFitnessIsNoBaseline() {
        let c = curve(weeks: 16, fitness: nil)
        XCTAssertEqual(c.eligibility, .ineligible(.noBaseline))
        XCTAssertNil(c.expectedTime(on: c.raceDate))
        XCTAssertEqual(curve(weeks: 16, fitness: 0).eligibility, .ineligible(.noBaseline))
        XCTAssertEqual(curve(weeks: 16, fitness: .nan).eligibility, .ineligible(.noBaseline))
    }

    /// Both wrong at once: the race date is the thing to tell them about.
    func testTooCloseWinsOverNoBaseline() {
        XCTAssertEqual(curve(weeks: 4, fitness: nil).eligibility, .ineligible(.tooClose))
    }

    /// The 8-week gate is not the intake's plan gate; changing one must not move the other.
    func testEightWeekGateIsIndependentOfThePlanGate() {
        XCTAssertEqual(TrajectoryCurve.minimumBlockDays, 56)
        XCTAssertEqual(IntakeAnswers.minPlanWeeks, 2)
    }

    // MARK: - Taper lengths (mirrored from generator.ts DISTANCES)

    /// Only the marathon shortens its taper on a short block, at the generator's 10-week line.
    func testMarathonTaperShortensBelowTenBlockWeeks() {
        XCTAssertEqual(curve(weeks: 9).taperDays, 14)
        XCTAssertEqual(curve(weeks: 10).taperDays, 21)
    }

    func testTaperLengthFollowsTheDistance() {
        XCTAssertEqual(curve(weeks: 16, meters: fiveK).taperDays, 7, "5K: race week only")
        XCTAssertEqual(curve(weeks: 16, meters: 1_609).taperDays, 7, "mile: race week only")
        XCTAssertEqual(curve(weeks: 16, meters: 10_000).taperDays, 14)
        XCTAssertEqual(curve(weeks: 16, meters: half).taperDays, 14)
        XCTAssertEqual(curve(weeks: 9, meters: half).taperDays, 14, "half does not shorten")
        // A custom 30K resolves to the nearest row by ratio, as namedDistance does: marathon.
        XCTAssertEqual(curve(weeks: 16, meters: 30_000).taperDays, 21)
    }

    /// The half's goal is reached two weeks out (13 days before race day), and the 5K's on
    /// the Monday of race week.
    func testShorterTapersReachTheGoalLater() {
        let cal = calendar()
        let h = curve(weeks: 12, meters: half)
        XCTAssertEqual(h.taperStart, addDays(-13, to: h.raceDate, in: cal))
        XCTAssertEqual(h.expectedTime(on: h.taperStart), goal)
        XCTAssertGreaterThan(h.expectedTime(on: addDays(-14, to: h.raceDate, in: cal))!, goal)
        let k = curve(weeks: 12, meters: fiveK)
        XCTAssertEqual(k.taperStart, addDays(-6, to: k.raceDate, in: cal))
        XCTAssertEqual(k.expectedTime(on: k.taperStart), goal)
    }

    // MARK: - DST and time zones

    /// US DST ends Sunday 2026-11-01. A 10-week block to a November race straddles it: the
    /// race-day value must be the goal at every hour of race day, and the ramp must count
    /// calendar days, not 24-hour chunks (one of the block's days is 25 hours long).
    func testDSTRaceDayIsTheGoal() {
        let ny = calendar("America/New_York")
        let signup = date("2026-09-06", hour: 18, in: ny) // a Sunday evening, EDT
        let c = TrajectoryCurve(
            signupFitness: fitness, goalTime: goal,
            signupDate: signup, raceDate: date("2026-11-15", hour: 7, minute: 30, in: ny),
            raceMeters: marathon, calendar: ny
        )
        XCTAssertEqual(c.eligibility, .eligible)
        XCTAssertEqual(c.blockDays, 70)
        XCTAssertEqual(c.taperDays, 21)
        XCTAssertEqual(c.taperStart, date("2026-10-26", in: ny), "the Monday, at local midnight")
        for hour in [0, 7, 12, 23] {
            XCTAssertEqual(c.expectedTime(on: date("2026-11-15", hour: hour, in: ny)), goal, "race day \(hour):00")
        }
        XCTAssertEqual(c.expectedTime(on: date("2026-11-15", hour: 23, minute: 59, in: ny)), goal)
        // Signup day is signup fitness at any hour, including before the signup time.
        XCTAssertEqual(c.expectedTime(on: date("2026-09-06", hour: 1, in: ny)), fitness)
        // Ramp = 70 − 20 = 50 days; one day per step regardless of the 25-hour day.
        XCTAssertEqual(c.expectedTime(on: date("2026-10-01", in: ny))!, fitness - 900 * 25 / 50, accuracy: 1e-9)
    }

    /// The same block evaluated in a far-east zone: race day is race day in the runner's own
    /// calendar, and it reads as the goal at both ends of that day.
    func testTimeZoneRaceDayIsTheGoal() {
        for zone in ["Pacific/Auckland", "Asia/Tokyo", "America/Los_Angeles"] {
            let cal = calendar(zone)
            let c = curve(weeks: 16, cal: cal)
            XCTAssertEqual(c.eligibility, .eligible, zone)
            XCTAssertEqual(c.expectedTime(on: date("2026-10-11", hour: 0, in: cal)), goal, zone)
            XCTAssertEqual(c.expectedTime(on: date("2026-10-11", hour: 23, minute: 59, in: cal)), goal, zone)
            XCTAssertEqual(c.expectedTime(on: c.signupDate), fitness, zone)
        }
    }
}
