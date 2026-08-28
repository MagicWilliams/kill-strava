import XCTest
@testable import Tempo

/// Regression suite for the sync that kept 348 runs and wrote none of them (#37).
///
/// The bug had no crash and no error log. HR enrichment ran between the dedupe and the
/// insert — one serial HealthKit query per new run, on the premise that "kept is small" —
/// and with a five-year archive `kept` was 348. The refresh never reached the write, and
/// three telemetry events hours apart carried byte-identical counts as the same 348 were
/// recomputed on every launch.
///
/// What these tests hold down: the work that follows a write is bounded by a number, and
/// the sync reports what it actually wrote rather than what it hoped to.
final class SyncPassTests: XCTestCase {

    /// A stored run, `daysAgo` before the fixed clock the tests reason against.
    private func row(daysAgo: Double, avgHR: Int? = nil, corrected: Bool = false,
                     source: String = "healthkit") -> RunSummary {
        RunSummary(
            id: UUID(),
            start: Self.now.addingTimeInterval(-daysAgo * 86_400),
            distanceM: 10_000,
            durationS: 3_000,
            avgHR: avgHR,
            corrected: corrected,
            source: source
        )
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15, fixed

    // MARK: - The work that follows the write is bounded

    func testTheArchiveBacklogDoesNotBecomeAQueryPerRun() {
        // The exact shape of #37: 348 candidates cleared dedupe on every refresh. Whatever
        // they are, they are old, and old runs are not worth a HealthKit round trip each.
        let backlog = (0..<348).map { row(daysAgo: 200 + Double($0)) }
        XCTAssertTrue(SyncPass.hrEnrichmentTargets(rows: backlog, now: Self.now).isEmpty)
    }

    func testEnrichmentIsCappedEvenWhenEveryRowQualifies() {
        // 100 recent runs all missing HR: the refresh takes 25 and leaves the rest for the
        // next one. The cap is the point — an uncapped loop here is what stalled the write.
        let recent = (0..<100).map { row(daysAgo: Double($0) / 10) }
        XCTAssertEqual(SyncPass.hrEnrichmentTargets(rows: recent, now: Self.now).count,
                       SyncPass.hrEnrichmentLimit)
    }

    func testCapIsNeverExceededByARowsWorthOfSlack() {
        let recent = (0..<40).map { row(daysAgo: Double($0)) }
        XCTAssertEqual(SyncPass.hrEnrichmentTargets(rows: recent, now: Self.now, limit: 3).count, 3)
        XCTAssertTrue(SyncPass.hrEnrichmentTargets(rows: recent, now: Self.now, limit: 0).isEmpty)
    }

    func testOnlyRowsThatAreActuallyMissingHeartRateAreEnriched() {
        let rows = [row(daysAgo: 1, avgHR: 148), row(daysAgo: 2), row(daysAgo: 3, avgHR: 155)]
        let targets = SyncPass.hrEnrichmentTargets(rows: rows, now: Self.now)
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.id, rows[1].id)
    }

    func testCorrectedRowsAreNeverRecomputed() {
        // The athlete's word outranks the math: a corrected row keeps its number even
        // when the HR column is empty.
        let rows = [row(daysAgo: 1, corrected: true), row(daysAgo: 2, corrected: true)]
        XCTAssertTrue(SyncPass.hrEnrichmentTargets(rows: rows, now: Self.now).isEmpty)
    }

    func testManualRunsAreLeftAloneBecauseHealthKitHasNothingToSayAboutThem() {
        let rows = [row(daysAgo: 1, source: "manual"), row(daysAgo: 2, source: "manual")]
        XCTAssertTrue(SyncPass.hrEnrichmentTargets(rows: rows, now: Self.now).isEmpty)
    }

    func testTheWindowEdgeIsInclusiveAtNinetyDays() {
        let inside = row(daysAgo: 89.9)
        let outside = row(daysAgo: 90.1)
        XCTAssertEqual(SyncPass.hrEnrichmentTargets(rows: [inside, outside], now: Self.now).count, 1)
    }

    // MARK: - What was actually written

    func testWriteReportCountsRowsAndTheSpanTheyCover() {
        // The number David needs after this ships: not "kept", but "written", and over
        // which years — that is what settles whether the 348 are archive or last week.
        let written = [row(daysAgo: 0), row(daysAgo: 400), row(daysAgo: 10)]
        let report = SyncPass.writeReport(for: written)
        XCTAssertEqual(report.count, 3)
        XCTAssertEqual(report.oldest, "2025-12-11")
        XCTAssertEqual(report.newest, "2027-01-15")
    }

    func testWriteReportOfASingleRunHasOneDayForBothEnds() {
        let report = SyncPass.writeReport(for: [row(daysAgo: 0)])
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.oldest, report.newest)
    }

    func testWriteReportOfNothingClaimsNothing() {
        let report = SyncPass.writeReport(for: [])
        XCTAssertEqual(report, SyncPass.WriteReport(count: 0, oldest: nil, newest: nil))
    }

    // MARK: - When a drop is worth saying out loud

    func testAStandingConditionIsReportedOnceRatherThanEveryRefresh() {
        // David's phone holds ~220 unexplained near-duplicates that are still there on the
        // next refresh, and the one after that. Announcing them every time is what made the
        // first event the table ever recorded into noise.
        XCTAssertTrue(SyncPass.reExportSignal(unexplained: 220, lastSeen: nil),
                      "the first sighting is news")
        XCTAssertFalse(SyncPass.reExportSignal(unexplained: 220, lastSeen: 220),
                       "the same number next refresh is not news")
    }

    func testARealReExportBreaksTheSilence() {
        // Garmin rewrites a week of workouts under fresh uuids: the unexplained count
        // moves, and that movement is the signal.
        XCTAssertTrue(SyncPass.reExportSignal(unexplained: 227, lastSeen: 220))
    }

    func testTheConditionClearingIsAlsoNotAnAlarm() {
        // Duplicates disappearing is good news, and good news does not need an event.
        XCTAssertFalse(SyncPass.reExportSignal(unexplained: 0, lastSeen: 220))
    }

    func testAHandfulOfDropsIsOrdinaryClockDrift() {
        XCTAssertFalse(SyncPass.reExportSignal(unexplained: 4, lastSeen: nil))
        XCTAssertTrue(SyncPass.reExportSignal(unexplained: 5, lastSeen: nil))
    }

    func testAHealthyRefreshSaysNothingAtAll() {
        // Every candidate already ours by uuid: 1,690 drops, zero of them unexplained.
        XCTAssertFalse(SyncPass.reExportSignal(unexplained: 0, lastSeen: nil))
    }
}
