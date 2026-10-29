import Foundation

/// The goal time Tempo suggests for a "PR" or "Not sure" goal — pure, no I/O (#239).
///
/// Rule 3 (kept 2026-10-15): numbers come from code, words come from the model. Until this
/// existed, the intake told the coach to "propose a target from the data", and whatever it
/// proposed went into `create_plan.goal_time_s`, which is the pace basis for every training
/// pace in the block. A number the athlete trains on for months was the model's guess.
///
/// So code proposes, and the coach explains. The suggestion is the current projection
/// (`ProjectionHistory`, the same number the Progress card shows) improved by a fixed amount
/// per week of block left, and a range around it. The coach may offer the target, a value in
/// the range (a round number, a more or less ambitious line), or the athlete's own stated
/// time. `supabase/functions/coach/goal_guard.ts` rejects anything else.
enum SuggestedGoal {

    // MARK: - Constants

    /// How much faster, as a fraction of the projection, one week of training makes a goal.
    ///
    /// **A placeholder until the fitness spike (#234) lands.** 0.25% a week is ~3% over a
    /// 12-week block: a 3:30 marathon projection suggests ~3:23:42, a 20:00 5K ~19:24. That is
    /// a conservative middle of what coaches expect from a structured block, chosen so the
    /// suggestion is never the reason a block is over-reached. When #234 measures how this
    /// athlete actually responds to training, replace the constant, not the shape.
    static let improvementPerWeek = 0.0025

    /// Weeks of improvement credited at most. A 40-week runway does not make a runner 10%
    /// faster; past a long block the linear rate stops meaning anything. 24 weeks is longer
    /// than any block the plan engine builds by default, so every real block sits on the
    /// slope, and 6, 12 and 20 weeks all suggest different times.
    static let maxImprovementWeeks = 24

    /// Half-width of the range, as a fraction of the target. Also a placeholder for #234.
    ///
    /// The range exists so the coach can choose words without choosing a new number: "call it
    /// 3:25" when the target is 3:23:42, or a firmer line for an athlete on the ambitious dial.
    /// 2% is ±4 min on a 3:24 marathon and ±23 s on a 19:24 5K. On a 12-week block the slow
    /// end lands almost exactly on the current projection, so nothing in the range is slower
    /// than the athlete already is.
    static let rangeSpread = 0.02

    // MARK: - The suggestion

    /// The block-length-scaled improvement for `weeksToRace` weeks, as a fraction.
    /// Zero for a race this week or behind us; capped at `maxImprovementWeeks`.
    static func improvement(weeksToRace: Int) -> Double {
        Double(min(max(weeksToRace, 0), maxImprovementWeeks)) * improvementPerWeek
    }

    /// The suggested finish time and the range the coach may choose from, in seconds, or nil
    /// when there is nothing to suggest from.
    ///
    /// Nil without a projection is the important case. No qualifying run in six weeks (right
    /// after a race, a long layoff) is exactly when the intake used to have the coach invent a
    /// target "from the data". Now there is no number, so there is no target: the coach passes
    /// the goal type with no `goal_time_s` and the plan engine paces from current fitness.
    ///
    /// `distanceM` is the race the projection was made for. The rate is the same at every
    /// distance today; it is asked for so no caller can hand over a projection without saying
    /// which race it is, and so per-distance tuning from #234 has somewhere to go.
    static func suggestedGoalTime(
        projectionS: Double?,
        weeksToRace: Int,
        distanceM: Double
    ) -> (target: Int, range: ClosedRange<Int>)? {
        guard let projectionS, projectionS.isFinite, projectionS > 0,
              distanceM.isFinite, distanceM > 0 else { return nil }
        let target = projectionS * (1 - improvement(weeksToRace: weeksToRace))
        let fast = Int((target * (1 - rangeSpread)).rounded())
        let slow = Int((target * (1 + rangeSpread)).rounded())
        return (Int(target.rounded()), fast...slow)
    }

    // MARK: - Which race

    /// The race a suggestion is for: the intake being answered, then the active goal.
    ///
    /// The intake comes first because that is where the coach sets a goal: its race is the one
    /// the next `create_plan` is for, and it may be a different race from the active goal.
    /// Nil with no race date, or with a race already run: there is no block left to improve
    /// over, and the coach has no goal to set until the athlete names the next one.
    static func race(
        intake: IntakeStamp?,
        goal: GoalInfo?,
        now: Date,
        calendar: Calendar = RaceCountdown.calendar
    ) -> (meters: Double, raceDate: String, weeks: Int)? {
        let picked: (meters: Double, raceDate: String)?
        if let intake {
            picked = (Double(intake.distance_m), intake.race_date)
        } else if let goal, let date = goal.race_date {
            picked = (ProjectionHistory.raceMeters(goal: goal), date)
        } else {
            picked = nil
        }
        guard let picked, picked.meters > 0,
              let raceDay = day(picked.raceDate, calendar: calendar) else { return nil }
        let weeks = RaceCountdown.weeksRemaining(from: now, to: raceDay, calendar: calendar)
        guard weeks >= 1 else { return nil }
        return (picked.meters, picked.raceDate, weeks)
    }

    /// `yyyy-MM-dd` at midnight in `calendar`'s time zone: `PlanDates.day`, made to agree with
    /// the calendar the weeks are counted in, so a test in UTC and a phone in Chicago count
    /// the same race the same way.
    private static func day(_ iso: String, calendar: Calendar) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)
    }

    // MARK: - The coach's copy

    /// `<athlete_context>.suggested_goal`, or nil — and nil means absent, never empty.
    ///
    /// `distance_m` and `race_date` say which race the numbers are for. The coach can change
    /// the race mid-conversation ("make it the half"), and a range for the marathon would be
    /// a wrong number to hold a half to; the guard only applies the range to its own race.
    static func coachContext(
        runs: [RunSummary],
        race: (meters: Double, raceDate: String, weeks: Int)?,
        asOf: Date,
        calendar: Calendar = ProjectionHistory.calendar
    ) -> SuggestedGoalCoachContext? {
        guard let race,
              let projection = ProjectionHistory.projection(runs, asOf: asOf, raceMeters: race.meters, calendar: calendar),
              let suggestion = suggestedGoalTime(
                  projectionS: Double(projection.finishS), weeksToRace: race.weeks, distanceM: race.meters
              ) else { return nil }

        let run = projection.run
        let pace = run.paceSecPerMile.map { " at \(PaceModel.format($0))/mi" } ?? ""
        let percent = String(format: "%.1f", improvement(weeksToRace: race.weeks) * 100)
        let basis = "Current projection \(IntakeAnswers.finishTime(projection.finishS)) for this race, "
            + "from the fastest qualifying run in the last \(ProjectionHistory.windowDays) days "
            + "(\(String(format: "%.1f", run.miles)) mi\(pace)). "
            + "\(race.weeks) week\(race.weeks == 1 ? "" : "s") to race day at a placeholder "
            + "\(String(format: "%.2f", improvementPerWeek * 100))% a week is \(percent)% faster."

        return SuggestedGoalCoachContext(
            target_s: suggestion.target,
            range_s: [suggestion.range.lowerBound, suggestion.range.upperBound],
            distance_m: Int(race.meters.rounded()),
            race_date: race.raceDate,
            basis: basis
        )
    }
}

/// `<athlete_context>.suggested_goal` (#239). `range_s` is `[fastest, slowest]` in seconds.
struct SuggestedGoalCoachContext: Encodable, Equatable {
    let target_s: Int
    let range_s: [Int]
    let distance_m: Int
    let race_date: String
    let basis: String
}
