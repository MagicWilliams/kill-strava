import Foundation

/// Where a training block is in its life — a pure function of the goal, its plan and the
/// moment you ask (#100).
///
/// Until this existed Tempo had no idea a block could *end*. Chicago was 11 Oct 2026; on the
/// 12th the goal was still "active" with a race date in the past, the plan had simply run out
/// of sessions, and Today offered a rest day as if the next build started tomorrow. Nothing
/// looked back at sixteen weeks of work.
///
/// The phase is what lets Today ask the question at the right moment. Deliberately, nothing
/// here *closes* a block: `.racePassed` lasts until the athlete says the block is over. A race
/// date passing is evidence, not a decision — he may want to log the result first, or a race
/// may have been postponed and the date not yet moved.
enum BlockLifecycle {

    enum Phase: Equatable {
        /// Building toward a race more than a week out, or toward no dated race at all.
        case training
        /// The last seven days, race day included.
        case raceWeek
        /// From the day after race day (local) until the athlete closes the block.
        case racePassed
        /// The athlete closed it: the goal records an outcome, or its plan is done.
        case closed
    }

    /// Days before the race, race day included, that count as race week.
    static let raceWeekDays = 7

    /// - Parameters:
    ///   - goal: the block's goal. `completed_at` or `outcome` on it means closed.
    ///   - plan: its plan, when known. `status == "done"` also means closed — a plan stood
    ///     down without the goal being closed (a regeneration, 0010) is not a block to review.
    ///   - now: the moment asked about. Compared by **local calendar day**: `race_date` is a
    ///     date with no time, parsed at local midnight (`PlanDates.day`), so the race passes
    ///     at midnight after race day and not at some hour of the afternoon.
    static func phase(
        goal: GoalInfo,
        plan: PlanInfo?,
        now: Date,
        calendar: Calendar = .current
    ) -> Phase {
        if goal.completed_at != nil || goal.outcome != nil { return .closed }
        if plan?.status == "done" { return .closed }
        guard let raceDay = goal.raceDay else { return .training }

        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: raceDay)
        ).day ?? 0
        if days < 0 { return .racePassed }
        if days < raceWeekDays { return .raceWeek }
        return .training
    }
}
