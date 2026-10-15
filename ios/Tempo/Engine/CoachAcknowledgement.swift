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

    // MARK: - What the acknowledgement is asked about

    /// One turn as the `coach` function receives it. Kept here rather than reusing
    /// `ChatStore.WireMessage` so the shaping below stays pure and testable without the store.
    struct Turn: Equatable {
        enum Role: String { case user, assistant }
        let role: Role
        let content: String
    }

    /// The label the narration carries once it is folded into the athlete's turn. It marks
    /// the line as the result of the tap, so the coach reads it as what the plan engine did
    /// rather than something the athlete typed.
    static let narrationLabel = "What changed: "

    /// The wire history for an acknowledgement, given the transcript as it reads on screen.
    ///
    /// After a plan confirm the transcript is "Confirmed — …" (the athlete) and then "Plan is
    /// live: 16 weeks…" (the app, in the coach's bubble), in that order on purpose — the tap,
    /// then what it did (#39). Sent as-is, that history ends in an `assistant` turn and the
    /// model rejects it as prefill: every `create_plan` / `update_plan_settings`
    /// acknowledgement 502'd (#193). The server now drops a trailing assistant turn (#194),
    /// but dropping it means the coach acknowledges a plan change without ever seeing the
    /// sentence that says what was built (#195).
    ///
    /// So the trailing coach turns are folded into the user turn before them — on the wire
    /// only. The transcript keeps its two bubbles; the coach gets one user turn carrying both
    /// the tap and its result, and the history ends where the model needs it to.
    ///
    /// A history that already ends in a user turn (every dismiss, every confirm that does not
    /// narrate) passes through untouched. One with no user turn to fold into is also left
    /// alone: inventing a user turn would put words in the athlete's mouth, and the server's
    /// trailing-turn drop still covers it.
    static func wireHistory(_ transcript: [Turn]) -> [Turn] {
        guard transcript.last?.role == .assistant,
              let lastUser = transcript.lastIndex(where: { $0.role == .user }) else {
            return transcript
        }
        let narration = transcript[(lastUser + 1)...]
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let confirmation = transcript[lastUser].content
        let folded = narration.isEmpty
            ? confirmation
            : confirmation + "\n\n" + narrationLabel + narration.joined(separator: "\n\n")
        return Array(transcript[..<lastUser]) + [Turn(role: .user, content: folded)]
    }
}
