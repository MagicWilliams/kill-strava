import XCTest
@testable import Tempo

/// Pins the sub-distance PR scan (#25).
///
/// The reason this suite is not optional: `RunHistory.records` has always answered "fastest
/// 10K+ *run*" — an average over a whole run — and these numbers sit beside it in the same
/// table claiming something stronger. If the rolling window is off by a sample nothing
/// crashes and nothing logs; a PR table just quietly reads wrong, which is how every engine
/// bug on this board has presented.
final class BestEffortsTests: XCTestCase {

    // MARK: - Builders

    /// A run at a constant pace, sampled every `every` seconds.
    private func steady(
        meters: Double,
        secPerKm: Double,
        every: Double = 10,
        from t0: Double = 0
    ) -> [BestEfforts.Sample] {
        let metersPerSecond = 1000 / secPerKm
        let totalTime = meters / metersPerSecond
        var samples: [BestEfforts.Sample] = []
        var elapsed = 0.0
        while elapsed < totalTime {
            let step = min(every, totalTime - elapsed)
            if step <= 0 { break }
            samples.append(BestEfforts.Sample(
                start: t0 + elapsed,
                end: t0 + elapsed + step,
                meters: step * metersPerSecond
            ))
            elapsed += step
        }
        return samples
    }

    /// Blocks run back to back, each starting where the last one ended.
    private func join(_ blocks: [(meters: Double, secPerKm: Double)], every: Double = 10) -> [BestEfforts.Sample] {
        var out: [BestEfforts.Sample] = []
        var t = 0.0
        for b in blocks {
            let block = steady(meters: b.meters, secPerKm: b.secPerKm, every: every, from: t)
            out += block
            t = block.last?.end ?? t
        }
        return out
    }

    private func effort(_ efforts: [BestEfforts.Effort], _ key: Int) -> Int? {
        efforts.first { $0.distanceM == key }?.durationS
    }

    private func scan(_ samples: [BestEfforts.Sample]) -> [BestEfforts.Effort] {
        BestEfforts.efforts(timeline: BestEfforts.timeline(from: samples))
    }

    // MARK: - The number itself

    /// The whole point of the issue: the fast 5 K is buried in the middle of a long easy run,
    /// where whole-run averaging can never see it and a prefix scan from the start would miss
    /// it too.
    func testFindsAFastFiveKBuriedInTheMiddleOfALongRun() throws {
        // 8 km easy @ 6:00/km · 5 km hard @ 3:45/km · 8 km easy @ 6:00/km.
        let efforts = scan(join([
            (meters: 8000, secPerKm: 360),
            (meters: 5000, secPerKm: 225),
            (meters: 8000, secPerKm: 360),
        ]))

        // 5 km at 3:45/km is 18:45 exactly.
        XCTAssertEqual(try XCTUnwrap(effort(efforts, 5000)), 1125, accuracy: 1)

        // And it is genuinely better than the whole-run average, which is the bug being
        // closed: 21 km in 1:54:45 averages 5:27/km, so a whole-run number would call this
        // athlete's 5 K 27:19.
        XCTAssertLessThan(try XCTUnwrap(effort(efforts, 5000)), 1500)
    }

    /// A prefix scan — "best time from the start" — would pass the test above only because
    /// the slow block in front is symmetric. Putting the fast block at the very end catches
    /// the other direction.
    func testFindsTheFastBlockAtTheEndOfTheRun() throws {
        let efforts = scan(join([
            (meters: 10_000, secPerKm: 390),
            (meters: 1609.34, secPerKm: 220),
        ]))
        // A mile at 3:40/km is 5:54.
        XCTAssertEqual(try XCTUnwrap(effort(efforts, 1609)), 354, accuracy: 2)
    }

    /// A steady run's best segment is its own pace — no window can beat the average when
    /// every window is the average.
    func testSteadyRunReportsItsOwnPace() throws {
        let efforts = scan(steady(meters: 10_050, secPerKm: 300))
        XCTAssertEqual(try XCTUnwrap(effort(efforts, 5000)), 1500, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(effort(efforts, 10_000)), 3000, accuracy: 1)
    }

    // MARK: - Distances the run didn't cover

