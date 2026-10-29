import XCTest
@testable import Tempo

/// #238 (#232 3A): "I'm not racing it anymore" had nowhere to go.
///
/// A goal could be raced and closed out (#100) or replaced by a new create_plan, and that was
/// all. An athlete dropping the Turkey Trot kept its plan on Today and in the coach's context
/// every morning. The coach's `end_goal` card now closes the block, and these pin what that
/// Confirm writes and says. Both regress quietly: an invented status the rest of the app
/// can't read, or a card promising a write that will touch nothing.
final class GoalRetirementTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func goal(name: String? = "Turkey Trot", raceDay: Date?) -> GoalInfo {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return GoalInfo(id: UUID(), race_name: name, race_date: raceDay.map(f.string(from:)), goal_time_seconds: nil)
    }

    private func plan(for goal: GoalInfo) -> PlanInfo {
        PlanInfo(id: UUID(), goal_id: goal.id, start_date: "2026-10-19", weeks: 6, status: "active")
    }

    // MARK: - Which closed state

    /// Before race day is the state 0013 already names for it: given up before race day.
    func testDroppingBeforeRaceDayIsAbandoned() {
        let raceDay = at(2026, 11, 27)
        XCTAssertEqual(GoalRetirement.outcome(raceDay: raceDay, now: at(2026, 10, 29), calendar: cal), .abandoned)
        // 11pm the night before is still before race day.
        XCTAssertEqual(GoalRetirement.outcome(raceDay: raceDay, now: at(2026, 11, 26, 23), calendar: cal), .abandoned)
    }

    /// From race day on it is a race they did not start. That includes the morning of it:
    /// `race_date` has no time, so race day is not "before race day" at any hour.
    func testDroppingOnOrAfterRaceDayIsDidNotStart() {
        let raceDay = at(2026, 11, 27)
        XCTAssertEqual(GoalRetirement.outcome(raceDay: raceDay, now: at(2026, 11, 27, 6), calendar: cal), .didNotStart)
        XCTAssertEqual(GoalRetirement.outcome(raceDay: raceDay, now: at(2026, 12, 2), calendar: cal), .didNotStart)
    }

    func testNoRaceDateIsAbandoned() {
        XCTAssertEqual(GoalRetirement.outcome(raceDay: nil, now: at(2026, 10, 29), calendar: cal), .abandoned)
    }

    /// No new states. The outcome must be one the 0013 check constraint accepts, and the patch
    /// must be the close-out's own, so the closed block reads as `.closed` everywhere.
    func testItClosesTheBlockTheWayTheCloseoutDoes() throws {
        let g = goal(raceDay: at(2026, 11, 27))
        let p = plan(for: g)
        let now = at(2026, 10, 29)
        let r = try XCTUnwrap(GoalRetirement.retirement(goal: g, plan: p, now: now, calendar: cal))
        XCTAssertEqual(r.goal, g)
        XCTAssertEqual(r.planID, p.id)
        XCTAssertEqual(r.outcome, .abandoned)

        let patch = try BlockCloseout.goalPatch(outcome: r.outcome, finishS: nil, raceRunID: nil, now: now)
        XCTAssertFalse(patch.is_active)
        XCTAssertEqual(patch.outcome, "abandoned")
        XCTAssertNil(patch.result_time_s, "there is no result to record")
        XCTAssertEqual(BlockCloseout.PlanPatch().status, "done")

        // What the app reads back afterwards: closed, and Today is just running again.
        var closed = g
        closed.completed_at = now
        closed.outcome = patch.outcome
        XCTAssertEqual(BlockLifecycle.phase(goal: closed, plan: nil, now: now, calendar: cal), .closed)
        XCTAssertEqual(TodayMode.resolve(goal: nil, plan: nil), .justRunning)
    }

    /// A "no plan, just coaching" goal (#102) is still a goal to drop.
    func testAGoalWithNoPlanIsStillRetired() throws {
        let r = try XCTUnwrap(GoalRetirement.retirement(goal: goal(raceDay: at(2026, 11, 27)), plan: nil, now: at(2026, 10, 29), calendar: cal))
        XCTAssertNotNil(r.goal)
        XCTAssertNil(r.planID)
    }

    /// Nothing active: Confirm refuses rather than reporting "Applied" over a write that
    /// touched nothing.
    func testNothingActiveIsNothingToEnd() {
        XCTAssertNil(GoalRetirement.retirement(goal: nil, plan: nil, now: at(2026, 10, 29), calendar: cal))
    }

    // MARK: - What the card says

    func testTheCardSaysWhatWillHappen() {
        let g = goal(raceDay: at(2026, 11, 27))
        XCTAssertEqual(GoalRetirement.cardLine(goal: g, plan: plan(for: g)),
                       "Ends your Turkey Trot plan. Your runs stay; Today goes back to just running.")
    }

    /// With no plan, Today is already the feed; promising it "goes back" would be untrue.
    func testAPlanlessGoalSaysOnlyTheGoalEnds() {
        XCTAssertEqual(GoalRetirement.cardLine(goal: goal(raceDay: at(2026, 11, 27)), plan: nil),
                       "Ends your Turkey Trot goal. Your runs stay.")
    }

    func testAnUnnamedRaceIsYourCurrentPlan() {
        let g = goal(name: "  ", raceDay: nil)
        XCTAssertEqual(GoalRetirement.cardLine(goal: g, plan: plan(for: g)),
                       "Ends your current plan. Your runs stay; Today goes back to just running.")
        XCTAssertEqual(GoalRetirement.cardLine(goal: nil, plan: nil), GoalRetirement.nothingToEnd)
    }

    // MARK: - The card itself

    /// The coach only offers end_goal to a build that names this string (`coach/goal_lifecycle.ts`).
    func testTheFeatureStringMatchesTheCoach() {
        XCTAssertEqual(GoalRetirement.coachFeature, "end_goal")
        XCTAssertEqual(GoalRetirement.actionType, "end_goal")
    }

    func testTheCardDecodesWithAndWithoutAReason() throws {
        let with = try JSONDecoder().decode(ProposedAction.self, from: Data(
            #"{"type":"end_goal","summary":"End my Turkey Trot plan","reason":"Hamstring flared up; not worth racing on it."}"#.utf8
        ))
        XCTAssertEqual(with.type, "end_goal")
        XCTAssertEqual(with.reason, "Hamstring flared up; not worth racing on it.")
        let without = try JSONDecoder().decode(ProposedAction.self, from: Data(#"{"type":"end_goal","summary":"End my Turkey Trot plan"}"#.utf8))
        XCTAssertNil(without.reason)
        XCTAssertEqual(without.displaySummary, "End my Turkey Trot plan")
    }

    /// "What changed" lists it as a plan change, with the athlete's reason when there was one.
    func testTheLedgerListsItAsAPlanChange() throws {
        let action = try JSONDecoder().decode(ProposedAction.self, from: Data(
            #"{"type":"end_goal","summary":"End my Turkey Trot plan","reason":"Not racing it anymore."}"#.utf8
        ))
        let entries = ChangeLedger.entries(from: [
            ChangeLedger.Record(messageID: UUID(), date: at(2026, 10, 29), text: "Done.", action: action),
        ])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.kind, .plan)
        XCTAssertEqual(entry.title, "Goal ended")
        XCTAssertEqual(entry.target, .plan)
        XCTAssertEqual(entry.changes.map(\.after), ["Not racing it anymore."])
    }
}
