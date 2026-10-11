import Foundation
import Supabase

/// The I/O half of "What changed" (#88): read every applied coach action, plus the
/// recorded snapshot of each run those actions amended, and hand both to
/// `Engine/ChangeLedger`. Nothing here decides what an entry says.
///
/// Read-only. No migration: the rows have existed since 0007.
enum ChangeLedgerService {

    enum Failure: Error { case unreachable }

    private struct Row: Decodable {
        let id: UUID
        let content: String
        let created_at: Date
        let proposed_action: ProposedAction?
    }

    private struct OriginalRow: Decodable {
        let id: UUID
        let original: ChangeLedger.RecordedRun?
    }

    /// Every applied change, newest first. Throws rather than returning `[]` on a failed
    /// read: "the coach has never changed anything" and "couldn't ask" are different
    /// screens.
    static func load() async throws -> [ChangeLedger.Entry] {
        let records = try await appliedRecords()
        let runIDs = Set(records.compactMap { record -> UUID? in
            guard record.action.type == "amend_run" else { return nil }
            return record.action.run_id.flatMap(UUID.init(uuidString:))
        })
        // The snapshots only add a "before" to a run's first amendment. Losing them costs a
        // number, not the ledger — so a failure here degrades instead of throwing.
        let recorded = (try? await recordedSnapshots(for: Array(runIDs))) ?? [:]
        return ChangeLedger.entries(from: records, recorded: recorded)
    }

    /// All applied rows, a page at a time — the same 1,000-row PostgREST cap that hid
    /// David's oldest runs (#48) would otherwise quietly drop the oldest changes here.
    private static func appliedRecords() async throws -> [ChangeLedger.Record] {
        var rows: [Row] = []
        var offset = 0
        while true {
            let page: [Row] = try await Supa.client
                .from("coach_messages")
                .select("id,content,created_at,proposed_action")
                .eq("action_state", value: "applied")
                .order("created_at", ascending: false)
                .order("id", ascending: false)   // a stable order, so a page boundary can't skip a tie
                .range(from: offset, to: offset + RunFetch.pageSize - 1)
                .execute()
                .value
            rows.append(contentsOf: page)
            if page.count < RunFetch.pageSize { break }
            offset += RunFetch.pageSize
            if offset >= RunFetch.maxRuns { break }   // a leash, as in RunStore
        }
        return rows.compactMap { row in
            guard let action = row.proposed_action else { return nil }
            return ChangeLedger.Record(messageID: row.id, date: row.created_at, text: row.content, action: action)
        }
    }

    private static func recordedSnapshots(for ids: [UUID]) async throws -> [UUID: ChangeLedger.RecordedRun] {
        var out: [UUID: ChangeLedger.RecordedRun] = [:]
        // Chunked so the `in` filter's query string stays well under URL limits.
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = ids[start..<min(start + 100, ids.count)].map(\.uuidString)
            let rows: [OriginalRow] = try await Supa.client
                .from("runs")
                .select("id,original")
                .in("id", values: chunk)
                .execute()
                .value
            for row in rows { if let original = row.original { out[row.id] = original } }
        }
        return out
    }
}
