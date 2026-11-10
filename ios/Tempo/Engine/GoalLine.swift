import Foundation

/// What the app says about the athlete's goal (on the Progress card and in the coach's
/// context) as a pure function of the goal it actually has.
///
/// The third of the Chicago fallbacks (#44), and the same species as the countdown constant
/// that became `RaceCountdown` (#36): a value from the beta-of-one reference athlete, left
/// in the no-goal branch and presented as if it were the user's own.
///
/// Two of them survived that fix. The Progress card printed `"3:15:00"` under the label
/// **Goal** whenever there was no goal, directly beside a projection that renders an empty
/// placeholder in the same state, so one screen showed a dash for the thing it did not know
/// and a confident number for the thing it also did not know. And `coachContext` handed the model
/// a sentence asserting sub-3:15 at Chicago and "rebuilding from a small base" before any
/// goal existed: that is the onboarding path, the one moment the coach is supposed to read
/// the history and *propose* a goal, and it was being given the conclusion instead.
///
/// So, as in `RaceCountdown`, there is no fallback goal here on purpose. Every case that
/// cannot name a real target says so (in dashes on screen, in words to the coach) because
/// a borrowed number reads as authoritative and an empty state does not.
enum GoalLine {

    /// The Goal column when there is no target time to show. Deliberately the same string
    /// the projection beside it uses for its own empty state: the two sit on one card, and
    /// they should be visibly equally ignorant, not one dashed and one confident.
    static let unknownFinish = "--:--:--"

    /// Used when a goal exists but carries no race name. Matches `RaceCountdown`, PlanView
    /// and YouView.
    static let unnamedRace = "Race"

