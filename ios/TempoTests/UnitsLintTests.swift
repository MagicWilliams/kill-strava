import XCTest
@testable import Tempo

/// The lint #109 asked for: no screen spells a unit itself.
///
/// Before #109 the app printed "mi" from forty-odd string literals across the screens, the
/// design-system cards and the widgets, each with its own `/ 1609.34` or `* 3.28084` next to
/// it. The mi/km switch could only work by finding every one of them, and the next screen
/// written the old way would quietly print miles to a km athlete. So this reads the view
/// source itself and fails on:
///
/// - a string literal with a unit after a space, digit or slash: `" mi"`, `"%.1f mi"`,
///   `"PACE /MI"`, `" km"`, or one that opens with the unit (`"MI %.2f"`);
/// - the mile or the foot written out as a number: `1609`, `3.28084`.
///
/// Those all belong to `Units` / `UnitsDisplay` in `Engine/`, which are not scanned. A bare
/// `"mi"` is allowed: it is the You tab's picker naming the choice itself.
final class UnitsLintTests: XCTestCase {

    /// `ios/`, found from this file's own path. The test runs in the simulator on the same
    /// Mac (or CI runner) that compiled it, so the source tree is readable.
    private var iosRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private let scanned = ["Tempo/Screens", "Tempo/DesignSystem", "TempoWidgets"]

    func testNoViewSpellsAUnitItself() throws {
        var violations: [String] = []
        var files = 0
        for dir in scanned {
            let url = iosRoot.appendingPathComponent(dir)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }
            for name in names {
                files += 1
                let text = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
                for (n, line) in text.components(separatedBy: "\n").enumerated() {
                    for problem in Self.problems(in: line) {
                        violations.append("\(dir)/\(name):\(n + 1): \(problem)\n    \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(files, 20, "the scan found the view sources")
        XCTAssertTrue(violations.isEmpty, "Route these through Units (Engine/UnitsDisplay.swift):\n" + violations.joined(separator: "\n"))
    }

    /// The scanner itself, against the shapes it has to catch and the ones it must not.
    func testTheScannerCatchesTheOldShapesAndPassesTheNewOnes() {
        for bad in [
            #"Text(String(format: "%.1f mi", miles))"#,
            #"Text("\(store.thisWeekMiles) MI")"#,
            #"Text(PaceModel.format(pace) + " /mi")"#,
            #"Text("PACE /MI")"#,
            #"let mile = scrub.map { String(format: "MI %.2f", $0.miles) }"#,
            #"label: "\(x) km")"#,
            #"let miles = Double(m) / 1609.34"#,
            #"Text(String(format: "%.0f ft", $0 * 3.28084))"#,
        ] {
            XCTAssertFalse(Self.problems(in: bad).isEmpty, "missed: \(bad)")
        }
        for fine in [
            #"Text(units.formatDistance(miles: week.miles))"#,
            #"Text("mi").tag(Units.mi)"#,
            #"Text("Already mid-block — \(units.abbreviation) this week")"#,
            #"SectionLabel("Weekly mileage")"#,
            #"// 1609.34 m is a mile, and "mi" is its name"#,
            #"Text("\(a ? "x" : "y") minutes")"#,
        ] {
            XCTAssertEqual(Self.problems(in: fine), [], "false positive: \(fine)")
        }
    }

    // MARK: - The scanner

    private static let unitInLiteral = try! NSRegularExpression(pattern: #"(?i)([\s\d/](mi|km)(?![a-z])|^(mi|km)\s)"#)

    static func problems(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return [] }
        var found: [String] = []
        let scan = Literals(line)
        for literal in scan.literals {
            let range = NSRange(literal.startIndex..., in: literal)
            if unitInLiteral.firstMatch(in: literal, range: range) != nil {
                found.append("unit in string literal \"\(literal)\"")
            }
        }
        for number in ["1609", "3.28084"] where scan.code.contains(number) {
            found.append("\(number) written out")
        }
        return found
    }

    /// Splits one line of Swift into its string-literal text (interpolations excluded, and
    /// scanned as code) and everything else, stopping at a trailing `//`.
    private struct Literals {
        private let c: [Character]
        private var i = 0
        private(set) var literals: [String] = []
        private(set) var code = ""

        init(_ line: String) {
            c = Array(line)
            scanCode(closing: false)
        }

        private mutating func scanCode(closing: Bool) {
            var depth = 0
            while i < c.count {
                let ch = c[i]
                if ch == "\"" {
                    i += 1
                    scanLiteral()
                    continue
                }
                if ch == "/", i + 1 < c.count, c[i + 1] == "/" {
                    i = c.count
                    return
                }
                if closing {
                    if ch == "(" { depth += 1 }
                    if ch == ")" {
                        if depth == 0 { i += 1; return }
                        depth -= 1
                    }
                }
                code.append(ch)
                i += 1
            }
        }

        private mutating func scanLiteral() {
            var piece = ""
            while i < c.count {
                let ch = c[i]
                if ch == "\\", i + 1 < c.count {
                    if c[i + 1] == "(" {
                        literals.append(piece)
                        piece = ""
                        i += 2
                        scanCode(closing: true)
                        continue
                    }
                    piece.append(c[i + 1])
                    i += 2
                    continue
                }
                i += 1
                if ch == "\"" { break }
                piece.append(ch)
            }
            literals.append(piece)
        }
    }
}
