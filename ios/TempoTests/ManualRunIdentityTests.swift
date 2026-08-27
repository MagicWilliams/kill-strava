import XCTest
@testable import Tempo

/// Regression suite for the double-confirmed manual run (#20).
///
/// `applyAdd` used to mint a fresh `UUID()` for `external_id` on every call, so the same
/// coach proposal confirmed twice inserted two rows: the unique constraint saw strangers, and
/// the athlete's week silently gained a run it never contained. Same failure shape as the
/// 2026-07-10 Garmin re-export `RunDedupeTests` pins — nothing crashes, a number is just
/// wrong — which is why the derivation lives in a pure function with these tests under it.
final class ManualRunIdentityTests: XCTestCase {

    func testSameProposalYieldsTheSameID() {
        // The Retry path: the write landed, only the response was lost, the athlete taps
        // Confirm again on the very same card.
        let card = UUID()
        XCTAssertEqual(
            ManualRunIdentity.externalID(forProposalIn: card),
            ManualRunIdentity.externalID(forProposalIn: card),
            "a second Confirm on one card must collide with the first, not insert beside it"
        )
    }

    func testDifferentProposalsDoNotCollide() {
        // Two genuinely separate runs the coach logged in one conversation.
        let ids = (0..<64).map { _ in ManualRunIdentity.externalID(forProposalIn: UUID()) }
        XCTAssertEqual(Set(ids).count, ids.count, "distinct proposals must stay distinct runs")
    }

    func testSurvivesARoundTripThroughStorage() throws {
        // The relaunch path: the card comes back from `coach_messages`, so the UUID has been
        // through Postgres and back. `uuidString` is canonical, but pin it — the whole fix
        // rests on the restored card deriving the id its first Confirm already wrote.
        let card = UUID()
        let restored = UUID(uuidString: card.uuidString.lowercased())
        XCTAssertEqual(
            ManualRunIdentity.externalID(forProposalIn: try XCTUnwrap(restored)),
            ManualRunIdentity.externalID(forProposalIn: card)
        )
    }

    func testIDIsNamespacedAwayFromHealthKit() {
        // HealthKit rows carry a bare `HKWorkout` uuid. Source already separates the two in
        // the constraint; the prefix is so a human reading `runs` can tell at a glance which
        // rows are a conversation and which are an export.
        let id = ManualRunIdentity.externalID(forProposalIn: UUID())
        XCTAssertTrue(id.hasPrefix("coach-msg:"))
        XCTAssertNil(UUID(uuidString: id), "must not be mistakable for a workout uuid")
        XCTAssertEqual(ManualRunIdentity.source, "manual")
    }
}
