import Foundation

/// The I/O half of the overlapping-runs review (#30): read which pairs have been ruled on,
/// and write a ruling — retire the losing run and record the decision — or take one back.
///
/// Which pairs exist, and what a verdict means for each row, are decided in
/// `Engine/RunDedupe.swift` (`unresolvedOverlaps`, `resolution(for:_:)`) and pinned there.
///
/// ## Why it is allowed to be missing
///
/// Migration 0012 ships with this file and is applied by hand. Until it is, the reviews read
/// fails, and that is reported as *unavailable* — not as "nothing reviewed yet". The
/// difference matters: an empty set would put every pair on screen with buttons that cannot
/// persist "both are real", and those pairs would come back on the next launch.
final class OverlapReviewService {

    struct Snapshot: Equatable {
        var reviewed: Set<RunDedupe.OverlapKey> = []
        /// False until migration 0012 is applied (or whenever the read fails). The review
        /// row and screen stay hidden while this is false.
        var available = false
    }

    private struct ReviewRow: Codable {
        var user_id: String? = nil
        let run_a: UUID
        let run_b: UUID
        var decision: String? = nil
    }

    // MARK: - Read

    /// Every pair already ruled on, paged for the same reason `RunStore` pages runs:
    /// PostgREST truncates an unbounded select at 1,000 rows.
    func snapshot() async -> Snapshot {
        var reviewed: Set<RunDedupe.OverlapKey> = []
        var offset = 0
        while true {
            let page: [ReviewRow]
            do {
                page = try await Supa.client
                    .from("run_overlap_reviews")
                    .select("run_a,run_b")
                    .order("reviewed_at", ascending: true)
                    .range(from: offset, to: offset + RunFetch.pageSize - 1)
                    .execute()
                    .value
            } catch {
                // Expected before 0012 lands, so not an error event — the feature is off.
                return Snapshot()
            }
            reviewed.formUnion(page.map { RunDedupe.OverlapKey($0.run_a, $0.run_b) })
            if page.count < RunFetch.pageSize { break }
            offset += RunFetch.pageSize
            if offset >= RunFetch.maxRuns { break }
        }
        return Snapshot(reviewed: reviewed, available: true)
    }

    // MARK: - Write

    private struct Supersede: Encodable { let superseded_by: String? }

    /// Apply a ruling. Returns whether it fully landed.
    ///
    /// The retirement goes first and the review row second. If the review row then fails,
    /// the retirement is rolled back — otherwise a "keep" would half-land: the run gone from
    /// every total with no record of why, and no Undo able to find it.
    func record(_ resolution: RunDedupe.OverlapResolution) async -> Bool {
        guard let uid = Supa.userID?.uuidString else { return false }

        if let retire = resolution.retire, let kept = resolution.kept {
            do {
                try await Supa.client
                    .from("runs")
                    .update(Supersede(superseded_by: kept.uuidString))
                    .eq("id", value: retire.uuidString)
                    .execute()
            } catch {
                Telemetry.error("overlap.retire_failed", error)
                return false
            }
        }

        do {
            try await Supa.client
                .from("run_overlap_reviews")
                .upsert(
                    ReviewRow(user_id: uid, run_a: resolution.key.low, run_b: resolution.key.high,
                              decision: resolution.decision),
                    onConflict: "user_id,run_a,run_b"
                )
                .execute()
        } catch {
            Telemetry.error("overlap.review_write_failed", error)
            if let retire = resolution.retire {
                _ = try? await Supa.client
                    .from("runs")
                    .update(Supersede(superseded_by: nil))
                    .eq("id", value: retire.uuidString)
                    .execute()
            }
            return false
        }
        return true
    }

    /// Take a ruling back: forget the decision, then un-retire the run it retired, so the
    /// pair is asked about again.
    ///
    /// The review row goes first. If the un-retire then fails, the loser is still retired and
    /// the pair stays out of the queue — the same state as before Undo, minus the audit row,
    /// which is restored. The other order could leave both runs live with the review row
    /// still hiding them: double-counted again, and invisible to the screen that fixes it.
    ///
    /// The un-retire is scoped to `superseded_by = kept`, so Undo can only reverse what this
    /// decision did — never a retirement 0008/0009 made for its own reasons.
    func undo(_ resolution: RunDedupe.OverlapResolution) async -> Bool {
        do {
            try await Supa.client
                .from("run_overlap_reviews")
                .delete()
                .eq("run_a", value: resolution.key.low.uuidString)
                .eq("run_b", value: resolution.key.high.uuidString)
                .execute()
        } catch {
            Telemetry.error("overlap.review_delete_failed", error)
            return false
        }

        if let retire = resolution.retire, let kept = resolution.kept {
            do {
                try await Supa.client
                    .from("runs")
                    .update(Supersede(superseded_by: nil))
                    .eq("id", value: retire.uuidString)
                    .eq("superseded_by", value: kept.uuidString)
                    .execute()
            } catch {
                Telemetry.error("overlap.unretire_failed", error)
                if let uid = Supa.userID?.uuidString {
                    _ = try? await Supa.client
                        .from("run_overlap_reviews")
                        .upsert(
                            ReviewRow(user_id: uid, run_a: resolution.key.low, run_b: resolution.key.high,
                                      decision: resolution.decision),
                            onConflict: "user_id,run_a,run_b"
                        )
                        .execute()
                }
                return false
            }
        }
        return true
    }
}
