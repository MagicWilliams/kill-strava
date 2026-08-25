import XCTest
@testable import Tempo

/// Regression suite for issue #9 — confirm cards that did not survive an app restart.
///
/// The incident (progress.md, 2026-07-08 night): the coach proposed "I'll log that as 8.0
/// miles", the athlete quit before tapping Confirm, and on reopening the history replayed the
/// sentence with no card beneath it. The offer was neither applied nor refused, and there was
/// nothing on screen to say so.
///
/// The whole fix reduces to two invariants, and both live in `CoachActionState`:
///
///  1. An unresolved proposal comes back as an offer the athlete can still take.
///  2. A resolved one never comes back as a live offer.
///
/// Everything else in the round trip is the proposal's own JSON, pinned at the bottom.
final class CoachActionStateTests: XCTestCase {

    // MARK: Invariant 1 — an unresolved proposal comes back confirmable

    func testPendingProposalComesBackAsALiveOffer() {
        let restored = CoachActionState.restored(from: "pending")

        XCTAssertEqual(restored, .pending)
        XCTAssertTrue(restored.isActionable)
    }

    func testHistoryWrittenBeforeTheColumnExistedComesBackAsAnOffer() {
        // Every row predating migration 0007 has no state at all. Reading that absence as
        // "resolved" would swallow the coach's proposal a second time — the exact bug.
        XCTAssertEqual(CoachActionState.restored(from: nil), .pending)
        XCTAssertTrue(CoachActionState.restored(from: nil).isActionable)
    }

    func testFailedComesBackRetryable() {
        // A write that didn't land is still owed to the athlete, so the buttons return.
        let restored = CoachActionState.restored(from: "failed")

        XCTAssertEqual(restored, .failed)
        XCTAssertTrue(restored.isActionable)
    }

    // MARK: Invariant 2 — a resolved proposal never reappears as a live offer

    func testAppliedAndDismissedComeBackResolved() {
        let cases: [(stored: String, expected: CoachActionState)] = [
            ("applied", .applied),
            ("dismissed", .dismissed),
        ]
        for (stored, expected) in cases {
            let restored = CoachActionState.restored(from: stored)
            XCTAssertEqual(restored, expected)
            XCTAssertFalse(restored.isActionable, "\(stored) must not offer Confirm again")
        }
    }

    // MARK: `applying` is deliberately not durable

    func testApplyingIsNeverWritten() {
        // "A write is in flight and we don't know whether it landed" is not a fact worth
        // storing. Persisting it would make the next launch have to guess.
        XCTAssertNil(CoachActionState.applying.persisted)
    }

    func testStrandedApplyingComesBackAsAnOfferRatherThanAsApplied() {
        // Killed mid-write. Coming back green would claim the change landed when we cannot
        // know that; coming back as an offer at worst asks the athlete the same question
        // twice. Same rule as RunFetch: never dress "couldn't tell" up as "known".
        XCTAssertEqual(CoachActionState.restored(from: "applying"), .pending)
    }

    func testAStateFromSomeOtherBuildStillRenders() {
        // Restoring is total on purpose — an unrecognised value must not drop the card.
        XCTAssertEqual(CoachActionState.restored(from: "interrupted"), .pending)
        XCTAssertEqual(CoachActionState.restored(from: ""), .pending)
    }

    func testEveryDurableStateRoundTripsThroughTheColumn() {
        for state in [CoachActionState.pending, .applied, .dismissed, .failed] {
            let stored = state.persisted
            XCTAssertNotNil(stored, "\(state) has to survive a relaunch")
            XCTAssertEqual(CoachActionState.restored(from: stored), state)
        }
    }

    // MARK: The proposal itself survives the trip through jsonb

    /// An `amend_run` exactly as the coach function emits it — the shape from the incident.
    private let amendRun = """
    {"type":"amend_run","summary":"Log Tuesday as 8.0 mi","run_id":"7C0FF3E2-0000-4000-8000-000000000001",\
    "distance_m":12875,"duration_s":4200,"note":"watch cut out at the turnaround"}
    """

    /// `update_session` — the other proposal type the issue names, and the one with the most
    /// fields, so it is the better check that nothing is lost on the way to the column.
    private let updateSession = """
    {"type":"update_session","summary":"Move Thursday's tempo to Friday","session_id":"7C0FF3E2-0000-4000-8000-000000000002",\
    "date":"2026-07-10","session_type":"tempo","title":"Tempo 6mi","target_distance_m":9656,\
    "target_pace_sec":444,"detail":"2mi easy, 4mi @ tempo","session_status":"planned"}
    """

    func testAProposalSurvivesEncodeAndDecode() throws {
        for json in [amendRun, updateSession] {
            let original = try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
            let stored = try JSONEncoder().encode(original)
            let restored = try JSONDecoder().decode(ProposedAction.self, from: stored)

            XCTAssertEqual(restored, original)
            XCTAssertEqual(restored.displaySummary, original.displaySummary)
        }
    }

    func testAbsentFieldsAreNotWrittenBackAsNulls() throws {
        // ProposedAction is one flat struct covering every tool the coach has, so all but a
        // handful of its fields are nil on any given proposal. The synthesized encoder skips
        // nil — this pins that, because the day it stops holding, every stored proposal
        // silently grows twenty-odd null keys.
        let original = try JSONDecoder().decode(ProposedAction.self, from: Data(amendRun.utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            ["type", "summary", "run_id", "distance_m", "duration_s", "note"]
        )
    }
}
