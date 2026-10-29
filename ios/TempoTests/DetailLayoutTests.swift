import XCTest
import SwiftUI
@testable import Tempo

/// #81: the same shape that made the Projected Finish page drag sideways (#74) appears on the
/// other two detail screens — a `Card` header built as `HStack { label; Spacer(); trailing }`,
/// and Run Detail's distance hero with a `Spacer()` between "MI" and the pace stack.
///
/// The shape alone proves nothing. Whether a row's parts add back up past the width it was
/// offered depends on its exact text widths, so every row here is offered every width a phone
/// can hand it — at 2x and at 3x, since which widths land on the pixel grid is what changes
/// between them — and has to report no more than that.
///
/// Each row gets two tests, and the split is deliberate. #81 only fixes a row that overruns at
/// a width a real phone offers; an overrun somewhere else in the sweep is latent, the way the
/// `spread` row on Projected Finish is, and is left alone with the measurement written down.
/// CI runs `xcodebuild -quiet`, which keeps assertion messages out of the log and prints only
/// the names of the tests that failed — so which band an overrun lands in has to be in the
/// name, or the one thing the run needs to tell us is the one thing it can't.
///
/// What the sweep found, 2026-10: of the six rows #81 named, only `PaceHRHeaderRow` overruns,
/// and it does so at widths real phones hand it — so that one carries the fix and the other
/// five are pinned clean. The distance hero drifted in one state that looked real and wasn't:
/// "0.00" with a "0:00" clock, which no run on file can produce. Both of the no-pace states a
/// run can actually reach measure clean.
@MainActor
final class DetailLayoutTests: XCTestCase {

    /// Every iPhone width Tempo runs at: 375pt (SE) through 440pt (Pro Max).
    private static let screens: [CGFloat] = [375, 390, 393, 402, 414, 420, 428, 430, 440]

    /// What a row inside a `Card` is offered: the screen less the page's 20pt gutters and the
    /// card's 18pt padding, both sides.
    private let realCardOffers = DetailLayoutTests.screens.map { $0 - 76 }

    /// What a row in the page column itself is offered — the distance hero sits there, not in
    /// a card, so it is handed 36pt more than the headers are.
    private let realPageOffers = DetailLayoutTests.screens.map { $0 - 40 }

    /// Every on-grid width from 280pt to 420pt at both scales, which covers both bands above
    /// with headroom, plus the widths between them that no phone actually offers.
    private let sweep = onGridOffers(scale: 2) + onGridOffers(scale: 3)

    private func assertNoOverrun<Row: View>(_ row: Row, _ offers: [CGFloat],
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        let overrun = firstOverrun(of: row, offers: offers, file: file, line: line)
        XCTAssertNil(overrun, "reported \(overrun?.width ?? 0)pt for a \(overrun?.offer ?? 0)pt offer",
                     file: file, line: line)
    }

    // MARK: - Readiness Detail

    func testFitnessCurveHeaderAtRealPhoneWidths() {
        assertNoOverrun(FitnessCurveHeaderRow(), realCardOffers)
    }

    func testFitnessCurveHeaderAcrossTheWholeSweep() {
        assertNoOverrun(FitnessCurveHeaderRow(), sweep)
    }

    // MARK: - Run Detail · card headers

    func testCoachReadHeaderAtRealPhoneWidths() {
        assertNoOverrun(CoachReadHeaderRow(loading: false), realCardOffers)
    }

    func testCoachReadHeaderAcrossTheWholeSweep() {
        assertNoOverrun(CoachReadHeaderRow(loading: false), sweep)
    }

    /// The spinner is a second part in the sum while the takeaway is still loading.
    func testCoachReadHeaderLoadingAtRealPhoneWidths() {
        assertNoOverrun(CoachReadHeaderRow(loading: true), realCardOffers)
    }

    func testCoachReadHeaderLoadingAcrossTheWholeSweep() {
        assertNoOverrun(CoachReadHeaderRow(loading: true), sweep)
    }

    func testPaceHRHeaderAtRealPhoneWidths() {
        assertNoOverrun(PaceHRHeaderRow(), realCardOffers)
    }

    func testPaceHRHeaderAcrossTheWholeSweep() {
        assertNoOverrun(PaceHRHeaderRow(), sweep)
    }

    func testZoneHeaderAtRealPhoneWidths() {
        assertNoOverrun(ZoneHeaderRow(maxHR: 189, measured: true), realCardOffers)
    }

