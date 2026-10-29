import XCTest
@testable import Tempo

/// The Drift Detector's tiers (#236, PRD-02 §6.2): on track < 2%, drifting 2–< 5%,
/// off track ≥ 5%, measured against this week's point on the expected curve.
///
/// The thing this replaces is the Progress card's yes/no "projection ≤ goal". That compares
/// to the goal itself, so every runner early in a block reads as behind — the false alarm
/// the PRD calls out by name. The week-2 test below is that case.
final class DriftTests: XCTestCase {

    /// An expected value of 10 000 s makes every 1 s of gap exactly 0.01%, so the boundary
    /// cases below are written in whole seconds and read straight off as percentages.
    private let expected = 10_000.0

    private func reading(_ current: Double?, _ expected: Double?,
                         _ thresholds: DriftThresholds = .standard) -> Drift.Reading? {
        Drift.measure(current: current, expected: expected, thresholds: thresholds).reading
    }

    // MARK: - Boundaries

    func testJustUnderTwoPercentIsOnTrack() {
        let r = reading(10_199, expected)
        XCTAssertEqual(r?.percent ?? .nan, 1.99, accuracy: 1e-9)
        XCTAssertEqual(r?.status, .onTrack)
    }

    func testExactlyTwoPercentIsDrifting() {
        let r = reading(10_200, expected)
        XCTAssertEqual(r?.percent, 2.0, "lands on the boundary exactly, not a hair under it")
        XCTAssertEqual(r?.status, .drifting)
    }

    func testJustUnderFivePercentIsDrifting() {
        let r = reading(10_499, expected)
        XCTAssertEqual(r?.percent ?? .nan, 4.99, accuracy: 1e-9)
        XCTAssertEqual(r?.status, .drifting)
    }

    func testExactlyFivePercentIsOffTrack() {
        let r = reading(10_500, expected)
        XCTAssertEqual(r?.percent, 5.0)
        XCTAssertEqual(r?.status, .offTrack)
    }

    func testTierForAPercentDirectly() {
        XCTAssertEqual(Drift.status(forPercent: 1.99), .onTrack)
        XCTAssertEqual(Drift.status(forPercent: 2.0), .drifting)
        XCTAssertEqual(Drift.status(forPercent: 4.99), .drifting)
        XCTAssertEqual(Drift.status(forPercent: 5.0), .offTrack)
        XCTAssertEqual(Drift.status(forPercent: 40), .offTrack)
    }

    /// The PRD's own scale note: 5% on a 3:30 marathon is about ten and a half minutes.
    func testFivePercentOnAThreeThirtyIsTenAndAHalfMinutes() {
        let r = reading(12_600 + 630, 12_600)
        XCTAssertEqual(r?.gapSeconds, 630)
        XCTAssertEqual(r?.status, .offTrack)
    }

    // MARK: - Ahead of the curve

    /// Faster than expected is good news, not an alarm — but the number keeps its sign, so
    /// whatever explains it can say "ahead by 3%".
    func testAheadOfTheCurveIsOnTrackWithTheSignKept() {
        let r = reading(9_700, expected)
        XCTAssertEqual(r?.percent, -3.0)
        XCTAssertEqual(r?.gapSeconds, -300)
        XCTAssertEqual(r?.status, .onTrack)
    }

    func testFarAheadIsStillOnTrack() {
        XCTAssertEqual(reading(8_000, expected)?.status, .onTrack, "−20% is not off track")
    }

    func testExactlyOnTheCurveIsZero() {
        let r = reading(expected, expected)
        XCTAssertEqual(r?.percent, 0)
        XCTAssertEqual(r?.gapSeconds, 0)
        XCTAssertEqual(r?.status, .onTrack)
    }

    // MARK: - Insufficient data

    /// No estimate means no status — never a default tier that reads as a verdict.
    func testMissingCurrentIsInsufficientData() {
        XCTAssertEqual(Drift.measure(current: nil, expected: expected), .insufficientData)
    }

    func testMissingExpectedIsInsufficientData() {
        XCTAssertEqual(Drift.measure(current: 10_300, expected: nil), .insufficientData)
    }

    func testMissingBothIsInsufficientData() {
        XCTAssertEqual(Drift.measure(current: nil, expected: nil), .insufficientData)
    }

    /// Zero, negative or non-finite times aren't finish times. Dividing by a zero
    /// expectation would otherwise put `inf` or `nan` on screen.
    func testNonsenseTimesAreInsufficientDataNotADivisionByZero() {
        XCTAssertEqual(Drift.measure(current: 10_000, expected: 0), .insufficientData)
        XCTAssertEqual(Drift.measure(current: 0, expected: 10_000), .insufficientData)
        XCTAssertEqual(Drift.measure(current: -5, expected: 10_000), .insufficientData)
        XCTAssertEqual(Drift.measure(current: .nan, expected: 10_000), .insufficientData)
        XCTAssertEqual(Drift.measure(current: 10_000, expected: .infinity), .insufficientData)
    }

    // MARK: - Thresholds are config

    /// The PRD says the beta tunes these. Moving them must move the tiers with no change to
    /// the logic.
    func testCustomThresholdsMoveTheTiers() {
        let tight = DriftThresholds(driftingAt: 1, offTrackAt: 3)
        XCTAssertEqual(reading(10_150, expected, tight)?.status, .drifting, "1.5% under tight")
        XCTAssertEqual(reading(10_300, expected, tight)?.status, .offTrack, "3% under tight")
        XCTAssertEqual(reading(10_300, expected)?.status, .drifting, "3% under standard")
    }

    func testStandardThresholdsAreThePRDsNumbers() {
        XCTAssertEqual(DriftThresholds.standard, DriftThresholds(driftingAt: 2, offTrackAt: 5))
    }

    // MARK: - The PRD case

    /// PRD-02 #4 acceptance: "Week 2 of a 16-week block with normal early fitness → on
    /// track, not off track."
    ///
    /// A runner signs up with 3:45 fitness aiming at 3:30, sixteen weeks out. The real curve
    /// is #3's job; a straight line from signup to goal is enough to stand in for it here.
    /// Two weeks in they've improved a little, but less than the line — normal early-block
    /// noise. Against the curve that is well under 2%. Against the goal, which is what the
    /// Progress card measures today, the same runner is ~6.7% "behind": off track, in week 2,
    /// for doing exactly what a block's first fortnight looks like.
    func testWeekTwoOfASixteenWeekBlockWithNormalEarlyFitnessIsOnTrack() {
        let signup = 13_500.0   // 3:45:00
        let goal = 12_600.0     // 3:30:00
        let weeks = 16.0
        func straightLine(week: Double) -> Double { signup + (goal - signup) * week / weeks }

        let weekTwoExpected = straightLine(week: 2)   // 3:43:07.5
        let current = 13_450.0                        // 3:44:10: a little better than signup

        let vsCurve = reading(current, weekTwoExpected)
        XCTAssertEqual(vsCurve?.status, .onTrack)
        XCTAssertEqual(vsCurve?.gapSeconds, 62.5, "behind the line by about a minute")
        XCTAssertLessThan(vsCurve?.percent ?? .infinity, 1)

        // The comparison this replaces, to show why it had to go.
        XCTAssertEqual(reading(current, goal)?.status, .offTrack)
    }
}
