import XCTest
import SwiftUI

/// The width probe behind the sideways-scroll tests.
///
/// 2026-10: a `Card` holding a bare `HStack { label; Spacer(); trailing }` can report a width
/// a float ulp past what it was offered — the HStack hands back the sum of its parts, and
/// third-of-a-point text widths don't add up exactly. Any text-only card in the same column
/// then rounds that up to a whole device pixel and the page can be dragged sideways (#74).
///
/// Measuring that needs the row's raw answer. `UIHostingController.sizeThatFits` rounds its
/// result up to a whole pixel, which both hides a third-of-a-point overrun and invents one;
/// a `Layout` sees what the row actually said. Lifted out of `ProjectionLayoutTests` when the
/// same probe was pointed at the other detail screens (#81).

/// Asks its child for a size at each offer, the way the card's stack does, and records the
/// raw answers.
struct OfferProbe: Layout {
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

final class OfferLog {
    var answers: [(offer: CGFloat, width: CGFloat)] = []
}

/// Every content width in 280...420pt that lands on a `scale`x device pixel grid.
///
/// Real offers always land on the grid, so these step one pixel at a time. Building each one
/// as whole pixels divided by the scale keeps them exact: a stride in 1/3pt steps accumulates
/// its own float error, which is the bug under test.
func onGridOffers(scale: CGFloat) -> [CGFloat] {
    (Int(280 * scale)...Int(420 * scale)).map { CGFloat($0) / scale }
}

/// The first offer `row` answers with something wider, or nil if it never does.
@MainActor
func firstOverrun<Row: View>(of row: Row,
                             offers: [CGFloat],
                             file: StaticString = #filePath,
                             line: UInt = #line) -> (offer: CGFloat, width: CGFloat)? {
    let log = OfferLog()
    let host = UIHostingController(rootView: OfferProbe(offers: offers, log: log) { row })
    _ = host.sizeThatFits(in: CGSize(width: 500, height: 500))
    XCTAssertFalse(log.answers.isEmpty, "the probe never ran, so this test measured nothing",
                   file: file, line: line)
    return log.answers.first { $0.width > $0.offer }
}
