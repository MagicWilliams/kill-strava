import SwiftUI
import UIKit
import XCTest
@testable import Tempo

/// The palette is the one part of the design system that is pure, total, and checkable —
/// a fixed set of colours with arithmetic relationships that either hold or don't.
///
/// It earns tests for the same reason the engine does: every way it fails is silent. A hex
/// that's four points too light doesn't crash, it ships a label nobody can read, on one theme,
/// on a screen the author happened not to open. Two of the assertions below were already
/// failing when they were first written — `textTertiary` was under 4.5:1 on dark cards, and
/// `voltMark` was too close to the unfilled day dot to tell the two apart on white.
///
/// Ratios are WCAG 2.1 relative luminance. Thresholds: 4.5:1 for text, 3:1 for meaningful
/// graphical marks, and a much smaller 1.03:1 for "these two surfaces are distinguishable",
/// which is a real requirement now that a card is a fill instead of a fill plus a border.
@MainActor
final class DesignTokenTests: XCTestCase {

    private let themes: [(name: String, style: UIUserInterfaceStyle)] = [
        ("light", .light), ("dark", .dark),
    ]

    // MARK: - Helpers

    private func luminance(_ color: Color, _ style: UIUserInterfaceStyle) -> CGFloat {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: Color, on b: Color, _ style: UIUserInterfaceStyle) -> CGFloat {
        let (la, lb) = (luminance(a, style), luminance(b, style))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Every surface a token might sit on: the canvas, plus both depths of every well.
    private var allGrounds: [(String, Color)] {
        [("canvas", Tokens.Palette.canvas)]
            + Tokens.Well.allCases.flatMap {
                [("\($0) fill", $0.fill), ("\($0) inset", $0.insetFill)]
            }
    }

    // MARK: - The dynamic resolution itself

    /// If `Color` → `UIColor` ever stopped preserving the dynamic provider, every other test
    /// here would quietly compare a colour against itself and pass. This is the canary.
    func testTokensResolveDifferentlyPerTheme() {
        for (name, token) in [
            ("canvas", Tokens.Palette.canvas),
            ("surface", Tokens.Palette.surface),
            ("textPrimary", Tokens.Palette.textPrimary),
            ("accentText", Tokens.Palette.accentText),
        ] {
            let light = luminance(token, .light)
            let dark = luminance(token, .dark)
            XCTAssertNotEqual(light, dark, accuracy: 0,
                              "\(name) resolves identically in both themes — dynamic colour lost")
        }
    }

    /// Volt is the deliberate exception: it means the same thing on both grounds.
    func testVoltIsIntentionallyThemeInvariant() {
        XCTAssertEqual(luminance(Tokens.Palette.volt, .light),
                       luminance(Tokens.Palette.volt, .dark), accuracy: 0.0001)
        XCTAssertEqual(luminance(Tokens.Palette.onVolt, .light),
                       luminance(Tokens.Palette.onVolt, .dark), accuracy: 0.0001)
    }

    // MARK: - Text

    func testTextClears4point5OnEveryGround() {
        let text: [(String, Color)] = [
            ("textPrimary", Tokens.Palette.textPrimary),
            ("textSecondary", Tokens.Palette.textSecondary),
            ("textTertiary", Tokens.Palette.textTertiary),
            ("accentText", Tokens.Palette.accentText),
        ]
        for (theme, style) in themes {
            for (name, color) in text {
                for (ground, bg) in allGrounds {
                    let ratio = contrast(color, on: bg, style)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(theme): \(name) on \(ground) is \(String(format: "%.2f", ratio)):1"
                    )
                }
            }
        }
    }

    /// Status colours land on whatever card the thing they're describing lives in — an `info`
    /// adaptation note sits in a session card whose tint depends on the session type — so they
    /// have to clear on every ground too, not just their own.
    func testStatusTextClears4point5OnEveryGround() {
        let status: [(String, Color)] = [
            ("success", Tokens.Palette.success),
            ("warning", Tokens.Palette.warning),
            ("danger", Tokens.Palette.danger),
            ("info", Tokens.Palette.info),
        ]
        for (theme, style) in themes {
            for (name, color) in status {
                for (ground, bg) in allGrounds {
                    let ratio = contrast(color, on: bg, style)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(theme): \(name) on \(ground) is \(String(format: "%.2f", ratio)):1"
                    )
                }
            }
        }
    }

    func testOnVoltIsReadableOnVolt() {
        for (theme, style) in themes {
            let ratio = contrast(Tokens.Palette.onVolt, on: Tokens.Palette.volt, style)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme): onVolt on volt is \(ratio):1")
        }
    }

    // MARK: - Marks

    /// The week strip is seven dots: filled `voltMark`, unfilled `elevated`. If those two
    /// don't separate, the card says nothing at all.
    func testVoltMarkSeparatesFromItsBackgrounds() {
        for (theme, style) in themes {
            let vsEmpty = contrast(Tokens.Palette.voltMark, on: Tokens.Palette.elevated, style)
            XCTAssertGreaterThanOrEqual(
                vsEmpty, 3.0,
                "\(theme): a filled day dot vs an empty one is only \(String(format: "%.2f", vsEmpty)):1"
            )
            for (ground, bg) in allGrounds {
                let ratio = contrast(Tokens.Palette.voltMark, on: bg, style)
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "\(theme): voltMark on \(ground) is \(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    // MARK: - Surfaces

    /// A card is now a fill and nothing else — no border, no shadow. So the fill differing
    /// from what's behind it isn't a nicety, it's the entire mechanism.
    func testWellsSeparateFromCanvasAndFromTheirOwnInset() {
        for (theme, style) in themes {
            for well in Tokens.Well.allCases {
                let vsCanvas = contrast(well.fill, on: Tokens.Palette.canvas, style)
                XCTAssertGreaterThanOrEqual(
                    vsCanvas, 1.03,
                    "\(theme): \(well) card is invisible against the canvas (\(vsCanvas):1)"
                )
                let vsInset = contrast(well.fill, on: well.insetFill, style)
                XCTAssertGreaterThanOrEqual(
                    vsInset, 1.03,
                    "\(theme): \(well) inset doesn't recess against its own card (\(vsInset):1)"
                )
            }
        }
    }

    /// The wall's whole job is showing the shape of a season, which it can only do if the
    /// five levels are ordered. Light ramps toward ink, dark ramps toward light.
    func testWallRampIsMonotonic() {
        let light = Tokens.Wall.ramp.map { luminance($0, .light) }
        let dark = Tokens.Wall.ramp.map { luminance($0, .dark) }

        XCTAssertEqual(Tokens.Wall.ramp.count, 5)
        for i in 1..<light.count {
            XCTAssertLessThan(light[i], light[i - 1], "light wall ramp not descending at level \(i)")
            XCTAssertGreaterThan(dark[i], dark[i - 1], "dark wall ramp not ascending at level \(i)")
        }
    }

    /// Level 0 is "no run". It has to read as absence on both grounds — close to the card it
    /// sits on, and clearly apart from level 1.
    func testWallRampEmptyLevelReadsAsEmpty() {
        for (theme, style) in themes {
            let step = contrast(Tokens.Wall.ramp[0], on: Tokens.Wall.ramp[1], style)
            XCTAssertGreaterThanOrEqual(
                step, 1.15,
                "\(theme): a rest day and a light day look the same (\(step):1)"
            )
        }
    }
}
