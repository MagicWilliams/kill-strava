import XCTest
import SwiftUI
@testable import Tempo

/// #81: the same shape that made the Projected Finish page drag sideways (#74) appears on the
/// other two detail screens — a `Card` header built as `HStack { label; Spacer(); trailing }`,
/// and Run Detail's distance hero with a `Spacer()` between "MI" and the pace stack.
///
/// The shape alone proves nothing. Whether a row's parts add back up past the width it was
/// offered depends on its exact text widths, so each row here is offered every width a phone
/// can hand it — at 2x and at 3x, since which widths land on the pixel grid is what changes
/// between them — and has to report no more than that. A row that drifts carries the same
/// one-liner as #74; a row that measures clean is pinned clean, so a later text change that
/// starts the drift fails here instead of on David's phone.
@MainActor
final class DetailLayoutTests: XCTestCase {

    /// Every on-grid width from 280pt to 420pt at both scales. 2x and 3x disagree about which
    /// widths exist, and the bug lives in the last bits of the sum, so both grids are offered.
    private let offers = onGridOffers(scale: 2) + onGridOffers(scale: 3)

    /// The content widths the real phones actually hand these rows: 375pt (SE) through 440pt
    /// (Pro Max), minus the page's 20pt gutters — and minus a `Card`'s 18pt padding again for
    /// the rows that sit inside one. An overrun at one of these is the bug; an overrun only at
    /// some other width in the sweep is latent, worth saying out loud in the failure.
    private let realOffers: Set<CGFloat> = {
        let screens: [CGFloat] = [375, 390, 393, 402, 414, 420, 428, 430, 440]
        return Set(screens.map { $0 - 40 } + screens.map { $0 - 76 })
    }()

    private func assertNeverWiderThanOffered<Row: View>(_ row: Row, _ name: String,
                                                        file: StaticString = #filePath,
                                                        line: UInt = #line) {
        guard let overrun = firstOverrun(of: row, offers: offers, file: file, line: line) else { return }
        let reach = realOffers.contains(overrun.offer) ? "a width a real phone offers"
                                                       : "not a width a real phone offers"
        XCTFail("\(name) reported \(overrun.width)pt for a \(overrun.offer)pt offer — \(reach)",
                file: file, line: line)
    }

    // MARK: - Readiness

    func testFitnessCurveHeaderNeverReportsWiderThanOffered() {
        assertNeverWiderThanOffered(FitnessCurveHeaderRow(), "the fitness-curve header")
    }

    // MARK: - Run Detail headers

    func testCoachReadHeaderNeverReportsWiderThanOffered() {
        assertNeverWiderThanOffered(CoachReadHeaderRow(loading: false), "the coach's-read header")
    }

    /// The spinner is a second part in the sum while the takeaway is still loading.
    func testCoachReadHeaderLoadingNeverReportsWiderThanOffered() {
        assertNeverWiderThanOffered(CoachReadHeaderRow(loading: true), "the coach's-read header, loading")
    }

    func testPaceHRHeaderNeverReportsWiderThanOffered() {
        assertNeverWiderThanOffered(PaceHRHeaderRow(), "the pace+HR legend header")
    }

    func testZoneHeaderMeasuredNeverReportsWiderThanOffered() {
        assertNeverWiderThanOffered(ZoneHeaderRow(maxHR: 189, measured: true), "the zones header")
    }

    /// " EST" makes the trailing text two glyphs wider, which is a different sum.
    func testZoneHeaderEstimatedNeverReportsWiderThanOffered() {
        assertNeverWiderThanOffered(ZoneHeaderRow(maxHR: 189, measured: false), "the zones header, estimated max HR")
    }

    func testElevationHeaderNeverReportsWiderThanOffered() {
        // Built the way the card builds it, so the measured text is the real one.
        let summary = "↑ \(Units.mi.formatElevation(meters: 128)) · ↓ \(Units.mi.formatElevation(meters: 131))".uppercased()
        assertNeverWiderThanOffered(ElevationHeaderRow(summary: summary), "the elevation header")
    }

    /// A run with no elevation on file: label, Spacer, nothing.
    func testElevationHeaderWithoutSummaryNeverReportsWiderThanOffered() {
        assertNeverWiderThanOffered(ElevationHeaderRow(summary: nil), "the elevation header with no gain on file")
    }

    // MARK: - Run Detail distance hero

    private func hero(_ units: Units, meters: Double, seconds: Int, time: String) -> RunDistanceHeroRow {
        RunDistanceHeroRow(distance: units.number(meters: meters, decimals: 2),
                           unit: units.abbreviation.uppercased(),
                           pace: units.runPace(movingSeconds: seconds, meters: meters).map { units.formatPace($0) },
                           time: time)
    }

    /// A 6-mile run in 55:12 — the everyday case, and the narrowest the row gets.
    func testDistanceHeroNeverReportsWiderThanOffered() {
        assertNeverWiderThanOffered(hero(.mi, meters: 9656, seconds: 3312, time: "55:12"),
                                    "the distance hero")
    }

    /// A marathon: five distance glyphs and an hours field, the widest the row gets in miles.
    func testDistanceHeroMarathonNeverReportsWiderThanOffered() {
        assertNeverWiderThanOffered(hero(.mi, meters: 42195, seconds: 12333, time: "3:25:33"),
                                    "the distance hero, marathon")
    }

    /// Kilometres: "42.20 KM" and a "/km" pace suffix are a different set of widths again.
    func testDistanceHeroKilometresNeverReportsWiderThanOffered() {
        assertNeverWiderThanOffered(hero(.km, meters: 42195, seconds: 12333, time: "3:25:33"),
                                    "the distance hero, kilometres")
    }

    /// A run with no pace yet: the right-hand stack is one line, not two.
    func testDistanceHeroWithoutPaceNeverReportsWiderThanOffered() {
        let row = RunDistanceHeroRow(distance: "0.00", unit: "MI", pace: nil, time: "0:00")
        assertNeverWiderThanOffered(row, "the distance hero with no pace")
    }
}
