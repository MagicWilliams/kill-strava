import XCTest
@testable import Tempo

/// Today's "Coach's read" used to exist only for a run that fulfilled today's planned
/// session. With no plan there is no session, so between blocks the home screen could never
/// show a single thing the coach had said — even though every run the athlete opened was
/// still being read (#101). The just-running Today shows the newest read instead, and these
/// pin which one, and that an old read is never passed off as being about this morning.
final class LatestReadTests: XCTestCase {

    private let lastRun = UUID()
    private let olderRun = UUID()

    private func read(_ run: UUID, _ text: String = "Steady aerobic work; HR stayed honest.", daysAgo: Double = 0) -> LatestRead.Read {
        LatestRead.Read(runID: run, runStart: Date(timeIntervalSince1970: 1_791_000_000 - daysAgo * 86_400), text: text)
    }

    func testZeroRunsAndNoReadsShowsNothing() {
        XCTAssertEqual(LatestRead.state(lastRunID: nil, latest: nil), .none)
    }

    /// 2,000 runs, none of them opened: invite, don't generate. A takeaway is a Claude call.
    func testRunsWithNoReadInvitesOne() {
        XCTAssertEqual(LatestRead.state(lastRunID: lastRun, latest: nil), .invite(lastRun: lastRun))
    }

    func testAReadAboutTheLastRunIsCurrent() {
        let r = read(lastRun)
        XCTAssertEqual(LatestRead.state(lastRunID: lastRun, latest: r), .current(r))
    }

    /// The read is real but about an earlier run. It still shows — it's the coach's latest
    /// word — but marked as behind, so the card can date it and offer the newer run.
    func testAReadAboutAnEarlierRunIsBehind() {
        let r = read(olderRun, daysAgo: 4)
        XCTAssertEqual(LatestRead.state(lastRunID: lastRun, latest: r), .behind(r, lastRun: lastRun))
    }

    /// The column has held empty strings. An empty card under "Coach's read" is worse than
    /// the invitation.
    func testABlankTakeawayIsNoTakeaway() {
        XCTAssertEqual(LatestRead.state(lastRunID: lastRun, latest: read(lastRun, "  \n")), .invite(lastRun: lastRun))
        XCTAssertEqual(LatestRead.state(lastRunID: nil, latest: read(lastRun, "")), .none)
    }

    /// Health unavailable and the run list empty, but the DB still holds a read. It is
    /// still true; show it.
    func testAReadWithNoRunsOnScreenStillShows() {
        let r = read(olderRun)
        XCTAssertEqual(LatestRead.state(lastRunID: nil, latest: r), .current(r))
    }

    // MARK: - A read landing while the app is open

    /// Generating a read for an old run from the archive must not knock the newest read
    /// off Today.
    @MainActor
    func testAReadForAnOlderRunDoesNotDisplaceANewerOne() {
        let store = RunStore()
        let newer = read(lastRun, "newer", daysAgo: 0)
        store.noteTakeaway(newer)
        store.noteTakeaway(read(olderRun, "older", daysAgo: 30))
        XCTAssertEqual(store.latestRead, newer)

        let newest = read(UUID(), "newest", daysAgo: -1)
        store.noteTakeaway(newest)
        XCTAssertEqual(store.latestRead, newest)
    }
}
