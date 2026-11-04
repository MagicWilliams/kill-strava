import XCTest
@testable import Tempo

/// Telling a limit apart from an outage. Getting this wrong either way shows the athlete the
/// wrong failure: "Coach unreachable" for something no amount of retrying fixes, or "you've
/// reached your limit" while the platform is the thing that's down.
final class UsageLimitTests: XCTestCase {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    func testTheFunctionsRefusalIsRecognizedAndKeepsItsWords() {
        let refusal = UsageLimit.refusal(
            status: 429,
            body: body(#"{"error":"usage_limited","kind":"chat","retry_after_s":2400,"message":"It resets in about 40 minutes."}"#)
        )
        XCTAssertEqual(refusal?.message, "It resets in about 40 minutes.")
    }

    func testAGateway429IsAnOutageNotALimit() {
        // The Supabase gateway rate-limits too, with a body of its own.
        XCTAssertNil(UsageLimit.refusal(status: 429, body: body(#"{"message":"Too many requests"}"#)))
        XCTAssertNil(UsageLimit.refusal(status: 429, body: body("Too Many Requests")))
        XCTAssertNil(UsageLimit.refusal(status: 429, body: Data()))
    }

    func testOnlyA429IsALimitWhateverTheBodySays() {
        let limited = body(#"{"error":"usage_limited","message":"no"}"#)
        XCTAssertNil(UsageLimit.refusal(status: 500, body: limited))
        XCTAssertNil(UsageLimit.refusal(status: 401, body: limited))
    }

    func testTheOtherFunctionErrorsAreNotLimits() {
        // What `plan` and `coach` send for everything else.
        XCTAssertNil(UsageLimit.refusal(status: 400, body: body(#"{"error":"distance_required"}"#)))
        XCTAssertNil(UsageLimit.refusal(status: 401, body: body(#"{"error":"unauthorized"}"#)))
        XCTAssertNil(UsageLimit.refusal(status: 502, body: body(#"{"error":"anthropic 529"}"#)))
    }

    func testARefusalWithNoWordsStillSaysItIsALimit() {
        for json in [#"{"error":"usage_limited"}"#, #"{"error":"usage_limited","message":"  "}"#] {
            XCTAssertEqual(UsageLimit.refusal(status: 429, body: body(json))?.message, UsageLimit.Copy.fallback)
        }
    }

    func testTheFallbackCannotBeReadAsAnOutageOrAsLostData() {
        let copy = UsageLimit.Copy.fallback.lowercased()
        XCTAssertTrue(copy.contains("limit"))
        for word in ["unreachable", "couldn't", "failed", "offline", "lost"] {
            XCTAssertFalse(copy.contains(word), word)
        }
    }

    // MARK: - The size cap

    func testTheSizeRefusalIsRecognizedAndKeepsItsWords() {
        let refusal = UsageLimit.refusal(
            status: 413,
            body: body(#"{"error":"request_too_large","message":"Too much at once."}"#)
        )
        XCTAssertEqual(refusal?.message, "Too much at once.")
        XCTAssertEqual(refusal?.cause, .tooLarge)
    }

    func testAnAllowanceRefusalKeepsItsCause() {
        let refusal = UsageLimit.refusal(status: 429, body: body(#"{"error":"usage_limited","message":"Later."}"#))
        XCTAssertEqual(refusal?.cause, .allowance)
    }

    func testAGateway413IsAFailureNotARefusal() {
        // Whatever is in front of the function can turn away a body too, in words of its own.
        XCTAssertNil(UsageLimit.refusal(status: 413, body: body(#"{"message":"Payload too large"}"#)))
        XCTAssertNil(UsageLimit.refusal(status: 413, body: body("Request Entity Too Large")))
        XCTAssertNil(UsageLimit.refusal(status: 413, body: Data()))
    }

    func testEachCodeOnlyCountsWithItsOwnStatus() {
        XCTAssertNil(UsageLimit.refusal(status: 429, body: body(#"{"error":"request_too_large","message":"no"}"#)))
        XCTAssertNil(UsageLimit.refusal(status: 413, body: body(#"{"error":"usage_limited","message":"no"}"#)))
        XCTAssertNil(UsageLimit.refusal(status: 400, body: body(#"{"error":"request_too_large","message":"no"}"#)))
    }

    func testASizeRefusalWithNoWordsStillSaysWhatHappened() {
        for json in [#"{"error":"request_too_large"}"#, #"{"error":"request_too_large","message":"  "}"#] {
            XCTAssertEqual(UsageLimit.refusal(status: 413, body: body(json))?.message, UsageLimit.Copy.tooLargeFallback)
        }
    }

    func testTheSizeFallbackCannotBeReadAsAnOutageOrAsLostData() {
        let copy = UsageLimit.Copy.tooLargeFallback.lowercased()
        for word in ["unreachable", "couldn't", "failed", "offline", "lost"] {
            XCTAssertFalse(copy.contains(word), word)
        }
    }

    /// What keeps one too-large thread from blocking every newer recap, oldest first, forever.
    func testOnlyAnAllowanceStopsWhatIsQueuedBehindIt() {
        XCTAssertTrue(UsageLimit.Refusal(message: "", cause: .allowance).appliesToLaterRequests)
        XCTAssertFalse(UsageLimit.Refusal(message: "", cause: .tooLarge).appliesToLaterRequests)
    }
}
