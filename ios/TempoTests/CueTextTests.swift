import XCTest
@testable import Tempo

/// With the phone in a pocket, the voice cue is the only number David gets during a run
/// (#118). A wrong one is worse than none: he hears "seven sixty", or a pace one second off
/// because it was truncated instead of rounded, or mile 1 announced 4 m early, and either
/// trusts it or stops trusting the cue. None of that crashes, and on a run nobody looks at a
/// screen to check. These tests pin every sentence the recorder can say, in both units, and
/// the exact metre each split is said at.
final class CueTextTests: XCTestCase {

    // MARK: - The split cue

    /// The sentence from the issue, word for word.
    func testMileSplitReadsTheWayARunnerSaysIt() {
        XCTAssertEqual(CueText.split(index: 3, paceS: 461, averagePaceS: 468, units: .mi),
                       "Mile three. Seven forty-one. Average seven forty-eight.")
    }

    func testKilometerSplitReadsTheSameWay() {
        XCTAssertEqual(CueText.split(index: 12, paceS: 278, averagePaceS: 282, units: .km),
                       "Kilometer twelve. Four thirty-eight. Average four forty-two.")
    }

    /// No average yet is no "Average" sentence, not "Average zero".
    func testMissingAverageIsLeftOutNotInvented() {
        XCTAssertEqual(CueText.split(index: 1, paceS: 480, averagePaceS: nil, units: .mi),
                       "Mile one. Eight flat.")
        XCTAssertEqual(CueText.split(index: 1, paceS: 480, averagePaceS: .nan, units: .km),
                       "Kilometer one. Eight flat.")
    }

