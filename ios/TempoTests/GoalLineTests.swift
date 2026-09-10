import XCTest
@testable import Tempo

/// Two Chicago fallbacks outlived the countdown constant that `RaceCountdown` replaced (#44).
///
/// The Progress card printed `"3:15:00"` under the label **Goal** whenever there was no goal,
/// beside a projection rendering `—:—:—` in that same state. And `coachContext` shipped a
/// `static let` asserting "Sub-3:15 at the Chicago Marathon on 2026-10-11 … rebuilding from a
/// small base" as the athlete's goal whenever there wasn't one — which is precisely the
/// onboarding path, the one moment the coach exists to read the history and propose a goal.
/// It was handed the conclusion and asked to derive it.
///
/// Neither looked broken. Both are the beta-of-one reference athlete's numbers wearing the
/// user's name. These pin the states the old code could not express: no goal, a goal with no
/// target time, a goal with no date, and the zero that `?? 0` used to manufacture.
final class GoalLineTests: XCTestCase {

    private func state(race: String? = "Chicago", on: String? = "2026-10-11", seconds: Int? = 11_700) -> GoalLine.State {
        GoalLine.state(raceName: race, raceDate: on, goalTimeSeconds: seconds, hasGoal: true)
    }

    private let noGoal = GoalLine.state(raceName: nil, raceDate: nil, goalTimeSeconds: nil, hasGoal: false)

    // MARK: - No goal at all

    /// The headline regression. With no goal the Goal column showed a number the athlete had
    /// never chosen, and it was the *only* confident thing on a card that was otherwise
    /// honestly empty.
    func testNoGoalShowsDashesRatherThanTheReferenceAthletesTime() {
        XCTAssertEqual(noGoal, .noGoal)
        XCTAssertEqual(noGoal.finishTime, "—:—:—")
        XCTAssertNotEqual(noGoal.finishTime, "3:15:00", "the placeholder was never this user's goal")
    }

    /// The projection and the goal sit on one card. In the no-goal state both are unknown,
    /// so both must look unknown — that mismatch was the visible half of the bug.
    func testTheEmptyGoalMatchesTheEmptyProjectionBesideIt() {
        XCTAssertEqual(noGoal.finishTime, GoalLine.unknownFinish)
    }

    /// The coach used to be told a race, a date, and a finish time before the athlete had
    /// picked any of them. Nothing it now receives asserts a goal that does not exist.
    func testNoGoalTellsTheCoachThereIsNoGoalInsteadOfInventingOne() {
        let line = noGoal.coachLine
        for invention in ["Chicago", "3:15", "2026-10-11", "base-building", "small base"] {
            XCTAssertFalse(line.contains(invention), "\(invention) is the reference athlete, not the user")
        }
        XCTAssertFalse(line.contains(where: \.isNumber), "no numbers survive in the no-goal line")
    }

    /// The old fallback trailed "(no plan yet — assess and propose one when the athlete is
    /// ready)" after its assertion. The instruction was the good half; keep it.
    func testNoGoalStillAsksTheCoachToProposeOne() {
        XCTAssertTrue(noGoal.coachLine.lowercased().contains("propose"))
    }

    /// Nothing to compare a projection against, so the "on track" / "behind goal" tag has no
    /// number to fire on.
    func testNoGoalOffersNoTargetToCompareAgainst() {
        XCTAssertNil(noGoal.seconds)
    }

    // MARK: - A real goal

    func testARealGoalRendersAndDescribesItself() {
        XCTAssertEqual(state(), .timed(race: "Chicago", on: "2026-10-11", seconds: 11_700))
        XCTAssertEqual(state().finishTime, "3:15:00")
        XCTAssertEqual(state().seconds, 11_700)
        XCTAssertEqual(state().coachLine, "Chicago on 2026-10-11, target 3:15:00")
    }

    /// The number is the athlete's when the athlete has set one — this is the case that
    /// always worked, and it has to keep working after the fallback's removal.
    func testADifferentGoalIsReportedAsItself() {
        XCTAssertEqual(state(race: "Berlin", on: "2027-09-26", seconds: 10_800).coachLine,
                       "Berlin on 2027-09-26, target 3:00:00")
        XCTAssertEqual(state(race: "Berlin", on: "2027-09-26", seconds: 10_800).finishTime, "3:00:00")
    }

    // MARK: - A goal that is missing pieces

    /// `goal_time_seconds` is nullable. A goal row can exist with a race and a date and no
    /// target yet, and that is not the same as having a target.
    func testAGoalWithoutATargetTimeSaysSo() {
        let s = state(seconds: nil)
        XCTAssertEqual(s, .untimed(race: "Chicago", on: "2026-10-11"))
        XCTAssertEqual(s.finishTime, "—:—:—")
        XCTAssertNil(s.seconds)
        XCTAssertEqual(s.coachLine, "Chicago on 2026-10-11 — no target time set yet.")
    }

    /// The scar `?? 0` left: a missing target reached the coach as "target 0:00:00", a
    /// number stating the athlete intends to finish instantly. Zero is not a goal time.
    func testAZeroTargetIsNotATargetTime() {
        let s = state(seconds: 0)
        XCTAssertEqual(s.finishTime, "—:—:—")
        XCTAssertNil(s.seconds)
        XCTAssertFalse(s.coachLine.contains("0:00:00"), "the ?? 0 fallback does not come back")
    }

    /// `race_date` is nullable too, and `GoalInfo.raceDate` turns null into `""` — which the
    /// old coach line interpolated straight through as "Race on , target 3:15:00".
    func testAGoalWithoutARaceDateDoesNotLeaveADanglingOn() {
        XCTAssertEqual(state(on: nil).coachLine, "Chicago, target 3:15:00")
        XCTAssertEqual(state(on: "").coachLine, "Chicago, target 3:15:00", "an empty date is no date")
        XCTAssertEqual(state(on: "", seconds: nil).coachLine,
                       "Chicago — no race date or target time set yet.")
    }

    /// `race_name` is nullable. A goal with no name borrows the same "Race" placeholder
    /// `RaceCountdown`, PlanView and YouView use — a generic noun, not a specific city.
    func testAnUnnamedGoalIsCalledRaceNotChicago() {
        XCTAssertEqual(state(race: nil).coachLine, "Race on 2026-10-11, target 3:15:00")
        XCTAssertEqual(state(race: "").coachLine, "Race on 2026-10-11, target 3:15:00", "an empty name is no name")
    }

    /// A goal row carrying nothing at all still isn't the reference athlete's.
    func testAnEmptyGoalRowNamesNoRaceAndNoTime() {
        let s = GoalLine.state(raceName: nil, raceDate: nil, goalTimeSeconds: nil, hasGoal: true)
        XCTAssertEqual(s, .untimed(race: "Race", on: nil))
        XCTAssertEqual(s.finishTime, "—:—:—")
        XCTAssertFalse(s.coachLine.contains("Chicago"))
    }
}
