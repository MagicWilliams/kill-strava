import XCTest
@testable import Tempo

/// The whole rule for replacing an account: only when nothing is stored, or the server says
/// the stored session opens nothing.
final class SessionLossTests: XCTestCase {

    private func step(_ stored: SessionLoss.Slot, _ setAside: SessionLoss.Slot) -> SessionLoss.Step {
        SessionLoss.step(stored: stored, setAside: setAside, failure: "why")
    }

    func testNothingStoredCreatesAnAccount() {
        XCTAssertEqual(step(.empty, .empty), .createAccount(.nothingStored))
    }

    func testASessionStillStoredIsHeldWhateverTheError() {
        for setAside in [SessionLoss.Slot.empty, .held, .unreadable] {
            XCTAssertEqual(step(.held, setAside), .hold("why"))
        }
    }

    func testUnreadableStorageIsNeverReadAsEmpty() {
        for other in [SessionLoss.Slot.empty, .held, .unreadable] {
            XCTAssertEqual(step(.unreadable, other), .hold("storage_unreadable"))
        }
        XCTAssertEqual(step(.empty, .unreadable), .hold("storage_unreadable"))
    }

    func testASessionTheSDKRemovedIsAskedAbout() {
        XCTAssertEqual(step(.empty, .held), .askServer)
    }

    func testOnlyAMissingTokenOrSessionCreatesAnAccount() {
        let created: [String: SessionLoss.Cause] = ["refresh_token_not_found": .tokenNotFound,
                                                    "session_not_found": .sessionNotFound]
        for (code, cause) in created {
            XCTAssertEqual(SessionLoss.verdict(on: .http(status: 400, code: code)), .createAccount(cause))
        }
        // Refusals of a session that is still on the server, and one code that is ours.
        for code in ["refresh_token_already_used", "session_expired", "user_banned",
                     "over_request_rate_limit", "validation_failed", "bad_jwt", "unknown",
                     "unexpected_failure", "nothing_stored"] {
            XCTAssertEqual(SessionLoss.verdict(on: .http(status: 400, code: code)), .hold(code))
        }
    }

    func testEveryOtherAnswerIsAHold() {
        XCTAssertEqual(SessionLoss.verdict(on: .none), .hold("no_reply"))
        for status in [302, 400, 401, 403, 404, 429, 500, 502, 503, 504, 522, 540] {
            XCTAssertEqual(SessionLoss.verdict(on: .http(status: status, code: nil)), .hold("http_\(status)"))
        }
        // A 5xx cannot vouch for a code.
        XCTAssertEqual(SessionLoss.verdict(on: .http(status: 500, code: "session_not_found")),
                       .hold("session_not_found"))
    }

    func testASuccessfulRefreshRestores() {
        XCTAssertEqual(SessionLoss.verdict(on: .http(status: 200, code: nil)), .restore)
    }
}
