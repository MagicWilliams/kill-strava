import XCTest
@testable import Tempo

/// The readiness number on the Today screen. Every input is deterministic, so every
/// claim it makes is testable — including the one product rule that outranks the math.
final class LoadModelTests: XCTestCase {

    /// `count` runs, one per day, ending today.
    private func streak(count: Int, miles: Double, paceSecPerMile: Int,
                        endingAt end: Date = Date()) -> [RunSummary] {
        let cal = Calendar.current
        return (0..<count).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: end) else { return nil }
            return RunSummary(
                id: UUID(),
                start: day,
                distanceM: Int(miles * 1609.34),
                durationS: Int(miles * Double(paceSecPerMile)),
                avgHR: nil
            )
        }
    }

    func testNoRunsYieldsNoMetrics() {
        XCTAssertNil(LoadModel.compute(runs: [], checkInOK: nil))
    }

    func testFitnessAccumulatesWithConsistentTraining() {
        let light = LoadModel.compute(runs: streak(count: 10, miles: 3, paceSecPerMile: 540),
                                      checkInOK: nil)
        let heavy = LoadModel.compute(runs: streak(count: 90, miles: 8, paceSecPerMile: 540),
                                      checkInOK: nil)
        XCTAssertNotNil(light); XCTAssertNotNil(heavy)
        XCTAssertGreaterThan(heavy!.ctl, light!.ctl, "90 days of 8-milers must out-build 10 days of 3s")
    }

    func testFatigueRespondsFasterThanFitness() {
        // A sudden block on top of nothing: the 7-day EWMA must outrun the 42-day one.
        let metrics = LoadModel.compute(runs: streak(count: 5, miles: 10, paceSecPerMile: 540),
                                        checkInOK: nil)
        XCTAssertNotNil(metrics)
        XCTAssertGreaterThan(metrics!.atl, metrics!.ctl, "a hard week reads as fatigue, not fitness")
        XCTAssertLessThan(metrics!.form, 0, "form goes negative when you're digging a hole")
    }

    func testCheckInCapsReadinessRegardlessOfMath() {
        // The product rule: "the athlete's word outranks the math."
        let runs = streak(count: 60, miles: 4, paceSecPerMile: 600)
        let unreported = LoadModel.compute(runs: runs, checkInOK: nil)!
        let feelingOff = LoadModel.compute(runs: runs, checkInOK: false)!
        XCTAssertLessThanOrEqual(feelingOff.readiness, 40)
        XCTAssertLessThanOrEqual(feelingOff.readiness, unreported.readiness)
    }

    func testPositiveCheckInDoesNotInflateReadiness() {
        let runs = streak(count: 60, miles: 4, paceSecPerMile: 600)
        XCTAssertEqual(LoadModel.compute(runs: runs, checkInOK: true)!.readiness,
                       LoadModel.compute(runs: runs, checkInOK: nil)!.readiness,
                       "feeling good is not evidence of freshness — it only removes the cap")
    }

    func testReadinessStaysInBounds() {
        for (count, miles, pace) in [(1, 0.1, 1200), (200, 20, 300), (30, 6, 540)] {
            let m = LoadModel.compute(runs: streak(count: count, miles: miles, paceSecPerMile: pace),
                                      checkInOK: nil)
            guard let m else { continue }
            XCTAssertGreaterThanOrEqual(m.readiness, 5)
            XCTAssertLessThanOrEqual(m.readiness, 98)
        }
    }

    func testLabelsPartitionTheReadinessRange() {
        // Every readiness value must map to exactly one label, with no gap at a boundary.
        var seen = Set<String>()
        for readiness in 5...98 {
            let m = FitnessMetrics(readiness: readiness, ctl: 10, atl: 5, ctlSeries: [])
            XCTAssertFalse(m.label.isEmpty)
            XCTAssertFalse(m.caption.isEmpty)
            seen.insert(m.label)
        }
        XCTAssertEqual(seen, ["Primed", "Ready", "Loaded", "Run easy"])
    }

    func testSeriesIsCappedToEightWeeksAndOrderedOldestFirst() {
        let m = LoadModel.compute(runs: streak(count: 120, miles: 5, paceSecPerMile: 540),
                                  checkInOK: nil)!
        XCTAssertLessThanOrEqual(m.ctlSeries.count, 56)
        let dates = m.ctlSeries.map(\.date)
        XCTAssertEqual(dates, dates.sorted(), "chart data must be oldest-first")
    }

    func testRunsWithoutUsableDistanceAreIgnoredNotCrashed() {
        let junk = [RunSummary(id: UUID(), start: Date(), distanceM: 0, durationS: 600, avgHR: nil)]
        XCTAssertNil(LoadModel.compute(runs: junk, checkInOK: nil),
                     "a zero-distance run has no pace, so there is no baseline to build on")
    }
}
