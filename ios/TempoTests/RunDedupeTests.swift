import XCTest
@testable import Tempo

/// Regression suite for the Garmin re-export double-count (2026-07-10):
/// a settings change in Garmin Connect rewrote the week's workouts as new HKWorkout
/// objects, uuid dedupe let them through, and the weekly counter read 31 instead of 15.
final class RunDedupeTests: XCTestCase {

    private func run(_ minutesFromEpoch: Int, miles: Double = 6, id: UUID = UUID()) -> RunSummary {
        RunSummary(
            id: id,
            start: Date(timeIntervalSince1970: TimeInterval(minutesFromEpoch * 60)),
            distanceM: Int(miles * 1609.34),
            durationS: Int(miles * 9 * 60),
            avgHR: nil
        )
    }

    func testKeepsGenuinelyNewRuns() {
        let existing = [run(0)]
        let candidates = [run(24 * 60), run(48 * 60)]   // next two days
        XCTAssertEqual(RunDedupe.newRuns(from: candidates, existing: existing).count, 2)
    }

    func testDropsReExportOfAnExistingRun() {
        // Same run, brand-new uuid, clock drifted by 90 seconds.
        let original = run(600)
        let reExport = run(601, id: UUID())
        let kept = RunDedupe.newRuns(from: [reExport], existing: [original])
        XCTAssertTrue(kept.isEmpty, "a re-export within the window must not be re-inserted")
    }

