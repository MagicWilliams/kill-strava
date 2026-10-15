import XCTest
@testable import Tempo

/// #93: the Coach tab read `coach_messages` with `.order("created_at").limit(200)`.
/// PostgREST's `order` defaults to ascending, and ascending plus a limit returns the
/// *oldest* 200 rows — so once the history passed 200 messages, every relaunch opened on
/// the start of the conversation, and `messages.suffix(24)` briefed the coach on the
/// opening of a conversation it was supposedly continuing.
///
/// Nothing crashed, nothing logged, and the transcript on screen looked like a real
/// transcript. These tests exist because the only observable symptom was old text in the
/// right font.
///
/// What a unit test can reach is the device half: the page the server hands back arrives
/// newest-first and has to come out in reading order. The direction of the query itself
/// lives in `ChatStore.load` and is only provable on device.
final class ChatHistoryTests: XCTestCase {

    private struct Row: Equatable {
        let index: Int      // 0 is the first thing ever said
        let at: Date
    }

    /// 201 messages a minute apart — one more than the page, which is the whole trigger.
    private let archive: [Row] = (0..<201).map {
        Row(index: $0, at: Date(timeIntervalSince1970: 1_760_000_000 + Double($0) * 60))
    }

    /// What `.order("created_at", ascending: false).limit(pageSize)` returns.
    private var newestPage: [Row] {
        Array(archive.sorted { $0.at > $1.at }.prefix(ChatHistory.pageSize))
    }

    /// What the old read returned: `.order("created_at").limit(pageSize)`.
    private var oldestPage: [Row] {
        Array(archive.sorted { $0.at < $1.at }.prefix(ChatHistory.pageSize))
    }

    private func reading(_ page: [Row]) -> [Row] {
        ChatHistory.inReadingOrder(newestFirst: page, by: { $0.at })
    }

    // MARK: - The bug

    /// The scar itself, stated as a fact about the data rather than about the code: past the
    /// page size the two directions do not merely reorder the same rows, they return
    /// *different rows*. No amount of sorting on the device recovers a message the server
    /// was never asked for.
    func testAscendingAndDescendingPagesHoldDifferentMessages() {
        XCTAssertEqual(oldestPage.map(\.index).max(), 199, "ascending + limit stops at the 200th message ever sent")
        XCTAssertEqual(newestPage.map(\.index).max(), 200, "descending + limit reaches the latest one")
        XCTAssertFalse(
            oldestPage.contains(where: { $0.index == 200 }),
            "the newest message is absent from the old read — this is #93, and it is a server-side loss"
        )
    }

    // MARK: - Reading order

    func testTheNewestPageEndsOnTheLatestMessage() {
        let shown = reading(newestPage)

        XCTAssertEqual(shown.count, ChatHistory.pageSize)
        XCTAssertEqual(shown.last?.index, 200, "the Coach tab opens on the latest message")
        XCTAssertEqual(shown.first?.index, 1, "and scroll-back starts one past the archive's oldest")
        XCTAssertEqual(shown, shown.sorted { $0.at < $1.at }, "oldest first, newest last")
    }

    /// The second half of #93, and the one that quietly changed what the coach was told:
    /// `suffix(24)` is the window sent to the model, so it has to be the *recent* end.
    func testTheCoachWindowComesFromTheRecentEnd() {
        let window = reading(newestPage).suffix(24)

        XCTAssertEqual(window.map(\.index), Array(177...200), "the last 24 things actually said")
        XCTAssertEqual(window.last?.index, 200)
    }

    /// A short history is the common case on a fresh account, and it must not be special.
    func testAHistoryShorterThanThePageStillReadsOldestFirst() {
        let page = Array(archive.prefix(3).reversed())   // three messages, newest first

        XCTAssertEqual(reading(page).map(\.index), [0, 1, 2])
    }

    /// The function sorts rather than reversing, so a page handed back in some other order —
    /// a rearranged `order` clause, a tie-break that moved — still renders correctly.
    func testAScrambledPageIsStillPutInReadingOrder() {
        let scrambled = [archive[7], archive[2], archive[9], archive[0]]

        XCTAssertEqual(reading(scrambled).map(\.index), [0, 2, 7, 9])
    }

    /// Rows sharing a `created_at` to the microsecond keep their flipped arrival order, so
    /// the output is a function of the page and not of Swift's (unstable) sort.
    func testTiesHoldTheirFlippedArrivalOrder() {
        let same = Date(timeIntervalSince1970: 1_760_000_000)
        let page = [Row(index: 3, at: same), Row(index: 2, at: same), Row(index: 1, at: same)]

        XCTAssertEqual(reading(page).map(\.index), [1, 2, 3])
        XCTAssertEqual(reading(page), reading(page), "deterministic")
    }

    func testAnEmptyHistoryStaysEmpty() {
        XCTAssertTrue(reading([]).isEmpty)
    }

    // MARK: - The page itself

    /// Scroll-back for the athlete has to comfortably exceed the coach's own window, or
    /// shrinking one would silently shrink the other.
    func testThePageIsLargerThanTheCoachWindow() {
        XCTAssertGreaterThan(ChatHistory.pageSize, 24)
    }
}
