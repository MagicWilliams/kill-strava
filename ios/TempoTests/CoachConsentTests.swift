import XCTest
@testable import Tempo

/// The gate in front of Anthropic (App Review 5.1.2(i)).
///
/// Three things are pinned: only a real "agreed" sends, the phone and the server settle to one
/// answer without ever failing open, and every call in the app really does go through the one
/// place that checks.
final class CoachConsentTests: XCTestCase {
    private let earlier = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    private func agreed(_ at: Date) -> CoachConsent.Record { .init(decision: .agreed, at: at) }
    private func declined(_ at: Date) -> CoachConsent.Record { .init(decision: .declined, at: at) }

    // MARK: May this send?

    func testOnlyAgreedSends() {
        XCTAssertTrue(CoachConsent.maySend(.agreed))
        XCTAssertFalse(CoachConsent.maySend(.declined))
        XCTAssertFalse(CoachConsent.maySend(.undecided))
        XCTAssertFalse(CoachConsent.maySend(.unknown), "not knowing is a no")
    }

    func testOnlyUndecidedPrompts() {
        XCTAssertTrue(CoachConsent.shouldPrompt(.undecided))
        XCTAssertFalse(CoachConsent.shouldPrompt(.declined), "a decline is an answer: it is asked once")
        XCTAssertFalse(CoachConsent.shouldPrompt(.agreed))
        XCTAssertFalse(CoachConsent.shouldPrompt(.unknown), "a dropped connection must not re-ask")
    }

    // MARK: An existing athlete, on the first launch after this ships

    func testNoDecisionAnywhereIsUndecided() {
        let result = CoachConsent.resolve(server: .record(nil), local: nil)
        XCTAssertEqual(result.status, .undecided)
        XCTAssertNil(result.upload)
    }

    func testAgreedOnTheServerSurvivesAReinstall() {
        // Reinstalling empties UserDefaults; the anonymous session lives on in the Keychain.
        let result = CoachConsent.resolve(server: .record(agreed(earlier)), local: nil)
        XCTAssertEqual(result.status, .agreed)
        XCTAssertEqual(result.record, agreed(earlier), "kept on the phone for the next offline launch")
        XCTAssertNil(result.upload)
    }

    // MARK: The migration isn't applied yet

    func testAMissingColumnFallsBackToThePhone() {
        XCTAssertEqual(CoachConsent.resolve(server: .columnMissing, local: agreed(earlier)).status, .agreed)
        XCTAssertEqual(CoachConsent.resolve(server: .columnMissing, local: declined(earlier)).status, .declined)
    }

    func testAMissingColumnWithNoPhoneCopyStillAsks() {
        // The column being absent must not lock anyone out of the coach for good.
        XCTAssertEqual(CoachConsent.resolve(server: .columnMissing, local: nil).status, .undecided)
    }

    func testAMissingColumnHasNowhereToUploadTo() {
        XCTAssertNil(CoachConsent.resolve(server: .columnMissing, local: agreed(earlier)).upload)
    }

    func testADecisionMadeBeforeTheMigrationGoesUpAfterIt() {
        let result = CoachConsent.resolve(server: .record(nil), local: agreed(earlier))
        XCTAssertEqual(result.status, .agreed)
        XCTAssertEqual(result.upload, agreed(earlier))
    }

    // MARK: A failed read

    func testAFailedReadWithNoPhoneCopyIsUnknownAndDoesNotSend() {
        let result = CoachConsent.resolve(server: .unreadable, local: nil)
        XCTAssertEqual(result.status, .unknown)
        XCTAssertFalse(CoachConsent.maySend(result.status))
    }

    func testAFailedReadKeepsWhatThePhoneKnows() {
        XCTAssertEqual(CoachConsent.resolve(server: .unreadable, local: agreed(earlier)).status, .agreed)
        XCTAssertEqual(CoachConsent.resolve(server: .unreadable, local: declined(earlier)).status, .declined)
    }

    // MARK: The phone and the server disagree

    func testWithdrawingOfflineBeatsAnOlderAgreeOnTheServer() {
        let result = CoachConsent.resolve(server: .record(agreed(earlier)), local: declined(later))
        XCTAssertEqual(result.status, .declined)
        XCTAssertEqual(result.upload, declined(later), "and the server is corrected")
    }

    func testANewerServerDecisionBeatsAnOlderPhoneCopy() {
        let result = CoachConsent.resolve(server: .record(declined(later)), local: agreed(earlier))
        XCTAssertEqual(result.status, .declined)
        XCTAssertNil(result.upload)
        XCTAssertEqual(result.record, declined(later))
    }

    func testATieBetweenDifferentAnswersNeverSends() {
        let phoneAgreed = CoachConsent.resolve(server: .record(declined(earlier)), local: agreed(earlier))
        XCTAssertEqual(phoneAgreed.status, .declined)
        XCTAssertNil(phoneAgreed.upload)

        let phoneDeclined = CoachConsent.resolve(server: .record(agreed(earlier)), local: declined(earlier))
        XCTAssertEqual(phoneDeclined.status, .declined)
        XCTAssertEqual(phoneDeclined.upload, declined(earlier))
    }

