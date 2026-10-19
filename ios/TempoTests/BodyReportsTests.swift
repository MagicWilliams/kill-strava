import XCTest
@testable import Tempo

/// Body reports and the readiness cap (#89).
///
/// This layer has no crash in it. Every way it can be wrong is a number on Today that is
/// quietly off by the exact amount the athlete was trying to tell us about: a cleared calf
/// that keeps readiness pinned at 40, a 7/10 that stops capping because the coach labelled it
/// "watching", a 3/10 that silently costs a quality session. So the threshold is pinned on
/// both sides, and so is everything that is *supposed* to leave the number alone.
final class BodyReportsTests: XCTestCase {

    // MARK: - Fixtures

    private static let day: TimeInterval = 86_400

    private func report(
        _ severity: Int,
        area: String = "left calf",
        sensation: String = "tight",
        status: BodyReport.Status = .open,
        openedDaysAgo: Double = 0,
        clearedDaysAgo: Double? = nil
    ) -> BodyReport {
        BodyReport(
            id: UUID(),
            area: area,
            sensation: sensation,
            severity: severity,
            status: status,
            openedAt: Date().addingTimeInterval(-openedDaysAgo * Self.day),
            clearedAt: clearedDaysAgo.map { Date().addingTimeInterval(-$0 * Self.day) }
        )
    }

