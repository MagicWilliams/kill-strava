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

    // MARK: - The history the acknowledgement is asked about (#193, #195)

    private typealias Turn = CoachAcknowledgement.Turn
    private func user(_ s: String) -> Turn { Turn(role: .user, content: s) }
    private func coach(_ s: String) -> Turn { Turn(role: .assistant, content: s) }

    private let goalCard = "Want me to lock in the Turkey Trot 5K and build toward it?"
    private let confirmed = "Confirmed — Save my goal: 5K at Turkey Trot (Nov 27)"
    private let planIsLive = "Plan is live: 6 weeks (base build). Volume runs 18 → 24 mi/wk. Projection today: 22:41."

    /// The incident. 2026-10-15: two `coach.invoke_failed` rows, both plan-confirm
    /// acknowledgements, both "This model does not support assistant message prefill." The
    /// transcript ended "Confirmed — …" then the "Plan is live" narration — an assistant turn
    /// last. The wire history must end on the athlete's side.
    func testPlanConfirmHistoryEndsInAUserTurn() {
        let wire = CoachAcknowledgement.wireHistory([coach(goalCard), user(confirmed), coach(planIsLive)])
        XCTAssertEqual(wire.last?.role, .user)
    }

    /// The point of doing this client-side rather than leaning on #194's server drop: the
    /// coach has to see what the plan engine built, or its acknowledgement can only parrot
    /// the confirm line back. Both the tap and its result are in that last turn, in order.
    func testPlanConfirmHistoryStillCarriesTheNarration() throws {
        let wire = CoachAcknowledgement.wireHistory([coach(goalCard), user(confirmed), coach(planIsLive)])
        XCTAssertEqual(wire, [
            coach(goalCard),
            user(confirmed + "\n\n" + CoachAcknowledgement.narrationLabel + planIsLive),
        ])
        let last = try XCTUnwrap(wire.last?.content)
        let tap = try XCTUnwrap(last.range(of: confirmed))
        let result = try XCTUnwrap(last.range(of: planIsLive), "the coach must read what was built")
        XCTAssertLessThan(
            tap.lowerBound, result.lowerBound,
            "the tap, then what it did — the same causal order as the transcript (#39)"
        )
    }

    /// `update_plan_settings` is the other narrating path, and its no-plan branch narrates a
    /// fixed sentence. Same shape, same fold.
    func testSettingsSavedWithoutPlanFoldsTheSameWay() {
        let wire = CoachAcknowledgement.wireHistory([
            user("Confirmed — Train 4 days a week"),
            coach(PlanNarration.settingsSavedWithoutPlan),
        ])
        XCTAssertEqual(wire.count, 1)
        XCTAssertEqual(wire.last?.role, .user)
        XCTAssertTrue(wire.last!.content.hasSuffix(PlanNarration.settingsSavedWithoutPlan))
    }

    /// Every confirm that does not narrate, and every dismiss, already ends on the athlete's
    /// line. Those histories were never broken and must reach the coach byte-for-byte.
    func testHistoryEndingInAUserTurnPassesThroughUntouched() {
        let confirm = [coach("Tue's run looks short — correct it to 8.0 mi?"), user("Confirmed — Correct Tue's run: 6.0 → 8.0 mi")]
        XCTAssertEqual(CoachAcknowledgement.wireHistory(confirm), confirm)
        let dismiss = [coach(goalCard), user("Dismissed — Save my goal: 5K at Turkey Trot (Nov 27)")]
        XCTAssertEqual(CoachAcknowledgement.wireHistory(dismiss), dismiss)
    }

    /// Only the tail is reshaped. Earlier coach turns are the coach's real words and keep
    /// their role; nothing before the confirm is merged or dropped.
    func testOnlyTheTrailingCoachTurnsAreFolded() {
        let transcript = [
            user("drop me to 4 days a week"),
            coach("Easy — want me to rebuild around Tue/Thu/Sat/Sun?"),
            user(confirmed),
            coach(planIsLive),
        ]
        let wire = CoachAcknowledgement.wireHistory(transcript)
        XCTAssertEqual(Array(wire.prefix(2)), Array(transcript.prefix(2)))
        XCTAssertEqual(wire.count, 3)
    }

    /// A blank narration has nothing to add; folding it would leave a dangling label.
    func testBlankNarrationLeavesTheConfirmLineAlone() {
        let wire = CoachAcknowledgement.wireHistory([user(confirmed), coach("  \n")])
        XCTAssertEqual(wire, [user(confirmed)])
    }

    /// No athlete turn to fold into — e.g. a 24-turn window that is all coach. Inventing a
    /// user turn would put words in the athlete's mouth; leave it, and #194's server-side
    /// drop is the backstop.
    func testHistoryWithNoUserTurnIsLeftAlone() {
        XCTAssertEqual(CoachAcknowledgement.wireHistory([]), [])
        let allCoach = [coach("one"), coach("two")]
        XCTAssertEqual(CoachAcknowledgement.wireHistory(allCoach), allCoach)
    }
}
