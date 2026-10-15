import XCTest
@testable import Tempo

/// Regression suite for #155. On 2026-10-13 at 19:46:28 UTC one cancelled `refresh()` wrote
/// four never-before-seen error events to `app_events` inside 115 ms —
/// `sync.runs_unreadable`, `sync.insert_failed`, `takeaway.latest_unreadable`,
/// `block.past_unreadable` — every one `error_type: CancellationError`. The next refresh
/// succeeded; nothing was lost. The pair fired again on 2026-10-15 07:43:26 (`0.1.0+68`).
///
/// The danger was never the app, it was triage: four new named errors at once is what a
/// real regression looks like. These tests pin both halves of the fix — cancellation is
/// recognised in each spelling it arrives in, and nothing that is a genuine failure is.
final class CancellationTests: XCTestCase {

    // MARK: Cancellation is recognised

    func testSwiftCancellationErrorIsACancellation() {
        // The exact error from both incidents: `CancellationError()`.
        XCTAssertTrue(Cancellation.isCancellation(CancellationError()))
    }

    func testURLSessionCancelledIsACancellation() {
        // A URLSession task under a cancelled Swift task can surface this instead.
        XCTAssertTrue(Cancellation.isCancellation(URLError(.cancelled)))
    }

    func testBridgedNSURLErrorCancelledIsACancellation() {
        // The Objective-C shape of the same thing (NSURLErrorDomain −999) — what an error
        // that crossed a Foundation boundary looks like by the time it reaches a catch.
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertTrue(Cancellation.isCancellation(ns))
    }

    func testACancellationThrownFromACancelledTaskIsRecognised() async {
        // End to end through structured concurrency: the error `Task.checkCancellation()`
        // throws is the one the four catch sites saw.
        let task = Task { () -> Error? in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        let thrown = await task.value
        XCTAssertNotNil(thrown)
        XCTAssertTrue(Cancellation.isCancellation(thrown!))
    }

    // MARK: Real failures still report

    func testATimeoutIsARealFailure() {
        XCTAssertFalse(Cancellation.isCancellation(URLError(.timedOut)))
    }

    func testOfflineIsARealFailure() {
        XCTAssertFalse(Cancellation.isCancellation(URLError(.notConnectedToInternet)))
        XCTAssertFalse(Cancellation.isCancellation(URLError(.networkConnectionLost)))
    }

    func testAnUnrelatedErrorWithCodeMinus999IsNotACancellation() {
        // Only NSURLErrorDomain's −999 means "cancelled"; the number alone does not.
        let other = NSError(domain: "PostgrestError", code: NSURLErrorCancelled)
        XCTAssertFalse(Cancellation.isCancellation(other))
    }

    func testADecodingFailureIsARealFailure() {
        // The kind of error a schema drift produces — exactly what `sync.runs_unreadable`
        // exists to catch, and must keep catching.
        let decoding = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "column missing")
        )
        XCTAssertFalse(Cancellation.isCancellation(decoding))
    }
}