    func testTheSameAnswerIsNotUploadedAgain() {
        // The phone keeps sub-second precision the column's string lost. If that alone counted
        // as "newer", the decision would be rewritten on every launch forever.
        let phone = agreed(Date(timeIntervalSince1970: 1_000.7))
        let server = agreed(Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(CoachConsent.resolve(server: .record(server), local: phone).upload)
    }

    // MARK: Reading the columns

    func testTheColumnsBecomeARecord() {
        XCTAssertEqual(CoachConsent.record(decision: "agreed", at: earlier), agreed(earlier))
        XCTAssertEqual(CoachConsent.record(decision: "declined", at: earlier), declined(earlier))
    }

    func testAnythingElseInTheColumnsIsNotADecision() {
        XCTAssertNil(CoachConsent.record(decision: nil, at: nil))
        XCTAssertNil(CoachConsent.record(decision: "agreed", at: nil), "half a record is not consent")
        XCTAssertNil(CoachConsent.record(decision: nil, at: earlier))
        XCTAssertNil(CoachConsent.record(decision: "yes", at: earlier))
        XCTAssertEqual(
            CoachConsent.resolve(server: .record(CoachConsent.record(decision: "yes", at: earlier)), local: nil).status,
            .undecided
        )
    }

    // MARK: What the screen promises

    func testTheScreenNamesWhoAndWhat() {
        XCTAssertTrue(CoachConsent.Copy.lead.contains("Anthropic"))
        XCTAssertTrue(CoachConsent.Copy.sentHeading.contains("Anthropic"))
        let sent = CoachConsent.Copy.sent.joined(separator: " ")
        for item in ["messages", "conversation", "Run summaries", "heart rate", "plan", "goals", "notes"] {
            XCTAssertTrue(sent.contains(item), "the list must name \(item)")
        }
        let kept = CoachConsent.Copy.notSent.joined(separator: " ")
        for item in ["routes", "samples", "photos"] {
            XCTAssertTrue(kept.contains(item), "the list must rule out \(item)")
        }
    }

    func testThePolicyLinkIsThePublishedPage() {
        XCTAssertEqual(CoachConsent.privacyPolicy.scheme, "https")
        XCTAssertEqual(CoachConsent.privacyPolicy.lastPathComponent, "privacy.html")
    }

    func testTheNoticeSaysWhichProblemItIs() {
        XCTAssertEqual(CoachConsent.Copy.notice(for: .declined), CoachConsent.Copy.off)
        XCTAssertEqual(CoachConsent.Copy.notice(for: .undecided), CoachConsent.Copy.off)
        XCTAssertEqual(CoachConsent.Copy.notice(for: .unknown), CoachConsent.Copy.unconfirmed)
    }

    // MARK: Lint: one way out of the app

    /// `ios/`, found from this file's own path, exactly as `UnitsLintTests` does it.
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tempo")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// "Enforced in one place" is only true while nobody writes a sixth call. A new service
    /// that reached for the functions client directly would send without asking, compile,
    /// and pass every other test, so that is what this fails on.
    func testOnlyTheGatewayTouchesTheEdgeFunctions() throws {
        var violations: [String] = []
        let files = try UnitsLintTests.swiftFiles(under: appRoot)
        XCTAssertGreaterThan(files.count, 90, "the scan found the app sources")
        for name in files where name != "Services/CoachGateway.swift" {
            let text = try source(name)
            for needle in ["functions.invoke", ".functions.", "functions/v1", "api.anthropic.com"] where text.contains(needle) {
                violations.append("Tempo/\(name): \(needle)")
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "Every Claude call goes through CoachGateway, which checks consent:\n" + violations.joined(separator: "\n")
        )
    }

    func testTheGatewayChecksBeforeItCalls() throws {
        let gateway = try source("Services/CoachGateway.swift")
        let check = try XCTUnwrap(gateway.range(of: "maySend"), "the gateway checks consent")
        let call = try XCTUnwrap(gateway.range(of: "functions.invoke"), "the gateway makes the call")
        XCTAssertLessThan(check.lowerBound, call.lowerBound)
    }

    /// The claim the screen and the policy make, against the payloads that could break it. If
    /// this fails, a route or a sample is on its way to Anthropic: don't change the test,
    /// change the copy in `CoachConsent.Copy` and `site/privacy.html` first (PRD-02 rule 5).
    func testNoPayloadCarriesARouteOrARawSample() throws {
        let payloads = [
            ("Services/RunStore.swift", "struct CoachContext"),
            ("Services/TakeawayService.swift", "struct RunPayload"),
            ("Services/BlockReviewService.swift", "struct CoachBlock"),
        ]
        for (path, opening) in payloads {
            let text = try source(path)
            let start = try XCTUnwrap(text.range(of: opening), "\(path) still declares \(opening)")
            let body = Self.declaration(in: text, from: start.lowerBound).lowercased()
            for word in ["route", "latitude", "longitude", "coordinate", "polyline", "samples", "photo"] {
                XCTAssertFalse(body.contains(word), "\(opening) in \(path) mentions \(word)")
            }
        }
    }

    /// The text of the braced declaration starting at `start`.
    private static func declaration(in text: String, from start: String.Index) -> String {
        var depth = 0
        var opened = false
        var index = start
        while index < text.endIndex {
            if text[index] == "{" { depth += 1; opened = true }
            if text[index] == "}" { depth -= 1 }
            if opened && depth == 0 { return String(text[start...index]) }
            index = text.index(after: index)
        }
        return String(text[start...])
    }
}
