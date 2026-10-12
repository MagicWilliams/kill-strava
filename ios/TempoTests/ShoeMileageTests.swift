import XCTest
@testable import Tempo

/// Shoe mileage and the retirement nudge (#121).
///
/// A shoe total is a number nobody cross-checks. If superseded Garmin re-exports leak into
/// it, the pair reads 40 miles older than it is and the nudge fires a fortnight early; if the
/// threshold falls back to 0, every pair in the list reads "due". Neither crashes. Both are
/// pinned here.
final class ShoeMileageTests: XCTestCase {

    private let pegasus = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let vaporfly = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let stranger = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21

    private func shoe(_ id: UUID, _ name: String = "Pair", startM: Int = 0,
                      started: Date? = nil, retired: Date? = nil) -> Shoe {
        Shoe(id: id, name: name, startedAt: started ?? t0, retiredAt: retired, startMileageM: startM)
    }

    private func miles(_ m: Double) -> Int { Int((m * ShoeMileage.metersPerMile).rounded()) }

    // MARK: - Totals

    func testMileageIsStartMileagePlusEveryTaggedRun() {
        let shoes = [shoe(pegasus, startM: miles(120))]
        let runs = [
            ShoeMileage.Run(shoeID: pegasus, distanceM: 8_047),   // 5 mi
            ShoeMileage.Run(shoeID: pegasus, distanceM: 16_093),  // 10 mi
            ShoeMileage.Run(shoeID: nil, distanceM: 30_000),      // untagged — nobody's
        ]
        let tally = ShoeMileage.tallies(shoes, runs: runs)[pegasus]
        XCTAssertEqual(tally, ShoeMileage.Tally(meters: miles(120) + 8_047 + 16_093, runs: 2))
        XCTAssertEqual(tally?.miles ?? 0, 135, accuracy: 0.01)
    }

    func testSupersededRunsAreExcluded() {
        // A Garmin re-export retired by migration 0008 is the same run twice. Counted, it
        // would age the pair by the duplicate's distance and pull the nudge forward.
        let run = ShoeMileage.Run(shoeID: pegasus, distanceM: 32_187)          // 20 mi long run
        let duplicate = ShoeMileage.Run(shoeID: pegasus, distanceM: 32_187, isSuperseded: true)
        let tally = ShoeMileage.tally(shoe(pegasus), runs: [run, duplicate])
        XCTAssertEqual(tally, ShoeMileage.Tally(meters: 32_187, runs: 1))
    }

    func testRunsFromTheArchiveCountAsLive() {
        // RunStore reads `superseded_by is null`, so a RunSummary is live by construction.
        var summary = RunSummary(id: UUID(), start: t0, distanceM: 10_000, durationS: 3_000, avgHR: nil)
        summary.journal.shoeID = vaporfly
        let run = ShoeMileage.Run(summary)
        XCTAssertEqual(run, ShoeMileage.Run(shoeID: vaporfly, distanceM: 10_000, isSuperseded: false))
    }

    func testEveryPairHasATotalEvenWithNoRuns() {
        let tallies = ShoeMileage.tallies(
            [shoe(pegasus), shoe(vaporfly, startM: miles(42))],
            runs: [ShoeMileage.Run(shoeID: pegasus, distanceM: 5_000)]
        )
        XCTAssertEqual(tallies[vaporfly], ShoeMileage.Tally(meters: miles(42), runs: 0))
        XCTAssertEqual(tallies.count, 2)
    }

    func testRunsTaggedWithAPairNotInTheListAreIgnored() {
        let tallies = ShoeMileage.tallies(
            [shoe(pegasus)],
            runs: [ShoeMileage.Run(shoeID: stranger, distanceM: 50_000)]
        )
        XCTAssertEqual(tallies[pegasus], ShoeMileage.Tally(meters: 0, runs: 0))
        XCTAssertNil(tallies[stranger])
    }

    func testNegativeDistancesAndStartMileageNeverSubtract() {
        let tally = ShoeMileage.tally(
            shoe(pegasus, startM: -500),
            runs: [ShoeMileage.Run(shoeID: pegasus, distanceM: -1_000),
                   ShoeMileage.Run(shoeID: pegasus, distanceM: 2_000)]
        )
        XCTAssertEqual(tally.meters, 2_000)
    }

    func testRetiredPairsStillCarryTheirMileage() {
        let retired = shoe(pegasus, retired: t0.addingTimeInterval(86_400))
        let tally = ShoeMileage.tally(retired, runs: [ShoeMileage.Run(shoeID: pegasus, distanceM: 9_000)])
        XCTAssertEqual(tally.meters, 9_000)
    }

    // MARK: - Retirement threshold

    private func wear(_ m: Double, threshold: Int = 400, retired: Bool = false) -> ShoeMileage.Wear {
        ShoeMileage.wear(ShoeMileage.Tally(meters: miles(m), runs: 1), thresholdMiles: threshold, retired: retired)
    }

    func testDefaultThresholdIs400() {
        XCTAssertEqual(ShoeMileage.defaultRetirementMiles, 400)
        XCTAssertEqual(ShoeMileage.clampedThreshold(nil), 400)
    }

