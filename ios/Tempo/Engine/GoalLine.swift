import Foundation

/// What the app says about the athlete's goal — on the Progress card and in the coach's
/// context — as a pure function of the goal it actually has.
///
/// The third of the Chicago fallbacks (#44), and the same species as the countdown constant
/// that became `RaceCountdown` (#36): a value from the beta-of-one reference athlete, left
/// in the no-goal branch and presented as if it were the user's own.
///
/// Two of them survived that fix. The Progress card printed `"3:15:00"` under the label
/// **Goal** whenever there was no goal — directly beside a projection that renders `—:—:—`
/// in the same state, so one screen showed a dash for the thing it did not know and a
/// confident number for the thing it also did not know. And `coachContext` handed the model
/// a sentence asserting sub-3:15 at Chicago and "rebuilding from a small base" before any
/// goal existed: that is the onboarding path, the one moment the coach is supposed to read
/// the history and *propose* a goal, and it was being given the conclusion instead.
///
/// So, as in `RaceCountdown`, there is no fallback goal here on purpose. Every case that
/// cannot name a real target says so — in dashes on screen, in words to the coach — because
/// a borrowed number reads as authoritative and an empty state does not.
enum GoalLine {

    /// The Goal column when there is no target time to show. Deliberately the same string
    /// the projection beside it uses for its own empty state: the two sit on one card, and
    /// they should be visibly equally ignorant, not one dashed and one confident.
    static let unknownFinish = "—:—:—"

    /// Used when a goal exists but carries no race name. Matches `RaceCountdown`, PlanView
    /// and YouView.
    static let unnamedRace = "Race"

    /// What the app knows about the goal. `goal_time_seconds` and `race_date` are both
    /// nullable on the goal row, so "there is a goal" and "there is a target time" are
    /// genuinely different states and the old code collapsed them.
    enum State: Equatable {
        /// No goal row at all — the pre-onboarding state.
        case noGoal
        /// A goal, but no target finish time on it yet.
        case untimed(race: String, on: String?)
        case timed(race: String, on: String?, seconds: Int)

        /// The target time, when there is one. The Progress card's "on track" / "behind
        /// goal" tag and its caption both need the number, and they have to agree with the
        /// Goal column beside them about whether it exists at all.
        var seconds: Int? {
            guard case .timed(_, _, let seconds) = self else { return nil }
            return seconds
        }

        /// The Progress card's Goal column.
        var finishTime: String {
            switch self {
            case .noGoal, .untimed:
                return GoalLine.unknownFinish
            case .timed(_, _, let seconds):
                return PaceModel.formatFinish(seconds)
            }
        }

        /// The `goal` field of the coach's context.
        ///
        /// The no-goal case keeps the instruction the old fallback trailed after itself
        /// ("assess and propose one") and drops the assertion it trailed *from*. Nothing
        /// here names a race or a time the athlete has not chosen.
        var coachLine: String {
            switch self {
            case .noGoal:
                return "No goal set yet — assess the run history and propose one when the athlete is ready."
            case .untimed(let race, let on):
                guard let on else {
                    return "\(race) — no race date or target time set yet."
                }
                return "\(race) on \(on) — no target time set yet."
            case .timed(let race, let on, let seconds):
                let target = "target \(PaceModel.formatFinish(seconds))"
                guard let on else { return "\(race), \(target)" }
                return "\(race) on \(on), \(target)"
            }
        }
    }

    /// `raceName`, `raceDate` and `goalTimeSeconds` come straight off `RunStore.goal`; pass
    /// `nil` for the whole goal when there is none.
    ///
    /// An empty race name is no name and an empty race date is no date — `GoalInfo.raceDate`
    /// turns a null column into `""`, which the old coach line interpolated verbatim as
    /// "Race on , target …".
    static func state(raceName: String?, raceDate: String?, goalTimeSeconds: Int?, hasGoal: Bool) -> State {
        guard hasGoal else { return .noGoal }
        let race = raceName.flatMap { $0.isEmpty ? nil : $0 } ?? unnamedRace
        let on = raceDate.flatMap { $0.isEmpty ? nil : $0 }
        // A goal time of zero is not a goal time. It is what `?? 0` used to produce, which
        // reached the coach as "target 0:00:00" — the same lie in a different font.
        guard let seconds = goalTimeSeconds, seconds > 0 else {
            return .untimed(race: race, on: on)
        }
        return .timed(race: race, on: on, seconds: seconds)
    }
}
