import Foundation

/// What the Projected finish page says about the race it is projecting to, and the sentence
/// it hands the coach when the athlete wants a different one (#233).
///
/// The scar: Progress showed **4:18:04** as the projected finish for what David believed was
/// a 5K. It was projecting to a marathon (#215), and nothing on the card or on the detail
/// page named the race the number was for, so the only way to find out was to read the
/// database. #230 fixed that for the three tab headers; this is the same fix one screen
/// deeper, on the page the number's own card opens.
///
/// Every string here is a pure function of the goal, because the point is that the race named
/// on the card, the race in the countdown and the race named in the message to the coach are
/// all one reading of one goal. A label built in the view would be free to drift from the
/// metres the number was projected to, which is exactly how #215 stayed invisible.
///
/// Nothing here writes. "Change race or date" only opens the Coach composer with a sentence
/// in it: the athlete finishes it, the coach proposes a `create_plan` card, and the existing
/// confirm flow applies it. A screen that rewrote the goal itself would be a second path into
/// the plan, with none of the proposal and confirmation the first one has.
enum RaceChange {

    /// The card's target row when the goal carries no target time.
    ///
    /// A goal without a target time is a goal (#231): David's 27 Nov tune-up is saved with
    /// `goal_type = "unsure"` and no `goal_time_seconds`, deliberately. So this states the one
    /// thing that is missing instead of reading as a goal that failed to load.
    static let noTargetTime = "No target time"

    /// The card's date row when the goal has a race but no date on it.
    static let noRaceDate = "No race date yet"

    /// The Progress card's section label: "Projected finish · 5K".
    ///
    /// The distance is read off `ProjectionHistory.raceMeters(goal:)`, the very metres the
    /// number beside it was projected to, so the label and the number cannot name two
    /// different races. A label built from `goals.distance` could: the column and `distance_m`
    /// have disagreed before, and it cost a 5K block (#184).
    ///
    /// Bare "Projected finish" with no goal. `raceMeters` falls back to the marathon so the
    /// page always has something to project to, and printing that fallback as a race label
    /// would state a race the athlete never entered.
    static func projectedFinishLabel(goal: GoalInfo?, units: Units) -> String {
        let label = "Projected finish"
        guard goal != nil else { return label }
        let distance = RaceCountdown.distanceLabel(
            raceMeters: ProjectionHistory.raceMeters(goal: goal), units: units
        )
        return "\(label) · \(distance)"
    }

    /// "Target 3:15:00", or `noTargetTime`.
    ///
    /// Takes the `GoalLine.State` the Progress card and the coach context already read, so
    /// this page cannot disagree with them about whether a target exists at all (#44).
    static func targetLine(goal: GoalLine.State) -> String {
        guard let seconds = goal.seconds else { return noTargetTime }
        return "Target \(PaceModel.formatFinish(seconds))"
    }

    /// "Fri, Nov 27 · 43 days · 7 weeks": race day and what is left of the countdown.
    ///
    /// `on` is race day already formatted for the card, nil when the goal carries no date,
    /// the same hand-off `GoalLine.untimedLine(goalType:on:)` takes. Date formatting is a
    /// locale's business and the decision here is which parts to print.
    ///
    /// The count comes from `RaceCountdown.State` rather than from a second piece of date
    /// math, so this page counts the same days as Plan, Progress and You (#230). Every state
    /// with nothing left to count says what it is in words: a countdown that has run out
    /// reads as a countdown with time on it, which is the defect `RaceCountdown` exists to
    /// prevent.
    static func raceDayLine(state: RaceCountdown.State, on raceDate: String?) -> String {
        let date = raceDate.flatMap { $0.isEmpty ? nil : $0 }
        switch state {
        case .noGoal:
            // The card is hidden without a goal; nothing to say if it ever is not.
            return ""
        case .undated:
            return noRaceDate
        case .ahead:
            return [date, state.countdown()].compactMap { $0 }.joined(separator: " · ")
        case .raceDay:
            return [date, "race day"].compactMap { $0 }.joined(separator: " · ")
        case .past:
            return [date, "already run"].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// The sentence the Coach composer opens with, prefilled and never sent.
    ///
    /// It names the race off the goal, through `RaceCountdown.raceLabel`, so the message the
    /// coach receives names the same race the card above the button named. When this was a
    /// sentence typed in the view, the two could disagree, and the whole reason the row exists
    /// is that the athlete could not tell which race the app thought he had entered.
    ///
    /// Nil only when there is no goal, which is the one state the row is hidden in.
    ///
    /// `on` is race day already formatted, as `raceDayLine` takes it. The trailing space is
    /// deliberate: the composer opens with the cursor after it, ready for the athlete's own
    /// half of the sentence, with no need to tap past punctuation first.
    static func draft(goal: GoalInfo?, units: Units, on raceDate: String?) -> String? {
        guard let race = RaceCountdown.raceLabel(goal: goal, units: units) else { return nil }
        guard let date = raceDate.flatMap({ $0.isEmpty ? nil : $0 }) else {
            return "I want to change my race. It is currently \(race), with no date set yet. "
        }
        return "I want to change my race. It is currently \(race) on \(date). "
    }
}
