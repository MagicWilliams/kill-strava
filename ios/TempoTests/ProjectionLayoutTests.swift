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
/// cards rounded it up to the next device pixel, and the scroll content came out
/// 402.33pt wide on a 402pt screen. A third of a point is enough for UIScrollView to
/// allow a horizontal drag.
///
/// Whether the sum drifts depends on the exact offer and the tag's text width. These
/// tests offer the row every width a phone could give it and require it never to report
/// more than that.
@MainActor
final class ProjectionLayoutTests: XCTestCase {

    private let goal = 3 * 3600 + 30 * 60

    /// Every content width a phone hands this row: 375pt (SE) through 440pt (Pro Max),
    /// minus the page's 20pt gutters and the card's 18pt padding, with headroom on both ends.
    /// Real offers always land on the device pixel grid, so these step one pixel at a time.
    /// Building each one as whole pixels divided by the scale keeps them exact: a stride
    /// in 1/3pt steps accumulates its own float error, which is the bug under test.
    private var offers: [CGFloat] {
        let scale = UIScreen.main.scale
        return (Int(280 * scale)...Int(420 * scale)).map { CGFloat($0) / scale }
    }

    /// The first offer the row answers with something wider, or nil if it never does.
    private func firstOverrun(_ row: ProjectionStatusRow) -> (offer: CGFloat, width: CGFloat)? {
        let log = OfferLog()
        let host = UIHostingController(rootView: OfferProbe(offers: offers, log: log) { row })
        _ = host.sizeThatFits(in: CGSize(width: 500, height: 500))
        XCTAssertFalse(log.answers.isEmpty, "the probe never ran, so this test measured nothing")
        return log.answers.first { $0.width > $0.offer }
    }

    func testOnTrackRowNeverReportsWiderThanOffered() {
        // 3:12:45 against a 3:30 goal → "on track". The exact case measured on the 402pt phone.
        let overrun = firstOverrun(ProjectionStatusRow(projection: goal - 1035, goal: goal))
        XCTAssertNil(overrun, "row reported \(overrun?.width ?? 0)pt for a \(overrun?.offer ?? 0)pt offer")
    }

    func testBehindGoalRowNeverReportsWiderThanOffered() {
        let overrun = firstOverrun(ProjectionStatusRow(projection: goal + 600, goal: goal))
        XCTAssertNil(overrun, "row reported \(overrun?.width ?? 0)pt for a \(overrun?.offer ?? 0)pt offer")
    }
}

/// Asks its child for a size at each offer, the way the card's stack does, and records the
/// raw answers. It doesn't go through `UIHostingController.sizeThatFits`, because that
/// rounds its result up to a whole pixel and would hide (or invent) the overrun.
private struct OfferProbe: Layout {
    let offers: [CGFloat]
    let log: OfferLog

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if log.answers.isEmpty, let row = subviews.first {
            log.answers = offers.map { offer in
                (offer, row.sizeThatFits(ProposedViewSize(width: offer, height: nil)).width)
            }
        }
        return proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
}

private final class OfferLog {
    var answers: [(offer: CGFloat, width: CGFloat)] = []
}
