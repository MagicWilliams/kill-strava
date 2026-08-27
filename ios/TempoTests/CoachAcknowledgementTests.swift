import XCTest
@testable import Tempo

/// The coach proposed a change, the athlete confirmed it, the card went green — and the
/// coach said nothing. The last line in the transcript was one the app had written on the
/// athlete's behalf ("Confirmed — Correct Tue's run: 6.0 → 8.0 mi"), and the conversation
/// stopped there (#31).
///
/// The fix is one bit: *ask* for a reply. These pin which transitions get to ask, because
/// every way that bit can be wrong is silent. Reply on an onboarding auto-apply and the
/// setup interview asks every question twice. Reply on a failure and the coach apologises
/// over a card that is already offering Retry. Reply before the runs are re-read and it
/// narrates the numbers the athlete just corrected away.
final class CoachAcknowledgementTests: XCTestCase {

    private func asks(
        _ transition: CoachAcknowledgement.Transition,
        onboarding: Bool = false,
        _ type: String
    ) -> Bool {
        CoachAcknowledgement.shouldRequestReply(
            after: transition, onboardingMode: onboarding, actionType: type
        )
    }

    // MARK: - The transitions that earn a reply

    /// The headline case from #31: amend a run, confirm it, and the coach should have
    /// something to say about what the corrected number does to the week.
    func testConfirmedChangeAsksForAReply() {
        XCTAssertTrue(asks(.applied, "amend_run"))
        XCTAssertTrue(asks(.applied, "add_run"))
        XCTAssertTrue(asks(.applied, "update_session"))
        XCTAssertTrue(asks(.applied, "create_plan"))
    }

    /// Silence after a Dismiss is what makes a proposal feel pushed rather than offered.
    func testDismissAsksForAReply() {
        XCTAssertTrue(asks(.dismissed, "amend_run"))
        XCTAssertTrue(asks(.dismissed, "create_plan"))
    }

    /// Outside the interview these are ordinary cards with ordinary Confirm buttons; the
    /// auto-apply rule is about onboarding, not about the tool.
    func testAutoApplyTypesStillGetARepliedCardOutsideOnboarding() {
        for type in CoachAcknowledgement.onboardingAutoApplyTypes {
            XCTAssertTrue(asks(.applied, onboarding: false, type), "\(type) is a normal card once the interview is over")
        }
    }

    // MARK: - The transitions that must not

    /// A failed write already surfaces `errorText` and puts Retry back on the card. Asking
    /// the coach to comment would be asking it to reason about a state the app could not
    /// establish, on top of an affordance that already covers it.
    func testFailedApplyStaysQuiet() {
        XCTAssertFalse(asks(.failed, "amend_run"))
        XCTAssertFalse(asks(.failed, "add_run"))
        XCTAssertFalse(asks(.failed, onboarding: true, "create_plan"))
    }

    /// The ordering constraint, encoded. The write landed but `reloadFromSupabase()` did
    /// not, so `coachContext()` still holds the pre-correction runs. A reply built on that
    /// would confidently describe the 6.0-mile version of a run the athlete just made 8.0 —
    /// worse than saying nothing, and the athlete is already told the re-read failed.
    func testStaleContextStaysQuietRatherThanNarratingOldNumbers() {
        XCTAssertFalse(asks(.appliedWithStaleContext, "amend_run"))
        XCTAssertFalse(asks(.appliedWithStaleContext, "add_run"))
        XCTAssertFalse(asks(.appliedWithStaleContext, onboarding: true, "create_plan"))
    }

    /// During the setup interview, small facts apply silently — the athlete's answer was the
    /// consent, and the coach's next question is already the acknowledgement. An extra reply
    /// per fact would double every turn of the interview.
    func testOnboardingAutoAppliedFactsStayQuiet() {
        for type in CoachAcknowledgement.onboardingAutoApplyTypes {
            XCTAssertFalse(asks(.autoAppliedDuringOnboarding, onboarding: true, type), "\(type) applied silently")
        }
    }

    /// Second lock on the same door: `handleReply` strips the auto-apply types before they
    /// can become cards, so these should never reach a Confirm during the interview. If one
    /// ever does — a stale card restored from `coach_messages` after onboarding resumed —
    /// it still must not double the turn.
    func testOnboardingAutoApplyTypesStayQuietEvenIfTheyReachAConfirm() {
        for type in CoachAcknowledgement.onboardingAutoApplyTypes {
            XCTAssertFalse(asks(.applied, onboarding: true, type), "\(type) confirmed mid-interview")
            XCTAssertFalse(asks(.dismissed, onboarding: true, type), "\(type) dismissed mid-interview")
        }
    }

    /// `create_plan` is the one proposal the interview still puts behind a card, so it is
    /// also the one that should get an answer inside onboarding.
    func testCreatePlanRepliesEvenDuringOnboarding() {
        XCTAssertFalse(
            CoachAcknowledgement.onboardingAutoApplyTypes.contains("create_plan"),
            "create_plan must keep its confirm card — it is not a small fact"
        )
        XCTAssertTrue(asks(.applied, onboarding: true, "create_plan"))
        XCTAssertTrue(asks(.dismissed, onboarding: true, "create_plan"))
    }

    // MARK: - The set itself

    /// `ChatStore.handleReply` branches on this exact set. Adding a tool to the coach
    /// function without deciding which side of this line it falls on is how the interview
    /// starts either double-asking or blocking on a card nobody expected.
    func testAutoApplySetIsExactlyTheInterviewFacts() {
        XCTAssertEqual(
            CoachAcknowledgement.onboardingAutoApplyTypes,
            ["update_athlete", "update_plan_settings", "set_risk_tolerance", "complete_onboarding"]
        )
    }

    /// An unknown tool type — a newer coach deploy talking to an older build — should still
    /// get a reply rather than dead-ending the conversation.
    func testUnknownActionTypeStillReplies() {
        XCTAssertTrue(asks(.applied, "some_tool_shipped_after_this_build"))
        XCTAssertTrue(asks(.applied, onboarding: true, "some_tool_shipped_after_this_build"))
    }
}
