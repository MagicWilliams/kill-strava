import Foundation

/// Dropping a race: what Confirm on the coach's `end_goal` card closes, and what the card
/// says it will do (#238, David's call 3A on #232).
///
/// Before this a goal had two exits: race it and close the block (#100), or replace it with
/// a new create_plan. "I'm not racing it anymore" had no path back to just running (#101), so
/// the athlete was left with a plan they had walked away from on Today and in the coach's
/// context every morning.
///
/// No new states. Ending a goal is closing its block with the outcome the lifecycle already
/// has for it: `BlockCloseout.Outcome.abandoned` before race day, which 0013 defines as "the
/// block given up before race day", and `.didNotStart` from race day on, since by then it
/// is a race they did not start. The plan goes to `done` (`BlockCloseout.PlanPatch`). After
/// that, `BlockLifecycle` reads the block as `.closed`, `TodayMode` as `.justRunning`, and
/// Past blocks lists it as "Ended early" or "DNS".
///
/// Pure: the clock and calendar are arguments, so a card confirmed at 11pm the night before
/// the race is pinned to the right side of the line.
enum GoalRetirement {

    /// What a build that applies end_goal cards tells the coach (`CoachRequest.features`).
    /// The coach function offers the tool only to a build that sends this exact string, so an
    /// older install never gets a card it can't confirm.
    static let coachFeature = "end_goal"

    /// The card's `type`.
    static let actionType = "end_goal"

    /// What Confirm closes. Either may be nil, never both: a "no plan, just coaching" goal
    /// (#102) has no plan, and a plan whose goal failed to load has a plan but no goal in hand.
    struct Retirement: Equatable {
        let goal: GoalInfo?
        let planID: UUID?
        let outcome: BlockCloseout.Outcome
    }

    /// Nil when there is nothing active to end. The card says so and Confirm refuses, rather
    /// than reporting "Applied" for a write that touched nothing.
    static func retirement(
        goal: GoalInfo?,
        plan: PlanInfo?,
        now: Date,
        calendar: Calendar = .current
    ) -> Retirement? {
        guard goal != nil || plan != nil else { return nil }
        return Retirement(
            goal: goal,
            planID: plan?.id,
            outcome: outcome(raceDay: goal?.raceDay, now: now, calendar: calendar)
        )
    }

    /// `.abandoned` until race day, `.didNotStart` from race day on. Compared by local
    /// calendar day, as `BlockLifecycle` does: `race_date` has no time, so dropping out on the
    /// morning of the race is not "before race day". No race date is `.abandoned`; nothing
    /// was there to start.
    static func outcome(raceDay: Date?, now: Date, calendar: Calendar = .current) -> BlockCloseout.Outcome {
        guard let raceDay else { return .abandoned }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: raceDay)
        ).day ?? 0
        return days > 0 ? .abandoned : .didNotStart
    }

    /// The line under the coach's summary on the card, written by code, not by the model:
    /// the summary is the coach's words, but what Confirm will do is this file's to say.
    ///
    /// "Ends your Turkey Trot plan. Your runs stay; Today goes back to just running."
    static func cardLine(goal: GoalInfo?, plan: PlanInfo?) -> String {
        let name = goal?.raceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let race = name.map { "your \($0)" } ?? "your current"
        switch (goal, plan) {
        case (_, .some):
            return "Ends \(race) plan. Your runs stay; Today goes back to just running."
        case (.some, nil):
            // Today is already the feed with no plan; only the goal changes.
            return "Ends \(race) goal. Your runs stay."
        case (nil, nil):
            return nothingToEnd
        }
    }

    /// Shown on the card, and as the error, when there is no goal or plan to end.
    static let nothingToEnd = "There's no active goal or plan to end."
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
