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

    // MARK: #248 — the coach call site #201 missed

    func testTheCoachInvokeCancellationIsACancellation() {
        // 2026-10-29, 16:25:20 and 20:42:15 UTC (0.1.0+87 and +94): two `coach.invoke_failed`
        // error rows, both this error verbatim — the chat screen going away mid-send, not a
        // coach that failed. `ChatStore.requestReply` was the fifth catch site and still
        // called `Telemetry.error` directly; it now goes through `errorUnlessCancelled`.
        let cancelled = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: [NSLocalizedDescriptionKey: "cancelled"]
        )
        XCTAssertTrue(Cancellation.isCancellation(cancelled))
    }

    func testARealCoachInvokeFailureStillReports() {
        // The other `coach.invoke_failed` shape (#193/#195, both real): a 502 from the edge
        // function wrapping a bad wire history. Dropping these would have hidden a live bug.
        let http = NSError(domain: "FunctionsError", code: 502)
        XCTAssertFalse(Cancellation.isCancellation(http))
    }

    func testADecodingFailureIsARealFailure() {
        // The kind of error a schema drift produces — exactly what `sync.runs_unreadable`
        // exists to catch, and must keep catching.
        let decoding = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "column missing")
        )
        XCTAssertFalse(Cancellation.isCancellation(decoding))
    }

    // MARK: #292, the two call sites inside the thread write-up pass

    func testTheSummarizeCancellationIsACancellation() {
        // 2026-11-09, 16:38:04 UTC: one `coach.thread_summarize_failed` error row, `detail`
        // NSURLErrorDomain -999 "cancelled". `CoachThreadService.summarize` is reached from
        // `summarizePending`, which `CoachHomeView.reload()` runs on every Coach-tab
        // appearance, so leaving the tab mid-write-up is an ordinary thing to do. The row
        // read as a coach call that failed; it was a reload that went away.
        let cancelled = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: [NSLocalizedDescriptionKey: "cancelled"]
        )
        XCTAssertTrue(Cancellation.isCancellation(cancelled))
    }

    func testANonCancelledNSURLErrorStillReports() {
        // The discrimination this fix rests on is inside NSURLErrorDomain, not between
        // domains: the live row and a dropped connection share a domain and differ only by
        // code, and `context.error_type` reads `NSURLError` for both. Only -999 goes quiet.
        let dropped = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        XCTAssertFalse(Cancellation.isCancellation(dropped))
    }

    /// The classification above only matters if the call sites route through it, and that is
    /// the half this chain keeps missing: nine catch sites across #155, #201, #248, #281,
    /// #286 and #292, each found one live error row at a time. Both sites inside `summarize`
    /// are pinned by name here rather than left to the next triage pass. The transcript read
    /// has no error row of its own yet; it is the same unguarded shape in the same function.
    func testTheSummarizeCallSitesReportThroughErrorUnlessCancelled() throws {
        let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = ios.appendingPathComponent("Tempo")
        let events = ["coach.thread_transcript_unreadable", "coach.thread_summarize_failed"]
        var reported: [String: [String]] = [:]
        var files = 0
        for name in try UnitsLintTests.swiftFiles(under: root) {
            files += 1
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            for line in ZeroRowSingleLintTests.stripComments(text).components(separatedBy: "\n") {
                for event in events where line.contains("\"\(event)\"") {
                    reported[event, default: []].append("Tempo/\(name): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertGreaterThan(files, 90, "the scan found the app sources")
        for event in events {
            let sites = reported[event] ?? []
            XCTAssertEqual(sites.count, 1, "one call site reports \(event):\n" + sites.joined(separator: "\n"))
            XCTAssertTrue(
                sites.allSatisfy { $0.contains("Telemetry.errorUnlessCancelled(") },
                "A cancelled write-up pass is not a failure worth naming:\n" + sites.joined(separator: "\n")
            )
        }
    }
}
