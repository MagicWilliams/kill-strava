import Foundation

/// The lifecycle of a coach-proposed change, and the one rule that decides what a proposal
/// looks like after the app has been quit and reopened.
///
/// Until this existed the confirm card was pure memory. The coach would offer "I'll log that
/// as 8.0 miles", the athlete would background the app before tapping Confirm, and the offer
/// was gone — history replayed the coach's sentence with no card beneath it, so the change
/// was neither applied nor refused and nothing on screen said which
/// (`progress.md`, 2026-07-08 night).
///
/// The durable states are the ones the athlete decided: `pending` (offered, untouched),
/// `applied`, `dismissed`, `failed`. `applying` is deliberately *not* durable — see
/// `persisted`. Restoring is total: any value the column holds, including one written by a
/// build this one has never heard of, resolves to a state rather than dropping the card.
///
/// Pure and deterministic so the transitions can be pinned without a fake Supabase.
enum CoachActionState: String, Equatable {
    case pending      // card showing Confirm/Dismiss
    case applying     // write in flight — card shows progress
    case applied      // success — card stays as evidence
    case dismissed
    case failed       // error — buttons return, retryable

    /// The value to write to `coach_messages.action_state`, or nil for a state that must not
    /// be written at all.
    ///
    /// `applying` is nil on purpose. It means "a write is in flight and we do not yet know
    /// whether it landed", and there is no honest way to store that: coming back as `applied`
    /// would show a green card for a change that may never have reached Postgres — the same
    /// conflation of "couldn't tell" with "known" that `RunFetch` exists to prevent. Leaving
    /// the row at its previous value means an app killed mid-write reopens still offering the
    /// change. That is recoverable, and it does not claim anything untrue.
    var persisted: String? {
        self == .applying ? nil : rawValue
    }

    /// What a row loaded from `coach_messages` becomes on screen.
    ///
    /// Total by construction. A missing column, a NULL from history that predates migration
    /// 0007, and a value written by some build this one has never heard of all land on
    /// `pending` — because they all say the same thing: nobody recorded the athlete
    /// resolving this. The card comes back, and they get to answer it.
    static func restored(from stored: String?) -> CoachActionState {
        guard let stored, let state = CoachActionState(rawValue: stored) else { return .pending }
        switch state {
        case .applied, .dismissed, .failed:
            return state
        case .pending, .applying:
            // A stranded `applying` is one this build should never have written (see
            // `persisted`), but an interrupted older build could have. Offer it again.
            return .pending
        }
    }

    /// Whether the card is still an offer the athlete can act on. The whole point of
    /// persisting state is that a resolved proposal must never come back as a live one.
    var isActionable: Bool { self == .pending || self == .failed }
}
