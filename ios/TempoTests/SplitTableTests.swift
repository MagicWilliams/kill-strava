import XCTest
@testable import Tempo

/// The Run Detail split table (#109). It used to be a mile-only loop inside
/// `RunDetailLoader.compute`; a km athlete needs the same table cut every 1000 m, and a
/// split table that is wrong doesn't look wrong. A boundary a few metres late moves a few
/// seconds from one split to the next, and every row still reads like a pace.
///
/// The runs here are synthetic and exact on purpose: 4 m/s, one sample a second, so a
/// kilometre is 250 s on the nose and every boundary is a number you can check by hand.
final class SplitTableTests: XCTestCase {

    /// Constant 4 m/s (4:10 /km, 6:42 /mi) for `meters`.
    private func steady(_ meters: Int) -> (times: [Double], meters: [Double]) {
        let seconds = meters / 4
        let t = (0...seconds).map(Double.init)
        return (t, t.map { $0 * 4 })
    }

    func testATenKCutsIntoTenWholeKilometresAtTheExactPace() {
        let run = steady(10_000)
        let km = SplitTable.splits(times: run.times, meters: run.meters, every: Units.km.splitMeters)
        XCTAssertEqual(km.count, 10, "no zero-length eleventh split")
        XCTAssertEqual(km.map(\.id), Array(1...10))
        XCTAssertTrue(km.allSatisfy { $0.length == 1 && $0.paceSec == 250 }, "\(km.map(\.paceSec))")
    }

    /// The same run in miles: six whole miles and the 344 m left over, as a partial split
    /// whose pace is still the run's pace rather than 344 m worth of seconds per mile.
    func testTheSameRunInMilesEndsInAPartialSplitAtTheSamePace() throws {
        let run = steady(10_000)
        let mi = SplitTable.splits(times: run.times, meters: run.meters, every: Units.mi.splitMeters)
        XCTAssertEqual(mi.count, 7)
        XCTAssertTrue(mi.dropLast().allSatisfy { $0.length == 1 && $0.paceSec == 402 }, "\(mi.map(\.paceSec))")
        let last = try XCTUnwrap(mi.last)
        XCTAssertEqual(last.length, (10_000 - 6 * 1609.34) / 1609.34, accuracy: 1e-9)
        XCTAssertEqual(last.paceSec, 402, "a partial split is paced per whole unit")
    }

    /// The boundary rule `Units.completedSplits` states for the recorder: a split is complete
    /// at exactly its length. The table and the voice cue have to agree on how many there are.
    func testTheTableAgreesWithCompletedSplitsAtTheBoundary() {
        for units in Units.allCases {
            for meters in [4_000, 8_000, 9_656, 12_876] {
                let run = steady(meters)
                let whole = SplitTable.splits(times: run.times, meters: run.meters, every: units.splitMeters)
                    .filter { $0.length == 1 }.count
                XCTAssertEqual(whole, units.completedSplits(meters: Double(meters)), "\(units) at \(meters) m")
            }
        }
    }

    /// 5 mi is 8.047 km. The 47 m past the eighth kilometre is GPS noise, not a split: it
    /// would print a ninth row with a pace decided by a few samples. 60 m is kept.
    func testATrailingScrapUnderAFiftiethOfAUnitIsDropped() {
        let fiveMiles = steady(8_048)
        XCTAssertEqual(SplitTable.splits(times: fiveMiles.times, meters: fiveMiles.meters, every: 1000).count, 8)
        let longer = steady(8_060)
        let splits = SplitTable.splits(times: longer.times, meters: longer.meters, every: 1000)
        XCTAssertEqual(splits.count, 9)
        XCTAssertEqual(splits.last?.length ?? 0, 0.06, accuracy: 1e-9)
    }

    /// Heart rate and climb are per split, from the samples inside it.
    func testHeartRateAndElevationAreReadInsideEachSplit() {
        let run = steady(2_000)
        let hr = run.times.map { (t: $0, v: $0 < 250 ? 150.0 : 160.0) }
        let altitude = run.times.map { (t: $0, v: $0 / 100) }   // 1 m every 100 s
        let km = SplitTable.splits(times: run.times, meters: run.meters, every: 1000, hr: hr, altitude: altitude)
        XCTAssertEqual(km.count, 2)
        XCTAssertEqual(km[1].avgHR, 160)
        XCTAssertEqual(km[0].elevDeltaM ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertNil(SplitTable.splits(times: run.times, meters: run.meters, every: 1000).first?.avgHR,
                     "no samples is no HR, not zero")
    }

    func testNothingToCutIsNoSplits() {
        XCTAssertTrue(SplitTable.splits(times: [], meters: [], every: 1000).isEmpty)
        XCTAssertTrue(SplitTable.splits(times: [0, 10], meters: [0, 0], every: 1000).isEmpty)
        XCTAssertTrue(SplitTable.splits(times: [0, 10], meters: [0, 40], every: 0).isEmpty)
    }
}
