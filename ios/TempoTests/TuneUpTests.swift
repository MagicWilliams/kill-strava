import XCTest
@testable import Tempo

/// #238 (#232 1A): the Turkey Trot is a tune-up, and until now nothing could say so.
///
/// On 15 Oct the athlete told the coach the race was a tune-up. The coach saved `goal_type:
/// "unsure"` and kept the rest in chat, so the You tab could only call it a goal it couldn't
/// describe (#231). The role now rides on the create_plan card as `race_role`, lands in
/// `goals.preferences.race_role`, and is read back by the You card, the confirm card and the
/// plan narration.
///
/// Every way this regresses is a quiet word: "tune-up" missing from a card that set it, or
/// worse, a settings change that rebuilds the plan and silently turns the tune-up back into
/// the goal race.
final class TuneUpTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var today: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))! }

    private func card(_ json: String) throws -> ProposedAction {
        try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
    }

    private func goal(_ json: String) throws -> GoalInfo {
        try JSONDecoder().decode(GoalInfo.self, from: Data(json.utf8))
    }

    /// The Turkey Trot row once a tune-up card has been confirmed.
    private func turkeyTrot(role: String? = "tune_up") throws -> GoalInfo {
        let prefs = role.map { #","preferences":{"v":1,"plan_style":"full","race_role":"\#($0)"}"# } ?? ""
        return try goal("""
        {"id":"\(UUID().uuidString)","race_name":"Turkey Trot","race_date":"2026-11-27",
         "goal_time_seconds":null,"distance":"5k","distance_m":5000,"goal_type":"unsure"\(prefs)}
        """)
    }

    // MARK: - Reading the role

    func testMissingMeansGoal() throws {
        XCTAssertEqual(RaceRole.of(nil), .goal, "every goal before #238 was the race its block was for")
        XCTAssertEqual(RaceRole.of(GoalPreferences(plan_style: "full")), .goal)
        XCTAssertEqual(try turkeyTrot(role: nil).raceRole, .goal)
        XCTAssertNil(RaceRole.goal.label, "an ordinary goal race prints no role")
    }

    func testTheStoredTuneUpReadsBackAsOne() throws {
        XCTAssertEqual(try turkeyTrot().raceRole, .tuneUp)
        XCTAssertEqual(RaceRole.tuneUp.label, "tune-up")
    }

    /// Read the way `plan`'s `goal.ts raceRole` reads it, so the two sides never disagree.
    func testSpellingsAreOneAnswerAndNonsenseIsNone() {
        for wire in ["tune_up", "tune-up", "Tune up", " TUNEUP "] {
            XCTAssertEqual(RaceRole(wire: wire), .tuneUp, wire)
        }
        XCTAssertEqual(RaceRole(wire: "goal"), .goal)
        for wire in [nil, "", "warmup", "a race"] as [String?] {
            XCTAssertNil(RaceRole(wire: wire), String(describing: wire))
        }
    }

    /// A preferences blob the goal can't make sense of must cost the role, never the goal: a
    /// goal that fails to decode reads as no goal on every screen.
    func testANonStringRoleCostsTheRoleNotTheGoal() throws {
        let g = try goal("""
        {"id":"\(UUID().uuidString)","race_name":"Turkey Trot","race_date":"2026-11-27",
         "goal_time_seconds":null,"preferences":{"v":1,"race_role":7}}
        """)
        XCTAssertEqual(g.raceName, "Turkey Trot")
        XCTAssertEqual(g.raceRole, .goal)
    }

    // MARK: - The card reaches plan

    /// "The Turkey Trot is just a tune-up": the card the coach sends, and the request it makes.
    func testATuneUpCardSendsItsRole() throws {
        let action = try card("""
        {"type":"create_plan","summary":"Save the Turkey Trot as a tune-up","race_date":"2026-11-27",
         "race_name":"Turkey Trot","distance":"5k","goal_type":"unsure","race_role":"tune_up"}
        """)
        XCTAssertEqual(action.race_role, "tune_up")
        let body = try XCTUnwrap(PlanRequest.forCreatePlanCard(
            action, goal: nil, planStartDate: nil, today: today, calendar: cal
        ))
        XCTAssertEqual(body.race_role, "tune_up")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(json["race_role"] as? String, "tune_up")
        XCTAssertEqual(body.cardLine(calendar: cal), "5K · Turkey Trot · Nov 27 · tune-up",
                       "the card shows what the payload says, not just what the summary claims")
    }

    /// A card with no role sends none: `plan` then keeps whatever the same race already had.
    func testACardWithoutARoleSendsNone() throws {
        let action = try card(#"{"type":"create_plan","race_date":"2027-04-20","distance":"marathon","goal_time_s":11400,"summary":"x"}"#)
        let body = try XCTUnwrap(PlanRequest.forCreatePlanCard(action, goal: nil, planStartDate: nil, today: today, calendar: cal))
        XCTAssertNil(body.race_role)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertNil(json["race_role"], "omitted, not sent as null")
        XCTAssertFalse(body.cardLine(calendar: cal).contains("tune-up"))
    }

    /// "Drop me to 5 days" rebuilds the plan from the goal's carried preferences. The role is
    /// in them, so the rebuilt block is still a tune-up.
    func testARegenerationCarriesTheRole() throws {
        let trot = try turkeyTrot()
        var body = PlanRequest.carryingForward(
            goal: trot, planStartDate: "2026-10-19", goalTimeS: nil,
            raceName: trot.raceName, raceDate: trot.raceDate, today: today, calendar: cal
        )
        XCTAssertEqual(body.preferences?.race_role, "tune_up")
        XCTAssertEqual(body.raceRole, .tuneUp)
        // And the card's own role, when it names one, wins: "it's my goal race now".
        body.race_role = "goal"
        XCTAssertEqual(body.raceRole, .goal)
    }

    /// An intake card has no role of its own (the form never asks), but the coach's card can.
    func testTheCardsRoleRidesOnAnIntakeCardToo() throws {
        var answers = IntakeAnswers()
        answers.distance = .fiveK
        answers.raceName = "Turkey Trot"
        answers.raceDate = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 12))
        answers.goalType = .unsure
        let stamp = try XCTUnwrap(answers.stamp(today: today, calendar: cal))
        let echoed = try card(#"{"type":"create_plan","goal_type":"unsure","race_date":"2026-11-27","race_role":"tune_up","summary":"x"}"#)
        let stamped = IntakeHandoff.stamping(echoed, with: IntakeHandoff(answers: answers, stamp: stamp))
        let body = try XCTUnwrap(PlanRequest.forCreatePlanCard(stamped, goal: nil, planStartDate: nil, today: today, calendar: cal))
        XCTAssertEqual(body.race_role, "tune_up")
        XCTAssertEqual(body.distance, "5k")
    }

    // MARK: - The narration

    func testATuneUpPlanSaysSoInItsFirstWords() {
        let line = PlanNarration.planIsLive(PlanNarration.PlanResult(
            weeks: 4, archetype: "sharpen", raceRole: .tuneUp
        ))
        XCTAssertEqual(line, "Tune-up plan is live: 4 weeks (sharpen).")
    }

    /// The role comes from what `plan` reported storing. A `plan` that predates #238 reports
    /// none, and the line stays exactly what it always was rather than claiming a tune-up the
    /// row doesn't hold.
    func testAGoalPlanReadsAsItAlwaysDid() {
        XCTAssertEqual(PlanNarration.planIsLive(PlanNarration.PlanResult(weeks: 16, archetype: "base_build")),
                       "Plan is live: 16 weeks (base build).")
    }
}
