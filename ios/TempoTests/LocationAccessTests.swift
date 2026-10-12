import CoreLocation
import XCTest
@testable import Tempo

/// Pins how Core Location's two permission axes collapse into "can this run be recorded
/// outdoors" (#110). The recorder doesn't exist on a device yet, so these are written against
/// the failure it is designed around: a run that *looks* recorded — a moving dot, a distance
/// ticking up — built from approximate fixes that are kilometres off. The athlete finds out at
/// the finish, when the splits are nonsense and the run can't be redone.
final class LocationAccessTests: XCTestCase {

    private func access(_ status: CLAuthorizationStatus,
                        _ accuracy: CLAccuracyAuthorization = .fullAccuracy) -> LocationAccess {
        LocationAccess.resolve(status: status, accuracy: accuracy)
    }

    // MARK: - The full grid

    func testEveryStatusAndAccuracyPair() {
        let cases: [(CLAuthorizationStatus, CLAccuracyAuthorization, LocationAccess)] = [
            (.notDetermined, .fullAccuracy, .notDetermined),
            (.notDetermined, .reducedAccuracy, .notDetermined),
            (.denied, .fullAccuracy, .denied),
            (.denied, .reducedAccuracy, .denied),
            (.restricted, .fullAccuracy, .restricted),
            (.restricted, .reducedAccuracy, .restricted),
            (.authorizedWhenInUse, .fullAccuracy, .whenInUse),
            (.authorizedWhenInUse, .reducedAccuracy, .reducedAccuracy),
            (.authorizedAlways, .fullAccuracy, .always),
            (.authorizedAlways, .reducedAccuracy, .reducedAccuracy),
        ]
        for (status, accuracy, expected) in cases {
            XCTAssertEqual(access(status, accuracy), expected,
                           "status \(status.rawValue), accuracy \(accuracy.rawValue)")
        }
    }

    // MARK: - Reduced accuracy is a no, not a weaker yes

    func testPreciseLocationOffBlocksAnOutdoorRunEvenWhenAllowed() {
        // The athlete tapped "Allow While Using App" but switched Precise off in the same
        // prompt. Location is "authorized" — and useless for pace.
        let state = access(.authorizedWhenInUse, .reducedAccuracy)
        XCTAssertFalse(state.canRecordOutdoors)
        XCTAssertFalse(state.canPrompt, "the system prompt won't come back; only Settings fixes this")
        XCTAssertNotNil(state.blocker?.range(of: "Precise Location"),
                        "the message has to name the one switch that fixes it")
    }

    func testReducedAccuracyWinsOverAlways() {
        XCTAssertFalse(access(.authorizedAlways, .reducedAccuracy).canRecordOutdoors)
    }

    // MARK: - What Tempo asks for is enough

    func testWhenInUseWithPreciseLocationRecords() {
        // Tempo never asks for Always: a run starts in the foreground, and background updates
        // carry it through a locked screen. If When In Use didn't count, nothing would.
        let state = access(.authorizedWhenInUse)
        XCTAssertTrue(state.canRecordOutdoors)
        XCTAssertNil(state.blocker)
    }

    func testAlwaysGrantedElsewhereAlsoRecords() {
        XCTAssertTrue(access(.authorizedAlways).canRecordOutdoors)
        XCTAssertNil(access(.authorizedAlways).blocker)
    }

    // MARK: - Asking vs. sending to Settings

    func testNeverAskedIsTheOnlyStateThatPrompts() {
        let all: [LocationAccess] = [.notDetermined, .denied, .restricted, .reducedAccuracy, .whenInUse, .always]
        XCTAssertEqual(all.filter(\.canPrompt), [.notDetermined])
    }

    func testNeverAskedIsNotABlocker() {
        // The sheet explains and asks; it does not lead with an error before anyone said no.
        XCTAssertFalse(access(.notDetermined).canRecordOutdoors)
        XCTAssertNil(access(.notDetermined).blocker)
    }

    func testEveryRefusalExplainsItselfAndOffersTreadmill() {
        // Denied, restricted and reduced each get a message; each one leaves a way to run.
        for state in [LocationAccess.denied, .restricted, .reducedAccuracy] {
            XCTAssertFalse(state.canRecordOutdoors, "\(state)")
            let message = state.blocker
            XCTAssertNotNil(message, "\(state) needs a message")
            XCTAssertNotNil(message?.range(of: "Treadmill"), "\(state) should point at treadmill")
        }
    }

    func testDeniedMessageCoversAirplaneModeAndGlobalOff() {
        // Core Location reports all three as `.denied`; the copy can't pick one, so it names
        // each so the athlete can find theirs.
        let message = access(.denied).blocker ?? ""
        XCTAssertNotNil(message.range(of: "Airplane Mode"))
        XCTAssertNotNil(message.range(of: "Location Services"))
    }
}
