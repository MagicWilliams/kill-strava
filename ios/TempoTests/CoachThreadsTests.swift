import XCTest
@testable import Tempo

/// Threads, recaps and the memory count (#87).
///
/// The bug these are written against is the one #93 was a cousin of: nothing here crashes
/// when it is wrong. A thread list sorted by `started_at` instead of `last_message_at` puts
/// the conversation you are in the middle of third; a recap that falls back to "" shows a
/// blank card; a summarize trigger that fires one message too early writes "Picking up
/// from" at the top of the chat it is summarizing. All of it looks like a working screen.
///
/// So each rule gets a test, with the numbers written out rather than derived from the
/// constants — if `idleWindow` moves, these should have to be re-read, not silently follow.
final class CoachThreadsTests: XCTestCase {

    // MARK: - Fixtures

    /// 2026-10-16 12:00 UTC, a Friday. Threads are dated relative to it.
    private let now = Date(timeIntervalSince1970: 1_792_152_000)

    private func row(
        _ id: UUID = UUID(),
        title: String? = nil,
        summary: String? = nil,
        startedHoursAgo: Double,
        lastHoursAgo: Double? = nil,
        messages: Int? = nil
    ) -> CoachThreads.Row {
        CoachThreads.Row(
            id: id,
            title: title,
            summary: summary,
            startedAt: now.addingTimeInterval(-startedHoursAgo * 3600),
            lastMessageAt: now.addingTimeInterval(-(lastHoursAgo ?? startedHoursAgo) * 3600),
            messageCount: messages
        )
    }

    private func action(_ json: String) throws -> ProposedAction {
        try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
    }

    private func record(_ json: String, at hoursAgo: Double = 1) throws -> ChangeLedger.Record {
        ChangeLedger.Record(
            messageID: UUID(),
            date: now.addingTimeInterval(-hoursAgo * 3600),
            text: "",
            action: try action(json)
        )
    }

    // MARK: - List order

    /// The whole point of ordering by `last_message_at`: a thread started days ago and
    /// replied to an hour ago is the live one.
    func testTheListLeadsWithTheMostRecentlyActiveThreadNotTheNewestOne() {
        let old = row(title: "Pacing Chicago", startedHoursAgo: 72, lastHoursAgo: 1)
        let young = row(title: "Shoes", startedHoursAgo: 5, lastHoursAgo: 5)

        XCTAssertEqual(CoachThreads.inListOrder([young, old]).map(\.title), ["Pacing Chicago", "Shoes"])
    }

    func testTiesAreBrokenByStartThenIdSoTheOrderIsAFunctionOfTheRows() {
        let a = row(UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!, startedHoursAgo: 4, lastHoursAgo: 2)
        let b = row(UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!, startedHoursAgo: 4, lastHoursAgo: 2)
        let newerStart = row(startedHoursAgo: 3, lastHoursAgo: 2)

        let ordered = CoachThreads.inListOrder([a, b, newerStart])
        XCTAssertEqual(ordered.first?.id, newerStart.id, "same last message, later start wins")
        XCTAssertEqual(CoachThreads.inListOrder([a, b]), CoachThreads.inListOrder([b, a]), "deterministic")
    }

    func testAnEmptyListStaysEmpty() {
        XCTAssertTrue(CoachThreads.inListOrder([]).isEmpty)
        XCTAssertNil(CoachThreads.active(in: [], now: now))
        XCTAssertTrue(CoachThreads.awaitingSummary([], now: now).isEmpty)
    }

    // MARK: - Which thread is live

    func testTheNewestThreadIsTheActiveOneWhileItIsStillWarm() {
        let live = row(title: "Race-week shakeout", startedHoursAgo: 3, lastHoursAgo: 0.5)

        XCTAssertEqual(CoachThreads.active(in: [live], now: now)?.id, live.id)
    }

    /// Past the idle window the conversation is over. Continuing it would append to a thread
    /// that is already being summarized, so the next message starts a new one.
    func testAThreadIdleForSixHoursIsNoLongerActive() {
        let stale = row(startedHoursAgo: 12, lastHoursAgo: 6)

        XCTAssertTrue(CoachThreads.isIdle(stale, now: now), "exactly six hours is idle, not nearly idle")
        XCTAssertNil(CoachThreads.active(in: [stale], now: now))
    }

