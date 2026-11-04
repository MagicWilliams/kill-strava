import Foundation

/// Which proposal card in a conversation can still be answered: at most one, and only one the
/// coach stands behind as of the last thing the athlete said.
///
/// Every card used to stay live until someone tapped it, for ever. On 2026-11-04 a fresh account
/// finished setup looking at three unanswered plan and memory cards from earlier turns, each
/// with a working Confirm, while the conversation had moved on from all of them. A Confirm on
/// the oldest would have written what the athlete had since talked the coach out of.
///
/// Derived, not stored. `coach_messages` keeps `pending` on a card that closed this way, and
/// this reads the transcript each time, so there is no second state to keep in step, no
/// migration, and cards already sitting in old conversations are covered the moment this ships.
/// "What changed" only reads `applied`, so an old `pending` row claims nothing anywhere else.
enum OpenProposal {

    /// How long an unanswered card stays live with nothing else happening. "Make today easier"
    /// means nothing by tomorrow night, and asking again costs one message.
    static let lifetime: TimeInterval = 24 * 3600

    enum Reason: Equatable {
        /// A newer card came after it.
        case replaced
        /// The athlete said something after it, and the coach's answer did not propose it
        /// again. The coach is told an unrepeated card closes (`open_proposal` in the prompt),
        /// so a card still meant comes back with what they said folded in. If the coach forgets,
        /// that costs a message; the other way round, a stale card writes the wrong plan.
        case movedOn
        case expired

        var line: String {
            switch self {
            case .replaced: return "Replaced by a newer suggestion."
            case .movedOn: return "Closed: the conversation moved on. Ask the coach if you still want this."
            case .expired: return "Closed: this was a while ago. Ask the coach if you still want it."
            }
        }
    }

    enum Status: Equatable {
        case live
        /// Answered (applied or dismissed), or not a card at all.
        case resolved
        case closed(Reason)
    }

    /// `applying` counts as live: the athlete answered while it was open, and a card must not
    /// read as closed while its write is running.
    static func status(of id: UUID, in messages: [ChatMessage], now: Date) -> Status {
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].action != nil else {
            return .resolved
        }
        let card = messages[index]
        switch card.actionState {
        case .applied, .dismissed: return .resolved
        case .applying: return .live
        case .pending, .failed: break
        }
        let later = messages[(index + 1)...]
        if later.contains(where: { $0.action != nil }) { return .closed(.replaced) }
        // Only once the coach has answered: while it is still thinking, the card is what it is
        // being asked about, and a failed round trip must not cost the athlete their card.
        if let spoke = later.firstIndex(where: { $0.role == .user }),
           later[spoke...].contains(where: { $0.role == .coach }) {
            return .closed(.movedOn)
        }
        if now.timeIntervalSince(card.timestamp) >= lifetime { return .closed(.expired) }
        return .live
    }

    /// The card still open in this conversation, if there is one.
    static func liveCard(in messages: [ChatMessage], now: Date) -> ChatMessage? {
        guard let newest = messages.last(where: { $0.action != nil }),
              status(of: newest.id, in: messages, now: now) == .live else { return nil }
        return newest
    }

    // MARK: - What a reply may put up

    /// When a reply carries several cards, the one that matters most to the athlete's training
    /// stays. Mirrors `CARD_RANK` in the coach function, which does this first and tells the
    /// model. Anything unlisted ranks last.
    static let rank = [
        "create_plan", GoalRetirement.actionType, "update_plan_settings", "update_session",
        "amend_run", "add_run", "set_risk_tolerance", "update_athlete", "remember",
    ]

    /// The one card to show. complete_onboarding never is one: during the interview it applies
    /// silently and is gone before this runs, and after it there is nothing for it to do.
    static func oneCard(from actions: [ProposedAction]) -> ProposedAction? {
        let cards = actions.filter { $0.type != "complete_onboarding" }
        return cards.enumerated().min { a, b in
            let left = rank.firstIndex(of: a.element.type) ?? rank.count
            let right = rank.firstIndex(of: b.element.type) ?? rank.count
            return left == right ? a.offset < b.offset : left < right
        }?.element
    }

    /// Prose and what the app stamps on: two cards that differ only in these make the same change.
    private static let notTheChange: Set<String> = [
        "summary", "note", "rationale", "risk_named", "reason", "based_on", "intake", "intake_changes",
    ]

    /// Whether this card only proposes again what the newest card in the conversation already
    /// applied. The tool-free acknowledgement stops most of these, but "thanks, that's great" can
    /// bring one back too: the run correction of 2026-11-04 returned after a typed turn.
    ///
    /// The newest card only, and applied only. Moving a session to Saturday, to Sunday and back
    /// to Saturday is three real changes. And offering a dismissed card again is fine once the
    /// athlete has asked for it, which is the only way it comes back (acknowledgements carry no
    /// cards). Compared on the keys the new card sends, because an applied run card has had
    /// code's totals stamped onto it since (#206).
    static func repeatsWhatWasApplied(_ action: ProposedAction, in messages: [ChatMessage]) -> Bool {
        guard let newest = messages.last(where: { $0.action != nil }),
              newest.actionState == .applied,
              let applied = newest.action,
              let new = changeFields(action),
              let old = changeFields(applied) else { return false }
        return new.allSatisfy { key, value in old[key].map { ($0 as AnyObject).isEqual(value) } ?? false }
    }

    private static func changeFields(_ action: ProposedAction) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(action),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return fields.filter { !notTheChange.contains($0.key) }
    }

    // MARK: - What the coach is told

    /// `<athlete_context>.open_proposal`. The transcript the coach is sent is text, so without
    /// this it cannot know a card exists, what it says, or that one it proposed was answered.
    /// The intake is left off because `intake` already carries it.
    static func forCoach(_ card: ProposedAction) -> ProposedAction {
        var card = card
        card.intake = nil
        card.based_on = nil
        return card
    }

    /// `<athlete_context>.applied_in_thread`, oldest first and capped, or nil when nothing has
    /// been applied. Summaries rather than payloads: this is so the coach does not offer them
    /// again, and the data they changed is in the context already.
    static func appliedSummaries(in messages: [ChatMessage]) -> [String]? {
        let applied = messages
            .filter { $0.action != nil && $0.actionState == .applied }
            .compactMap { $0.action?.displaySummary }
        return applied.isEmpty ? nil : Array(applied.suffix(8))
    }

    /// The form's answers, for a create_plan proposed when the handoff is gone: `intakeHandoff`
    /// lives in memory, and a relaunch mid-conversation loses it while the card that carried it
    /// is still in the transcript. Without this, a re-proposed card would drop everything the
    /// athlete tapped. Nil once a plan was built from them.
    static func unbuiltStamp(in messages: [ChatMessage]) -> IntakeStamp? {
        guard let newest = messages.last(where: { $0.action?.intake != nil }),
              newest.actionState != .applied else { return nil }
        return newest.action?.intake
    }
}
