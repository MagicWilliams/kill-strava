import XCTest
@testable import Tempo

/// #184: a create_plan card whose summary said 5K, saved as a marathon.
///
/// On 2026-10-15 David confirmed "Save my goal: 5K at Turkey Trot, Nov 5, time unsure for
/// now". The card had no intake stamp (the 13 Oct intake card had failed and the handoff was
/// gone), and the create_plan tool had no distance field, so the payload named no distance.
/// The fallback request carried nothing over, since the active goal was Chicago on another
/// date, and `plan` resolved "no distance" to a marathon: `goals.distance_m = 42195`, a
/// 4:18:04 projection.
///
/// These pin the app's half of the fix. The card's own distance reaches the request, the
/// intake stamp still outranks it, and the card shows the distance Confirm will send, so a
/// card that names none can be seen before it is confirmed.
final class PlanCardDistanceTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var today: Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
    }

    private func card(_ json: String) throws -> ProposedAction {
        try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
    }

    /// The active goal on 15 Oct: Chicago, run four days earlier, still active.
    private let chicago = GoalInfo(
        id: UUID(), race_name: "Chicago", race_date: "2026-10-11", goal_time_seconds: 11_700,
        distance: "marathon", distance_m: 42_195, goal_type: "time"
    )

    private func request(_ action: ProposedAction, goal: GoalInfo?) -> PlanRequest? {
        PlanRequest.forCreatePlanCard(action, goal: goal, planStartDate: "2026-06-01", today: today, calendar: cal)
    }

    // MARK: - The payload's distance reaches plan

    /// The 15 Oct card, as the new coach tool sends it: the same payload, plus `distance`.
    func testAnUnstampedFiveKCardBuildsAFiveKRequest() throws {
        let action = try card("""
        {"type":"create_plan","summary":"Save my goal: 5K at Turkey Trot, Nov 5, time unsure for now",
         "goal_type":"unsure","race_date":"2026-11-05","race_name":"Turkey Trot 2026","distance":"5k",
         "rationale":"Fresh off Chicago."}
        """)
        XCTAssertEqual(action.distance, "5k")
        XCTAssertNil(action.intake)

        let body = try XCTUnwrap(request(action, goal: chicago))
        XCTAssertEqual(body.distance, "5k")
        XCTAssertEqual(body.distance_m, 5_000, "not the 42,195 m it was saved as")
        XCTAssertEqual(body.goal_type, "unsure")
        XCTAssertNil(body.goal_time_s)
        XCTAssertEqual(body.race_date, "2026-11-05")
    }

    /// The 15 Oct card exactly as it was: no distance anywhere. The request names none either,
    /// which is what lets `plan` refuse it (`distance_required`) instead of guessing a marathon.
    func testTheOriginalCardNamesNoDistance() throws {
        let action = try card("""
        {"type":"create_plan","summary":"Save my goal: 5K at Turkey Trot, Nov 5, time unsure for now",
         "goal_type":"unsure","race_date":"2026-11-05","race_name":"Turkey Trot 2026"}
        """)
        let body = try XCTUnwrap(request(action, goal: chicago))
        XCTAssertNil(body.distance)
        XCTAssertNil(body.distance_m)
        XCTAssertNil(body.distanceLabel, "the card has nothing to show, so it warns")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertNil(json["distance"], "omitted, never sent as a marathon")
        XCTAssertNil(json["distance_m"])
    }

    /// A label replaces the carried metres too. "10k" for the active goal's own date, with the
    /// marathon's 42,195 m carried beside it, would resolve back to a marathon, because `plan`
    /// reads metres first.
    func testThePayloadDistanceReplacesTheCarriedPairTogether() throws {
        let action = try card(#"{"type":"create_plan","goal_time_s":2700,"race_date":"2026-10-11","distance":"10k","summary":"x"}"#)
        let body = try XCTUnwrap(request(action, goal: chicago))
        XCTAssertEqual(body.distance, "10k")
        XCTAssertEqual(body.distance_m, 10_000)
    }

    /// The same race, re-proposed without a distance (a new goal time agreed in chat): the
    /// goal's own distance still carries, as it did before #184.
    func testTheSameRaceWithoutADistanceStillCarriesIt() throws {
        let action = try card(#"{"type":"create_plan","goal_time_s":11400,"race_date":"2026-10-11","summary":"x"}"#)
        let body = try XCTUnwrap(request(action, goal: chicago))
        XCTAssertEqual(body.distance, "marathon")
        XCTAssertEqual(body.distance_m, 42_195)
    }

    func testCustomMetresTravelWithTheirLabel() throws {
        let action = try card(#"{"type":"create_plan","goal_time_s":1900,"race_date":"2026-11-05","distance":"custom","distance_m":8000,"summary":"x"}"#)
        let body = try XCTUnwrap(request(action, goal: chicago))
        XCTAssertEqual(body.distance, "custom")
        XCTAssertEqual(body.distance_m, 8_000)
        XCTAssertEqual(body.distanceLabel, "8,000 m")
    }

    // MARK: - The stamp still wins

    /// The intake is what the athlete tapped; the payload is the model's echo of it. When
    /// they disagree, the tap is the truth.
    func testTheIntakeStampOutranksThePayload() throws {
        var answers = IntakeAnswers()
        answers.distance = .tenK
        answers.raceName = "Turkey Trot"
        answers.raceDate = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))
        answers.goalType = .unsure
        let stamp = try XCTUnwrap(answers.stamp(today: today, calendar: cal))

        let echoed = try card(#"{"type":"create_plan","goal_type":"unsure","race_date":"2026-11-05","distance":"5k","summary":"x"}"#)
        let stamped = IntakeHandoff.stamping(echoed, with: IntakeHandoff(answers: answers, stamp: stamp))
        let body = try XCTUnwrap(request(stamped, goal: chicago))
        XCTAssertEqual(body.distance, "10k")
        XCTAssertEqual(body.distance_m, 10_000)
        XCTAssertEqual(body.distanceLabel, "10K", "and the card shows the stamp's distance, which is what Confirm sends")
    }

    /// A card that can't be built shows no line and is refused on Confirm, as before.
    func testATimelessTimeCardStillBuildsNothing() throws {
        let action = try card(#"{"type":"create_plan","race_date":"2026-11-05","distance":"5k","summary":"x"}"#)
        XCTAssertNil(request(action, goal: chicago))
    }

    // MARK: - What the card shows

    func testTheCardLineReadsDistanceRaceAndDay() throws {
        var body = PlanRequest(goal_time_s: nil, race_name: "Turkey Trot 2026", race_date: "2026-11-05")
        XCTAssertEqual(body.cardLine(calendar: cal), "Turkey Trot 2026 · Nov 5", "no distance named, none shown")
        body.distance = "5k"
        body.distance_m = 5_000
        XCTAssertEqual(body.cardLine(calendar: cal), "5K · Turkey Trot 2026 · Nov 5")
        body.race_name = "  "
        XCTAssertEqual(body.cardLine(calendar: cal), "5K · Nov 5")
    }

    /// Metres outrank the label, as they do in `plan`; and metres `plan` would reject are not
    /// a distance to show.
    func testTheDistanceLabelReadsMetresFirst() {
        var body = PlanRequest(goal_time_s: nil, race_name: nil, race_date: "2026-11-05")
        body.distance = "marathon"
        body.distance_m = 21_097
        XCTAssertEqual(body.distanceLabel, "Half")
        body.distance_m = nil
        XCTAssertEqual(body.distanceLabel, "Marathon")
        body.distance = "custom"
        XCTAssertNil(body.distanceLabel, "custom with no metres names nothing")
        body.distance = "ultra"
        XCTAssertNil(body.distanceLabel)
        body.distance_m = 50
        XCTAssertNil(body.distanceLabel, "below what plan accepts")
    }

    // MARK: - plan's refusal

    func testThePlanRefusalIsReadFromTheErrorBody() {
        XCTAssertEqual(PlanRequest.refusal(inErrorBody: Data(#"{"error":"distance_required"}"#.utf8)), PlanRequest.distanceRequired)
        XCTAssertEqual(PlanRequest.refusal(inErrorBody: Data(#"{"error":"race is too close for a plan"}"#.utf8)), "race is too close for a plan")
        XCTAssertNil(PlanRequest.refusal(inErrorBody: Data("<html>502</html>".utf8)))
        XCTAssertNil(PlanRequest.refusal(inErrorBody: Data()))
    }
}
