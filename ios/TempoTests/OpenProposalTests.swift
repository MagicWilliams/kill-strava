import XCTest
@testable import Tempo

/// At most one card in a conversation can be answered, and it is one the coach stands behind as
/// of the last thing the athlete said.
///
/// Every way these go wrong is quiet: a working Confirm on a card the conversation has moved
/// past writes a plan nobody wants any more, and looks exactly like a right answer.
final class OpenProposalTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func action(_ json: String) throws -> ProposedAction {
        try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
    }

    private func plan() throws -> ProposedAction {
        try action(#"{"type":"create_plan","goal_time_s":1170,"race_date":"2026-11-26","summary":"Build my plan"}"#)
    }

    private func said(_ role: ChatMessage.Role, _ text: String = "…", ago: TimeInterval = 60) -> ChatMessage {
        ChatMessage(id: UUID(), role: role, text: text, timestamp: now.addingTimeInterval(-ago))
    }

    private func card(_ action: ProposedAction, _ state: ChatMessage.ActionState = .pending, ago: TimeInterval = 60) -> ChatMessage {
        ChatMessage(id: UUID(), role: .coach, text: "Here's the plan.", timestamp: now.addingTimeInterval(-ago), action: action, actionState: state)
    }

    private func status(_ message: ChatMessage, in messages: [ChatMessage]) -> OpenProposal.Status {
        OpenProposal.status(of: message.id, in: messages, now: now)
    }

    // MARK: - Which card is live

    func testAnUnansweredCardIsLive() throws {
        let offer = card(try plan())
        XCTAssertEqual(status(offer, in: [said(.user), offer]), .live)
    }

    func testANewerCardReplacesAnOlderOne() throws {
        let old = card(try plan())
        let new = card(try plan())
        let messages = [old, said(.user), new]
        XCTAssertEqual(status(old, in: messages), .closed(.replaced))
        XCTAssertEqual(status(new, in: messages), .live)
        XCTAssertEqual(OpenProposal.liveCard(in: messages, now: now)?.id, new.id)
    }

    /// A dismissed newer card still closes the older one. Saying no to the revision is not
    /// saying yes to what it replaced.
    func testDismissingTheNewerCardDoesNotReviveTheOlderOne() throws {
        let old = card(try plan())
        let new = card(try plan(), .dismissed)
        let messages = [old, new]
        XCTAssertEqual(status(old, in: messages), .closed(.replaced))
        XCTAssertNil(OpenProposal.liveCard(in: messages, now: now))
    }

    /// The headline case: they answered, the coach answered them, and the card was not put up
    /// again. Whatever it said, it no longer reflects the conversation.
    func testACardCloseOnceTheAthleteSpeaksAndTheCoachAnswersWithoutIt() throws {
        let offer = card(try plan())
        let messages = [offer, said(.user, "I can only do four days"), said(.coach, "Four it is.")]
        XCTAssertEqual(status(offer, in: messages), .closed(.movedOn))
        XCTAssertNil(OpenProposal.liveCard(in: messages, now: now))
    }

    /// While the coach is still working it stays up, and a failed round trip must not cost the
    /// athlete their card.
    func testACardStaysLiveWhileTheirMessageIsUnanswered() throws {
        let offer = card(try plan())
        XCTAssertEqual(status(offer, in: [offer, said(.user, "Why five days?")]), .live)
    }

    /// The plan engine's narration is a coach line nobody asked for. It is not an answer.
    func testACoachLineWithNoAthleteTurnBeforeItLeavesTheCardLive() throws {
        let offer = card(try plan())
        XCTAssertEqual(status(offer, in: [offer, said(.coach, "Plan is live: 17 weeks.")]), .live)
    }

    func testACardExpires() throws {
        let fresh = card(try plan(), ago: OpenProposal.lifetime - 60)
        let old = card(try plan(), ago: OpenProposal.lifetime)
        XCTAssertEqual(status(fresh, in: [fresh]), .live)
        XCTAssertEqual(status(old, in: [old]), .closed(.expired))
    }

    func testAnAnsweredCardIsResolvedNotClosed() throws {
        for state in [ChatMessage.ActionState.applied, .dismissed] {
            let answered = card(try plan(), state)
            XCTAssertEqual(status(answered, in: [answered, said(.user), said(.coach)]), .resolved)
        }
    }

    /// Retry stays available on the newest card, and goes away like any other when replaced.
    func testAFailedCardIsStillAnOffer() throws {
        let failed = card(try plan(), .failed)
        XCTAssertEqual(status(failed, in: [failed]), .live)
        let new = card(try plan())
        XCTAssertEqual(status(failed, in: [failed, new]), .closed(.replaced))
    }

    /// A write that is running must not read as closed.
    func testACardApplyingIsLiveWhateverCameAfter() throws {
        let running = card(try plan(), .applying)
        XCTAssertEqual(status(running, in: [running, said(.user), said(.coach)]), .live)
    }

    /// Replayed from history, as it would be from the two threads of 2026-11-04: rows written
    /// before this rule, several still `pending`. Exactly one can be answered, and only if
    /// the conversation stopped there.
    func testOldThreadsWithSeveralPendingCardsCollapseToAtMostOne() throws {
        let cards = try (0..<3).map { _ in card(try action(#"{"type":"remember","fact":"x","summary":"Remember x"}"#)) }
        let live = cards.filter { status($0, in: cards) == .live }
        XCTAssertEqual(live.map(\.id), [cards[2].id])
    }

    func testAMessageThatIsNotACardHasNoOfferToClose() {
        let plain = said(.coach)
        XCTAssertEqual(status(plain, in: [plain]), .resolved)
        XCTAssertEqual(OpenProposal.status(of: UUID(), in: [plain], now: now), .resolved)
    }

    // MARK: - One card per reply

    func testOfSeveralProposalsTheOneThatMattersMostIsShown() throws {
        let memory = try action(#"{"type":"remember","fact":"x","summary":"Remember x"}"#)
        let session = try action(#"{"type":"update_session","session_id":"s","summary":"Move it"}"#)
        XCTAssertEqual(OpenProposal.oneCard(from: [memory, session, memory])?.type, "update_session")
        XCTAssertEqual(OpenProposal.oneCard(from: [memory, try plan()])?.type, "create_plan")
    }

    func testTheFirstOfEqualRankIsShown() throws {
        let first = try action(#"{"type":"remember","fact":"first","summary":"Remember first"}"#)
        let second = try action(#"{"type":"remember","fact":"second","summary":"Remember second"}"#)
        XCTAssertEqual(OpenProposal.oneCard(from: [first, second])?.fact, "first")
    }

    func testAnUnknownToolStillGetsACardItJustRanksLast() throws {
        let future = try action(#"{"type":"new_tool","summary":"Something new"}"#)
        XCTAssertEqual(OpenProposal.oneCard(from: [future])?.type, "new_tool")
        let memory = try action(#"{"type":"remember","fact":"x","summary":"x"}"#)
        XCTAssertEqual(OpenProposal.oneCard(from: [future, memory])?.type, "remember")
    }

    /// Five of these went up in one conversation after setup had ended, each doing nothing.
    func testCompleteOnboardingIsNeverACard() throws {
        let done = try action(#"{"type":"complete_onboarding","summary":"You're all set"}"#)
        XCTAssertNil(OpenProposal.oneCard(from: [done]))
        XCTAssertNil(OpenProposal.oneCard(from: []))
    }

    // MARK: - A change that already happened

    private let amend = #"{"type":"amend_run","run_id":"r","actual_distance":5.11,"actual_time":"1:02:00","unit":"mi","summary":"Correct Oct 27"}"#

    /// The run correction of 2026-11-04 came back four times, with new wording on some.
    func testProposingWhatWasJustAppliedIsARepeatWhateverTheWording() throws {
        let again = try action(#"{"type":"amend_run","run_id":"r","actual_distance":5.11,"actual_time":"1:02:00","unit":"mi","summary":"Fix that run","note":"per Strava"}"#)
        XCTAssertTrue(OpenProposal.repeatsWhatWasApplied(again, in: [card(try action(amend), .applied)]))
    }

    /// Confirm stamps code's totals onto an applied run card (#206). They must not make the same
    /// correction read as a different one.
    func testAStampedAppliedCardStillMatchesTheCardThatProducedIt() throws {
        var applied = try action(amend)
        applied.distance_m = 8_224
        applied.duration_s = 3_720
        applied.based_on = RunCorrection.Recorded(distance_m: 5_300, duration_s: 2_000, avg_hr: nil)
        XCTAssertTrue(OpenProposal.repeatsWhatWasApplied(try action(amend), in: [card(applied, .applied)]))
    }

    func testADifferentChangeIsNotARepeat() throws {
        let other = try action(#"{"type":"amend_run","run_id":"r","actual_distance":6.2,"unit":"mi","summary":"Correct again"}"#)
        XCTAssertFalse(OpenProposal.repeatsWhatWasApplied(other, in: [card(try action(amend), .applied)]))
        XCTAssertFalse(OpenProposal.repeatsWhatWasApplied(try plan(), in: [card(try action(amend), .applied)]))
    }

    /// Saturday, Sunday, back to Saturday is three real changes.
    func testGoingBackToAnEarlierChangeIsNotARepeat() throws {
        let saturday = try action(#"{"type":"update_session","session_id":"s","date":"2026-11-07","note":"n","summary":"Move to Saturday"}"#)
        let sunday = try action(#"{"type":"update_session","session_id":"s","date":"2026-11-08","note":"n","summary":"Move to Sunday"}"#)
        XCTAssertFalse(OpenProposal.repeatsWhatWasApplied(saturday, in: [card(saturday, .applied), card(sunday, .applied)]))
    }

    /// They said no, then changed their mind in words. That has to be able to come back.
    func testADismissedCardCanBeOfferedAgain() throws {
        XCTAssertFalse(OpenProposal.repeatsWhatWasApplied(try plan(), in: [card(try plan(), .dismissed)]))
    }

    /// An open card proposed again is how the coach keeps standing behind it.
    func testAnOpenCardCanBeProposedAgain() throws {
        XCTAssertFalse(OpenProposal.repeatsWhatWasApplied(try plan(), in: [card(try plan())]))
    }

    // MARK: - What the coach is told

    func testTheCoachSeesTheOpenCardWithoutTheFormStapledToIt() throws {
        var card = try plan()
        card.based_on = RunCorrection.Recorded(distance_m: 1, duration_s: 1, avg_hr: nil)
        let told = OpenProposal.forCoach(card)
        XCTAssertNil(told.based_on)
        XCTAssertNil(told.intake)
        XCTAssertEqual(told.goal_time_s, 1170, "what it proposes is the point")
        XCTAssertEqual(told.summary, "Build my plan")
    }

    func testAppliedSummariesListOnlyWhatLanded() throws {
        let messages = [
            card(try plan(), .applied),
            card(try action(amend), .dismissed),
            said(.user),
            card(try action(amend)),
        ]
        XCTAssertEqual(OpenProposal.appliedSummaries(in: messages), ["Build my plan"])
        XCTAssertNil(OpenProposal.appliedSummaries(in: [said(.user)]), "absent, not an empty claim")
    }

    func testAppliedSummariesAreCapped() throws {
        let many = try (0..<20).map { _ in card(try plan(), .applied) }
        XCTAssertEqual(OpenProposal.appliedSummaries(in: many)?.count, 8)
    }
}
