import XCTest
@testable import Tempo

/// Regression suite for the silent-revert read path (issue #8), the same bug class as the
/// 2026-08-23 splash freeze: `try?` erased the difference between "the table is empty" and
/// "the server never answered", so a network blip swapped the athlete's corrected distances
/// for the raw Apple Health numbers they had overwritten — a wrong number on screen, no
/// crash, nothing to notice.
///
/// The two invariants below are the ones that matter. Everything else is detail.
final class RunFetchTests: XCTestCase {

    /// A run as Supabase returns it: corrected by the athlete through the coach.
    private func corrected(_ minutesFromEpoch: Int, miles: Double, id: UUID = UUID()) -> RunSummary {
        RunSummary(
            id: id,
            start: Date(timeIntervalSince1970: TimeInterval(minutesFromEpoch * 60)),
            distanceM: Int(miles * 1609.34),
            durationS: Int(miles * 9 * 60),
            avgHR: nil,
            corrected: true,
            source: "healthkit"
        )
    }

    /// The same run as HealthKit still holds it — raw, pre-correction.
    private func raw(_ minutesFromEpoch: Int, miles: Double, id: UUID = UUID()) -> RunSummary {
        RunSummary(
            id: id,
            start: Date(timeIntervalSince1970: TimeInterval(minutesFromEpoch * 60)),
            distanceM: Int(miles * 1609.34),
            durationS: Int(miles * 9 * 60),
            avgHR: nil
        )
    }

    // MARK: Invariant 1 — a failed read never replaces corrected numbers with raw ones

    func testUnreachableKeepsTheCorrectedSetInsteadOfTheHealthKitCopy() {
        // The exact scenario from the issue: the athlete told the coach the run was 8.0,
        // Supabase holds 8.0, HealthKit still holds Garmin's 7.6. The server blips.
        let onScreen = [corrected(600, miles: 8.0)]
        let ingested = [raw(600, miles: 7.6)]

        let decision = RunFetch.resolve(.unreachable, ingested: ingested, onScreen: onScreen)

        XCTAssertNil(decision.runs, "nil means: leave the corrected set alone")
        XCTAssertEqual(decision.freshness, .stale)
        XCTAssertEqual(decision.availability, .ready)
        XCTAssertEqual(decision.warning, RunFetch.Copy.stale)
    }

    func testUnreachableWithNothingCachedFallsBackButSaysTheNumbersAreRaw() {
        // Cold launch offline: the fallback is the only way to show anything at all, so it
        // stays — but it is announced, because these numbers are not the corrected ones.
        let ingested = [raw(600, miles: 7.6)]

        let decision = RunFetch.resolve(.unreachable, ingested: ingested, onScreen: [])

        XCTAssertNotNil(decision.runs)
        XCTAssertEqual(decision.runs ?? [], ingested)
        XCTAssertEqual(decision.freshness, .uncorrected)
        XCTAssertEqual(decision.warning, RunFetch.Copy.uncorrected)
    }

    // MARK: Invariant 2 — anything other than a clean read is announced

    func testOnlyACleanReadIsSilent() {
        let rows = [corrected(600, miles: 8.0)]
        let ingested = [raw(600, miles: 7.6)]

        let everyOutcome: [RunFetch.Decision] = [[], rows].flatMap { onScreen in
            [RunFetch.Response.rows(rows), .rows([]), .incomplete([]), .unreachable].map {
                RunFetch.resolve($0, ingested: ingested, onScreen: onScreen)
            }
        }

        for decision in everyOutcome {
            if decision.freshness == .current {
                XCTAssertNil(decision.warning, "a clean read has nothing to apologise for")
            } else {
                XCTAssertNotNil(
                    decision.warning,
                    "\(decision.freshness) is not the corrected record and must say so"
                )
            }
        }
    }

    // MARK: An empty table is not a failure

    func testEmptyTableReadsAsEmptyNotAsAProblem() {
        // The distinction the old `try?` destroyed: a readable, genuinely empty `runs`
        // table is a new athlete, not an outage.
        let decision = RunFetch.resolve(.rows([]), ingested: [], onScreen: [])

        XCTAssertNotNil(decision.runs, "an empty table is an answer, not a shrug")
        XCTAssertEqual(decision.runs ?? [], [])
        XCTAssertEqual(decision.availability, .empty)
        XCTAssertEqual(decision.freshness, .current)
        XCTAssertNil(decision.warning)
    }

    func testCleanReadWinsOverBothTheHealthKitCopyAndWhatIsOnScreen() {
        let rows = [corrected(600, miles: 8.0)]
        let decision = RunFetch.resolve(
            .rows(rows),
            ingested: [raw(600, miles: 7.6)],
            onScreen: [corrected(60, miles: 3.0)]
        )

        XCTAssertEqual(decision.runs ?? [], rows)
        XCTAssertEqual(decision.availability, .ready)
        XCTAssertNil(decision.warning)
    }

    func testNothingAnywhereIsUnavailableAndExplainsWhy() {
        let decision = RunFetch.resolve(.unreachable, ingested: [], onScreen: [])

        XCTAssertNil(decision.runs)
        XCTAssertEqual(decision.availability, .unavailable)
        XCTAssertEqual(decision.warning, RunFetch.Copy.nothing,
                       "a blank screen must not blame Health access when the server is down")
    }

    // MARK: The post-insert re-read

    func testIncompleteReadShowsTheJustSyncedRunsRatherThanHidingThem() {
        // We inserted this morning's run, then the re-read failed. Before this fix the run
        // simply wasn't there until the next refresh.
        let yesterday = corrected(0, miles: 8.0)
        let thisMorning = raw(600, miles: 6.0)

        let decision = RunFetch.resolve(
            .incomplete([yesterday]),
            ingested: [thisMorning],
            onScreen: [yesterday]
        )

        XCTAssertEqual(decision.runs?.count, 2)
        XCTAssertEqual(decision.runs?.first?.id, thisMorning.id, "newest first")
        XCTAssertEqual(decision.freshness, .missingRecent)
        XCTAssertEqual(decision.warning, RunFetch.Copy.missingRecent)
    }

    func testIncompleteReadGraftsNothingWhenTheRowsAlreadyHoldTheRun() {
        // Re-export shape: the ingested candidate starts within the dedupe window of a row
        // we already have, so it is the same run — nothing is missing, nothing to warn about.
        let row = corrected(600, miles: 8.0)
        let sameRunReExported = raw(601, miles: 7.6)

        let decision = RunFetch.resolve(
            .incomplete([row]),
            ingested: [sameRunReExported],
            onScreen: [row]
        )

        XCTAssertEqual(decision.runs ?? [], [row])
        XCTAssertEqual(decision.freshness, .current)
        XCTAssertNil(decision.warning)
    }

    // MARK: The takeaway cache — a failed read must not cost a Claude call

    func testUnreadableTakeawayNeverTriggersGeneration() {
        XCTAssertFalse(RunFetch.Takeaway.unreadable.shouldGenerate)
        XCTAssertNil(RunFetch.Takeaway.unreadable.text)
    }

    func testAnEmptyColumnIsTheOnlyReasonToGenerate() {
        XCTAssertTrue(RunFetch.Takeaway.notGenerated.shouldGenerate)
        XCTAssertFalse(RunFetch.Takeaway.cached("Solid tempo.").shouldGenerate)
        XCTAssertEqual(RunFetch.Takeaway.cached("Solid tempo.").text, "Solid tempo.")
    }
}
