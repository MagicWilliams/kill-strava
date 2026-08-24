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
}
