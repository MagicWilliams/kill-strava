import XCTest
@testable import Tempo

/// Regression suite for the sync that kept 348 runs and wrote none of them (#37).
///
/// The bug had no crash and no error log. HR enrichment ran between the dedupe and the
/// insert (one serial HealthKit query per new run, on the premise that "kept is small")
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

    // MARK: - An unfinished read of the retired uuids is not an empty one (2026-11-05)

    func testAFinishedReadCarriesItsIDs() {
        let read = SyncPass.retiredRead(ids: ["a", "b"], reachedLastPage: true, failure: nil)
        XCTAssertEqual(read, .complete(["a", "b"]))
        XCTAssertEqual(read.ids, ["a", "b"])
    }

    func testAFinishedReadOfNothingIsStillAnAnswer() {
        // Over-holding would be the other half of the bug: an athlete who has never retired a
        // run gets this answer on every refresh, and their sync must go ahead on it.
        let read = SyncPass.retiredRead(ids: [], reachedLastPage: true, failure: nil)
        XCTAssertEqual(read.ids, [], "empty and known, not nil")
    }

    func testBothSpellingsOfCancellationAreCancelledNotUnreadable() {
        // The exact error from the incident, and the URLSession form of the same thing.
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            XCTAssertEqual(SyncPass.retiredRead(ids: [], reachedLastPage: false, failure: error), .cancelled)
        }
    }

    func testARealFailureIsUnreadable() {
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "column missing"))
        for error: Error in [URLError(.timedOut), URLError(.notConnectedToInternet), decoding] {
            XCTAssertEqual(SyncPass.retiredRead(ids: [], reachedLastPage: false, failure: error), .unreadable)
        }
    }

    func testAFailureOnALaterPageDiscardsThePagesAlreadyRead() {
        // A partial set misses the same way an empty one does, only for fewer runs.
        let read = SyncPass.retiredRead(ids: ["page-one"], reachedLastPage: false, failure: URLError(.timedOut))
        XCTAssertEqual(read, .unreadable)
        XCTAssertNil(read.ids)
    }

    func testTheFailureOutranksAReachedLastPage() {
        // Neither call site in the read passes this today. The rule still has one answer.
        let read = SyncPass.retiredRead(ids: ["a"], reachedLastPage: true, failure: URLError(.timedOut))
        XCTAssertNil(read.ids)
    }

    func testRunningOutOfLeashIsNotAnAnswer() {
        // No error, plenty of ids, and still no idea what the next page held.
        let read = SyncPass.retiredRead(ids: ["a"], reachedLastPage: false, failure: nil)
        XCTAssertEqual(read, .unreadable)
        XCTAssertNil(read.ids)
    }

    func testNothingButACompleteReadOffersIDsToFilterAgainst() {
        XCTAssertNil(SyncPass.RetiredRead.cancelled.ids)
        XCTAssertNil(SyncPass.RetiredRead.unreadable.ids)
    }

    /// Why the pass holds: the numbers an unknown set produces, in miniature. On 2026-11-05
    /// the 120 retired uuids split into 47 kept and 73 "never stored", and that second number
    /// is what `reExportSignal` reads, so one cancelled read made two false events.
    func testReconcilingAgainstAnEmptySetIsWhatInventsAReExport() {
        let keeper = run(externalID: "keeper-uuid", minutesAfterKeeper: 0)
        let nearTwin = run(externalID: "retired-near", minutesAfterKeeper: 1, meters: 11_000)
        let farTwin = run(externalID: "retired-far", minutesAfterKeeper: 600, meters: 11_000)
        let candidates = [keeper, nearTwin, farTwin]

        let known = RunDedupe.reconcile(candidates: candidates, existing: [keeper],
                                        retiredExternalIDs: ["retired-near", "retired-far"])
        XCTAssertTrue(known.inserts.isEmpty)
        XCTAssertEqual(known.droppedAlreadyStored, 3)
        XCTAssertEqual(known.droppedUnknownUUID, 0)

        let guessed = RunDedupe.reconcile(candidates: candidates, existing: [keeper],
                                          retiredExternalIDs: [])
        XCTAssertEqual(guessed.inserts.map(\.externalID), ["retired-far"], "the 47")
        XCTAssertEqual(guessed.droppedAlreadyStored, 1)
        XCTAssertEqual(guessed.droppedUnknownUUID, 1, "the 73")
    }

    /// And the harm a held pass rules out: this graft only runs after an insert, and an insert
    /// now only follows a complete read, so `resolve` can no longer be handed a guess.
    func testAGuessedEmptySetWouldGraftARetiredDuplicateOntoTheScreen() {
        let keeper = run(externalID: "keeper-uuid", minutesAfterKeeper: 0)
        let farTwin = run(externalID: "retired-far", minutesAfterKeeper: 600, meters: 11_000)

        let guessed = RunFetch.resolve(.incomplete([keeper]), ingested: [farTwin],
                                       onScreen: [keeper], retiredExternalIDs: [])
        XCTAssertEqual(guessed.runs?.count, 2, "the premise: an empty set double counts it")

        let known = RunFetch.resolve(.incomplete([keeper]), ingested: [farTwin],
                                     onScreen: [keeper], retiredExternalIDs: ["retired-far"])
        XCTAssertEqual(known.runs, [keeper])
    }

    /// A HealthKit copy with its uuid, placed relative to one fixed keeper. Distances differ
    /// between keeper and twins so neither is mistaken for the other clock of the same run.
    private func run(externalID: String, minutesAfterKeeper: Double, meters: Int = 13_000) -> RunSummary {
        RunSummary(
            id: UUID(),
            start: Self.now.addingTimeInterval(minutesAfterKeeper * 60),
            distanceM: meters,
            durationS: 3_000,
            avgHR: nil,
            corrected: false,
            source: "healthkit",
            externalID: externalID
        )
    }

    // MARK: - The work that follows the write is bounded

    func testTheArchiveBacklogDoesNotBecomeAQueryPerRun() {
        // The exact shape of #37: 348 candidates cleared dedupe on every refresh. Whatever
        // they are, they are old, and old runs are not worth a HealthKit round trip each.
        let backlog = (0..<348).map { row(daysAgo: 200 + Double($0)) }
        XCTAssertTrue(SyncPass.hrEnrichmentTargets(rows: backlog, now: Self.now).isEmpty)
    }

    func testEnrichmentIsCappedEvenWhenEveryRowQualifies() {
        // 100 recent runs all missing HR: the refresh takes 25 and leaves the rest for the
        // next one. The cap is the point. An uncapped loop here is what stalled the write.
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
        // which years. That is what settles whether the 348 are archive or last week.
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

    // MARK: - The report comes from the server's answer, not the client's intent (#94)

    func testAPassWhereEveryCandidateConflictsReportsNothingWritten() {
        // The exact shape of #94. Six passes across three days and three app builds each
        // emitted `count=47 oldest=2021-12-26 newest=2025-04-27`; `runs` gained zero rows.
        // All 47 were archive runs already stored under a different `external_id`, and
        // `ignoreDuplicates: true` discards a conflicting row with no error and nothing
        // returned. So: 47 proposed, the server confirms none, the report says none.
        let proposed = (0..<47).map { row(daysAgo: 400 + Double($0)) }
        let written = SyncPass.confirmedWrites(proposed: proposed, writtenExternalIDs: [])

        XCTAssertTrue(written.isEmpty)
        XCTAssertEqual(SyncPass.writeReport(for: written),
                       SyncPass.WriteReport(count: 0, oldest: nil, newest: nil),
                       "a pass that wrote nothing must not report the set it hoped to write")
    }

    func testOnlyTheRowsTheDatabaseTookReachTheReport() {
        // A partial pass is the case that makes "count" worth trusting: some candidates are
        // genuinely new, the rest collide. The span must describe the two that landed, not
        // the five that were offered.
        let proposed = (0..<5).map { row(daysAgo: Double($0) * 100) }
        let taken = [proposed[1], proposed[3]]
        let written = SyncPass.confirmedWrites(
            proposed: proposed,
            writtenExternalIDs: taken.map(\.id.uuidString)
        )

        XCTAssertEqual(written.map(\.id), taken.map(\.id))
        let report = SyncPass.writeReport(for: written)
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(report.oldest, "2026-03-21")   // 300 days before the fixed clock
        XCTAssertEqual(report.newest, "2026-10-07")   // 100 days before it
    }

    func testEveryCandidateLandingIsStillReportedInFull() {
        let proposed = (0..<47).map { row(daysAgo: 1 + Double($0)) }
        let written = SyncPass.confirmedWrites(proposed: proposed,
                                               writtenExternalIDs: proposed.map(\.id.uuidString))
        XCTAssertEqual(SyncPass.writeReport(for: written).count, 47)
    }

    func testIDCasingCannotSilentlyZeroTheCount() {
        // `UUID.uuidString` is uppercase; the column is plain text. A round trip that
        // lowercased it would match nothing and report 0 writes on a pass that wrote
        // everything. The same lie as #94 with the sign flipped.
        let proposed = (0..<3).map { row(daysAgo: Double($0)) }
        let lowercased = proposed.map { $0.id.uuidString.lowercased() }
        XCTAssertEqual(SyncPass.confirmedWrites(proposed: proposed, writtenExternalIDs: lowercased).count, 3)
    }

    func testAnIDWeNeverProposedIsNotCountedAsOurWrite() {
        // Defensive: the report summarises rows from *this* pass. An id we cannot account
        // for inflates nothing, because the count comes from the matched summaries.
        let proposed = [row(daysAgo: 1)]
        let written = SyncPass.confirmedWrites(
            proposed: proposed,
            writtenExternalIDs: [proposed[0].id.uuidString, UUID().uuidString]
        )
        XCTAssertEqual(written.count, 1)
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