    func testFiveHoursFiftyNineIsStillTheSameConversation() {
        let nearlyStale = row(startedHoursAgo: 12, lastHoursAgo: 5.98)

        XCTAssertFalse(CoachThreads.isIdle(nearlyStale, now: now))
        XCTAssertNotNil(CoachThreads.active(in: [nearlyStale], now: now))
    }

    // MARK: - Who is owed a summary

    /// Starting a new chat is the athlete saying the last one is finished — no waiting.
    func testStartingANewThreadPutsThePreviousOneInTheSummaryQueueImmediately() {
        let previous = row(title: nil, startedHoursAgo: 2, lastHoursAgo: 1, messages: 6)
        let fresh = row(startedHoursAgo: 0.1, messages: 1)

        let owed = CoachThreads.awaitingSummary([previous, fresh], now: now)
        XCTAssertEqual(owed.map(\.id), [previous.id], "the one just left, and not the one just opened")
    }

    func testTheOnlyThreadIsOwedASummaryOnceItHasGoneQuiet() {
        let quiet = row(startedHoursAgo: 30, lastHoursAgo: 8, messages: 4)

        XCTAssertEqual(CoachThreads.awaitingSummary([quiet], now: now).map(\.id), [quiet.id])
    }

    func testAThreadTheAthleteIsStillInIsLeftAlone() {
        let live = row(startedHoursAgo: 1, lastHoursAgo: 0.2, messages: 3)

        XCTAssertTrue(
            CoachThreads.awaitingSummary([live], now: now).isEmpty,
            "summarizing a live thread is how 'Picking up from' lands on top of its own conversation"
        )
    }

    func testASummarizedThreadIsNeverAskedAgain() {
        let done = row(title: "Pacing Chicago", summary: "Settled on 7:25 through 20.",
                       startedHoursAgo: 48, lastHoursAgo: 40, messages: 9)

        XCTAssertTrue(CoachThreads.awaitingSummary([done], now: now).isEmpty)
    }

    /// A thread the athlete opened and never typed in. There is nothing to write up, and a
    /// model asked anyway would invent a conversation.
    func testAnEmptyThreadIsSkipped() {
        let empty = row(startedHoursAgo: 20, lastHoursAgo: 20, messages: 0)
        let real = row(startedHoursAgo: 19, lastHoursAgo: 19, messages: 5)

        XCTAssertEqual(CoachThreads.awaitingSummary([empty, real], now: now).map(\.id), [real.id])
    }

    /// An uncounted thread is not an empty one: `messageCount` is nil when the caller didn't
    /// count, and refusing to summarize on that basis would stall every recap.
    func testAnUncountedThreadIsStillSummarized() {
        let uncounted = row(startedHoursAgo: 20, lastHoursAgo: 20, messages: nil)

        XCTAssertEqual(CoachThreads.awaitingSummary([uncounted], now: now).map(\.id), [uncounted.id])
    }

    func testTheQueueRunsOldestFirst() {
        let oldest = row(startedHoursAgo: 90, lastHoursAgo: 88, messages: 3)
        let middle = row(startedHoursAgo: 60, lastHoursAgo: 58, messages: 3)
        let newest = row(startedHoursAgo: 30, lastHoursAgo: 28, messages: 3)

        XCTAssertEqual(
            CoachThreads.awaitingSummary([middle, newest, oldest], now: now).map(\.id),
            [oldest.id, middle.id, newest.id]
        )
    }

    /// "Has this been written up" has one definition. A whitespace summary read as written
    /// by the queue and as blank by the list would leave the thread permanently recap-less.
    func testAWhitespaceSummaryIsStillOwedARecap() {
        let blank = row(title: "Pacing", summary: "   ", startedHoursAgo: 30, lastHoursAgo: 28, messages: 4)

        XCTAssertNil(CoachThreads.recapText(blank))
        XCTAssertEqual(CoachThreads.awaitingSummary([blank], now: now).map(\.id), [blank.id])
        XCTAssertNil(CoachThreads.predecessor(of: UUID(), in: [blank]))
    }

