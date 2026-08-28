import Foundation

/// The line the athlete's Confirm taps stand in.
///
/// The coach can put two proposal cards on screen in one reply, and both Confirm buttons used
/// to be live at once: `ChatStore.confirm` had no in-flight guard, so tapping both started two
/// writes concurrently — and since #33, which made every resolved card ask the coach for a
/// reply, two round trips landed in the transcript on top of them. The second reply was built
/// from a `CoachContext` snapshotted while the first write was still running, so it narrated
/// numbers that were in the middle of being replaced (#38).
///
/// The onboarding path learned this first. `ChatStore.handleReply` applies its silent facts
/// SEQUENTIALLY, with a comment noting that parallel applies "once raced two simultaneous
/// regenerations." The manual confirm path never got the same treatment; this is it.
///
/// The rule is **serialize, not drop**. The athlete tapped Confirm and meant it — a tap that
/// evaporates because something else happened to be in flight is the exact failure the card
/// exists to prevent. The one thing that *is* dropped is a second tap on a card already in the
/// line, because that is one offer answered twice, not two offers.
///
/// Pure and value-typed so the ordering rules can be pinned without a fake Supabase.
struct ConfirmQueue: Equatable {

    /// Confirms accepted and not yet finished, in tap order. `first` is the one whose write is
    /// actually running; the rest are waiting their turn.
    private(set) var accepted: [UUID] = []

    /// What a tap is allowed to do, given everything already in the line.
    enum Admission: Equatable {
        /// Nothing ahead of it — apply now.
        case start
        /// A confirm is already running. Fall in behind it, in tap order.
        case wait
        /// Not a live offer, or the same card tapped twice. Nothing happens.
        case ignore
    }

    /// Decide *and* record, so a caller cannot take the decision and forget to join the line.
    ///
    /// - Parameters:
    ///   - id: the message carrying the card.
    ///   - state: that card's state at the moment of the tap, or `nil` when the message or its
    ///     action is gone — a card resolved elsewhere and replayed on load.
    mutating func admit(_ id: UUID, offering state: ChatMessage.ActionState?) -> Admission {
        guard let state, state.isOpenOffer, !accepted.contains(id) else { return .ignore }
        let admission: Admission = accepted.isEmpty ? .start : .wait
        accepted.append(id)
        return admission
    }

    /// A confirm finished, however it finished — applied, failed, or rejected on re-entry.
    /// Its successor is next.
    mutating func finish(_ id: UUID) {
        accepted.removeAll { $0 == id }
    }

    /// True from the moment a card's Confirm is tapped until its write is done.
    ///
    /// Read it only where the card is still `pending`/`failed`: once the write actually
    /// starts, `actionState` becomes `.applying` and that branch renders the progress row. So
    /// on a pending card this answers the question the view actually asks — *is this tap
    /// already banked, and therefore must the button stop looking live?*
    func isAwaitingTurn(_ id: UUID) -> Bool {
        accepted.contains(id)
    }

    /// Whether anything is in the line at all.
    var isBusy: Bool { !accepted.isEmpty }
}

extension ChatMessage.ActionState {
    /// `pending` is an unanswered offer and `failed` is one the athlete may retry. Everything
    /// else has already been answered, and answering it again would double-apply a write.
    var isOpenOffer: Bool { self == .pending || self == .failed }
}
