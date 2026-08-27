import XCTest
@testable import Tempo

/// The coach answered one message with two proposal cards, both Confirm buttons were live, and
/// tapping both started two writes at once. After #33 each of those also fired an
/// acknowledgement round trip, so two coach replies landed in the transcript — and the second
/// was built from a `CoachContext` snapshotted while the first write was still running, which
/// is how the coach ends up narrating a number that is mid-correction (#38).
///
/// These pin the admission rules, because every way they can be wrong is quiet. Admit too much
/// and the race is back. Admit too little and a Confirm the athlete deliberately tapped
/// vanishes with no error and no card change — indistinguishable from a dead button.
final class ConfirmQueueTests: XCTestCase {

    private let cardA = UUID()
    private let cardB = UUID()
    private let cardC = UUID()

    // MARK: - The race, closed

    /// The headline case. Two cards, two taps, one write at a time.
    func testSecondConfirmWaitsRatherThanStartingItsOwnWrite() {
        var queue = ConfirmQueue()
        XCTAssertEqual(queue.admit(cardA, offering: .pending), .start)
        XCTAssertEqual(queue.admit(cardB, offering: .pending), .wait,
                       "a write is already in flight — this one falls in behind it")
    }

    /// And it must actually *happen*. The athlete tapped it and meant it; the whole point of
    /// serializing rather than dropping is that the second card still applies.
    func testTheWaitingConfirmRunsOnceTheFirstFinishes() {
        var queue = ConfirmQueue()
        _ = queue.admit(cardA, offering: .pending)
        XCTAssertEqual(queue.admit(cardB, offering: .pending), .wait)

        queue.finish(cardA)

        XCTAssertEqual(queue.accepted, [cardB], "B is still in the line, not discarded")
        XCTAssertTrue(queue.isBusy)
        queue.finish(cardB)
        XCTAssertEqual(queue.accepted, [], "and the line drains")
        XCTAssertFalse(queue.isBusy)
    }

    /// Tap order is the order they apply. Three cards from one busy reply should not reshuffle
    /// themselves — an amend and the plan rebuild that reads it are not commutative.
    func testTapOrderIsApplyOrder() {
        var queue = ConfirmQueue()
        _ = queue.admit(cardA, offering: .pending)
        _ = queue.admit(cardB, offering: .pending)
        _ = queue.admit(cardC, offering: .pending)
        XCTAssertEqual(queue.accepted, [cardA, cardB, cardC])
    }

    /// A queue that has drained is a fresh queue: the next tap starts immediately rather than
    /// waiting on a ghost.
    func testQueueGoesIdleAndAdmitsTheNextTapImmediately() {
        var queue = ConfirmQueue()
        _ = queue.admit(cardA, offering: .pending)
        queue.finish(cardA)
        XCTAssertEqual(queue.admit(cardB, offering: .pending), .start)
    }

    // MARK: - The taps that are not offers

    /// One offer answered twice is not two offers. This is the impatient double-tap, and the
    /// only thing the queue is allowed to swallow.
    func testSameCardTappedTwiceIsIgnored() {
        var queue = ConfirmQueue()
        XCTAssertEqual(queue.admit(cardA, offering: .pending), .start)
        XCTAssertEqual(queue.admit(cardA, offering: .pending), .ignore)
        XCTAssertEqual(queue.accepted, [cardA], "and it must not join the line twice")
    }

    /// Double-tapping a card that is *waiting* is the likelier version — its button is gone,
    /// but a queued tap is easy to repeat before the card redraws.
    func testWaitingCardTappedAgainIsIgnored() {
        var queue = ConfirmQueue()
        _ = queue.admit(cardA, offering: .pending)
        XCTAssertEqual(queue.admit(cardB, offering: .pending), .wait)
        XCTAssertEqual(queue.admit(cardB, offering: .pending), .ignore)
        XCTAssertEqual(queue.accepted, [cardA, cardB])
    }

    /// Already-resolved cards keep their answer. Re-admitting an applied card would run the
    /// write a second time — a duplicate run, or an amend applied to its own result.
    func testResolvedCardsAreNotOffers() {
        for state: ChatMessage.ActionState in [.applying, .applied, .dismissed] {
            var queue = ConfirmQueue()
            XCTAssertEqual(queue.admit(cardA, offering: state), .ignore, "\(state.rawValue) is answered")
            XCTAssertEqual(queue.accepted, [], "and never joins the line")
        }
    }

    /// A card whose message or action is gone — resolved elsewhere and replayed on load.
    func testMissingCardIsIgnored() {
        var queue = ConfirmQueue()
        XCTAssertEqual(queue.admit(cardA, offering: nil), .ignore)
        XCTAssertEqual(queue.accepted, [])
    }

    /// Retry is a real offer. A failed write puts the button back, and that tap has to work —
    /// including when it lands while another confirm is still going.
    func testFailedCardIsStillAnOfferAndCanBeRetried() {
        var queue = ConfirmQueue()
        XCTAssertEqual(queue.admit(cardA, offering: .failed), .start)

        var busy = ConfirmQueue()
        _ = busy.admit(cardB, offering: .pending)
        XCTAssertEqual(busy.admit(cardA, offering: .failed), .wait)
    }

    /// The same card can be confirmed again after its first attempt failed and left the line.
    func testRetryAfterAFailedAttemptIsAdmittedAgain() {
        var queue = ConfirmQueue()
        _ = queue.admit(cardA, offering: .pending)
        queue.finish(cardA)
        XCTAssertEqual(queue.admit(cardA, offering: .failed), .start, "the retry card means it")
    }

    // MARK: - What the card renders

    /// `CoachView` reads this in the pending/failed branch to decide whether the buttons are
    /// still honest. A tap the queue has banked must not leave a button that looks live and
    /// does nothing — that is the symptom the athlete would actually see.
    func testATappedCardKnowsItIsWaiting() {
        var queue = ConfirmQueue()
        _ = queue.admit(cardA, offering: .pending)
        _ = queue.admit(cardB, offering: .pending)

        XCTAssertTrue(queue.isAwaitingTurn(cardB), "B's Confirm is spoken for")
        XCTAssertFalse(queue.isAwaitingTurn(cardC), "an untapped card keeps its buttons")

        queue.finish(cardA)
        queue.finish(cardB)
        XCTAssertFalse(queue.isAwaitingTurn(cardB), "and gets them back if it never applied")
    }

    /// A queue nobody has tapped into leaves every card alone.
    func testIdleQueueLeavesEveryCardTappable() {
        let queue = ConfirmQueue()
        XCTAssertFalse(queue.isBusy)
        XCTAssertFalse(queue.isAwaitingTurn(cardA))
    }

    // MARK: - The state predicate itself

    /// `confirm` and `dismiss` both gate on this. Getting it wrong in either direction is
    /// silent: too narrow and Retry stops working, too wide and an applied card re-applies.
    func testOnlyPendingAndFailedAreOpenOffers() {
        XCTAssertTrue(ChatMessage.ActionState.pending.isOpenOffer)
        XCTAssertTrue(ChatMessage.ActionState.failed.isOpenOffer, "Retry has to be tappable")
        XCTAssertFalse(ChatMessage.ActionState.applying.isOpenOffer, "already running")
        XCTAssertFalse(ChatMessage.ActionState.applied.isOpenOffer)
        XCTAssertFalse(ChatMessage.ActionState.dismissed.isOpenOffer)
    }
}