    // MARK: - Which conversation a thread picks up from

    func testAThreadPicksUpFromTheWrittenUpConversationBeforeIt() {
        let older = row(title: "Pacing", summary: "Settled on 7:25.", startedHoursAgo: 50, lastHoursAgo: 48)
        let previous = row(title: "Shoes", summary: "New pair logged.", startedHoursAgo: 30, lastHoursAgo: 28)
        let mine = row(startedHoursAgo: 2, lastHoursAgo: 1)

        XCTAssertEqual(
            CoachThreads.predecessor(of: mine.id, in: [older, previous, mine])?.id, previous.id,
            "the one that had just finished, not the oldest one with a recap"
        )
        XCTAssertEqual(CoachThreads.predecessor(of: previous.id, in: [older, previous, mine])?.id, older.id)
    }

    /// Reopening a conversation from the archive must not show a recap of one that happened
    /// after it — a note about the future, presented as what the coach is carrying in.
    func testAnOlderThreadDoesNotPickUpFromANewerOne() {
        let oldest = row(startedHoursAgo: 90, lastHoursAgo: 88)
        let middle = row(title: "Pacing", summary: "Settled on 7:25.", startedHoursAgo: 60, lastHoursAgo: 58)
        let newest = row(title: "The calf", summary: "Watching it.", startedHoursAgo: 10, lastHoursAgo: 8)

        XCTAssertNil(
            CoachThreads.predecessor(of: oldest.id, in: [oldest, middle, newest]),
            "nothing was written up before the oldest conversation started"
        )
        XCTAssertEqual(CoachThreads.predecessor(of: newest.id, in: [oldest, middle, newest])?.id, middle.id)
    }

    func testAnUnsummarizedPredecessorCarriesNothing() {
        let previous = row(startedHoursAgo: 30, lastHoursAgo: 28)   // finished, not yet written up
        let mine = row(startedHoursAgo: 1, lastHoursAgo: 1)

        XCTAssertNil(CoachThreads.predecessor(of: mine.id, in: [previous, mine]))
    }

    /// The interview resolves its thread without reading the list, so its id matches no row.
    func testAThreadWithNoRowFallsBackToTheNewestRecap() {
        let written = row(title: "Pacing", summary: "Settled on 7:25.", startedHoursAgo: 30, lastHoursAgo: 28)

        XCTAssertEqual(CoachThreads.predecessor(of: UUID(), in: [written])?.id, written.id)
        XCTAssertNil(CoachThreads.predecessor(of: nil, in: []))
    }

    // MARK: - What a row says

    func testAnUnsummarizedThreadSaysSoInsteadOfShowingABlankRow() {
        let live = row(startedHoursAgo: 1, messages: 4)

        XCTAssertEqual(CoachThreads.displayTitle(live), "This conversation")
        XCTAssertEqual(CoachThreads.recap(live, isActive: true), "Still going.")
        XCTAssertEqual(
            CoachThreads.recap(live, isActive: false), "Recap not written yet.",
            "an older thread with no summary is waiting on a round trip, and must not look like a recap"
        )
    }

    func testASummarizedThreadShowsItsOwnWords() {
        let done = row(title: "Race-week shakeout and the calf",
                       summary: "Calf tight after Tuesday's strides. Thursday's tempo became an easy 5.",
                       startedHoursAgo: 5, lastHoursAgo: 4, messages: 6)

        XCTAssertEqual(CoachThreads.displayTitle(done), "Race-week shakeout and the calf")
        XCTAssertEqual(CoachThreads.recap(done, isActive: false), done.summary)
    }

    /// Whitespace from the model is not a title. This is the case that would have shipped a
    /// row with a 20-point blank where the title goes.
    func testAWhitespaceTitleOrSummaryFallsBack() {
        let blank = row(title: "   ", summary: "\n ", startedHoursAgo: 9, lastHoursAgo: 9, messages: 2)

        XCTAssertEqual(CoachThreads.displayTitle(blank), "This conversation")
        XCTAssertEqual(CoachThreads.recap(blank, isActive: false), "Recap not written yet.")
    }

