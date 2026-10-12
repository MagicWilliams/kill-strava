import XCTest
@testable import Tempo

/// `Units` (#108) is going to sit under every number the app shows. When it is wrong,
/// a split arrives 4 m late, a pace reads 6:60, a km total disagrees with the sum of its
/// splits. None of these crash. They put a plausible wrong number on screen, the way every
/// past bug in `Engine/` has.
///
/// The mile was already spread across the codebase as 1609.34 in thirteen places, and `m:ss`
/// was built two different ways (`PaceModel.format`, `ChangeLedger.Format.pace`). The
/// recorder (#112) and its voice cues are about to add a split boundary and a spoken pace on
/// top. These tests pin the one implementation before anything else is built on it.
final class UnitsTests: XCTestCase {

    // MARK: - Round trips

    /// Metres → unit → metres comes back to the same metres, at awkward values in both
    /// units. A conversion that rounds anywhere on the way fails this.
    func testMetersRoundTripInBothUnits() {
        for units in Units.allCases {
            for m in [0.0, 0.4, 1.0, 999.6, 1609.34, 1609.33, 5_000, 21_097.5, 42_195, 160_934.4] {
                XCTAssertEqual(units.meters(distance: units.distance(meters: m)), m, accuracy: 1e-9,
                               "\(units): \(m) m did not survive the round trip")
            }
        }
    }

    func testOneOfEachUnitIsItsLength() {
        XCTAssertEqual(Units.mi.distance(meters: 1609.34), 1.0, accuracy: 1e-12)
        XCTAssertEqual(Units.km.distance(meters: 1000), 1.0, accuracy: 1e-12)
        XCTAssertEqual(Units.mi.meters(distance: 26.2188), 42_195, accuracy: 0.1, "a marathon is a marathon")
        XCTAssertEqual(Units.km.meters(distance: 42.195), 42_195, accuracy: 1e-9)
    }

    /// The stored preference round-trips through the column's two allowed values, and
    /// anything else reads as miles rather than failing the launch.
    func testStoredValueRoundTripsAndFallsBackToMiles() {
        for units in Units.allCases {
            XCTAssertEqual(Units(stored: units.rawValue), units)
        }
        XCTAssertEqual(Units(stored: "KM"), .km, "case is not a reason to lose the preference")
        XCTAssertEqual(Units(stored: nil), .mi, "no row yet / null")
        XCTAssertEqual(Units(stored: "furlongs"), .mi, "a value this build doesn't know")
        XCTAssertEqual(Units(stored: ""), .mi)
        XCTAssertEqual(Units.fallback, .mi, "must match the column default in 0015")
    }

    /// A sec/mi pace re-expressed in km and back again is the same pace. The plan stores
    /// every target as sec/mi (`TrainingPaces`), so this is how a km athlete sees one.
    func testPaceRoundTripsBetweenUnits() {
        let secPerMile = 420.0   // 7:00 /mi
        let secPerKm = Units.km.pace(secondsPerMile: secPerMile)
        XCTAssertEqual(secPerKm, 420 * 1000 / 1609.34, accuracy: 1e-9)
        XCTAssertEqual(Units.km.formatPace(secPerKm), "4:21 /km")
        XCTAssertEqual(Units.mi.pace(secondsPerMile: secPerMile), secPerMile, "miles is the identity")
        // Back again: the km pace times km per mile is the mile pace.
        XCTAssertEqual(secPerKm * Units.metersPerMile / 1000, secPerMile, accuracy: 1e-9)
    }

    // MARK: - Pace at the 59.5 s boundary

    /// The whole pace is rounded before it is cut into minutes and seconds. Cut first and
    /// round the seconds, and 419.5 s reads "6:60". Rounded once, it reads 7:00.
    func testPaceRoundsUpThroughTheMinuteInMiles() {
        XCTAssertEqual(Units.mi.formatPace(419.5), "7:00 /mi", "not 6:60")
        XCTAssertEqual(Units.mi.formatPace(419.49), "6:59 /mi")
        XCTAssertEqual(Units.mi.formatPace(59.5), "1:00 /mi")
        XCTAssertEqual(Units.mi.formatPace(59.49), "0:59 /mi")
    }

    func testPaceRoundsUpThroughTheMinuteInKilometres() {
        XCTAssertEqual(Units.km.formatPace(239.5), "4:00 /km", "not 3:60")
        XCTAssertEqual(Units.km.formatPace(239.49), "3:59 /km")
        XCTAssertEqual(Units.km.formatPace(59.5), "1:00 /km")
        XCTAssertEqual(Units.km.formatPace(59.49), "0:59 /km")
    }

    /// The same boundary when the pace is computed from a split, which is how the
    /// recorder will produce it.
    func testPaceFromSecondsAndMetersHitsTheSameBoundary() {
        XCTAssertEqual(Units.mi.formatPace(seconds: 419.5, meters: 1609.34), "7:00 /mi")
        XCTAssertEqual(Units.km.formatPace(seconds: 239.5, meters: 1000), "4:00 /km")
        // Half a split at 3:59.6/km is 119.8 s over 500 m.
        XCTAssertEqual(Units.km.formatPace(seconds: 119.8, meters: 500), "4:00 /km")
    }

