import XCTest
@testable import Tempo

/// What the setup interview is told before it asks anything (#167).
///
/// 2026-10-14, simulator, a fresh staging user: "Where are you right now?" → Just running for
/// now → the coach interview. The coach opened by presenting 6 days a week and a Sunday long
/// run as settled — the profile's column defaults, which nobody had said — asked a few
/// questions, said "I'll plan to weave in strength work alongside the running", and stopped.
/// No `complete_onboarding`, no exit, the rest of the app unreachable, `onboarded_at` null.
/// These pin the two halves of what the coach is handed: where the athlete started, and
/// only the facts they actually gave.
final class OnboardingFactsTests: XCTestCase {

    // MARK: - Starting point

    /// Each step-1 answer reaches the coach under its own name. The prompt's just-running
    /// interview keys off `just_running`; a mapping that slipped would send that athlete
    /// straight back into the eight-question, plan-first interview that trapped him.
    func testEachStepOneAnswerMapsToItsStartingPoint() {
        XCTAssertEqual(OnboardingFacts.StartingPoint(.midBlock), .racingNow)
        XCTAssertEqual(OnboardingFacts.StartingPoint(.newBlock), .wantToTrain)
        XCTAssertEqual(OnboardingFacts.StartingPoint(.justRunning), .justRunning)

        XCTAssertEqual(OnboardingFacts.StartingPoint.racingNow.rawValue, "racing_now")
        XCTAssertEqual(OnboardingFacts.StartingPoint.wantToTrain.rawValue, "want_to_train")
        XCTAssertEqual(OnboardingFacts.StartingPoint.justRunning.rawValue, "just_running")
    }

    /// End to end through the encoder: choosing Just running puts `starting_point` on the wire,
    /// inside `onboarding`, where the prompt reads it.
    @MainActor
    func testJustRunningPutsTheStartingPointOnTheWire() throws {
        let store = RunStore()
        var answers = IntakeAnswers()
        answers.situation = .justRunning
        store.beginIntake(answers)

        let onboarding = try XCTUnwrap(wire(store.coachContext(onboarding: true))["onboarding"] as? [String: Any])
        XCTAssertEqual(onboarding["starting_point"] as? String, "just_running")
    }

    /// A plan card confirmed mid-interview clears the intake; the interview still has to know
    /// where the athlete started.
    @MainActor
    func testTheStartingPointOutlivesTheIntakeItCameFrom() throws {
        let store = RunStore()
        var answers = IntakeAnswers()
        answers.situation = .newBlock
        store.beginIntake(answers)
        store.finishIntake()

        let onboarding = try XCTUnwrap(wire(store.coachContext(onboarding: true))["onboarding"] as? [String: Any])
        XCTAssertEqual(onboarding["starting_point"] as? String, "want_to_train")
    }

    // MARK: - Known, without defaults

    /// The headline. A profile nobody has filled in reads 6 days, Sunday, "standard" — and
    /// none of that may be handed to the coach as something the athlete said.
    func testAFreshProfileKnowsNothingFromItsDefaults() {
        let known = OnboardingFacts.known(
            daysPerWeek: 6, longRunDay: 0, riskTolerance: "standard",
            given: [], planOnFile: false,
            maxHR: nil, birthdate: nil, activePlan: nil
        )
        XCTAssertEqual(known, [:])
    }

    /// The same check on the real store, through the encoder: a just-launched `RunStore` holds
    /// those same defaults, and the wire's `known` must be empty.
    @MainActor
    func testTheStoresDefaultsNeverReachKnownOnTheWire() throws {
        let store = RunStore()
        let onboarding = try XCTUnwrap(wire(store.coachContext(onboarding: true))["onboarding"] as? [String: Any])
        let known = try XCTUnwrap(onboarding["known"] as? [String: String])
        XCTAssertNil(known["days_per_week"])
        XCTAssertNil(known["long_run_day"])
        XCTAssertNil(known["risk_tolerance"])
    }

    /// Once the athlete answers — the interview records it, or a card is confirmed — it is
    /// known, and only what they answered.
    @MainActor
    func testAnAnsweredSettingBecomesKnown() throws {
        let store = RunStore()
        store.setPlanSettings(daysPerWeek: 4, longRunDay: nil)

        let onboarding = try XCTUnwrap(wire(store.coachContext(onboarding: true))["onboarding"] as? [String: Any])
        let known = try XCTUnwrap(onboarding["known"] as? [String: String])
        XCTAssertEqual(known["days_per_week"], "4")
        XCTAssertNil(known["long_run_day"], "the long-run day is still the default nobody chose")
        XCTAssertNil(known["risk_tolerance"])

        store.setRiskTolerance("ambitious")
        let after = try XCTUnwrap(
            (wire(store.coachContext(onboarding: true))["onboarding"] as? [String: Any])?["known"] as? [String: String]
        )
        XCTAssertEqual(after["risk_tolerance"], "ambitious")
    }

    /// An active goal was built from the profile's settings, so they are the athlete's.
    func testSettingsBehindAPlanOnFileAreKnown() {
        let known = OnboardingFacts.known(
            daysPerWeek: 5, longRunDay: 6, riskTolerance: "standard",
            given: [], planOnFile: true,
            maxHR: nil, birthdate: nil,
            activePlan: "Chicago on 2026-10-11, goal 3:15:00 — keep unless the goal changes"
        )
        XCTAssertEqual(known["days_per_week"], "5")
        XCTAssertEqual(known["long_run_day"], "Saturday")
        XCTAssertEqual(known["risk_tolerance"], "standard")
        XCTAssertEqual(known["active_plan"], "Chicago on 2026-10-11, goal 3:15:00 — keep unless the goal changes")
    }

    /// Max HR and birthdate are nullable columns: present means somebody said so.
    func testNullableFactsAreKnownWhenPresent() {
        let known = OnboardingFacts.known(
            daysPerWeek: 6, longRunDay: 0, riskTolerance: "standard",
            given: [], planOnFile: false,
            maxHR: 197, birthdate: "1998-03-14", activePlan: nil
        )
        XCTAssertEqual(known, ["max_hr_measured": "197", "birthdate": "1998-03-14"])
    }

    // MARK: -

    private func wire(_ context: CoachContext) throws -> [String: Any] {
        let data = try JSONEncoder().encode(context)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
