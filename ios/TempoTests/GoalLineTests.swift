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

    // MARK: - The goal card's TARGET (#188)

    /// Found while building #185: the You tab read every goal time as a marathon time.
    /// TARGET was `PaceModel.paces(for: .marathon, goalSeconds:).marathon`, so a 25:00 5K
    /// goal was divided over 26.2 miles and the card asked for 0:57 /mi.
    private func goal(seconds: Int?, distance: String, meters: Int? = nil) -> GoalInfo {
        GoalInfo(id: UUID(), race_name: "Race", race_date: "2026-11-26", goal_time_seconds: seconds,
                 distance: distance, distance_m: meters)
    }

    func testAFiveKGoalTargetsFiveKRacePace() {
        let fiveK = goal(seconds: 25 * 60, distance: "5k", meters: 5_000)
        XCTAssertEqual(GoalLine.targetPace(goal: fiveK, units: .mi), "8:03 /mi")
        XCTAssertEqual(GoalLine.targetPace(goal: fiveK, units: .km), "5:00 /km")
    }

    /// The exact number the old code put on screen for that goal, pinned so it can't return.
    func testAFiveKGoalIsNoLongerReadAsAMarathon() {
        let fiveK = goal(seconds: 25 * 60, distance: "5k", meters: 5_000)
        let old = Units.mi.formatPace(secondsPerMile: PaceModel.paces(for: .marathon, goalSeconds: 1_500).marathon)
        XCTAssertEqual(old, "0:57 /mi")
        XCTAssertNotEqual(GoalLine.targetPace(goal: fiveK, units: .mi), old)
    }

    /// The marathon was the one case the old formula got right; the fix must not move it.
    /// 3:15:00 still reads 7:26 /mi.
    func testAMarathonGoalReadsExactlyWhatItAlwaysDid() {
        let chicago = goal(seconds: 11_700, distance: "marathon")
        XCTAssertEqual(GoalLine.targetPace(goal: chicago, units: .mi), "7:26 /mi")
        XCTAssertEqual(GoalLine.targetPace(goal: chicago, units: .mi),
                       Units.mi.formatPace(secondsPerMile: PaceModel.paces(for: .marathon, goalSeconds: 11_700).marathon))
        XCTAssertEqual(GoalLine.targetPace(goal: chicago, units: .km), "4:37 /km")
    }

    /// The distance is read the way the projection reads it: `distance_m` first (a custom
    /// 30K is labelled `custom`, which alone would read as a marathon), the label when a goal
    /// predates `distance_m`.
    func testTheDistanceComesFromTheSameReadingAsTheProjection() {
        let thirtyK = goal(seconds: 9_000, distance: "custom", meters: 30_000)
        XCTAssertEqual(GoalLine.targetPace(goal: thirtyK, units: .km), "5:00 /km")

        let labelOnly = goal(seconds: 25 * 60, distance: "5k")
        XCTAssertEqual(GoalLine.targetPace(goal: labelOnly, units: .km), "5:00 /km")
    }

    func testAGoalWithNoTargetTimeHasNoTargetPace() {
        XCTAssertEqual(GoalLine.targetPace(goal: goal(seconds: nil, distance: "5k", meters: 5_000), units: .mi), "—")
        XCTAssertEqual(GoalLine.targetPace(goal: goal(seconds: 0, distance: "5k", meters: 5_000), units: .mi), "—")
        XCTAssertEqual(GoalLine.targetPace(goal: nil, units: .mi), "—")
    }

    // MARK: - The You card for a goal with no target time (#231)
    //
    // 15 Oct, You tab: the subtitle read "Race · 6 weeks out" and the card directly beneath
    // it read "No goal yet. The coach proposes one from your data", with a Talk to Coach
    // button — both at once. The goal was the 27 Nov tune-up: `goal_type = "unsure"`, no
    // `goal_time_seconds`, deliberately. The card branched on the target time, so a goal
    // without one read as no goal at all. `State.untimed` had existed since #44 for exactly
    // this; the card just never read it.

    private func untimed(name: String? = "Turkey Trot", type: String? = "unsure",
                         distance: String = "5k", meters: Int? = 5_000) -> GoalInfo {
        GoalInfo(id: UUID(), race_name: name, race_date: "2026-11-27", goal_time_seconds: nil,
                 distance: distance, distance_m: meters, goal_type: type)
    }

    /// The regression, in the state the card now switches on: a goal with no target time is
    /// an untimed goal, never `.noGoal`, so the empty state cannot fire on it.
    func testAnUntimedGoalIsNeverTheNoGoalEmptyState() {
        let g = untimed()
        let s = GoalLine.state(raceName: g.raceName, raceDate: g.raceDate,
                               goalTimeSeconds: g.goalTimeSeconds, hasGoal: true)
        XCTAssertEqual(s, .untimed(race: "Turkey Trot", on: "2026-11-27"))
        XCTAssertNotEqual(s, .noGoal, "the 27 Nov tune-up is a goal")
        XCTAssertFalse(GoalLine.untimedLine(goalType: g.goal_type, on: "Nov 27")
            .localizedCaseInsensitiveContains("no goal"),
                       "the card may not offer to set a goal that already exists")
    }

    /// The three lines the issue specifies, verbatim. "Just finish" is the one type that does
    /// *not* trail "no target time": the goal is to finish, so there is no target absent from
    /// it, and naming one would read as a gap rather than the athlete's choice.
    func testTheUntimedLineSaysWhichKindOfGoalItIs() {
        XCTAssertEqual(GoalLine.untimedLine(goalType: "finish", on: "Nov 27"),
                       "Just finish · Nov 27")
        XCTAssertEqual(GoalLine.untimedLine(goalType: "pr", on: "Nov 27"),
                       "Chasing a PR · Nov 27 · no target time")
        XCTAssertEqual(GoalLine.untimedLine(goalType: "unsure", on: "Nov 27"),
                       "Nov 27 · no target time")
        XCTAssertEqual(GoalLine.untimedLine(goalType: nil, on: "Nov 27"),
                       "Nov 27 · no target time",
                       "every goal written before the intake (#102) has no type")
    }

    /// `unsure` is what the coach saved for the tune-up, and `time` is a time goal that has
    /// lost its time — a contradiction. Neither earns a phrase: one has nothing to say, the
    /// other would say something the goal does not contain.
    func testOnlyTheGoalTypesThatSaySomethingGetAPhrase() {
        XCTAssertEqual(GoalLine.goalTypePhrase("finish"), "Just finish")
        XCTAssertEqual(GoalLine.goalTypePhrase("pr"), "Chasing a PR")
        XCTAssertNil(GoalLine.goalTypePhrase("unsure"))
        XCTAssertNil(GoalLine.goalTypePhrase("time"))
        XCTAssertNil(GoalLine.goalTypePhrase(nil))
        XCTAssertNil(GoalLine.goalTypePhrase("tune-up"), "not a goal_type — that is #232's role")
    }

    /// `race_date` is nullable, so the date can be missing from a line that is otherwise fine.
    /// What is left still has to read as a sentence, which means the line that opens on "no
    /// target time" opens on a capital.
    func testAnUndatedUntimedGoalDropsTheDateRatherThanPrintingAnEmptyOne() {
        XCTAssertEqual(GoalLine.untimedLine(goalType: "unsure", on: nil), "No target time")
        XCTAssertEqual(GoalLine.untimedLine(goalType: nil, on: ""), "No target time",
                       "an empty date is no date, as everywhere else here")
        XCTAssertEqual(GoalLine.untimedLine(goalType: "finish", on: nil), "Just finish")
        XCTAssertEqual(GoalLine.untimedLine(goalType: "pr", on: nil), "Chasing a PR · no target time")
    }

    // MARK: - The card's title names the distance (#231, #230)

    /// The title used to be `"<time> · <race name>"`. A 5K saved as a marathon (#215) sat on
    /// this screen for two weeks because nothing on it said which race the plan was for.
    func testTheRaceLabelNamesTheDistanceBesideTheName() {
        XCTAssertEqual(GoalLine.raceLabel(goal: untimed(), units: .mi), "Turkey Trot · 5K")
        XCTAssertEqual(GoalLine.raceLabel(goal: untimed(distance: "half", meters: 21_098), units: .mi),
                       "Turkey Trot · Half")
    }

    /// Not twice, though: the athlete's own name for the race usually carries the distance.
    func testANameThatAlreadyCarriesTheDistanceKeepsIt() {
        XCTAssertEqual(
            GoalLine.raceLabel(goal: untimed(name: "Chicago Marathon", distance: "marathon", meters: 42_195), units: .mi),
            "Chicago Marathon")
        XCTAssertEqual(GoalLine.raceLabel(goal: untimed(name: "Turkey Trot 5k"), units: .mi),
                       "Turkey Trot 5k", "the match is case-insensitive")
    }

    /// `race_name` is nullable, and a goal always has a distance even when it has no name —
    /// so the unnamed case says the distance rather than the bare "Race" the old card used.
    func testAnUnnamedGoalIsNamedByItsDistance() {
        XCTAssertEqual(GoalLine.raceLabel(goal: untimed(name: nil, distance: "marathon", meters: 42_195), units: .mi),
                       "Marathon race")
        XCTAssertEqual(GoalLine.raceLabel(goal: untimed(name: "   "), units: .mi), "5K race",
                       "a name of spaces is no name")
        XCTAssertNil(GoalLine.raceLabel(goal: nil, units: .mi), "no goal, nothing to name")
    }

    /// The metres come from `RaceRecap.raceMeters(goal:)`, the same reading TARGET and
    /// PROJECTED use, so the title can't name one race while the numbers answer for another.
    /// A custom distance has no label of its own and is spelled out in the athlete's unit.
    func testTheDistanceIsReadOffTheSameMetresTheNumbersUse() {
        XCTAssertEqual(GoalLine.distanceLabel(raceMeters: RaceRecap.raceMeters(goalDistance: "half"), units: .mi),
                       "Half", "21,097.5 and 21,098 are one distance")
        XCTAssertEqual(GoalLine.distanceLabel(raceMeters: Units.metersPerMile, units: .mi), "1 mi")
        XCTAssertEqual(GoalLine.distanceLabel(raceMeters: 30_000, units: .km), "30.0 km")
        XCTAssertEqual(GoalLine.raceLabel(goal: untimed(distance: "custom", meters: 30_000), units: .km),
                       "Turkey Trot · 30.0 km")
        // A goal written before 0014 has no `distance_m`; the label still carries it.
        XCTAssertEqual(GoalLine.raceLabel(goal: untimed(distance: "10k", meters: nil), units: .mi),
                       "Turkey Trot · 10K")
    }
}
