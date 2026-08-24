import XCTest
@testable import Tempo

/// TrainingPaces.swift claims to be "pure and unit-tested". Until now only half of that
/// was true. These lock the deterministic half of the hybrid engine — the LLM tunes
/// within these bounds, so if they drift, every generated plan drifts with them.
final class PaceModelTests: XCTestCase {

    private let sub315: Double = 3 * 3600 + 15 * 60   // 11,700s — David's Chicago goal

    func testRiegelIsIdentityAtSameDistance() {
        XCTAssertEqual(PaceModel.equivalentTime(seconds: 1200, from: 5, to: 5), 1200, accuracy: 0.001)
    }

    func testRiegelScalesUpWithDistance() {
        let tenK = PaceModel.equivalentTime(seconds: 1200, from: RaceDistance.fiveK.miles,
                                            to: RaceDistance.tenK.miles)
        // Doubling distance costs more than doubling time is generous — Riegel's 1.06
        // exponent puts a 20:00 5k at roughly 41:40 for 10k.
        XCTAssertGreaterThan(tenK, 2400)
        XCTAssertLessThan(tenK, 2560)
    }

    func testRiegelIsMonotonic() {
        var previous = 0.0
        for distance in [3.1, 6.2, 13.1, 26.2] {
            let t = PaceModel.equivalentTime(seconds: 1200, from: 3.1, to: distance)
            XCTAssertGreaterThan(t, previous)
            previous = t
        }
    }

    func testSub315MarathonPacesMatchTheDesign() {
        let p = PaceModel.paces(for: .marathon, goalSeconds: sub315)
        // Documented expectation at the bottom of TrainingPaces.swift.
        XCTAssertEqual(p.marathon, 447, accuracy: 2)      // ~7:26/mi
        XCTAssertEqual(p.threshold, 424, accuracy: 8)     // ~7:0x/mi
        XCTAssertEqual(p.easy, p.threshold + 75)
    }

    func testPacesAreOrderedFastestToSlowest() {
        for distance in RaceDistance.allCases {
            let p = PaceModel.paces(for: distance, goalSeconds: sub315)
            XCTAssertLessThan(p.repetition, p.interval, "\(distance) reps must be fastest")
            XCTAssertLessThan(p.interval, p.threshold, "\(distance) intervals faster than threshold")
            XCTAssertLessThan(p.threshold, p.easy, "\(distance) easy must be slowest")
        }
    }

    func testMarathonPaceIsSlowerThanThresholdForAMarathonGoal() {
        let p = PaceModel.paces(for: .marathon, goalSeconds: sub315)
        XCTAssertGreaterThan(p.marathon, p.threshold,
                             "you cannot hold threshold for 26.2 — MP must be slower")
    }

    func testFormat() {
        XCTAssertEqual(PaceModel.format(447), "7:27")
        XCTAssertEqual(PaceModel.format(600), "10:00")
        XCTAssertEqual(PaceModel.format(65), "1:05")
        XCTAssertEqual(PaceModel.format(0), "0:00")
    }

    func testRaceDistancesAreSane() {
        XCTAssertEqual(RaceDistance.marathon.miles, 26.2188, accuracy: 0.01)
        XCTAssertEqual(RaceDistance.half.miles * 2, RaceDistance.marathon.miles, accuracy: 0.02)
    }
}
