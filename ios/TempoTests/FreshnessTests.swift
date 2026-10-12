import XCTest
@testable import Tempo

/// The just-running Today replaces the readiness ring with a Freshness card (#101).
/// Readiness's words are instructions — "Primed", "Run easy" — and with no plan there is
/// nothing to instruct, so this card says where the athlete *is*.
///
/// Both words come off the same load model, on the same screen-adjacent surfaces (the card
/// taps into the readiness breakdown), so the main thing to pin beyond the bands is that
/// they can never contradict each other.
final class FreshnessTests: XCTestCase {

    private func state(ctl: Double, atl: Double, before: Double? = nil) -> Freshness.State {
        Freshness.state(ctl: ctl, atl: atl, ctlFourWeeksAgo: before)
    }

    // MARK: - Bands

    /// 12 Oct 2026, the Monday after Chicago: a week of taper fitness under a marathon's
    /// worth of fatigue. That is carrying fatigue, and the card should say so.
    func testTheDayAfterAMarathonIsCarryingFatigue() {
        XCTAssertEqual(state(ctl: 5.2, atl: 8.9), .carryingFatigue)
    }

    /// Taper week: volume down, fitness barely moved.
    func testATaperIsFresh() {
        XCTAssertEqual(state(ctl: 5.0, atl: 3.5), .fresh)
    }

    func testBalancedFormWithFitnessRisingIsBuilding() {
        XCTAssertEqual(state(ctl: 5.0, atl: 5.2, before: 4.5), .building, "+11% in four weeks")
    }

    func testBalancedFormWithFitnessFlatIsSteady() {
        XCTAssertEqual(state(ctl: 5.0, atl: 5.0, before: 4.95), .steady, "+1% is not a trend")
        XCTAssertEqual(state(ctl: 5.0, atl: 5.0, before: 5.6), .steady, "easing off is not building")
    }

    /// Fewer than 29 days of series can't say what fitness was four weeks ago, and not
    /// knowing must not read as progress.
    func testNoFourWeekHistoryNeverReadsAsBuilding() {
        XCTAssertEqual(state(ctl: 5.0, atl: 5.0, before: nil), .steady)
    }

    func testAlmostNoRecentRunningIsRested() {
        XCTAssertEqual(state(ctl: 0.2, atl: 0.1), .rested)
        XCTAssertEqual(state(ctl: 0, atl: 0), .rested, "and never divides by zero")
    }

    /// Someone in their first fortnight back has little fitness and real fatigue. "Both
    /// low" would be false about the half of it that isn't.
    func testComingBackFromNothingIsBuildingNotRested() {
        XCTAssertEqual(state(ctl: 0.3, atl: 1.4), .building)
    }

    func testBandEdges() {
        XCTAssertEqual(state(ctl: 10, atl: 8.2), .fresh, "form +18%")
        XCTAssertEqual(state(ctl: 10, atl: 8.4), .steady, "form +16% is not yet fresh")
        XCTAssertEqual(state(ctl: 10, atl: 10.9), .steady, "form −9% is not yet fatigued")
        XCTAssertEqual(state(ctl: 10, atl: 11.1), .carryingFatigue, "form −11%")
    }

    // MARK: - Agreement with readiness

    /// Readiness is `55 + formPct × 90`. The bands are placed so "Fresh" always lands in
    /// Primed and "Carrying fatigue" always below Ready: tap the card and the breakdown it
    /// opens never says the opposite thing.
    func testFreshnessNeverContradictsReadiness() throws {
        let cal = Calendar.current
        let now = Date()
        func run(_ daysAgo: Int, _ miles: Double) -> RunSummary {
            RunSummary(id: UUID(), start: cal.date(byAdding: .day, value: -daysAgo, to: now)!,
                       distanceM: Int(miles * 1609.34), durationS: Int(miles * 540), avgHR: nil)
        }
        let scenarios: [[RunSummary]] = [
            (0..<90).map { run($0, 6) },                                // steady block
            (7..<90).map { run($0, 8) },                                // a week off after it
            (14..<90).map { run($0, 8) },                               // two weeks off
            (0..<90).map { run($0, 4) } + (0..<5).map { run($0, 10) },  // sudden spike
            (0..<20).map { run($0, 5) },                                // three weeks back
            [run(0, 26.2)] + (1..<100).map { run($0, 7) },              // race yesterday
        ]
        for runs in scenarios {
            let m = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil, now: now))
            switch Freshness.state(m) {
            case .fresh:
                XCTAssertEqual(m.label, "Primed", "fresh at readiness \(m.readiness)")
            case .carryingFatigue:
                XCTAssertLessThan(m.readiness, 55, "fatigued at readiness \(m.readiness)")
            default:
                break
            }
        }
    }

    // MARK: - Four weeks ago

    func testFourWeeksAgoReadsTwentyEightDaysBackFromTheNewestPoint() {
        let series = (0..<56).map { (date: Date(timeIntervalSince1970: Double($0) * 86_400), ctl: Double($0)) }
        XCTAssertEqual(Freshness.ctlFourWeeksAgo(series), 27, "newest is index 55; 55 − 28 = 27")
        XCTAssertEqual(Freshness.ctlFourWeeksAgo(Array(series.prefix(29))), 0)
        XCTAssertNil(Freshness.ctlFourWeeksAgo(Array(series.prefix(28))))
        XCTAssertNil(Freshness.ctlFourWeeksAgo([]))
    }
}
