import XCTest
@testable import Tempo

/// Chicago, Sunday 11 Oct 2026. On the 12th Tempo still thought David was training for it:
/// the goal was active, the race date was in the past, and Today offered a rest day as if
/// the next build started tomorrow (#100).
///
/// The phase decides when Today asks "review your block". These pin the day boundaries —
/// a card that appears an evening early asks a man to review a race he hasn't run yet — and
/// the one rule with a reason behind it: a race date passing never closes a block by itself.
final class BlockLifecycleTests: XCTestCase {

    /// `GoalInfo.raceDay` parses `race_date` in the device's zone (`PlanDates.day`), so the
    /// test builds its instants in that zone too.
    private let cal = Calendar.current

    private func at(_ iso: String, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        let midnight = PlanDates.day.date(from: iso)!
        return cal.date(byAdding: .minute, value: hour * 60 + minute, to: midnight)!
    }

    private func chicago(outcome: String? = nil, completedAt: Date? = nil, raceDate: String? = "2026-10-11") -> GoalInfo {
        GoalInfo(id: UUID(), race_name: "Chicago", race_date: raceDate, goal_time_seconds: 11_700,
                 distance: "marathon", completed_at: completedAt, outcome: outcome)
    }

    private func plan(status: String = "active") -> PlanInfo {
        PlanInfo(id: UUID(), goal_id: UUID(), start_date: "2026-06-22", weeks: 16, status: status)
    }

    private func phase(_ goal: GoalInfo, _ now: Date, plan: PlanInfo? = nil) -> BlockLifecycle.Phase {
        BlockLifecycle.phase(goal: goal, plan: plan ?? self.plan(), now: now, calendar: cal)
    }

    // MARK: - Day boundaries

    /// Race passes at local midnight after race day, not at some hour of race day. At 23:59 on
    /// the 11th he may still be in the beer tent; at 00:00 on the 12th the block is reviewable.
    func testRacePassedStartsTheDayAfterRaceDay() {
        XCTAssertEqual(phase(chicago(), at("2026-10-11", 7, 30)), .raceWeek, "race morning")
        XCTAssertEqual(phase(chicago(), at("2026-10-11", 23, 59)), .raceWeek, "race night is still race day")
        XCTAssertEqual(phase(chicago(), at("2026-10-12", 0, 0)), .racePassed, "midnight after")
        XCTAssertEqual(phase(chicago(), at("2026-10-12", 9, 0)), .racePassed, "the morning David opened the app")
    }

    /// Race week is the last seven days, race day included: Monday 5 Oct for a Sunday race.
    func testRaceWeekIsTheLastSevenDays() {
        XCTAssertEqual(phase(chicago(), at("2026-10-04", 23, 59)), .training, "8 days out")
        XCTAssertEqual(phase(chicago(), at("2026-10-05", 0, 0)), .raceWeek, "6 days out")
        XCTAssertEqual(phase(chicago(), at("2026-08-27", 15)), .training)
    }

    /// `racePassed` does not decay into `closed` with time. Weeks later the card is still
    /// there — the athlete closes a block, the calendar doesn't.
    func testRacePassedNeverClosesOnItsOwn() {
        XCTAssertEqual(phase(chicago(), at("2026-12-25", 12)), .racePassed)
        XCTAssertEqual(phase(chicago(), at("2027-10-11", 12)), .racePassed)
    }

    func testNoRaceDateIsTraining() {
        XCTAssertEqual(phase(chicago(raceDate: nil), at("2026-10-12", 9)), .training,
                       "no date, nothing to pass")
    }

    // MARK: - Closed

    func testAnOutcomeOrCompletionClosesTheBlock() {
        XCTAssertEqual(phase(chicago(outcome: "raced"), at("2026-10-12", 9)), .closed)
        XCTAssertEqual(phase(chicago(completedAt: at("2026-10-12", 9)), at("2026-10-12", 9)), .closed)
        XCTAssertEqual(phase(chicago(outcome: "did_not_start"), at("2026-10-01")), .closed,
                       "closed beats every date rule")
    }

    /// A plan stood down without its goal being closed — a regeneration, the way four plans
    /// were retired on 2026-07-10 (migration 0010) — is not a block to review.
    func testADonePlanIsClosed() {
        XCTAssertEqual(phase(chicago(), at("2026-10-12", 9), plan: plan(status: "done")), .closed)
        XCTAssertEqual(BlockLifecycle.phase(goal: chicago(), plan: nil, now: at("2026-10-12", 9), calendar: cal),
                       .racePassed, "no plan on hand is not a done plan")
    }
}
