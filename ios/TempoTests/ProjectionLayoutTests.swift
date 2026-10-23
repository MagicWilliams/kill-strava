import XCTest
import SwiftUI
@testable import Tempo

/// 2026-10: the Projected Finish page could be dragged sideways on a 402pt iPhone even
/// though nothing on it reached the screen edge (#74).
///
/// Nothing was visibly too wide. The hero's top row (`HStack { "NOW"; Spacer(); tag }`)
/// reported 326.00000000000006pt when offered 326, because an HStack with a Spacer hands
/// back the sum of its parts and third-of-a-point text widths don't add up exactly in
/// floating point. The page column then offered that width to every card, the text-only
/// cards below round that hair up to a whole device pixel, and the scroll content came out
/// 402.33pt wide on a 402pt screen. A third of a point is enough for UIScrollView to
/// allow a horizontal drag.
///
/// Whether the sum drifts depends on the exact offer and the tag's text width. These
/// tests offer the row every width a phone could give it and require it never to report
/// more than that. The probe itself lives in `OfferProbe.swift`.
@MainActor
final class ProjectionLayoutTests: XCTestCase {

    private let goal = 3 * 3600 + 30 * 60

    /// Every content width a phone hands this row: 375pt (SE) through 440pt (Pro Max),
    /// minus the page's 20pt gutters and the card's 18pt padding, with headroom on both ends.
    private var offers: [CGFloat] { onGridOffers(scale: UIScreen.main.scale) }

    func testOnTrackRowNeverReportsWiderThanOffered() {
        // 3:12:45 against a 3:30 goal → "on track". The exact case measured on the 402pt phone.
        let overrun = firstOverrun(of: ProjectionStatusRow(projection: goal - 1035, goal: goal), offers: offers)
        XCTAssertNil(overrun, "row reported \(overrun?.width ?? 0)pt for a \(overrun?.offer ?? 0)pt offer")
    }

    func testBehindGoalRowNeverReportsWiderThanOffered() {
        let overrun = firstOverrun(of: ProjectionStatusRow(projection: goal + 600, goal: goal), offers: offers)
        XCTAssertNil(overrun, "row reported \(overrun?.width ?? 0)pt for a \(overrun?.offer ?? 0)pt offer")
    }
}