    /// An absent row and a row reading zero are different claims. A 3-mile run holds no half.
    func testRunShorterThanADistanceEmitsNoRowForIt() {
        let efforts = scan(steady(meters: 4828, secPerKm: 330))   // 3.0 miles
        XCTAssertEqual(Set(efforts.map(\.distanceM)), [400, 800, 1609],
                       "only the distances actually covered")
        XCTAssertNil(effort(efforts, 5000))
        XCTAssertNil(effort(efforts, 21_098))
        XCTAssertNil(effort(efforts, 42_195))
    }

    /// Exactly on the line counts — and a two-point timeline is the smallest thing the scan
    /// has to survive.
    func testDistanceCoveredExactlyStillCounts() throws {
        let efforts = scan([BestEfforts.Sample(start: 0, end: 1500, meters: 5000)])
        XCTAssertEqual(try XCTUnwrap(effort(efforts, 5000)), 1500)
        XCTAssertNil(effort(efforts, 10_000))
    }

    func testEmptyAndDegenerateTimelinesProduceNothing() {
        XCTAssertTrue(BestEfforts.efforts(timeline: []).isEmpty)
        XCTAssertTrue(BestEfforts.efforts(timeline: [BestEfforts.Point(t: 0, m: 0)]).isEmpty)
        XCTAssertTrue(BestEfforts.timeline(from: []).isEmpty)
    }

    // MARK: - What Garmin actually writes

    /// Sparse, irregular samples are the normal case here, not the edge case: Garmin writes
    /// one sample every few seconds on a good day and every minute on a bad one. Resolution
    /// is the thing that degrades; the number is not allowed to.
    func testSparseSamplingLandsOnTheSameNumberAsDenseSampling() throws {
        let dense = scan(steady(meters: 6000, secPerKm: 300, every: 1))
        let sparse = scan(steady(meters: 6000, secPerKm: 300, every: 47))

        XCTAssertEqual(try XCTUnwrap(effort(dense, 5000)), 1500, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(effort(sparse, 5000)),
                       try XCTUnwrap(effort(dense, 5000)), accuracy: 15)
    }

    /// Samples arriving out of order — two sources interleaved over one window — must not
    /// invert the cumulative curve. A curve that goes backwards reports negative windows.
    func testOutOfOrderSamplesAreSortedBeforeScanning() {
        let ordered = steady(meters: 3000, secPerKm: 300)
        XCTAssertEqual(scan(ordered), scan(ordered.reversed().map { $0 }))
    }

    /// Zero-length and negative-distance junk is dropped rather than divided by.
    func testJunkSamplesAreDropped() throws {
        var samples = steady(meters: 3000, secPerKm: 300)
        samples.append(BestEfforts.Sample(start: 100, end: 100, meters: 500))   // no duration
        samples.append(BestEfforts.Sample(start: 120, end: 130, meters: -40))   // negative
        XCTAssertEqual(try XCTUnwrap(effort(scan(samples), 1609)), 483, accuracy: 2)
    }

    /// A pause mid-run — a gap in the samples carrying no distance — is a slow window, not a
    /// fast one. The kilometre either side of a stop must not be credited with the stop.
    func testAPauseMakesTheWindowSpanningItSlowNotFast() throws {
        var samples = steady(meters: 1000, secPerKm: 240)
        samples += steady(meters: 1000, secPerKm: 240, from: 240 + 600)   // ten minutes standing still

        let efforts = scan(samples)
        // The best 800 is still 3:12 — one of the two halves, not the pair.
        XCTAssertEqual(try XCTUnwrap(effort(efforts, 800)), 192, accuracy: 2)
        // No mile window can avoid the stop, so the mile reads honestly slow.
        XCTAssertEqual(try XCTUnwrap(effort(efforts, 1609)), 986, accuracy: 3)
    }

    // MARK: - Idempotency

