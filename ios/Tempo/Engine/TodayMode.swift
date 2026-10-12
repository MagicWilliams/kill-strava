import Foundation

/// Which Today the athlete gets — a pure function of the goal and plan the app holds.
///
/// Until #101 there was only one Today, built around a training plan, and every way of not
/// having one fell through to a "No plan yet" card with a button. That was fine while the
/// only path to the app ran through onboarding into a plan. It stopped being fine the day
/// the first block ended: Chicago was 11 Oct 2026, and the athlete it was built for walked
/// out of a 16-week block into a screen that treated him as someone who hadn't started.
/// Most new users start in that same state — mid-block elsewhere, between races, or just
/// curious — and it should be a good place to be, not a waiting room.
///
/// The decision lives here, not in `TodayView`, so every screen that changes shape with it
/// (Today, Plan, Progress, the coach's context) asks the same question and gets the same
/// answer.
enum TodayMode: Equatable {
    /// An active plan: today's session, the check-in, tomorrow, the week against target.
    case training
    /// Nothing to train against. Today becomes a feed of your own running — last run, the
    /// coach's latest read, freshness, the 12-week line — with a way to opt back in.
    case justRunning
    /// The race is over but the block hasn't been closed. The "review your block" card
    /// (`BlockReviewPrompt`, #100) sits on top; the sessions have run out, so underneath it
    /// the athlete gets the just-running feed rather than a rest card that never changes.
    case racePassed

    /// - Parameters:
    ///   - hasGoal: `RunStore.goal != nil`.
    ///   - hasPlan: `RunStore.plan != nil` — an *active* plan; `loadPlan` only reads those.
    ///   - phase: the block's lifecycle phase (`BlockLifecycle`), nil with no goal. Only
    ///     `.racePassed` changes the answer: race week is still training, and a closed block
    ///     has no active plan, so the plan check has already answered for it.
    ///
    /// The plan decides, not the goal. A goal without a plan has no sessions to show, so
    /// it is just running until the plan exists. A plan without a goal is a *transient*
    /// state, not a real one: `loadPlan` reads the goal with `try?` after the plan, so one
    /// failed request leaves the plan in hand and the goal nil. Flipping the athlete's whole
    /// Today to "you're not training" over a dropped packet would be a lie told loudly.
    static func resolve(hasGoal: Bool, hasPlan: Bool, phase: BlockLifecycle.Phase? = nil) -> TodayMode {
        guard hasPlan else { return .justRunning }
        if phase == .racePassed { return .racePassed }
        return .training
    }

    /// Convenience over the app's models; the rule is the `Bool` overload above.
    static func resolve(goal: GoalInfo?, plan: PlanInfo?, phase: BlockLifecycle.Phase? = nil) -> TodayMode {
        resolve(hasGoal: goal != nil, hasPlan: plan != nil, phase: phase)
    }

    /// Whether Today shows the plan-shaped layout (session, tomorrow) or the feed.
    var showsTrainingDay: Bool { self == .training }

    /// The `mode` field of `CoachContext`. The coach prompt carries one ground rule keyed on
    /// `"just_running"`: general guidance, and no asking about a race that doesn't exist.
    ///
    /// `.racePassed` has its own value and its own rule (#100): the plan and goal are still
    /// in the context, and without being told, the coach reads a finished plan as the current
    /// one and prescribes from it the morning after the marathon.
    var coachMode: String {
        switch self {
        case .training:    return "training"
        case .justRunning: return "just_running"
        case .racePassed:  return "race_passed"
        }
    }
}
