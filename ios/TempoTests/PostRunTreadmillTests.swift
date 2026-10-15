import XCTest
@testable import Tempo

/// "Treadmill said…" on the save screen (#130): the stepper that takes the console's distance.
///
/// It sits one tap from Save, on a screen he reaches out of breath. What would go wrong is
/// quiet: a stepper that drifts to 4.999999 after a few taps and saves a correction he never
/// made, a typed "5,25" (a comma-decimal region's keypad) read as nothing or as 525, a Save on
/// the untouched prefill that marks the run edited, or a summary that shows one distance while
/// the save writes another.
final class PostRunTreadmillTests: XCTestCase {

    /// The phone counted 4.7137 mi: 4.71 on the stepper.
    private let estimate = Units.mi.meters(distance: 4.7137)

    // MARK: - The stepper

    func testItOpensOnThePhonesCountToTheHundredth() {
        XCTAssertEqual(PostRun.consolePrefill(estimateM: estimate, units: .mi), 471)
        XCTAssertEqual(PostRun.consolePrefill(estimateM: Units.km.meters(distance: 7.586), units: .km), 759)
        XCTAssertEqual(PostRun.consolePrefill(estimateM: 0, units: .mi), 0, "no steps: it opens on 0.00")
        XCTAssertEqual(PostRun.consolePrefill(estimateM: .nan, units: .mi), 0)
        XCTAssertEqual(PostRun.consoleText(471), "4.71")
        XCTAssertEqual(PostRun.consoleText(500), "5.00")
        XCTAssertEqual(PostRun.consoleText(5), "0.05")
    }

    /// ±0.01 a tap, in whole hundredths: a hundred taps each way end exactly where they began.
    func testEachTapIsOneHundredthAndNeverDrifts() {
        var value = 471
        for _ in 0..<100 { value = PostRun.stepped(value, by: 1) }
        XCTAssertEqual(PostRun.consoleText(value), "5.71")
        for _ in 0..<100 { value = PostRun.stepped(value, by: -1) }
        XCTAssertEqual(value, 471)
    }

    func testItStaysInsideTheRange() {
        XCTAssertEqual(PostRun.stepped(0, by: -1), 0, "nothing below zero")
        XCTAssertEqual(PostRun.stepped(9_999, by: 1), 9_999)
    }

    // MARK: - Tap-to-type

    func testTypedDistancesAreReadTheWayHeMeantThem() {
        let cases: [(String, Int?)] = [
            ("5", 500), ("5.2", 520), ("5.25", 525), (" 5.00 ", 500), (".8", 80),
            ("5,25", 525),                  // a comma-decimal keypad
            ("5.256", 526),                 // the console shows two places
            ("", nil), ("abc", nil), ("5.2.1", nil), ("-3", nil), ("100", nil), ("1e2", nil),
        ]
        for (typed, expected) in cases {
            XCTAssertEqual(PostRun.typedConsole(typed), expected, "\"\(typed)\"")
        }
    }

    // MARK: - What Save hands over

    func testZeroIsNoReading() {
        XCTAssertNil(PostRun.consoleMeters(0, units: .mi))
        XCTAssertNil(PostRun.consoleMeters(nil, units: .mi))
        XCTAssertEqual(PostRun.consoleMeters(500, units: .mi), 5 * Units.metersPerMile)
        XCTAssertEqual(PostRun.consoleMeters(800, units: .km), 8_000)
    }

    /// Skippable by leaving it alone: Save on the prefill is no correction at all.
    func testTheUntouchedPrefillIsNoCorrection() {
        let prefill = PostRun.consolePrefill(estimateM: estimate, units: .mi)
        XCTAssertNil(TreadmillDistance.correction(consoleM: PostRun.consoleMeters(prefill, units: .mi),
                                                  estimateM: estimate, units: .mi))
        XCTAssertNotNil(TreadmillDistance.correction(consoleM: PostRun.consoleMeters(prefill + 1, units: .mi),
                                                     estimateM: estimate, units: .mi))
    }

    // MARK: - What the screen says while he edits

    /// The summary shows what Save will write: the step count until he changes it, then the
    /// console's figure.
    func testTheSummaryDistanceFollowsTheStepper() {
        XCTAssertEqual(PostRun.shownDistanceM(estimateM: estimate, consoleHundredths: 471, units: .mi), estimate)
        XCTAssertEqual(PostRun.shownDistanceM(estimateM: estimate, consoleHundredths: 500, units: .mi),
                       5 * Units.metersPerMile)
        XCTAssertEqual(PostRun.shownDistanceM(estimateM: estimate, consoleHundredths: 0, units: .mi), estimate,
                       "zero is no reading")
        let s = PostRun.summary(distanceM: PostRun.shownDistanceM(estimateM: estimate, consoleHundredths: 500, units: .mi),
                                movingS: 2_280, elapsedS: 2_400, units: .mi)
        XCTAssertEqual(s.distance, "5.00")
        XCTAssertEqual(s.pace, "7:36", "pace recomputed from the console's distance")
    }

    func testTheHintSaysWhatLeavingItAloneDoes() {
        XCTAssertEqual(PostRun.consoleHint(estimateM: estimate, consoleHundredths: 471, units: .mi),
                       "Your phone counted 4.71 mi from your steps. Set this to what the treadmill showed, or leave it.")
        XCTAssertEqual(PostRun.consoleHint(estimateM: estimate, consoleHundredths: 500, units: .mi),
                       "Your phone counted 4.71 mi from your steps. The run will be saved at the treadmill's distance.")
        XCTAssertEqual(PostRun.consoleHint(estimateM: 0, consoleHundredths: 0, units: .km),
                       "Your phone didn't count any steps. Set this to what the treadmill showed, or the run is saved with no distance.")
    }
}