    func testDropsDuplicatesWithinASingleBatch() {
        // Garmin can emit both copies in the same read — nothing in the DB to compare against.
        let a = run(600)
        let b = run(602, id: UUID())
        let kept = RunDedupe.newRuns(from: [a, b], existing: [])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.id, a.id, "first candidate in a cluster wins")
    }

    func testBoundaryIsExclusiveAtTheWindowEdge() {
        let existing = [run(0)]
        // Exactly 300s away is NOT a duplicate; one second inside is.
        let atEdge = RunSummary(id: UUID(), start: Date(timeIntervalSince1970: 300),
                                distanceM: 9656, durationS: 3240, avgHR: nil)
        let insideEdge = RunSummary(id: UUID(), start: Date(timeIntervalSince1970: 299),
                                    distanceM: 9656, durationS: 3240, avgHR: nil)
        XCTAssertEqual(RunDedupe.newRuns(from: [atEdge], existing: existing).count, 1)
        XCTAssertEqual(RunDedupe.newRuns(from: [insideEdge], existing: existing).count, 0)
    }

    func testReplaysTheJulyTenthWeek() {
        // The actual shape of the bug: Tue 7.10 and Wed 8.00 already recorded, Garmin
        // re-exports both plus the raw 5.85 that the 8.00 correction replaced.
        let tue = run(0, miles: 7.10)
        let wed = run(24 * 60, miles: 8.00)
        let existing = [tue, wed]
        let reExport = [
            run(1, miles: 7.10),          // Tue again
            run(24 * 60 + 1, miles: 8.00), // Wed again
            run(24 * 60 + 2, miles: 5.85), // the resurrected pre-correction raw row
            run(72 * 60, miles: 3.33)      // a genuinely new Friday run
        ]
        let kept = RunDedupe.newRuns(from: reExport, existing: existing)
        XCTAssertEqual(kept.count, 1, "only the new Friday run survives")
        XCTAssertEqual(kept.first.map { ($0.miles * 100).rounded() / 100 }, 3.33)
    }

    func testEmptyInputs() {
        XCTAssertTrue(RunDedupe.newRuns(from: [], existing: [run(0)]).isEmpty)
        XCTAssertEqual(RunDedupe.newRuns(from: [run(0)], existing: []).count, 1)
    }

    // MARK: - Two clocks, one run

    /// One run at a fixed distance, recorded against a specific clock.
    private func clocked(_ secondsFromEpoch: Int, meters: Int, durationS: Int,
                         avgHR: Int? = nil, id: UUID = UUID()) -> RunSummary {
        RunSummary(
            id: id,
            start: Date(timeIntervalSince1970: TimeInterval(secondsFromEpoch)),
            distanceM: meters,
            durationS: durationS,
            avgHR: avgHR
        )
    }

    func testTwoClocksInOneBatchMergeInsteadOfDroppingOne() {
        // The 2022-04-03 shape: 6.50 mi exported twice, 58:28 moving and 1:02:26 elapsed.
        // The old rule kept whichever HealthKit returned first and binned the other.
        let moving = clocked(0, meters: 10461, durationS: 3508)
        let elapsed = clocked(1, meters: 10461, durationS: 3746)
        let kept = RunDedupe.newRuns(from: [elapsed, moving], existing: [])

        XCTAssertEqual(kept.count, 1, "still one run — this is not two runs")
        XCTAssertEqual(kept.first?.durationS, 3508, "the shorter clock is moving time")
        XCTAssertEqual(kept.first?.elapsedS, 3746, "the longer clock is kept, not discarded")
        XCTAssertEqual(kept.first?.clocks.stoppedS, 238)
    }

    func testMergeKeepsHeartRateFromWhicheverCopyCarriedIt() {
        // Garmin associates HR with one export and not the other; the merged run should
        // not lose it just because the moving-time copy happened to arrive without it.
        let moving = clocked(0, meters: 10461, durationS: 3508, avgHR: nil)
        let elapsed = clocked(2, meters: 10461, durationS: 3746, avgHR: 152)
        XCTAssertEqual(RunDedupe.newRuns(from: [moving, elapsed], existing: []).first?.avgHR, 152)
    }

    func testNearMissDistanceIsStillDroppedNotMerged() {
        // Two devices recording one outing: within a few hundred metres but not identical.
        // Dedupe must still collapse them to one row, and must NOT invent a stopped time
        // out of two unrelated GPS traces.
        let a = clocked(0, meters: 10108, durationS: 2895)
        let b = clocked(3, meters: 10286, durationS: 2965)
        let kept = RunDedupe.newRuns(from: [a, b], existing: [])
        XCTAssertEqual(kept.count, 1)
        XCTAssertNil(kept.first?.elapsedS, "different traces are not two clocks on one run")
    }

    func testASecondClockTeachesAnExistingRowItsElapsedTime() {
        let stored = clocked(0, meters: 10461, durationS: 3508)
        let elapsedCopy = clocked(1, meters: 10461, durationS: 3746)
        let result = RunDedupe.reconcile(candidates: [elapsedCopy], existing: [stored])

        XCTAssertTrue(result.inserts.isEmpty, "the run is already recorded")
        XCTAssertEqual(result.elapsedPatches[stored.id], 3746)
    }

    func testARowHoldingElapsedTimeIsReportedRatherThanRewritten() {
        // The stored row has the LONGER duration, so its "moving time" is really elapsed
        // and its pace has been reading slow for years. Fixing that rewrites history, so
        // the rule reports it and changes nothing.
        let stored = clocked(0, meters: 10461, durationS: 3746)
        let movingCopy = clocked(1, meters: 10461, durationS: 3508)
        let result = RunDedupe.reconcile(candidates: [movingCopy], existing: [stored])

        XCTAssertTrue(result.inserts.isEmpty)
        XCTAssertTrue(result.elapsedPatches.isEmpty, "never silently rewrite duration_s")
        XCTAssertEqual(result.suspectedElapsedStored, [stored.id])
    }

    func testACorrectedRowIsNeverTouched() {
        // The athlete's own edit is the record. A re-export must not amend it, even
        // additively — the corrected duration is not the same quantity HealthKit measured.
        var stored = clocked(0, meters: 10461, durationS: 3508)
        stored.corrected = true
        let elapsedCopy = clocked(1, meters: 10461, durationS: 3746)
        let result = RunDedupe.reconcile(candidates: [elapsedCopy], existing: [stored])
        XCTAssertTrue(result.elapsedPatches.isEmpty)
    }

    // MARK: - Why a candidate was dropped

    /// A stored row as the DB returns it: its own row id, the HealthKit uuid in
    /// `externalID`. That column is the only thing that distinguishes a workout we already
    /// hold from one wearing a new id.
    private func stored(_ minutesFromEpoch: Int, externalID: String) -> RunSummary {
        var run = self.run(minutesFromEpoch)
        run.externalID = externalID
        return run
    }

    /// A HealthKit candidate, whose `externalID` is its own workout uuid.
    private func candidate(_ minutesFromEpoch: Int, externalID: String = UUID().uuidString) -> RunSummary {
        var run = self.run(minutesFromEpoch)
        run.externalID = externalID
        return run
    }

    func testAHealthyRefreshExplainsEveryDropAndSignalsNothing() {
        // The ordinary case, and the one that made the old signal useless: a full HealthKit
        // read re-offers the whole archive, and every dropped candidate is a workout we
        // already store under that exact uuid. 1,690 drops, nothing to report (#37).
        let ids = (0..<50).map { _ in UUID().uuidString }
        let existing = ids.enumerated().map { stored($0.offset * 24 * 60, externalID: $0.element) }
        let candidates = ids.enumerated().map { candidate($0.offset * 24 * 60, externalID: $0.element) }

        let result = RunDedupe.reconcile(candidates: candidates, existing: existing)
        XCTAssertTrue(result.inserts.isEmpty)
        XCTAssertEqual(result.droppedAlreadyStored, 50)
        XCTAssertEqual(result.droppedUnknownUUID, 0, "a workout we already hold is not evidence of anything")
    }

    func testAReExportUnderFreshUUIDsIsCountedSeparately() {
        // What the signal is actually for: the same runs arriving with uuids we have never
        // stored. Dedupe still drops them — but this is the one that is worth an event.
        let ids = (0..<3).map { _ in UUID().uuidString }
        let existing = ids.enumerated().map { stored($0.offset * 24 * 60, externalID: $0.element) }
        let reExported = (0..<3).map { candidate($0 * 24 * 60 + 1) }   // new uuids, clock drifted

        let result = RunDedupe.reconcile(candidates: reExported, existing: existing)
        XCTAssertTrue(result.inserts.isEmpty)
        XCTAssertEqual(result.droppedUnknownUUID, 3)
        XCTAssertEqual(result.droppedAlreadyStored, 0)
    }

    func testBothCopiesArrivingInOneBatchCountAsUnknown() {
        // Nothing in the DB to compare against, so the collision is between two candidates.
        // A second uuid for a run we are about to write is the re-export shape too.
        let result = RunDedupe.reconcile(candidates: [candidate(600), candidate(602)], existing: [])
        XCTAssertEqual(result.inserts.count, 1)
        XCTAssertEqual(result.droppedUnknownUUID, 1)
    }

    func testEveryDropLandsInExactlyOneBucket() {
        // The counts have to add up, or the signal is arguing with the drop total.
        let known = UUID().uuidString
        let existing = [stored(0, externalID: known), stored(24 * 60, externalID: UUID().uuidString)]
        let candidates = [
            candidate(0, externalID: known),   // already ours
            candidate(24 * 60 + 1),            // re-export of the second stored run
            candidate(48 * 60),                // genuinely new
            candidate(48 * 60 + 1)             // ...and its twin, inside this batch
        ]
        let result = RunDedupe.reconcile(candidates: candidates, existing: existing)
        XCTAssertEqual(result.inserts.count, 1)
        XCTAssertEqual(result.droppedAlreadyStored + result.droppedUnknownUUID,
                       candidates.count - result.inserts.count)
        XCTAssertEqual(result.droppedAlreadyStored, 1)
        XCTAssertEqual(result.droppedUnknownUUID, 2)
    }

    // MARK: - A retired row still owns its uuid (#97)

    /// The incident: from 2026-10-09 every sync proposed the same 47 runs, all dated
    /// 2021-12-26 → 2025-04-27, and the database took none of them (#94). They were the
    /// duplicates migrations 0008/0009 retired — timezone re-imports a whole number of hours
    /// from their keepers. Retiring sets `superseded_by` and leaves the row, so each one still
    /// held its `(user_id, source, external_id)` key; but the live archive is all dedupe was
    /// given, and nothing live starts within five minutes of a row that sits hours away.
    private let firstStuck = ISO8601DateFormatter().date(from: "2021-12-26T14:00:00Z")!
    private let lastStuck = ISO8601DateFormatter().date(from: "2025-04-27T13:00:00Z")!

    /// The 47, spread across the real window: each a live keeper with HR plus its retired
    /// twin `hoursOff` hours away (0008 matched offsets up to 12 h; 0009 saw up to 8).
    private func stuckFortySeven() -> (live: [RunSummary], retiredIDs: Set<String>, healthKit: [RunSummary]) {
        let step = lastStuck.timeIntervalSince(firstStuck) / 46
        var live: [RunSummary] = [], retiredIDs = Set<String>(), healthKit: [RunSummary] = []
        for i in 0..<47 {
            let keeperStart = firstStuck.addingTimeInterval(Double(i) * step)
            let hoursOff = Double(1 + i % 8)
            var keeper = RunSummary(id: UUID(), start: keeperStart, distanceM: 10461,
                                    durationS: 3508, avgHR: 148)
            keeper.externalID = UUID().uuidString
            var twin = RunSummary(id: UUID(), start: keeperStart.addingTimeInterval(hoursOff * 3600),
                                  distanceM: 10461, durationS: 3508, avgHR: nil)
            twin.externalID = UUID().uuidString

            live.append(keeper)
            retiredIDs.insert(twin.externalID!)
            // HealthKit never heard that Tempo retired anything: it offers both workouts,
            // under the uuids they were stored with.
            healthKit.append(keeper)
            healthKit.append(twin)
        }
        return (live, retiredIDs, healthKit)
    }

    func testTheFortySevenRetiredDuplicatesAreNoLongerProposed() {
        let (live, retiredIDs, healthKit) = stuckFortySeven()

        // The mechanism, as it was: the live archive alone cannot recognize them.
        let before = RunDedupe.reconcile(candidates: healthKit, existing: live)
        XCTAssertEqual(before.inserts.count, 47, "the doomed upsert, every refresh since 2026-10-09")

        let result = RunDedupe.reconcile(candidates: healthKit, existing: live,
                                         retiredExternalIDs: retiredIDs)
        XCTAssertTrue(result.inserts.isEmpty, "a retired row's uuid is already stored — nothing to write")
        XCTAssertEqual(result.droppedAlreadyStored, 94, "47 keepers + 47 retired twins, all ours")
        XCTAssertEqual(result.droppedUnknownUUID, 0, "a retired row is not a Garmin re-export")
    }

    func testARetiredTwinInsideTheWindowIsAlreadyStoredNotAReExport() {
        // The 0009 shape: the retired clock started within a minute of its keeper, so the
        // window always dropped it — but as an unknown uuid, nudging the re-export signal
        // with a workout we have held since 2021.
        let keeper = clocked(0, meters: 10461, durationS: 3508)
        var retired = clocked(40, meters: 10461, durationS: 3746)
        retired.externalID = "retired-elapsed-copy"

        let result = RunDedupe.reconcile(candidates: [retired], existing: [keeper],
                                         retiredExternalIDs: ["retired-elapsed-copy"])
        XCTAssertTrue(result.inserts.isEmpty)
        XCTAssertEqual(result.droppedAlreadyStored, 1)
        XCTAssertEqual(result.droppedUnknownUUID, 0)
    }

    func testARetiredWorkoutCannotShadowOrAmendAGenuinelyNewRun() {
        // A retired workout must not take a new run's place in the batch — HealthKit order
        // is not ours to choose — nor fold its clock into a run it is not part of.
        var retired = clocked(0, meters: 10461, durationS: 3746)
        retired.externalID = "retired"
        var fresh = clocked(30, meters: 10461, durationS: 3508)
        fresh.externalID = "never-seen"

        for batch in [[retired, fresh], [fresh, retired]] {
            let result = RunDedupe.reconcile(candidates: batch, existing: [],
                                             retiredExternalIDs: ["retired"])
            XCTAssertEqual(result.inserts.map(\.externalID), ["never-seen"])
            XCTAssertNil(result.inserts.first?.elapsedS, "a retired copy carries nothing into a new row")
            XCTAssertEqual(result.droppedAlreadyStored, 1)
            XCTAssertEqual(result.droppedUnknownUUID, 0)
        }
    }

    func testAStoredUUIDNeverReachesTheUpsertEvenWithNothingNearIt() {
        // The rule #97 asks for, stated generally: only a uuid the database has never held
        // may be written. A live row whose start no longer lines up with HealthKit's is the
        // same conflict as a retired one.
        let row = stored(0, externalID: "held")
        let result = RunDedupe.reconcile(candidates: [candidate(60, externalID: "held")], existing: [row])
        XCTAssertTrue(result.inserts.isEmpty)
        XCTAssertEqual(result.droppedAlreadyStored, 1)
    }

    func testAPlainReExportStillCarriesNothingNew() {
        // Same distance, same duration: migration 0008's class. Nothing to learn.
        let stored = clocked(0, meters: 10461, durationS: 3508)
        let copy = clocked(2, meters: 10461, durationS: 3508)
        let result = RunDedupe.reconcile(candidates: [copy], existing: [stored])
        XCTAssertTrue(result.inserts.isEmpty)
        XCTAssertTrue(result.elapsedPatches.isEmpty)
        XCTAssertTrue(result.suspectedElapsedStored.isEmpty)
    }
}