    func testZoneHeaderAcrossTheWholeSweep() {
        assertNoOverrun(ZoneHeaderRow(maxHR: 189, measured: true), sweep)
    }

    /// " EST" makes the trailing text two glyphs wider, which is a different sum.
    func testZoneHeaderEstimatedAtRealPhoneWidths() {
        assertNoOverrun(ZoneHeaderRow(maxHR: 189, measured: false), realCardOffers)
    }

    func testZoneHeaderEstimatedAcrossTheWholeSweep() {
        assertNoOverrun(ZoneHeaderRow(maxHR: 189, measured: false), sweep)
    }

    /// Built the way the card builds it, so the measured text is the real one.
    private let elevationSummary =
        "↑ \(Units.mi.formatElevation(meters: 128)) · ↓ \(Units.mi.formatElevation(meters: 131))".uppercased()

    func testElevationHeaderAtRealPhoneWidths() {
        assertNoOverrun(ElevationHeaderRow(summary: elevationSummary), realCardOffers)
    }

    func testElevationHeaderAcrossTheWholeSweep() {
        assertNoOverrun(ElevationHeaderRow(summary: elevationSummary), sweep)
    }

    /// A run with no elevation on file: label, Spacer, nothing.
    func testElevationHeaderWithoutGainAtRealPhoneWidths() {
        assertNoOverrun(ElevationHeaderRow(summary: nil), realCardOffers)
    }

    func testElevationHeaderWithoutGainAcrossTheWholeSweep() {
        assertNoOverrun(ElevationHeaderRow(summary: nil), sweep)
    }

    // MARK: - Run Detail · the distance hero

    private func hero(_ units: Units, meters: Double, seconds: Int, time: String) -> RunDistanceHeroRow {
        RunDistanceHeroRow(distance: units.number(meters: meters, decimals: 2),
                           unit: units.abbreviation.uppercased(),
                           pace: units.runPace(movingSeconds: seconds, meters: meters).map { units.formatPace($0) },
                           time: time)
    }

    /// A 6-mile run in 55:12 — the everyday case.
    func testDistanceHeroAtRealPhoneWidths() {
        assertNoOverrun(hero(.mi, meters: 9656, seconds: 3312, time: "55:12"), realPageOffers)
    }

    func testDistanceHeroAcrossTheWholeSweep() {
        assertNoOverrun(hero(.mi, meters: 9656, seconds: 3312, time: "55:12"), sweep)
    }

    /// A marathon: five distance glyphs and an hours field, the widest the row gets in miles.
    func testDistanceHeroMarathonAtRealPhoneWidths() {
        assertNoOverrun(hero(.mi, meters: 42195, seconds: 12333, time: "3:25:33"), realPageOffers)
    }

    func testDistanceHeroMarathonAcrossTheWholeSweep() {
        assertNoOverrun(hero(.mi, meters: 42195, seconds: 12333, time: "3:25:33"), sweep)
    }

    /// Kilometres: "42.20 KM" and a "/km" pace suffix are a different set of widths again.
    func testDistanceHeroKilometresAtRealPhoneWidths() {
        assertNoOverrun(hero(.km, meters: 42195, seconds: 12333, time: "3:25:33"), realPageOffers)
    }

    func testDistanceHeroKilometresAcrossTheWholeSweep() {
        assertNoOverrun(hero(.km, meters: 42195, seconds: 12333, time: "3:25:33"), sweep)
    }

    /// An indoor run HealthKit gave no distance for: "0.00", a real duration, and no pace —
    /// `runPace` has nothing to divide, so the right-hand stack is one line instead of two.
    func testDistanceHeroWithoutDistanceAtRealPhoneWidths() {
        assertNoOverrun(hero(.mi, meters: 0, seconds: 1930, time: "32:10"), realPageOffers)
    }

    func testDistanceHeroWithoutDistanceAcrossTheWholeSweep() {
        assertNoOverrun(hero(.mi, meters: 0, seconds: 1930, time: "32:10"), sweep)
    }

    /// An aborted recording: under the 0.05mi floor `runPace` needs, so again no pace line.
    func testDistanceHeroWithoutPaceAtRealPhoneWidths() {
        assertNoOverrun(hero(.mi, meters: 48, seconds: 12, time: "0:12"), realPageOffers)
    }

    func testDistanceHeroWithoutPaceAcrossTheWholeSweep() {
        assertNoOverrun(hero(.mi, meters: 48, seconds: 12, time: "0:12"), sweep)
    }
}