    /// The robotic failure mode: hand the synthesizer "7:41" and it may read "seven colon
    /// forty-one" or "seven zero five". Across every split and pace a run can produce, the
    /// cue contains no digit and no colon for it to guess at.
    func testNoDigitsOrColonsAcrossManyPacesAndSplits() {
        for units in Units.allCases {
            for index in 1...60 {
                for paceS in stride(from: 150.0, through: 1_200, by: 7.3) {
                    let cue = CueText.split(index: index, paceS: paceS, averagePaceS: paceS + 4.6, units: units)
                    XCTAssertNil(cue.rangeOfCharacter(from: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ":"))),
                                 "\(units) split \(index) at \(paceS): \(cue)")
                    XCTAssertTrue(cue.hasPrefix(units == .mi ? "Mile " : "Kilometer "), cue)
                }
            }
        }
    }

    /// A finished `TrackMath.Split` is announced; the partial one in progress never is.
    func testOnlyAWholeSplitFromTrackMathIsAnnounced() {
        let whole = TrackMath.Split(index: 2, meters: 1609.34, durationS: 445, paceS: 445,
                                    elevationDeltaM: nil, isPartial: false)
        XCTAssertEqual(CueText.split(whole, averagePaceS: 450, units: .mi),
                       "Mile two. Seven twenty-five. Average seven thirty.")
        let partial = TrackMath.Split(index: 3, meters: 800, durationS: 222, paceS: 446.6,
                                      elevationDeltaM: nil, isPartial: true)
        XCTAssertNil(CueText.split(partial, averagePaceS: 450, units: .mi))
    }

    // MARK: - Pace in words

    /// The phrasing table. Rounded to the whole second first (`Units.clock`'s rule), so
    /// 479.6 s is "eight flat", never "seven sixty".
    func testPacePhrasing() {
        let cases: [(Double, String)] = [
            (461, "seven forty-one"),
            (420, "seven flat"),
            (425, "seven oh five"),
            (479.4, "seven fifty-nine"),
            (479.6, "eight flat"),
            (479.5, "eight flat"),
            (61, "one oh one"),
            (59.5, "one flat"),
            (600, "ten flat"),
            (721, "twelve oh one"),
            (1_335, "twenty-two fifteen"),
            (45, "forty-five seconds"),
            (1, "one second"),
        ]
        for (seconds, said) in cases {
            XCTAssertEqual(CueText.spokenPace(seconds), said, "\(seconds) s")
        }
    }

    func testAnImpossiblePaceSaysNothing() {
        XCTAssertNil(CueText.spokenPace(-1))
        XCTAssertNil(CueText.spokenPace(.nan))
        XCTAssertNil(CueText.spokenPace(.infinity))
    }

    /// The spoken pace and the pace on screen are the same number.
    func testSpokenPaceAgreesWithTheClockOnScreen() {
        for seconds in stride(from: 60.0, through: 1_200, by: 0.25) {
            let clock = Units.clock(seconds).split(separator: ":").map { Int($0)! }
            let said = CueText.spokenPace(seconds)!
            let minutes = CueText.words(clock[0])
            XCTAssertTrue(said.hasPrefix(minutes + " "), "\(seconds): \(said) vs \(Units.clock(seconds))")
            if clock[1] == 0 { XCTAssertTrue(said.hasSuffix(" flat"), said) }
            else { XCTAssertTrue(said.hasSuffix(" " + CueText.words(clock[1])), said) }
        }
    }

    func testNumberWords() {
        let cases: [(Int, String)] = [
            (0, "zero"), (7, "seven"), (13, "thirteen"), (20, "twenty"), (21, "twenty-one"),
            (40, "forty"), (99, "ninety-nine"), (100, "one hundred"), (105, "one hundred five"),
            (342, "three hundred forty-two"), (999, "nine hundred ninety-nine"), (1_000, "1000"),
        ]
        for (n, said) in cases { XCTAssertEqual(CueText.words(n), said) }
    }

    // MARK: - When a split is said: the boundary

    /// Mile 1 is said on the update that reaches 1609.34 m, not one before. Same for 1000 m.
    func testSplitIsAnnouncedExactlyOnTheBoundary() {
        XCTAssertNil(CueText.splitToAnnounce(previousMeters: 1_600, currentMeters: 1_609.33, units: .mi))
        XCTAssertEqual(CueText.splitToAnnounce(previousMeters: 1_609.33, currentMeters: 1_609.34, units: .mi), 1)
        XCTAssertNil(CueText.splitToAnnounce(previousMeters: 990, currentMeters: 999.99, units: .km))
        XCTAssertEqual(CueText.splitToAnnounce(previousMeters: 999.99, currentMeters: 1_000, units: .km), 1)
    }

    /// Once said, not said again on the next update past the boundary.
    func testSplitIsAnnouncedOnce() {
        XCTAssertNil(CueText.splitToAnnounce(previousMeters: 1_609.34, currentMeters: 1_620, units: .mi))
        XCTAssertNil(CueText.splitToAnnounce(previousMeters: 1_000, currentMeters: 1_005, units: .km))
    }

    /// The same 5 km of running says three miles or five kilometres, each at its own metre,
    /// and never one in place of the other.
    func testOneRunAnnouncesEachUnitsOwnSplits() {
        for (units, expected) in [(Units.mi, [1, 2, 3]), (.km, [1, 2, 3, 4, 5])] {
            var said: [Int] = []
            var previous = 0.0
            for m in stride(from: 0.0, through: 5_000, by: 3.7) + [5_000] {
                if let split = CueText.splitToAnnounce(previousMeters: previous, currentMeters: m, units: units) {
                    said.append(split)
                    XCTAssertGreaterThanOrEqual(m, Double(split) * units.splitMeters, "\(units) \(split) early")
                }
                previous = m
            }
            XCTAssertEqual(said, expected, "\(units)")
        }
    }

    /// GPS back after a tunnel jumps two boundaries in one update: say the latest split only.
    func testAJumpOverTwoBoundariesSaysTheLatest() {
        XCTAssertEqual(CueText.splitToAnnounce(previousMeters: 1_500, currentMeters: 3_300, units: .mi), 2)
        XCTAssertEqual(CueText.splitToAnnounce(previousMeters: 900, currentMeters: 3_100, units: .km), 3)
    }

    func testNoDistanceSaysNoSplit() {
        XCTAssertNil(CueText.splitToAnnounce(previousMeters: 0, currentMeters: 0, units: .mi))
        XCTAssertNil(CueText.splitToAnnounce(previousMeters: 0, currentMeters: .nan, units: .km))
        XCTAssertNil(CueText.splitToAnnounce(previousMeters: 1_700, currentMeters: 1_650, units: .mi),
                     "distance never goes backwards, but if it does, nothing is said")
    }

    // MARK: - Auto-pause

    func testAutoPauseCuesFollowTheDecision() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        XCTAssertEqual(CueText.autoPause(.pause(at: at)), "Auto-paused.")
        XCTAssertEqual(CueText.autoPause(.resume(at: at)), "Resumed.")
    }

    // MARK: - Race distance

    /// Chicago 2026 at goal pace. The last sentence is the reason this cue exists.
    func testMarathonCueInMiles() {
        XCTAssertEqual(
            CueText.raceDistance(meters: 42_195, elapsedS: 3 * 3600 + 5 * 60 + 42, averagePaceS: 419, units: .mi),
            "Twenty-six point two miles. Three hours, five minutes, forty-two seconds. Average six fifty-nine. "
            + "GPS reads long, so the finish is still ahead. Keep going.")
    }

    func testMarathonCueInKilometers() {
        let perKm = Units.km.pace(secondsPerMile: 419)   // 260.4 s
        XCTAssertEqual(
            CueText.raceDistance(meters: 42_195, elapsedS: 3 * 3600 + 5 * 60 + 42, averagePaceS: perKm, units: .km),
            "Forty-two point two kilometers. Three hours, five minutes, forty-two seconds. Average four twenty. "
            + "GPS reads long, so the finish is still ahead. Keep going.")
    }

    /// Every distance a goal can have (`RaceRecap.raceMeters`), as the shirt prints it.
    func testRaceDistancesInBothUnits() {
        let cases: [(Double, Units, String)] = [
            (42_195, .mi, "twenty-six point two miles"),
            (21_097.5, .mi, "thirteen point one miles"),
            (21_097.5, .km, "twenty-one point one kilometers"),
            (16_093.4, .mi, "ten miles"),
            (16_093, .mi, "ten miles"),
            (15_000, .km, "fifteen kilometers"),
            (10_000, .mi, "six point two miles"),
            (5_000, .mi, "three point one miles"),
            (5_000, .km, "five kilometers"),
            (1_609.34, .mi, "one mile"),
            (1_609.34, .km, "one point six kilometers"),
            (1_000, .km, "one kilometer"),
        ]
        for (meters, units, said) in cases {
            XCTAssertEqual(CueText.spokenDistance(meters: meters, units: units), said, "\(meters) m in \(units)")
        }
    }

    func testDurationPhrasing() {
        XCTAssertEqual(CueText.spokenDuration(19 * 60 + 52), "nineteen minutes, fifty-two seconds")
        XCTAssertEqual(CueText.spokenDuration(3_600), "one hour")
        XCTAssertEqual(CueText.spokenDuration(3_661), "one hour, one minute, one second")
        XCTAssertEqual(CueText.spokenDuration(7_200.4), "two hours")
        XCTAssertEqual(CueText.spokenDuration(0), "zero seconds")
        XCTAssertNil(CueText.spokenDuration(-5))
    }

    /// Said once, on the update that reaches the race distance.
    func testRaceMarkIsCrossedOnce() {
        XCTAssertFalse(CueText.crossed(42_195, previousMeters: 42_000, currentMeters: 42_194.9))
        XCTAssertTrue(CueText.crossed(42_195, previousMeters: 42_194.9, currentMeters: 42_195))
        XCTAssertFalse(CueText.crossed(42_195, previousMeters: 42_195, currentMeters: 42_210))
        XCTAssertFalse(CueText.crossed(0, previousMeters: 0, currentMeters: 10), "no race, no cue")
    }
}
