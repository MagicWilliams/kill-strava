import XCTest
@testable import Tempo

/// Progress showed **4:18:04** as David's projected finish for what he believed was a 5K.
/// It was projecting to a marathon (#215): the goal had been saved with the wrong distance,
/// and every string the number sat under was equally true of either race. The card said
/// "PROJECTED FINISH". The detail page said "the race". Two weeks went by, and the only way
/// to find out was to read the `goals` row.
///
/// #230 pinned the three tab headers to one race label for that reason. These pin the same
/// rule one screen deeper (#233): the Progress card's own label, the "Your race" card on the
/// page it opens, and the sentence the coach is handed when the athlete wants a different
/// race. All three read the goal once, through the metres the projection itself used, so
/// none of them can name a race the number does not answer for.
final class RaceChangeTests: XCTestCase {

    /// The 27 Nov tune-up as it is actually stored: `goal_type = "unsure"`, no target time,
    /// `distance_m` carrying the real distance.
    private func goal(
        name: String? = "Turkey Trot",
        date: String? = "2026-11-27",
        seconds: Int? = nil,
        distance: String = "5k",
        meters: Int? = 5_000
    ) -> GoalInfo {
        GoalInfo(id: UUID(), race_name: name, race_date: date, goal_time_seconds: seconds,
                 distance: distance, distance_m: meters, goal_type: "unsure")
    }

    // MARK: - The Progress card's label (#233 item 1)

    /// The regression, named. A 5K goal labels the card 5K, whatever the number under it is.
    func testTheProgressLabelNamesTheDistance() {
        XCTAssertEqual(
            RaceChange.projectedFinishLabel(goal: goal(), units: .mi),
            "Projected finish · 5K"
        )
        XCTAssertEqual(
            RaceChange.projectedFinishLabel(goal: goal(distance: "marathon", meters: 42_195), units: .mi),
            "Projected finish · Marathon"
        )
    }

    /// The label is read off the metres the projection extrapolates to, not off
    /// `goals.distance`. The two have disagreed before and it cost a 5K block (#184): a
    /// custom 30K carries `distance = "custom"`, which on its own reads as a marathon.
    func testTheLabelReadsTheSameMetresAsTheNumber() {
        let thirtyK = goal(distance: "custom", meters: 30_000)
        XCTAssertEqual(
            RaceChange.projectedFinishLabel(goal: thirtyK, units: .km),
            "Projected finish · 30.0 km"
        )
        XCTAssertEqual(
            RaceChange.projectedFinishLabel(goal: thirtyK, units: .km),
            "Projected finish · " + RaceCountdown.distanceLabel(
                raceMeters: ProjectionHistory.raceMeters(goal: thirtyK), units: .km
            ),
            "the label and the projection must read one number"
        )
    }

    /// With no goal, `raceMeters` falls back to the marathon so the page has something to
    /// project to. Printing that fallback as a race label would assert a race the athlete
    /// never entered, which is the #44 family of bug.
    func testNoGoalNamesNoRace() {
        XCTAssertEqual(RaceChange.projectedFinishLabel(goal: nil, units: .mi), "Projected finish")
        XCTAssertFalse(
            RaceChange.projectedFinishLabel(goal: nil, units: .mi)
                .localizedCaseInsensitiveContains("marathon"),
            "no goal, no borrowed race"
        )
    }

    // MARK: - The target row (#233 item 2)

    /// A goal with no target time is a goal (#231), so the row says which thing is missing
    /// rather than reading as a number that failed to load.
    func testTheTargetRowStatesWhatIsMissing() {
        let untimed = GoalLine.state(raceName: "Turkey Trot", raceDate: "2026-11-27",
                                     goalTimeSeconds: nil, hasGoal: true)
        XCTAssertEqual(RaceChange.targetLine(goal: untimed), "No target time")

        let timed = GoalLine.state(raceName: "Chicago", raceDate: "2026-10-11",
                                   goalTimeSeconds: 11_700, hasGoal: true)
        XCTAssertEqual(RaceChange.targetLine(goal: timed), "Target 3:15:00")
    }

    /// Zero is what `?? 0` used to produce, and it is not a target time (#44).
    func testAZeroTargetIsNoTarget() {
        let zero = GoalLine.state(raceName: "Turkey Trot", raceDate: "2026-11-27",
                                  goalTimeSeconds: 0, hasGoal: true)
        XCTAssertEqual(RaceChange.targetLine(goal: zero), "No target time")
    }

    // MARK: - The date row (#233 item 2)

    func testTheDateRowCarriesTheCountdown() {
        XCTAssertEqual(
            RaceChange.raceDayLine(
                state: .ahead(race: "Turkey Trot · 5K", days: 43, weeks: 7),
                on: "Fri, Nov 27"
            ),
            "Fri, Nov 27 · 43 days · 7 weeks"
        )
    }

