import XCTest
@testable import Tempo

/// A takeaway is cached in `runs.coach_takeaway` once and never regenerated. When a
/// completion came back empty twice, the coach answered with its fallback line — in takeaway
/// mode too — and the app cached it, so "Lost my train of thought there — ask me that again."
/// became that run's permanent read on Today and Run Detail (#137). These pin what the app
/// will and won't write into the column.
final class TakeawayReplyTests: XCTestCase {

    /// The exact line `supabase/functions/coach` sends after an empty retry.
    private let fallback = "Lost my train of thought there — ask me that again."

    func testARealReadIsCached() {
        let read = "Easy 6 at 9:12 with HR under 145 the whole way — exactly the aerobic day the plan asked for."
        XCTAssertEqual(TakeawayReply.usable(read), read)
    }

    /// The incident itself: the fallback line must never reach the column.
    func testTheCoachFallbackLineIsNeverCached() {
        XCTAssertNil(TakeawayReply.usable(fallback))
    }

    /// Matched by its opening, the same test the 0018 cleanup uses, so a reworded tail or
    /// stray whitespace around it doesn't sneak it back in.
    func testTheFallbackIsMatchedByItsOpening() {
        XCTAssertNil(TakeawayReply.usable("Lost my train of thought there."))
        XCTAssertNil(TakeawayReply.usable("  \(fallback)\n"))
    }

    /// The fixed coach answers a failed takeaway with an empty reply. Empty is "nothing to
    /// cache, ask again next open", never a blank card.
    func testAnEmptyOrBlankReplyIsNotCached() {
        XCTAssertNil(TakeawayReply.usable(nil))
        XCTAssertNil(TakeawayReply.usable(""))
        XCTAssertNil(TakeawayReply.usable(" \n\t "))
    }

    /// Only the coach's own non-answer is refused. A real read that happens to mention the
    /// phrase mid-sentence is still a read.
    func testAReadThatMerelyMentionsThePhraseIsKept() {
        let read = "Your note says \"Lost my train of thought at mile 9\" — that's the fueling gap, not fitness."
        XCTAssertEqual(TakeawayReply.usable(read), read)
    }

    /// What's cached is trimmed, so the card doesn't carry the model's trailing newline.
    func testTheCachedTextIsTrimmed() {
        XCTAssertEqual(TakeawayReply.usable("\nSolid tempo.\n"), "Solid tempo.")
    }
}
