import Foundation
import Supabase

/// The I/O half of body reports (#89): read what the athlete has reported, log a new one,
/// clear one that has resolved.
///
/// What a report *means* — which ones count, which cap readiness, how they sort — is decided
/// in `Engine/BodyReports.swift` and pinned there. This file only moves rows.
///
/// ## Why it is allowed to be missing
///
/// Migration 0020 ships with this file and David applies it by hand. Until it lands the read
/// fails, and that is reported as *unavailable* — not as "nothing reported". The difference
/// is the same one `OverlapReviewService` draws: an empty set would put a Body section on
/// screen with a Clear button that cannot persist anything, and readiness would silently go
/// back to load-plus-check-in with no sign that the calf just reported was dropped.
final class BodyReportService {

    struct Snapshot: Equatable {
        var reports: [BodyReport] = []
        /// False until migration 0020 is applied (or whenever the read fails). The Body
        /// section stays hidden and `log_body` cards fail retryably while this is false.
        var available = false
    }

    /// Reports are a handful per block, not an archive. A ceiling anyway, because PostgREST
    /// will happily hand back a thousand rows and the Body section is a card, not a screen.
    private static let limit = 100

    private struct Row: Decodable {
        let id: UUID
        let area: String
        let sensation: String
        let severity: Int
        let status: String
        let opened_at: Date
        let cleared_at: Date?
        let source_message_id: UUID?

        var report: BodyReport {
            BodyReport(
                id: id,
                area: area,
                sensation: sensation,
                severity: severity,
                status: BodyReport.Status(decoding: status),
                openedAt: opened_at,
                clearedAt: cleared_at,
                sourceMessageID: source_message_id
            )
        }
    }

    // MARK: - Read

    /// Every report, live and cleared, newest first. RLS scopes it to the athlete.
    func snapshot() async -> Snapshot {
        do {
            let rows: [Row] = try await Supa.client
                .from("body_reports")
                .select("id,area,sensation,severity,status,opened_at,cleared_at,source_message_id")
                .order("opened_at", ascending: false)
                .limit(Self.limit)
                .execute()
                .value
            return Snapshot(reports: rows.map(\.report), available: true)
        } catch {
            // Expected before 0020 lands, so not an error event — the feature is simply off.
            return Snapshot()
        }
    }

    // MARK: - Write

    /// Log what the athlete just told the coach. Returns the row as written, so the caller
    /// can put it on screen — and recompute readiness — without a round trip.
    ///
    /// `sourceMessageID` is the card that proposed it, which is what lets the Body section
    /// link back to the conversation the report came out of.
    func log(
        area: String,
        sensation: String,
        severity: Int,
        status: BodyReport.Status,
        sourceMessageID: UUID?
    ) async throws -> BodyReport {
        guard let uid = Supa.userID?.uuidString else { throw BodyReportError.noSession }
        struct Insert: Encodable {
            let user_id: String
            let area: String
            let sensation: String
            let severity: Int
            let status: String
            let source_message_id: String?
        }
        // Never 'cleared' on an insert: the table's own check constraint ties that status to
        // a `cleared_at`, and a report that arrives already resolved is not a report.
        let opening: BodyReport.Status = status == .cleared ? .open : status
        let row: Row = try await Supa.client
            .from("body_reports")
            .insert(Insert(
                user_id: uid,
                area: area,
                sensation: sensation,
                severity: severity,
                status: opening.rawValue,
                source_message_id: sourceMessageID?.uuidString
            ))
            .select("id,area,sensation,severity,status,opened_at,cleared_at,source_message_id")
            .single()
            .execute()
            .value
        return row.report
    }

    /// Mark a report resolved. Both columns together — the check constraint in 0020 refuses
    /// a `cleared` row with no `cleared_at`, which is the point of writing them as a pair.
    func clear(_ id: UUID, now: Date = .now) async throws {
        struct Patch: Encodable { let status: String; let cleared_at: String }
        try await Supa.client
            .from("body_reports")
            .update(Patch(status: BodyReport.Status.cleared.rawValue,
                          cleared_at: ISO8601DateFormatter().string(from: now)))
            .eq("id", value: id.uuidString)
            .execute()
    }

    enum BodyReportError: Error { case noSession }
}