    func testThresholdIsClampedTo300Through500() {
        XCTAssertEqual(ShoeMileage.clampedThreshold(250), 300)
        XCTAssertEqual(ShoeMileage.clampedThreshold(350), 350)
        XCTAssertEqual(ShoeMileage.clampedThreshold(5_000), 500)
        XCTAssertEqual(ShoeMileage.retirementMilesOptions, [300, 350, 400, 450, 500])
    }

    func testAnUnsetThresholdFallsBackToTheDefaultNotToZero() {
        // `UserDefaults.integer(forKey:)` is 0 for a key never written. Clamped to 300 it
        // would quietly move the nudge; read as 0, every pair would be "due".
        XCTAssertEqual(ShoeMileage.clampedThreshold(0), 400)
        XCTAssertEqual(ShoeMileage.clampedThreshold(-1), 400)
    }

    func testWearAcrossTheThreshold() {
        XCTAssertEqual(wear(0), .fine)
        XCTAssertEqual(wear(349.9), .fine)
        XCTAssertEqual(wear(350), .nearing(milesLeft: 50))
        XCTAssertEqual(wear(399.2), .nearing(milesLeft: 1), "rounded up — never '0 mi left' before the line")
        XCTAssertEqual(wear(400), .due)
        XCTAssertEqual(wear(612), .due)
    }

    func testTheNudgeFollowsTheConfiguredThreshold() {
        XCTAssertEqual(wear(320, threshold: 300), .due)
        XCTAssertEqual(wear(320, threshold: 400), .fine)
        XCTAssertEqual(wear(470, threshold: 500), .nearing(milesLeft: 30))
        XCTAssertEqual(wear(320, threshold: 0), .fine, "an unset threshold means 400")
    }

    func testRetiredPairsAreNeverNudged() {
        XCTAssertEqual(wear(720, retired: true), .fine)
    }

    // MARK: - Default pair

    func testDefaultResolvesWhileThePairIsInService() {
        let shoes = [shoe(pegasus), shoe(vaporfly)]
        XCTAssertEqual(ShoeMileage.resolvedDefault(storedID: vaporfly, shoes: shoes), vaporfly)
    }

    func testRetiringTheDefaultLeavesNoDefault() {
        // Not "the next pair along": the picker would then tag runs with shoes the athlete
        // never chose, and the mileage on both pairs would be wrong.
        let shoes = [shoe(pegasus), shoe(vaporfly, retired: t0.addingTimeInterval(3_600))]
        XCTAssertNil(ShoeMileage.resolvedDefault(storedID: vaporfly, shoes: shoes))
    }

    func testADefaultThatIsNotInTheListResolvesToNothing() {
        XCTAssertNil(ShoeMileage.resolvedDefault(storedID: stranger, shoes: [shoe(pegasus)]))
        XCTAssertNil(ShoeMileage.resolvedDefault(storedID: nil, shoes: [shoe(pegasus)]))
    }

    // MARK: - Ordering

    func testActiveNewestFirstThenRetiredMostRecentlyRetiredFirst() {
        let a = shoe(UUID(), "Old trainer", started: t0)
        let b = shoe(UUID(), "New trainer", started: t0.addingTimeInterval(86_400))
        let c = shoe(UUID(), "Retired long ago", started: t0, retired: t0.addingTimeInterval(1_000))
        let d = shoe(UUID(), "Retired last week", started: t0, retired: t0.addingTimeInterval(9_000))
        let (active, retired) = ShoeMileage.ordered([a, c, b, d])
        XCTAssertEqual(active.map(\.name), ["New trainer", "Old trainer"])
        XCTAssertEqual(retired.map(\.name), ["Retired last week", "Retired long ago"])
    }

    // MARK: - Writing

    func testDraftTrimsTheNameAndRefusesABlankOne() {
        XCTAssertEqual(ShoeMileage.draft(name: "  Pegasus 41  ", startMiles: nil),
                       ShoeMileage.Draft(name: "Pegasus 41", startMileageM: 0))
        XCTAssertNil(ShoeMileage.draft(name: "   \n", startMiles: 100),
                     "the column refuses a blank name, and a refused insert loses the form")
    }

    func testDraftStoresStartMilesAsMetresAndNeverNegative() {
        XCTAssertEqual(ShoeMileage.draft(name: "Used pair", startMiles: 100)?.startMileageM, 160_934)
        XCTAssertEqual(ShoeMileage.draft(name: "Used pair", startMiles: -20)?.startMileageM, 0)
        XCTAssertEqual(ShoeMileage.draft(name: "Used pair", startMiles: .nan)?.startMileageM, 0)
    }

    func testRetiredAtIsNeverBeforeTheServerStampedStart() {
        // `shoes` checks retired_at >= started_at, and started_at is the server's clock.
        // A phone a few seconds behind, retiring a pair it just added, would be refused.
        // And a second clear of it: the write is ISO-8601 text, which drops the start's
        // microseconds, so the start itself would round to just before the start.
        let started = t0.addingTimeInterval(0.123456)
        XCTAssertEqual(ShoeMileage.retiredAt(now: started.addingTimeInterval(-5), startedAt: started),
                       started.addingTimeInterval(1))
        XCTAssertGreaterThan(ShoeMileage.retiredAt(now: started, startedAt: started), started)
        let later = started.addingTimeInterval(86_400)
        XCTAssertEqual(ShoeMileage.retiredAt(now: later, startedAt: started), later)
    }
}
