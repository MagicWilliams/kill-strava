import XCTest
@testable import Tempo

/// Pins the moving/elapsed rules. Every past bug in this layer produced a wrong number on
/// screen rather than a crash, and the two clocks are exactly the kind of pair where an
/// off-by-one direction — showing elapsed where moving was meant — looks completely normal
/// and quietly makes every pace read slow.
final class TimeAccountingTests: XCTestCase {

    // MARK: - resolve

    func testUnknownElapsedCollapsesToMovingWithNoStop() {
        // Every run ingested before migration 0009. "We don't know" must render as a run
        // with no stops, never as a run with a negative or invented one.
        let c = TimeAccounting.resolve(movingS: 2400, elapsedS: nil)
        XCTAssertEqual(c.movingS, 2400)
        XCTAssertEqual(c.elapsedS, 2400)
        XCTAssertEqual(c.stoppedS, 0)
        XCTAssertFalse(c.hasMeaningfulStop)
    }

    func testStoppedTimeIsTheGapBetweenTheClocks() {
        let c = TimeAccounting.resolve(movingS: 2672, elapsedS: 2838)
        XCTAssertEqual(c.stoppedS, 166)
        XCTAssertTrue(c.hasMeaningfulStop)
    }

    func testElapsedShorterThanMovingIsImpossibleAndClampsToMoving() {
        // Physically impossible, and it happens: two records of one run that disagree.
        // Never surface a negative stop.
        let c = TimeAccounting.resolve(movingS: 3000, elapsedS: 2900)
        XCTAssertEqual(c.elapsedS, 3000)
        XCTAssertEqual(c.stoppedS, 0)
    }

    func testSecondsOfDisagreementAreNoiseNotAStop() {
        // The archive is full of pairs differing by 1–8 seconds: a re-import rounding
        // differently, not the athlete standing still. "3 seconds stopped" is worse than
        // saying nothing.
        for delta in [1, 2, 3, 8, 29] {
            let c = TimeAccounting.resolve(movingS: 2400, elapsedS: 2400 + delta)
            XCTAssertFalse(c.hasMeaningfulStop, "\(delta)s apart should read as continuous")
        }
        let atFloor = TimeAccounting.resolve(movingS: 2400, elapsedS: 2430)
        XCTAssertTrue(atFloor.hasMeaningfulStop, "30s is the floor, and is meaningful")
    }

    func testAnAbsurdlyLongStopIsKeptNotFiltered() {
        // 2026-01-10 in the real archive: 4.34 mi, 49 min moving, 1h58m elapsed — the watch
        // was left running. That is a fact about the run, and the athlete's record outranks
        // our sense of a plausible stop. Moving time stays sane, which is the point.
        let c = TimeAccounting.resolve(movingS: 2952, elapsedS: 7063)
        XCTAssertEqual(c.stoppedS, 4111)
        XCTAssertEqual(TimeAccounting.paceSecPerMile(seconds: c.movingS, miles: 4.34), 680)
    }

    // MARK: - pace

    func testPaceIsComputedOverWhicheverClockIsAsked() {
        let c = TimeAccounting.resolve(movingS: 2700, elapsedS: 3000)
        XCTAssertEqual(TimeAccounting.paceSecPerMile(seconds: c.movingS, miles: 5), 540)
        XCTAssertEqual(TimeAccounting.paceSecPerMile(seconds: c.elapsedS, miles: 5), 600)
    }

    func testPaceRefusesDistancesTooShortToDivideBy() {
        // A GPS blip yields a pace in the hours; there is nothing useful to say about it.
        XCTAssertNil(TimeAccounting.paceSecPerMile(seconds: 600, miles: 0.02))
        XCTAssertNil(TimeAccounting.paceSecPerMile(seconds: 0, miles: 5))
    }

    // MARK: - two clocks vs two runs

    func testSameDistanceToTheMeterWithDifferentClocksIsOneRun() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(TimeAccounting.isSameRunTwoClocks(
            distanceA: 9656, startA: start, durationA: 3508,
            distanceB: 9656, startB: start.addingTimeInterval(1), durationB: 3746
        ))
    }

    func testNearMissDistancesAreTwoRecordingsNotTwoClocks() {
        // 86 pairs in the archive agree within 5% but not to the meter: two devices
        // recording one outing, each with its own GPS. Folding those together would
        // silently destroy one of the two recordings, so the test is exact on purpose.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(TimeAccounting.isSameRunTwoClocks(
            distanceA: 10108, startA: start, durationA: 2895,
            distanceB: 10286, startB: start.addingTimeInterval(3), durationB: 2965
        ))
    }

    func testIdenticalDurationIsAPlainDuplicateNotASecondClock() {
        // Same distance AND same duration carries no new information — that is migration
        // 0008's re-export class, and there is no elapsed time to learn from it.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(TimeAccounting.isSameRunTwoClocks(
            distanceA: 9656, startA: start, durationA: 3400,
            distanceB: 9656, startB: start, durationB: 3400
        ))
    }

    func testRunsFarApartInTimeAreNotTheSameRun() {
        // Same distance to the meter can happen twice — a measured loop, a treadmill.
        // Hours apart, it is two runs.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(TimeAccounting.isSameRunTwoClocks(
            distanceA: 8047, startA: start, durationA: 2400,
            distanceB: 8047, startB: start.addingTimeInterval(6 * 3600), durationB: 2500
        ))
    }
}