    /// A block followed by ten easy days — a taper, in other words.
    ///
    /// Deliberately not a run-every-day streak: with constant daily load the 7-day EWMA
    /// outruns the 42-day one forever, form stays negative, and readiness sits *below* 40 on
    /// its own. A cap at 40 would then be invisible, and every assertion here would pass
    /// whether the cap worked or not. Ten days of rest puts form positive and readiness well
    /// clear of the cap, so a cap that lands is a cap you can see.
    private func taperedRuns(count: Int = 60, miles: Double = 4, paceSecPerMile: Int = 600) -> [RunSummary] {
        let cal = Calendar.current
        return (0..<count).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -(offset + 10), to: Date()) else { return nil }
            return RunSummary(
                id: UUID(),
                start: day,
                distanceM: Int(miles * 1609.34),
                durationS: Int(miles * Double(paceSecPerMile)),
                avgHR: nil
            )
        }
    }

    // MARK: - The threshold

    func testTheThresholdHoldsOnBothSidesAtEverySeverity() {
        for severity in 0...10 {
            XCTAssertEqual(
                BodyReports.capsReadiness([report(severity)]),
                severity >= BodyReports.capSeverity,
                "a \(severity)/10 must \(severity >= BodyReports.capSeverity ? "" : "not ")cap readiness"
            )
        }
    }

    func testAReportAtTheThresholdCapsReadiness() throws {
        let runs = taperedRuns()
        let uncapped = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil))
        let capped = try XCTUnwrap(LoadModel.compute(
            runs: runs, checkInOK: nil, bodyReports: [report(BodyReports.capSeverity)]
        ))
        XCTAssertLessThanOrEqual(capped.readiness, LoadModel.reportedCap)
        XCTAssertLessThan(capped.readiness, uncapped.readiness,
                          "the fixture has to start above the cap or this test proves nothing")
    }

    func testAReportBelowTheThresholdLeavesTheNumberExactlyWhereItWas() throws {
        let runs = taperedRuns()
        let unreported = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil))
        let niggle = try XCTUnwrap(LoadModel.compute(
            runs: runs, checkInOK: nil, bodyReports: [report(BodyReports.capSeverity - 1)]
        ))
        XCTAssertEqual(niggle.readiness, unreported.readiness,
                       "a 4/10 is recorded and shown; it does not move the number")
    }

    func testFitnessAndFatigueAreUntouchedByAReport() throws {
        let runs = taperedRuns()
        let plain = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil))
        let hurt = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil, bodyReports: [report(9)]))
        XCTAssertEqual(hurt.ctl, plain.ctl, accuracy: 0.0001, "a report is not training load")
        XCTAssertEqual(hurt.atl, plain.atl, accuracy: 0.0001)
    }

    // MARK: - Status

    func testWatchingCountsTheSameAsOpen() {
        // The coach picks between the two labels for its own narration. If that choice could
        // gate the cap, a 6/10 it happened to call "watching" would stop counting — the
        // athlete's word overruled by a word the model chose.
        XCTAssertTrue(BodyReports.capsReadiness([report(6, status: .watching)]))
        XCTAssertTrue(BodyReports.capsReadiness([report(6, status: .open)]))
    }

    func testClearingRestoresReadiness() throws {
        let runs = taperedRuns()
        let open = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil, bodyReports: [report(8)]))
        let cleared = try XCTUnwrap(LoadModel.compute(
            runs: runs, checkInOK: nil,
            bodyReports: [report(8, status: .cleared, openedDaysAgo: 3, clearedDaysAgo: 0)]
        ))
        let never = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil))
        XCTAssertLessThanOrEqual(open.readiness, LoadModel.reportedCap)
        XCTAssertEqual(cleared.readiness, never.readiness, "clearing it puts the number back, exactly")
    }

    func testAnUnrecognisedStatusCountsAsLive() {
        // A status this build doesn't know must not be the reason a 7/10 stops capping.
        XCTAssertEqual(BodyReport.Status(decoding: "flare"), .open)
        XCTAssertEqual(BodyReport.Status(decoding: "watching"), .watching)
        XCTAssertEqual(BodyReport.Status(decoding: "cleared"), .cleared)
        XCTAssertTrue(BodyReports.capsReadiness([report(7, status: BodyReport.Status(decoding: "flare"))]))
    }

    // MARK: - How it interacts with the check-in

    func testFeelingOkayDoesNotLiftABodyReportsCap() throws {
        // Two different questions. "Feeling okay?" is about today; the calf is about the
        // calf. A yes to the first must not cancel the second.
        let capped = try XCTUnwrap(LoadModel.compute(
            runs: taperedRuns(), checkInOK: true, bodyReports: [report(8)]
        ))
        XCTAssertLessThanOrEqual(capped.readiness, LoadModel.reportedCap)
    }

    func testTheCapDoesNotStackWithANegativeCheckIn() throws {
        let runs = taperedRuns()
        let checkInOnly = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: false))
        let both = try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: false, bodyReports: [report(9)]))
        XCTAssertEqual(both.readiness, checkInOnly.readiness,
                       "one athlete saying the same thing twice is one cap, not two")
    }

    func testNoReportsIsTheSameAsBeforeTheFeatureExisted() throws {
        let runs = taperedRuns()
        XCTAssertEqual(
            try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil, bodyReports: [])).readiness,
            try XCTUnwrap(LoadModel.compute(runs: runs, checkInOK: nil)).readiness
        )
    }

    // MARK: - What the lists and lines say

    func testLiveListsWorstFirstThenNewest() {
        let bad = report(8, area: "right knee", openedDaysAgo: 10)
        let oldNiggle = report(3, area: "left calf", openedDaysAgo: 20)
        let freshNiggle = report(3, area: "right hip", openedDaysAgo: 1)
        let gone = report(9, area: "hamstring", status: .cleared, openedDaysAgo: 30, clearedDaysAgo: 25)

        let live = BodyReports.live([oldNiggle, gone, freshNiggle, bad])
        XCTAssertEqual(live.map(\.area), ["right knee", "right hip", "left calf"])
        XCTAssertFalse(live.contains { $0.id == gone.id }, "a cleared report is not live")
    }

    func testClearedListsMostRecentlyResolvedFirst() {
        let older = report(4, area: "right hip flexor", status: .cleared, openedDaysAgo: 60, clearedDaysAgo: 50)
        let newer = report(6, area: "left calf", status: .cleared, openedDaysAgo: 20, clearedDaysAgo: 2)
        XCTAssertEqual(BodyReports.cleared([older, newer]).map(\.area),
                       ["left calf", "right hip flexor"])
    }

    func testSummaryLineIsTheLineTheCardShows() {
        XCTAssertEqual(report(3).summaryLine, "left calf · tight · 3/10")
    }

    func testTheReadinessEffectLineTellsTheTruthAboutBothCases() {
        let below = BodyReports.readinessEffect(severity: BodyReports.capSeverity - 1)
        XCTAssertTrue(below.contains("\(BodyReports.capSeverity) or higher"),
                      "a sub-threshold report has to say what *would* cap it: \(below)")
        XCTAssertFalse(below.contains("capped at"))

        let at = BodyReports.readinessEffect(severity: BodyReports.capSeverity)
        XCTAssertTrue(at.contains("\(LoadModel.reportedCap)"),
                      "a capping report quotes the cap it imposes: \(at)")
    }
}