    /// The pass is re-runnable by design — the unique constraint on `(run_id, distance_m)`
    /// only protects the table if the same input really does yield the same rows.
    func testSameInputTwiceYieldsIdenticalRows() {
        let samples = join([
            (meters: 3000, secPerKm: 340),
            (meters: 2000, secPerKm: 250),
            (meters: 6000, secPerKm: 320),
        ])
        let first = scan(samples)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, scan(samples))
    }

    // MARK: - The catalog

    /// These keys are a `check` constraint in migration 0011. If this list changes, that
    /// migration has to change with it — which is what this test is for.
    func testCatalogMatchesTheMigrationsCheckConstraint() {
        XCTAssertEqual(BestEfforts.distances.map(\.key), [400, 800, 1609, 5000, 10_000, 21_098, 42_195])
        XCTAssertEqual(BestEfforts.distance(forKey: 21_098)?.label, "Half")
        XCTAssertNil(BestEfforts.distance(forKey: 1600), "1600 m is not the mile and is not stored")
    }

    /// Keys are rounded metres; the arithmetic runs on the true distance. A mile measured as
    /// 1,609 m would shave a fraction off every mile PR, forever.
    func testMileAndHalfComputeOnTheTrueDistanceNotTheStoredKey() throws {
        XCTAssertEqual(try XCTUnwrap(BestEfforts.distance(forKey: 1609)).meters, 1609.34, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(BestEfforts.distance(forKey: 21_098)).meters, 21_097.5, accuracy: 0.001)
    }

    // MARK: - The backlog

    private func run(_ daysAgo: Int, source: String = "healthkit", external: String? = "hk") -> RunSummary {
        RunSummary(
            id: UUID(),
            start: Date(timeIntervalSince1970: 1_700_000_000 - TimeInterval(daysAgo * 86_400)),
            distanceM: 10_000,
            durationS: 3000,
            avgHR: nil,
            source: source,
            externalID: external
        )
    }

    /// Bounded by construction, for the same reason `SyncPass.hrEnrichmentTargets` is: the
    /// number of serial HealthKit reads one pass makes must not scale with the archive.
    func testSliceIsBoundedAndNewestFirst() {
        let rows = (0..<500).map { run($0) }
        let slice = BestEfforts.nextSlice(rows: rows, scanned: [], limit: 40)

        XCTAssertEqual(slice.count, 40)
        XCTAssertEqual(slice.first?.id, rows.first?.id, "newest run first — the table converges early")
        XCTAssertEqual(slice, slice.sorted { $0.start > $1.start })
    }

    /// A killed pass resumes rather than restarts. This is the whole reason a run is marked
    /// scanned even when it produced no rows.
    func testAlreadyScannedRunsAreNotRescanned() {
        let rows = (0..<10).map { run($0) }
        let done = Set(rows.prefix(6).map(\.id))
        let slice = BestEfforts.nextSlice(rows: rows, scanned: done, limit: 40)

        XCTAssertEqual(slice.count, 4)
        XCTAssertTrue(slice.allSatisfy { !done.contains($0.id) })
    }

    /// Manual runs carry a total and nothing else — no timeline to scan — so they are neither
    /// queued nor counted against progress. Counting them would park the percentage below 100
    /// forever.
    func testManualRunsAreNeitherScannedNorCounted() {
        let rows = [run(0), run(1, source: "manual", external: nil), run(2, external: nil)]
        XCTAssertEqual(BestEfforts.nextSlice(rows: rows, scanned: []).count, 1)
        XCTAssertEqual(BestEfforts.progress(rows: rows, scanned: []).total, 1)
    }

    /// Progress is a count comparison, not a "the last pass finished" flag — a killed pass
    /// must not be able to report done.
    func testProgressReportsPartialWorkHonestly() {
        let rows = (0..<10).map { run($0) }
        let partial = BestEfforts.progress(rows: rows, scanned: Set(rows.prefix(4).map(\.id)))
        XCTAssertEqual(partial.percent, 40)
        XCTAssertFalse(partial.isComplete)

        let whole = BestEfforts.progress(rows: rows, scanned: Set(rows.map(\.id)))
        XCTAssertTrue(whole.isComplete)
        XCTAssertEqual(whole.percent, 100)

        XCTAssertTrue(BestEfforts.progress(rows: [], scanned: []).isComplete,
                      "an empty archive is fully scanned, not 0% of nothing")
    }

    // MARK: - Formatting

    func testTimeFormattingCrossesTheHourCorrectly() {
        XCTAssertEqual(BestEfforts.formatTime(72), "1:12")
        XCTAssertEqual(BestEfforts.formatTime(1125), "18:45")
        XCTAssertEqual(BestEfforts.formatTime(3599), "59:59")
        XCTAssertEqual(BestEfforts.formatTime(3600), "1:00:00")
        XCTAssertEqual(BestEfforts.formatTime(11_647), "3:14:07")
    }

    func testPacePerMileIsDerivedFromTheTrueDistance() throws {
        // 5 K in 18:45 is 6:02/mi.
        let pace = BestEfforts.paceSecPerMile(BestEfforts.Effort(distanceM: 5000, durationS: 1125))
        XCTAssertEqual(try XCTUnwrap(pace), 362, accuracy: 1)
    }
}