    /// No distance means no pace, not "0:00" or a division by zero.
    func testNoDistanceIsNoPace() {
        XCTAssertNil(Units.mi.pace(seconds: 30, meters: 0))
        XCTAssertNil(Units.km.pace(seconds: 30, meters: -5))
        XCTAssertNil(Units.km.pace(seconds: .nan, meters: 100))
        XCTAssertEqual(Units.mi.formatPace(seconds: 30, meters: 0), "—")
        XCTAssertEqual(Units.mi.formatPace(.infinity), "—")
        XCTAssertEqual(Units.km.formatPace(-1), "—")
    }

    /// The existing mile formatters now route through `Units`, and must read exactly as
    /// they did: these strings are already on screen and in the change ledger.
    func testExistingMileFormattersAreUnchanged() {
        XCTAssertEqual(PaceModel.format(446), "7:26")
        XCTAssertEqual(PaceModel.format(60), "1:00")
        XCTAssertEqual(PaceModel.format(0), "0:00")
        XCTAssertEqual(ChangeLedger.Format.pace(446), "7:26 /mi")
        XCTAssertEqual(ChangeLedger.Format.miles(32_187), "20.00 mi")
        XCTAssertEqual(ChangeLedger.Format.miles(0), "0.00 mi")
    }

    // MARK: - Split length

    func testSplitLength() {
        XCTAssertEqual(Units.mi.splitMeters, 1609.34)
        XCTAssertEqual(Units.km.splitMeters, 1000)
    }

    /// A split completes exactly on its boundary, not a metre early or late. The voice cue
    /// fires on this, so a cue 4 m late at mile 26 is what a rounded mile would cost.
    func testSplitsCompleteExactlyOnTheBoundary() {
        XCTAssertEqual(Units.mi.completedSplits(meters: 1609.33), 0)
        XCTAssertEqual(Units.mi.completedSplits(meters: 1609.34), 1)
        XCTAssertEqual(Units.mi.completedSplits(meters: 3218.67), 1)
        XCTAssertEqual(Units.mi.completedSplits(meters: 3218.68), 2)
        XCTAssertEqual(Units.km.completedSplits(meters: 999.99), 0)
        XCTAssertEqual(Units.km.completedSplits(meters: 1000), 1)
        XCTAssertEqual(Units.km.completedSplits(meters: 42_195), 42)
        XCTAssertEqual(Units.mi.completedSplits(meters: 42_195), 26)
        XCTAssertEqual(Units.mi.completedSplits(meters: 0), 0)
        XCTAssertEqual(Units.km.completedSplits(meters: -3), 0, "a negative distance has no splits")
    }

    // MARK: - Never round before converting

    /// The conversion is exact: fractional metres go straight through. Rounding to whole
    /// metres first would make 1609.8 m read as 1610 m, 0.66 m off before it even started.
    func testConversionUsesTheUnroundedMeters() {
        XCTAssertEqual(Units.mi.distance(meters: 1609.8), 1609.8 / 1609.34, accuracy: 1e-12)
        XCTAssertNotEqual(Units.mi.distance(meters: 1609.8), 1610 / 1609.34, accuracy: 1e-9)
        XCTAssertEqual(Units.km.distance(meters: 999.6), 0.9996, accuracy: 1e-12)
    }

    /// Rounding happens once, at display. 1004.9 m is 1.00 km and 1005.1 m is 1.01 km.
    /// Going through rounded miles (1005.1 m → 0.62 mi → 0.998 km) would print the second
    /// one as "1.00 km", and a km total built that way stops agreeing with the sum of its
    /// km splits.
    func testDistanceIsRoundedOnlyAtDisplay() {
        XCTAssertEqual(Units.km.formatDistance(meters: 1004.9), "1.00 km")
        XCTAssertEqual(Units.km.formatDistance(meters: 1005.1), "1.01 km")
        XCTAssertEqual(Units.km.formatDistance(meters: 4999.6), "5.00 km")
        XCTAssertEqual(Units.mi.formatDistance(meters: 8_046.7), "5.00 mi")
        XCTAssertEqual(Units.km.formatDistance(meters: 8_046.7), "8.05 km")
        // Five 1.61 km "miles" printed separately would sum to 8.05 km; the total computed
        // from metres must agree with that, not with 5 × a rounded mile.
        XCTAssertEqual(Units.km.formatDistance(meters: 5 * Units.metersPerMile), "8.05 km")
        XCTAssertEqual(Units.mi.formatDistance(meters: 42_195, decimals: 1), "26.2 mi")
        XCTAssertEqual(Units.km.formatDistance(meters: 42_195, decimals: 0), "42 km")
    }

    // MARK: - Labels

    func testLabels() {
        XCTAssertEqual(Units.mi.abbreviation, "mi")
        XCTAssertEqual(Units.km.abbreviation, "km")
        XCTAssertEqual(Units.mi.paceSuffix, "/mi")
        XCTAssertEqual(Units.km.paceSuffix, "/km")
        XCTAssertEqual(Units.mi.name(plural: false), "mile")
        XCTAssertEqual(Units.km.name(plural: true), "kilometers")
    }
}
