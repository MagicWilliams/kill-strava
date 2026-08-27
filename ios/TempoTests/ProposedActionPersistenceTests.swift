import XCTest
@testable import Tempo

/// A coach proposal is a write the athlete has not yet accepted. It used to live only in
/// memory, so quitting the app before tapping Confirm silently discarded the offer while
/// the replayed chat still showed the coach promising the change (#9).
///
/// These pin the two halves that make persistence safe: the action survives a JSON
/// round-trip through `jsonb` intact, and the state machine never writes down a state the
/// app could not stand behind after a crash.
final class ProposedActionPersistenceTests: XCTestCase {

    private func decode(_ json: String) throws -> ProposedAction {
        try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
    }

    // MARK: - Round trip

    /// The payload the coach Edge Function actually returns for the flagship case:
    /// "I forgot to start my watch."
    func testAmendRunSurvivesARoundTrip() throws {
        let original = try decode("""
        {"type":"amend_run","run_id":"8B0F1E22-0000-4000-8000-00000000ABCD",
         "distance_m":12874,"duration_s":4512,"avg_hr":141,
         "note":"Added the 2 unrecorded miles at the stated 10:00 pace; HR estimated from your own comparable runs.",
         "summary":"Correct Tue's run: 6.0 → 8.0 mi, 55:12 → 1:15:12, avg HR est. 141"}
        """)

        let reheated = try JSONDecoder().decode(
            ProposedAction.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(reheated, original, "what comes back out of jsonb must be what went in")
        XCTAssertEqual(reheated.run_id, "8B0F1E22-0000-4000-8000-00000000ABCD", "the id is the whole point")
        XCTAssertEqual(reheated.distance_m, 12874)
        XCTAssertEqual(reheated.avg_hr, 141)
    }

    /// Every tool the coach can propose has a different subset of fields populated; the
    /// rest are nil and must stay nil rather than round-tripping into something.
    func testSparseActionsKeepTheirShape() throws {
        let plan = try decode("""
        {"type":"create_plan","goal_time_s":11700,"race_date":"2026-10-11",
         "race_name":"Chicago","summary":"Build my plan: 3:15:00 at Chicago, Oct 11"}
        """)
        let reheated = try JSONDecoder().decode(ProposedAction.self, from: JSONEncoder().encode(plan))

        XCTAssertEqual(reheated, plan)
        XCTAssertEqual(reheated.goal_time_s, 11700)
        XCTAssertNil(reheated.run_id, "a plan proposal carries no run")
        XCTAssertNil(reheated.distance_m)
        XCTAssertNil(reheated.session_id)
    }

    func testDisplaySummaryNeverEmpty() throws {
        let noSummary = try decode("""
        {"type":"add_run","note":"Treadmill run Garmin never exported.","start_time":"2026-08-20T12:00:00Z"}
        """)
        XCTAssertEqual(noSummary.displaySummary, "Treadmill run Garmin never exported.", "falls back to the note")

        let neither = try decode("{\"type\":\"set_risk_tolerance\"}")
        XCTAssertEqual(neither.displaySummary, "Proposed set_risk_tolerance", "still never blank")
    }

    // MARK: - State machine

    func testResolvedStatesPersistAsThemselves() {
        XCTAssertEqual(ChatMessage.ActionState.applied.durable, .applied)
        XCTAssertEqual(ChatMessage.ActionState.dismissed.durable, .dismissed)
        XCTAssertEqual(ChatMessage.ActionState.failed.durable, .failed)
        XCTAssertEqual(ChatMessage.ActionState.pending.durable, .pending)
    }

    /// The crash-safety rule. An app killed mid-write cannot know whether the write landed,
    /// so `applying` must never reach the database — the row stays pending and the athlete
    /// is re-offered the action rather than shown a state the app can't stand behind.
    func testApplyingNeverPersists() {
        XCTAssertEqual(ChatMessage.ActionState.applying.durable, .pending)
    }

    /// Every durable state must satisfy the migration's CHECK constraint.
    func testDurableStatesMatchTheSchemaConstraint() {
        let allowed: Set<String> = ["pending", "applied", "dismissed", "failed"]
        for state in [ChatMessage.ActionState.pending, .applying, .applied, .dismissed, .failed] {
            XCTAssertTrue(
                allowed.contains(state.durable.rawValue),
                "\(state.rawValue) persists as \(state.durable.rawValue), which the CHECK constraint would reject"
            )
        }
    }

    func testUnknownStoredStateFallsBackToPending() {
        // A row written by a future version, read by this one: re-offer rather than drop.
        XCTAssertNil(ChatMessage.ActionState(rawValue: "superseded"))
    }
}
