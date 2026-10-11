import XCTest
@testable import Tempo

/// Pins the overlapping-runs queue (#30).
///
/// After 0008 and 0009 retired every duplicate that was one by construction, ~108 pairs of
/// live runs still overlapped in time, and every all-time number — Records, the training
/// wall, biggest week and month, the coach's context — counted both. They can't be resolved
/// by rule: on 2023-11-19 the database holds the marathon (26.68 mi / 188 min) beside the
/// watch left running afterwards (27.59 mi / 304 min, HR 119), and "keep the longest" and
/// "keep the one with HR" both delete the race. So the engine finds pairs and David rules.
///
/// What these protect: a pair that silently never surfaces is a mile counted twice forever;
/// a ruled-on pair that resurfaces is a queue that never empties.
final class OverlapReviewTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_380_800)   // 2023-11-19 08:00 UTC

    private func run(
        _ minutes: Double,
        miles: Double,
        durationMin: Int,
        hr: Int? = nil,
        corrected: Bool = false,
        id: UUID = UUID()
    ) -> RunSummary {
        RunSummary(
            id: id,
            start: t0.addingTimeInterval(minutes * 60),
            distanceM: Int(miles * 1609.34),
            durationS: durationMin * 60,
            avgHR: hr,
            corrected: corrected
        )
    }

    private func overlaps(_ runs: [RunSummary], reviewed: Set<RunDedupe.OverlapKey> = []) -> [RunDedupe.OverlapPair] {
        RunDedupe.unresolvedOverlaps(in: runs, reviewed: reviewed)
    }

    // MARK: - Detection

    func testMarathonAndTheWatchLeftRunningSurfaceAsAPairWithNothingChosen() {
        // 2023-11-19, as stored. The blob is longer and carries HR — every simple rule's
        // favourite — so the only safe output is the pair itself, in time order.
        let marathon = run(0, miles: 26.68, durationMin: 188)
        let blob = run(2, miles: 27.59, durationMin: 304, hr: 119)

        let pairs = overlaps([blob, marathon])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.earlier.id, marathon.id, "left is whichever started first, not the 'better' run")
        XCTAssertEqual(pairs.first?.later.id, blob.id)
    }

    func testRunsThatOnlyTouchDoNotOverlap() {
        // Warm-up ends at 08:20, workout starts at 08:20: two runs, not one.
        let warmup = run(0, miles: 2, durationMin: 20)
        let workout = run(20, miles: 6, durationMin: 45)
        let cooldown = run(80, miles: 2, durationMin: 20)
        XCTAssertTrue(overlaps([warmup, workout, cooldown]).isEmpty)
    }

    func testOneSecondInsideIsAnOverlap() {
        let a = run(0, miles: 2, durationMin: 20)
        let b = RunSummary(id: UUID(), start: t0.addingTimeInterval(20 * 60 - 1),
                           distanceM: 3218, durationS: 1200, avgHR: nil)
        XCTAssertEqual(overlaps([a, b]).count, 1)
    }

    func testFindsThePairQuery4MissesWhenTheEarlierRunHasTheLargerID() {
        // 0009's review query joins on a.id < b.id AND b starting after a, so this pair —
        // earlier run holding the larger uuid — never showed up in it.
        let big = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!
        let small = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let earlier = run(0, miles: 6, durationMin: 50, id: big)
        let later = run(10, miles: 5.9, durationMin: 48, id: small)

        let pairs = overlaps([later, earlier])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.earlier.id, big)
    }

    func testWholeRunAndItsSplitsSurfaceEverySegment() {
        // 2022-06-25: 13.01 mi stored whole and as four segments. Each segment overlaps the
        // whole; the segments don't overlap each other.
        let whole = run(0, miles: 13.01, durationMin: 108)
        let segments = [
            run(1, miles: 4.52, durationMin: 37),
            run(39, miles: 0.50, durationMin: 4),
            run(44, miles: 4.92, durationMin: 41),
            run(86, miles: 3.66, durationMin: 21),
        ]
        let pairs = overlaps([whole] + segments)
        XCTAssertEqual(pairs.count, 4)
        XCTAssertTrue(pairs.allSatisfy { $0.earlier.id == whole.id })
    }

    func testCorrectedRunsStillPair() {
        // The athlete's edit says the numbers on this row are right. It says nothing about
        // whether a second recording of the same outing exists.
        let edited = run(0, miles: 8.0, durationMin: 70, corrected: true)
        let twin = run(1, miles: 7.6, durationMin: 69)
        XCTAssertEqual(overlaps([edited, twin]).count, 1)
    }

    func testNewestFirst() {
        let day: Double = 24 * 60
        let old = [run(0, miles: 5, durationMin: 45), run(5, miles: 5.1, durationMin: 44)]
        let recent = [run(300 * day, miles: 3, durationMin: 27), run(300 * day + 1, miles: 3.2, durationMin: 27)]
        let pairs = overlaps(old + recent)
        XCTAssertEqual(pairs.map(\.earlier.id), [recent[0].id, old[0].id])
    }

    // MARK: - Reviewed and retired pairs stay gone

    func testReviewedPairsAreExcludedWhicheverWayRoundTheyWereStored() {
        let a = run(0, miles: 5, durationMin: 45)
        let b = run(5, miles: 5.1, durationMin: 44)
        XCTAssertTrue(overlaps([a, b], reviewed: [RunDedupe.OverlapKey(a.id, b.id)]).isEmpty)
        XCTAssertTrue(overlaps([a, b], reviewed: [RunDedupe.OverlapKey(b.id, a.id)]).isEmpty,
                      "'both are real' must not resurface because the key was built the other way round")
    }

    func testRetiringOneRunOfAClusterRetiresItsPairsButNotTheOthers() {
        // Three recordings of one morning. Rule on one pair by retiring a run: it leaves the
        // live set, which takes every pair it was in with it. The pair it was not in stays.
        let watch = run(0, miles: 10.0, durationMin: 80, hr: 150)
        let phone = run(1, miles: 10.3, durationMin: 82)
        let strava = run(2, miles: 9.9, durationMin: 79)
        XCTAssertEqual(overlaps([watch, phone, strava]).count, 3)

        // Live set as RunStore reads it after `phone` gets superseded_by = watch.
        let remaining = overlaps([watch, strava])
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.key, RunDedupe.OverlapKey(watch.id, strava.id))
    }

    func testKeyIsOrderIndependentAndMatchesPostgresUUIDOrder() {
        let low = UUID(uuidString: "0A000000-0000-0000-0000-000000000000")!
        let high = UUID(uuidString: "A0000000-0000-0000-0000-000000000000")!
        let key = RunDedupe.OverlapKey(high, low)
        XCTAssertEqual(key, RunDedupe.OverlapKey(low, high))
        XCTAssertEqual(key.low, low, "run_a < run_b is a check constraint; the wrong order fails the insert")
        XCTAssertEqual(key.high, high)
    }

    // MARK: - What a verdict writes

    func testKeepRetiresTheOtherRunAndNamesTheKeySide() {
        let low = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
        let high = UUID(uuidString: "20000000-0000-0000-0000-000000000000")!
        // Laid out with the larger id on the left, so screen side and key side disagree.
        let pair = RunDedupe.OverlapPair(
            earlier: run(0, miles: 26.68, durationMin: 188, id: high),
            later: run(2, miles: 27.59, durationMin: 304, hr: 119, id: low)
        )

        let keepLeft = RunDedupe.resolution(for: pair, .keep(pair.earlier.id))
        XCTAssertEqual(keepLeft?.decision, "kept_b")
        XCTAssertEqual(keepLeft?.kept, high)
        XCTAssertEqual(keepLeft?.retire, low)

        let keepRight = RunDedupe.resolution(for: pair, .keep(pair.later.id))
        XCTAssertEqual(keepRight?.decision, "kept_a")
        XCTAssertEqual(keepRight?.retire, high)
    }

    func testBothRealRetiresNothing() {
        let pair = RunDedupe.OverlapPair(earlier: run(0, miles: 3, durationMin: 25),
                                         later: run(10, miles: 3, durationMin: 25))
        let r = RunDedupe.resolution(for: pair, .bothReal)
        XCTAssertEqual(r?.decision, "both_real")
        XCTAssertNil(r?.retire)
        XCTAssertNil(r?.kept)
    }

    func testKeepingARunOutsideThePairWritesNothing() {
        let pair = RunDedupe.OverlapPair(earlier: run(0, miles: 3, durationMin: 25),
                                         later: run(10, miles: 3, durationMin: 25))
        XCTAssertNil(RunDedupe.resolution(for: pair, .keep(UUID())),
                     "a stale tap must never become superseded_by on an unrelated run")
    }
}