    /// What the app knows about the goal. `goal_time_seconds` and `race_date` are both
    /// nullable on the goal row, so "there is a goal" and "there is a target time" are
    /// genuinely different states and the old code collapsed them.
    enum State: Equatable {
        /// No goal row at all: the pre-onboarding state.
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
                return "No goal set yet. Assess the run history and propose one when the athlete is ready."
            case .untimed(let race, let on):
                guard let on else {
                    return "\(race): no race date or target time set yet."
                }
                return "\(race) on \(on): no target time set yet."
            case .timed(let race, let on, let seconds):
                let target = "target \(PaceModel.formatFinish(seconds))"
                guard let on else { return "\(race), \(target)" }
                return "\(race) on \(on), \(target)"
            }
        }
    }

    // MARK: - The You tab's goal card (#231)

    /// The second line of the goal card, under the race label, when the goal has no target
    /// time. Named rather than inlined so the card and its tests cannot drift apart.
    static let noTargetTime = "no target time"

    /// The goal-type phrase, for the types that say something the date and the distance
    /// don't.
    ///
    /// Nil for the three that add nothing: `unsure` is what the coach saves when the athlete
    /// didn't state a target (it is the value David's 27 Nov tune-up actually carries),
    /// `time` is a time goal with no time on it (a contradiction, and printing "A time"
    /// beside no time would read as a promise) and nil is every goal written before the
    /// intake (#102).
    static func goalTypePhrase(_ goalType: String?) -> String? {
        guard let type = IntakeAnswers.GoalType(rawValue: goalType ?? "") else { return nil }
        switch type {
        case .finish: return "Just finish"
        case .pr:     return "Chasing a PR"
        case .time, .unsure: return nil
        }
    }

    /// What the card says under the race label when there is no target time: "Nov 27 · no
    /// target time", "Just finish · Nov 27", "Chasing a PR · Nov 27 · no target time".
    ///
    /// The scar: on 15 Oct the You tab's subtitle read "Race · 6 weeks out" and the card
    /// directly beneath it read "No goal yet. The coach proposes one from your data", with a
    /// Talk to Coach button. Both on screen at once. There *was* a goal: the 27 Nov tune-up,
    /// `goal_type = "unsure"`, no `goal_time_seconds`, which is deliberate for a race with no
    /// target. The card branched on the target time, so a goal without one read as no goal at
    /// all, exactly the collapse `State.untimed` was split out to prevent (#44), one screen
    /// late.
    ///
    /// So the line states what is known and names the one thing that is missing, instead of
    /// offering to set a goal that already exists.
    ///
    /// `on` is race day already formatted for the card ("Nov 27"), nil when the goal carries
    /// no date. A phrase rather than a `switch` in the view, so the tune-up word (#232) plugs
    /// in here when it lands.
    static func untimedLine(goalType: String?, on raceDate: String?) -> String {
        var parts: [String] = []
        if let phrase = goalTypePhrase(goalType) { parts.append(phrase) }
        if let raceDate, !raceDate.isEmpty { parts.append(raceDate) }
        // "Just finish" *is* the goal; there is no target time absent from it, and saying so
        // would read as a gap rather than as the athlete's choice. Every other type is
        // waiting on a number the coach has not proposed yet, and the card should say which.
        if goalType != IntakeAnswers.GoalType.finish.rawValue { parts.append(noTargetTime) }
        let line = parts.joined(separator: " · ")
        guard let first = line.first else { return line }
        return first.uppercased() + String(line.dropFirst())
    }

    /// The goal's distance as the intake form names it ("5K", "Half", "Marathon") keyed by
    /// metres off `IntakeAnswers.Distance` rather than a second hand-written table, so the
    /// label and the math read one number. A distance that is none of them (a custom 30K) is
    /// spelled out in the athlete's own unit.
    static func distanceLabel(raceMeters: Double, units: Units) -> String {
        // Within 1%: a half arrives as 21,097 or 21,098 and a mile as 1,609 or 1,609.34,
        // depending which of the app's constants wrote it.
        let known = IntakeAnswers.Distance.allCases.first { d in
            d.meters.map { abs(raceMeters - Double($0)) / Double($0) < 0.01 } ?? false
        }
        return known?.label ?? units.formatDistance(meters: raceMeters, decimals: 1)
    }

    /// "Turkey Trot · 5K": the title of the goal card, the race named once with its
    /// distance. Nil only when there is no goal.
    ///
    /// The card used to title itself `"<time> · <race name>"`, which named no distance at
    /// all. That silence is how a 5K saved as a marathon (#215) sat on the You tab for two
    /// weeks with nothing on screen contradicting it: "Race" is equally true of both. The
    /// metres come from `RaceRecap.raceMeters(goal:)` (the same reading TARGET and PROJECTED
    /// use) so the title cannot name one race while the numbers beneath it answer for
    /// another.
    ///
    /// The distance is left off a name that already carries it: "Chicago Marathon", not
    /// "Chicago Marathon · Marathon". A goal with no name reads "Marathon race" rather than a
    /// bare "Race", because a goal always has a distance even when it has no name.
    ///
    /// **Overlap note.** #230 (PR #249, open and green when this was written) adds
    /// `RaceCountdown.raceLabel` with this same rule, keyed the same way, for the three tab
    /// subtitles. Whichever lands second should delete its copy and call the other; both
    /// suites pin the same strings, so the fold is mechanical.
    static func raceLabel(goal: GoalInfo?, units: Units) -> String? {
        guard let goal else { return nil }
        let distance = distanceLabel(raceMeters: RaceRecap.raceMeters(goal: goal), units: units)
        guard let name = goal.raceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return "\(distance) race"
        }
        return name.localizedCaseInsensitiveContains(distance) ? name : "\(name) · \(distance)"
    }

    /// The You tab goal card's **TARGET**: the goal time spread over the goal's own distance,
    /// in the athlete's unit. Units.missing when the goal has no target time.
    ///
    /// This used to be `PaceModel.paces(for: .marathon, goalSeconds:).marathon`, which reads
    /// every goal time as a *marathon* time and divides it over 26.2, so a 25:00 5K goal
    /// showed a target of 0:57 /mi (#188). It is not a Riegel equivalent either: the target
    /// is the pace the athlete has to hold on race day, which is plain time over distance.
    ///
    /// The distance is `ProjectionHistory.raceMeters(goal:)`, the same reading the projected
    /// finish beside it uses (#185), so TARGET and PROJECTED always answer for one race.
    static func targetPace(goal: GoalInfo?, units: Units) -> String {
        guard let seconds = goal?.goalTimeSeconds, seconds > 0 else { return Units.missing }
        return units.formatPace(seconds: Double(seconds), meters: ProjectionHistory.raceMeters(goal: goal))
    }

    /// `raceName`, `raceDate` and `goalTimeSeconds` come straight off `RunStore.goal`; pass
    /// `nil` for the whole goal when there is none.
    ///
    /// An empty race name is no name and an empty race date is no date, `GoalInfo.raceDate`
    /// turns a null column into `""`, which the old coach line interpolated verbatim as
    /// "Race on , target …".
    static func state(raceName: String?, raceDate: String?, goalTimeSeconds: Int?, hasGoal: Bool) -> State {
        guard hasGoal else { return .noGoal }
        let race = raceName.flatMap { $0.isEmpty ? nil : $0 } ?? unnamedRace
        let on = raceDate.flatMap { $0.isEmpty ? nil : $0 }
        // A goal time of zero is not a goal time. It is what `?? 0` used to produce, which
        // reached the coach as "target 0:00:00". The same lie in a different font.
        guard let seconds = goalTimeSeconds, seconds > 0 else {
            return .untimed(race: race, on: on)
        }
        return .timed(race: race, on: on, seconds: seconds)
    }
}