    /// Inside the final week the week count adds nothing the day count has not said, and
    /// `RaceCountdown.State` already decides that. This row must not re-decide it.
    func testTheFinalWeekIsDaysOnly() {
        XCTAssertEqual(
            RaceChange.raceDayLine(state: .ahead(race: "Turkey Trot · 5K", days: 6, weeks: 1),
                                   on: "Fri, Nov 27"),
            "Fri, Nov 27 · 6 days"
        )
    }

    /// Every state with nothing left to count says so in words. A countdown that has run
    /// out reads as a countdown with time on it, which is the whole reason `RaceCountdown`
    /// exists (#36).
    func testStatesWithNothingToCountSayWhatTheyAre() {
        XCTAssertEqual(
            RaceChange.raceDayLine(state: .undated(race: "5K race"), on: nil),
            "No race date yet"
        )
        XCTAssertEqual(
            RaceChange.raceDayLine(state: .raceDay(race: "Turkey Trot · 5K"), on: "Fri, Nov 27"),
            "Fri, Nov 27 · race day"
        )
        XCTAssertEqual(
            RaceChange.raceDayLine(state: .past(race: "Turkey Trot · 5K"), on: "Fri, Nov 27"),
            "Fri, Nov 27 · already run"
        )
        XCTAssertEqual(RaceChange.raceDayLine(state: .noGoal, on: nil), "")
    }

    // MARK: - The sentence handed to the coach (#233 item 3)

    /// The point of the pure function: the race in the message is the race on the card,
    /// named by the same `RaceCountdown.raceLabel` the card's title uses.
    func testTheDraftNamesTheRaceOnTheCard() {
        let draft = RaceChange.draft(goal: goal(), units: .mi, on: "Fri, Nov 27")
        XCTAssertEqual(
            draft,
            "I want to change my race. It is currently Turkey Trot · 5K on Fri, Nov 27. "
        )
        XCTAssertEqual(
            draft?.contains(RaceCountdown.raceLabel(goal: goal(), units: .mi)!), true,
            "the sentence and the card must name one race"
        )
    }

    /// A goal with no race name still has a distance, so the sentence says "5K race" rather
    /// than a bare "race" the coach cannot act on (#230 item 3).
    func testAnUnnamedRaceIsStillNamedByItsDistance() {
        XCTAssertEqual(
            RaceChange.draft(goal: goal(name: nil), units: .mi, on: "Fri, Nov 27"),
            "I want to change my race. It is currently 5K race on Fri, Nov 27. "
        )
        XCTAssertEqual(
            RaceChange.draft(goal: goal(name: "   "), units: .mi, on: "Fri, Nov 27"),
            "I want to change my race. It is currently 5K race on Fri, Nov 27. ",
            "whitespace is not a race name"
        )
    }

    /// A custom distance is spelled out in the athlete's own unit, both of them.
    func testACustomDistanceIsSpelledOut() {
        let thirtyK = goal(name: nil, distance: "custom", meters: 30_000)
        XCTAssertEqual(
            RaceChange.draft(goal: thirtyK, units: .km, on: "Fri, Nov 27"),
            "I want to change my race. It is currently 30.0 km race on Fri, Nov 27. "
        )
        XCTAssertEqual(
            RaceChange.draft(goal: thirtyK, units: .mi, on: "Fri, Nov 27"),
            "I want to change my race. It is currently 18.6 mi race on Fri, Nov 27. "
        )
    }

    /// No date on the goal is its own sentence. Interpolating an empty string is how the
    /// coach once read "Race on , target ..." (#44).
    func testAGoalWithNoDateSaysSo() {
        for date in [nil, ""] as [String?] {
            XCTAssertEqual(
                RaceChange.draft(goal: goal(date: nil), units: .mi, on: date),
                "I want to change my race. It is currently Turkey Trot · 5K, with no date set yet. "
            )
        }
    }

    /// Nil with no goal: there is no race to ask to change, and the row that calls this is
    /// hidden in that state.
    func testNoGoalHandsTheCoachNothing() {
        XCTAssertNil(RaceChange.draft(goal: nil, units: .mi, on: "Fri, Nov 27"))
    }

    /// The trailing space is load-bearing: the composer opens with the cursor after it, so
    /// the athlete types their own half of the sentence without first tapping past
    /// punctuation. Easy to "tidy away" in a later edit, so it is pinned.
    func testTheDraftEndsReadyToBeTypedInto() {
        let draft = RaceChange.draft(goal: goal(), units: .mi, on: "Fri, Nov 27")!
        XCTAssertTrue(draft.hasSuffix(". "), "the composer opens with the cursor after a space")
        XCTAssertFalse(draft.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Prefilled, never sent, so the sentence must read as the athlete's own opening and not
    /// as an instruction the app issued on their behalf.
    func testTheDraftIsTheAthletesSentence() {
        let draft = RaceChange.draft(goal: goal(), units: .mi, on: "Fri, Nov 27")!
        XCTAssertTrue(draft.hasPrefix("I want to change my race"))
    }
}
