import Foundation

/// Whether resolving a coach proposal should ask the coach to say something back.
///
/// The coach used to propose a change, watch it land, and go silent. The last line in the
/// transcript was one the *app* wrote — "Confirmed — Correct Tue's run: 6.0 → 8.0 mi" — and
/// then nothing. It read like the other side of the conversation walking off mid-sentence
/// (#31). Nothing new needs to be sent to fix that: `confirm`/`dismiss` already append that
/// turn, so it is already in the history the coach sees. The reply was simply never asked for.
///
/// This is the "ask for it?" decision, pulled out of `ChatStore` because it is a decision and
/// not I/O, and because all three ways it regresses are silent rather than crashy: an
/// interview that asks every question twice, an apology chained onto a failure the retry card
/// already covers, and a coach that confidently narrates the numbers it just replaced.
enum CoachAcknowledgement {

    /// How a proposal card stopped being an open offer.
    enum Transition: Equatable {
        /// The write landed and the runs were re-read, so `coachContext()` is current.
        case applied

        /// The write landed, but the re-read that follows it failed. Asking here is worse
        /// than silence: the coach would describe the pre-correction numbers as if the
        /// correction had not happened — the exact confusion the amend was meant to end.
        /// The athlete already gets "Saved — but your runs couldn't be re-read just now."
        case appliedWithStaleContext

        /// The write threw. `errorText` says so and the card comes back as Retry; a coach
        /// apologising on top of that is noise, and it would be reasoning from a state the
        /// app itself could not establish.
        case failed

        /// The athlete said no. Worth a short acknowledgement — silence after a Dismiss is
        /// what made the proposal feel like it was pushed rather than offered.
        case dismissed

        /// A fact the setup interview applied silently. The athlete's answer *was* the
        /// consent, and the interview's next question is already the reply.
        case autoAppliedDuringOnboarding
    }

    /// Tool types the setup interview applies without a card. `ChatStore.handleReply` strips
    /// these from the proposals it turns into cards, so during onboarding they never reach a
    /// Confirm — the guard below is the second lock on that door, not the first.
    static let onboardingAutoApplyTypes: Set<String> =
        ["update_athlete", "update_plan_settings", "set_risk_tolerance", "complete_onboarding"]

    /// The one turn of acknowledgement, or nothing. Whatever comes back is handed to
    /// `handleReply`, which may attach another card but never asks for a further reply — that
    /// is what keeps this from becoming a coach talking to itself.
    static func shouldRequestReply(
        after transition: Transition,
        onboardingMode: Bool,
        actionType: String
    ) -> Bool {
        switch transition {
        case .failed, .appliedWithStaleContext, .autoAppliedDuringOnboarding:
            return false
        case .applied, .dismissed:
            return !(onboardingMode && onboardingAutoApplyTypes.contains(actionType))
        }
    }
}