    func testAnEmptyThreadNamesItself() {
        let empty = row(startedHoursAgo: 2, messages: 0)

        XCTAssertEqual(CoachThreads.displayTitle(empty), "Empty chat")
        XCTAssertEqual(CoachThreads.recap(empty, isActive: true), "Nothing said yet.")
    }

    // MARK: - Change tags

    func testOneChangeOfAKindNamesItself() throws {
        let tags = CoachThreads.tags(from: [
            try record("""
                {"type":"update_session","summary":"Swap Thursday's tempo for an easy 5",
                 "session_id":"\(UUID().uuidString)","detail":"5 mi easy","note":"Calf is tight"}
                """),
        ])

        XCTAssertEqual(tags.map(\.label), ["Plan · Session changed"])
        XCTAssertEqual(tags.map(\.kind), [.plan])
    }

    func testSeveralChangesOfOneKindAreCounted() throws {
        let session = UUID().uuidString
        let tags = CoachThreads.tags(from: [
            try record("""
                {"type":"update_session","summary":"Easy 5 on Thursday","session_id":"\(session)",
                 "detail":"5 mi easy","note":"Calf"}
                """, at: 3),
            try record("""
                {"type":"update_plan_settings","summary":"Drop to 5 days","days_per_week":5}
                """, at: 2),
        ])

        XCTAssertEqual(tags.map(\.label), ["Plan · 2 changes"])
    }

    /// One tag per kind, in the ledger's own order, so the row doesn't reshuffle its pills
    /// depending on which change the coach happened to make first.
    func testTagsAreOnePerKindInLedgerOrder() throws {
        let tags = CoachThreads.tags(from: [
            try record("""
                {"type":"update_athlete","summary":"Recorded: max HR 197","max_hr":197}
                """, at: 1),
            try record("""
                {"type":"amend_run","summary":"Tuesday was 8.0","run_id":"\(UUID().uuidString)",
                 "distance_m":12875,"note":"GPS cut the river loop"}
                """, at: 2),
            try record("""
                {"type":"update_session","summary":"Easy 5","session_id":"\(UUID().uuidString)",
                 "detail":"5 mi easy","note":"Calf"}
                """, at: 3),
        ])

        XCTAssertEqual(tags.map(\.kind), [.plan, .runs, .body], "Kind.allCases order, not the order applied")
        XCTAssertEqual(tags.count, Set(tags.map(\.kind)).count, "no kind appears twice")
    }

    func testAThreadThatChangedNothingHasNoTags() {
        XCTAssertTrue(CoachThreads.tags(from: []).isEmpty)
    }

    // MARK: - Picking up from

    func testTheNoteCarriesThePreviousRecapAndTheMemoryCount() {
        let note = CoachThreads.pickingUpNote(
            previousSummary: "Race pace settled at 7:25 through mile 20.",
            previousDayLabel: "Tue",
            memoryCount: 7
        )

        XCTAssertEqual(
            note,
            "Tue: Race pace settled at 7:25 through mile 20. Coach is carrying 7 things it knows about you."
        )
    }

    func testAFirstEverConversationHasNoNoteAtAll() {
        XCTAssertNil(
            CoachThreads.pickingUpNote(previousSummary: nil, previousDayLabel: nil, memoryCount: 0),
            "an empty card claims continuity the coach doesn't have"
        )
        XCTAssertNil(CoachThreads.pickingUpNote(previousSummary: "  ", previousDayLabel: "Tue", memoryCount: 0))
    }

    func testMemoryAloneIsWorthSaying() {
        XCTAssertEqual(
            CoachThreads.pickingUpNote(previousSummary: nil, previousDayLabel: nil, memoryCount: 1),
            "Coach is carrying 1 thing it knows about you."
        )
    }

    func testARecapWithNoDayLabelStillReads() {
        XCTAssertEqual(
            CoachThreads.pickingUpNote(previousSummary: "Settled on sub-3:15.", previousDayLabel: nil, memoryCount: 0),
            "Settled on sub-3:15."
        )
    }
}
