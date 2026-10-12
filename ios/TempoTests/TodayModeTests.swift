import XCTest
@testable import Tempo

/// Chicago was 11 Oct 2026. Closing that block (#100) leaves the athlete with no active
/// plan, and until #101 every screen read that as "hasn't started": Today said "No plan
/// yet", Plan pitched a plan, Progress said the coach would propose a goal, and the coach
/// itself — handed a context with no `plan` key — went looking for a race to train for.
///
/// These pin which Today applies, and that the coach is told in words rather than left to
/// infer it from a missing key.
final class TodayModeTests: XCTestCase {

    private func goal() -> GoalInfo {
        GoalInfo(id: UUID(), race_name: "Chicago", race_date: "2026-10-11", goal_time_seconds: 11_700, distance: "marathon")
    }

    private func plan(goalID: UUID = UUID()) -> PlanInfo {
        PlanInfo(id: UUID(), goal_id: goalID, start_date: "2026-06-22", weeks: 16, status: "active")
    }

    // MARK: - The four states

    /// The mid-block case, which is what every screen assumed until now.
    func testAnActivePlanIsTraining() {
        let g = goal()
        let mode = TodayMode.resolve(goal: g, plan: plan(goalID: g.id))
        XCTAssertEqual(mode, .training)
        XCTAssertTrue(mode.showsTrainingDay)
    }

    /// The headline case: after a block is closed, and before the first one. Not an empty
    /// state with a button — its own layout.
    func testNoGoalAndNoPlanIsJustRunning() {
        let mode = TodayMode.resolve(goal: nil, plan: nil)
        XCTAssertEqual(mode, .justRunning)
        XCTAssertFalse(mode.showsTrainingDay)
    }

    /// The coach can set a goal before the plan engine has built anything. There are no
    /// sessions to show, so there is no training day to render around them.
    func testAGoalWithoutAPlanIsStillJustRunning() {
        XCTAssertEqual(TodayMode.resolve(goal: goal(), plan: nil), .justRunning)
    }

    /// `loadPlan` reads the goal with `try?` *after* the plan. One dropped request leaves a
    /// plan in hand and the goal nil, and that must not flip the athlete's whole Today to
    /// "you're not training" mid-block.
    func testAPlanWhoseGoalFailedToLoadIsStillTraining() {
        XCTAssertEqual(TodayMode.resolve(goal: nil, plan: plan()), .training)
    }

    // MARK: - Race passed (#100 supplies the phase)

    /// Nothing passes a phase yet; when block close-out does, a finished race with the plan
    /// still open gets its own mode, so #100's review card has somewhere to sit.
    func testARacePassedPhaseWithThePlanStillOpenIsRacePassed() {
        let g = goal()
        let mode = TodayMode.resolve(goal: g, plan: plan(goalID: g.id), phase: .racePassed)
        XCTAssertEqual(mode, .racePassed)
        XCTAssertFalse(mode.showsTrainingDay, "the sessions are over — no rest card forever")
    }

    /// Once the block is closed the plan is no longer active, and no stale phase can drag
    /// the athlete back out of just running.
    func testAClosedBlockIsJustRunningWhateverThePhaseSays() {
        XCTAssertEqual(TodayMode.resolve(goal: nil, plan: nil, phase: .racePassed), .justRunning)
    }

    func testATrainingPhaseChangesNothing() {
        XCTAssertEqual(TodayMode.resolve(hasGoal: true, hasPlan: true, phase: .training), .training)
    }

    // MARK: - What the coach is told

    func testCoachModeNamesJustRunningExplicitly() {
        XCTAssertEqual(TodayMode.justRunning.coachMode, "just_running")
        XCTAssertEqual(TodayMode.training.coachMode, "training")
        // No prompt rule for a passed race yet; an unexplained value would be noise.
        XCTAssertEqual(TodayMode.racePassed.coachMode, "training")
    }

    /// End to end through the encoder: the field the prompt rule keys on is actually on the
    /// wire, and it follows the plan.
    @MainActor
    func testTheCoachContextCarriesTheModeOnTheWire() throws {
        let store = RunStore()
        XCTAssertEqual(try wireMode(store.coachContext()), "just_running")

        let g = goal()
        store.goal = g
        store.plan = plan(goalID: g.id)
        XCTAssertEqual(try wireMode(store.coachContext()), "training")
    }

    private func wireMode(_ context: CoachContext) throws -> String? {
        let data = try JSONEncoder().encode(context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["mode"] as? String
    }
}
