import XCTest
@testable import Tempo

/// No read may use `.single()` where matching zero rows is a normal day.
///
/// PostgREST turns a zero-row `.single()` into a thrown 406, not an empty result. On
/// 2026-08-23 that cost a splash-screen freeze: the profile read could not tell "no profile
/// yet" apart from "couldn't reach the server", because both arrived as the same throw. The
/// fix was to decode `[Row]` with `.limit(1)` and take `.first`.
///
/// That fix was applied by hand, one call site at a time, and it missed the today's-check-in
/// read — which then logged a 406 on every single app refresh for months until the edge logs
/// were read (#224). A sweep that has to be remembered is a sweep that gets missed, so this
/// is the lint instead.
///
/// `.single()` stays correct in two shapes, both of which the scanner allows:
///
/// - after an `.insert(` or `.upsert(`, which returns exactly the row just written;
/// - on a read filtered by `.eq("id", ...)`, where the row is fetched by primary key and its
///   absence is a genuine error worth throwing.
///
/// Anything else — a read filtered by a date, a status, a foreign key — can legally match
/// nothing, and must decode an array.
final class ZeroRowSingleLintTests: XCTestCase {

    /// `ios/`, found from this file's own path, exactly as `UnitsLintTests` does it: the test
    /// runs on the same machine that compiled it, so the source tree is readable.
    private var iosRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testNoReadUsesSingleWhereZeroRowsIsLegal() throws {
        var violations: [String] = []
        var files = 0
        let root = iosRoot.appendingPathComponent("Tempo")
        for name in try UnitsLintTests.swiftFiles(under: root) {
            files += 1
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            for query in Self.offendingQueries(in: text) {
                violations.append("Tempo/\(name): \(query)")
            }
        }
        // The whole app is scanned, not just Services/: the #172 scar is that a scan which
        // silently skips a folder still passes, and a query can be written anywhere.
        XCTAssertGreaterThan(files, 90, "the scan found the app sources")
        XCTAssertTrue(
            violations.isEmpty,
            "Zero rows is a legal answer here — decode [Row] with .limit(1) and take .first:\n"
                + violations.joined(separator: "\n")
        )
    }

    /// The scanner itself, against the shapes it has to catch and the ones it must not.
    /// Every "fine" case below is a real query in the app today.
    func testTheScannerCatchesTheOldShapeAndPassesTheLegitimateOnes() {
        for bad in [
            """
            try? await Supa.client
                .from("check_ins")
                .select("date,feels_ok,note")
                .eq("date", value: PlanDates.todayString)
                .single()
                .execute()
                .value
            """,
            """
            try await Supa.client.from("plans").select("id").eq("status", value: "active").single().execute().value
            """,
            """
            try await Supa.client.from("goals").select("*").eq("plan_id", value: id).single().execute().value
            """,
        ] {
            XCTAssertFalse(Self.offendingQueries(in: bad).isEmpty, "missed: \(bad)")
        }
        for fine in [
            // By primary key — absence is a real error.
            """
            try await Supa.client
                .from("runs")
                .select(Self.columns)
                .eq("id", value: run.id.uuidString)
                .single()
                .execute()
                .value
            """,
            // Insert and upsert both return exactly the row written.
            """
            try await Supa.client
                .from("shoes")
                .insert(Insert(user_id: uid, name: draft.name))
                .select(Self.columns)
                .single()
                .execute()
                .value
            """,
            """
            try await Supa.client
                .from("runs")
                .upsert(row, onConflict: "user_id,source,external_id")
                .select("id")
                .single()
                .execute()
                .value
            """,
            // The corrected shape.
            """
            try? await Supa.client
                .from("check_ins")
                .select("date,feels_ok,note")
                .eq("date", value: PlanDates.todayString)
                .limit(1)
                .execute()
                .value
            """,
            // Prose about `.single()` is not a call to it. Both of these sit next to real
            // queries in RunStore.swift and must not trip the scan.
            """
            // Decoded as an array rather than `.single()`: PostgREST turns a zero-row
            // `.single()` into a thrown error.
            try await Supa.client.from("profiles").select("units").eq("id", value: uid).limit(1).execute().value
            """,
            """
            try await Supa.client.from("runs").select("*").eq("id", value: id).limit(1).execute().value
            // `.single()` throws on zero rows, and generating against a row the DB
            // doesn't have is worse than generating nothing.
            """,
        ] {
            XCTAssertEqual(Self.offendingQueries(in: fine), [], "false positive: \(fine)")
        }
    }

    // MARK: - The scanner

    /// Every `Supa.client` query chain in `source` that calls `.single()` without being one
    /// of the two legitimate shapes, flattened onto one line for the failure message.
    ///
    /// Chains are split on `Supa.client` and cut at `.execute()`, so the builder calls in
    /// between are all that is examined — a `.single()` mentioned further down the function
    /// belongs to no chain.
    static func offendingQueries(in source: String) -> [String] {
        var found: [String] = []
        for chunk in stripComments(source).components(separatedBy: "Supa.client").dropFirst() {
            let query = chunk.components(separatedBy: ".execute()").first ?? chunk
            guard query.contains(".single()") else { continue }
            if query.contains(".insert(") || query.contains(".upsert(") { continue }
            if query.contains(".eq(\"id\"") { continue }
            found.append(
                query.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            )
        }
        return found
    }

    /// Drops `//` comments so that writing *about* `.single()` never counts as calling it —
    /// the comments added by the 2026-08-23 fix do exactly that. `://` is left alone so a
    /// URL in a string survives.
    static func stripComments(_ source: String) -> String {
        source.components(separatedBy: "\n").map { line -> String in
            var out = ""
            var previous: Character?
            var i = line.startIndex
            while i < line.endIndex {
                let ch = line[i]
                let next = line.index(after: i)
                if ch == "/", next < line.endIndex, line[next] == "/", previous != ":" { break }
                out.append(ch)
                previous = ch
                i = next
            }
            return out
        }.joined(separator: "\n")
    }
}
