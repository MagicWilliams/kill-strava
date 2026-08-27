import Foundation

/// Identity for a run the coach proposed and the athlete confirmed.
///
/// A manual insert used to mint `UUID()` for its `external_id` at the moment of the write,
/// which meant the row's identity was the identity of the *tap*, not of the run. Confirm the
/// same proposal twice — Retry after a write whose response was lost, or a card offered again
/// after the app was killed mid-write — and the `(user_id, source, external_id)` unique
/// constraint saw two strangers and stored the run twice. `RunDedupe` does not cover this:
/// that guard runs on the HealthKit ingest path, not on manual inserts.
///
/// The fix is to derive the id from the proposal instead. The coach message carrying the
/// offer is that proposal's identity — one card, one run, however many times it is confirmed.
/// The second write then collides on the constraint and is dropped rather than duplicated.
///
/// This is the same bug class as the 2026-07-10 Garmin re-export that turned a 15-mile week
/// into 31: nothing crashes, a number on screen is simply wrong afterwards. Hence a pure
/// function with tests rather than a line inside the write.
enum ManualRunIdentity {

    /// `runs.source` for a coach-proposed insert. The unique constraint is scoped by source,
    /// so manual ids can never collide with HealthKit's.
    static let source = "manual"

    /// The `external_id` for the run proposed by `messageID`.
    ///
    /// Deterministic and injective: `UUID.uuidString` is canonical (always the same uppercase
    /// form for a given UUID, including one decoded back out of Postgres), so a card restored
    /// after a relaunch derives the id its first Confirm already wrote.
    ///
    /// The prefix is for the human reading the table: it says at a glance that this row's
    /// identity is a conversation, not a workout export.
    static func externalID(forProposalIn messageID: UUID) -> String {
        "coach-msg:\(messageID.uuidString)"
    }
}
