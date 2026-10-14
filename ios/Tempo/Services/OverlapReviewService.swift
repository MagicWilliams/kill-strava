import Foundation
import Supabase

/// The I/O half of the overlapping-runs review (#30): read which pairs have been ruled on,
/// and write a ruling — retire the losing run and record the decision — or take one back.
///
/// Which pairs exist, and what a verdict means for each row, are decided in
/// `Engine/RunDedupe.swift` (`unresolvedOverlaps`, `resolution(for:_:)`) and pinned there.
/// What a retirement does to the two runs' journals is decided in
/// `Engine/OverlapJournalMerge.swift` (#152).
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

    /// Apply a ruling. Returns the journal transfer it made — empty for "both are real" and
    /// for any pair with no journal to carry — or nil if the ruling did not land.
    ///
    /// The journals are read first, fresh, and nothing is written if that read fails. The
    /// in-memory archive is not good enough to merge from: a value the athlete saved since
    /// the last refresh would be invisible to it, and the merge's one promise is that the
    /// kept run's own values are never overwritten.
    ///
    /// Then the retirement, then the review row. If the review row fails, the retirement is
    /// rolled back — otherwise a "keep" would half-land: the run gone from every total with no
    /// record of why, and no Undo able to find it.
    ///
    /// Then the journal (#152), kept run first. If the kept run's fill fails, the whole ruling
    /// is rolled back: a decision that strands the shoe and the photo is the bug this exists
    /// to fix, so it must not land quietly. If only the retired run's clear fails, the ruling
    /// stands — the shoe and photo are on the kept run already, and the duplicate left behind
    /// is on a row no read ever shows or counts.
    func record(_ resolution: RunDedupe.OverlapResolution) async -> OverlapJournalMerge.Transfer? {
        guard let uid = Supa.userID?.uuidString else { return nil }

        var transfer = OverlapJournalMerge.transfer(kept: RunJournalEntry(), retired: RunJournalEntry())

        if let retire = resolution.retire, let kept = resolution.kept {
            guard let journals = await journals(of: [kept, retire]) else { return nil }
            transfer = OverlapJournalMerge.transfer(
                kept: journals[kept] ?? RunJournalEntry(),
                retired: journals[retire] ?? RunJournalEntry()
            )

            do {
                try await Supa.client
                    .from("runs")
                    .update(Supersede(superseded_by: kept.uuidString))
                    .eq("id", value: retire.uuidString)
                    .execute()
            } catch {
                Telemetry.error("overlap.retire_failed", error)
                return nil
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
            await unretire(resolution)
            return nil
        }

        guard let retire = resolution.retire, let kept = resolution.kept, !transfer.isEmpty else {
            return transfer
        }

        do {
            try await patch(kept, transfer.keptPatch)
        } catch {
            reportJournal("overlap.journal_fill_failed", error)
            _ = try? await Supa.client
                .from("run_overlap_reviews")
                .delete()
                .eq("run_a", value: resolution.key.low.uuidString)
                .eq("run_b", value: resolution.key.high.uuidString)
                .execute()
            await unretire(resolution)
            return nil
        }

        do {
            try await patch(retire, transfer.retiredPatch)
        } catch {
            reportJournal("overlap.journal_move_failed", error)
        }
        // Column names only — never the values, which include the athlete's notes.
        Telemetry.info("overlap.journal_carried",
                       context: ["fields": transfer.filled.map(\.rawValue).joined(separator: ",")])
        return transfer
    }

    /// Roll back a retirement this ruling made.
    private func unretire(_ resolution: RunDedupe.OverlapResolution) async {
        guard let retire = resolution.retire else { return }
        _ = try? await Supa.client
            .from("runs")
            .update(Supersede(superseded_by: nil))
            .eq("id", value: retire.uuidString)
            .execute()
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
    ///
    /// Then the journal transfer is reversed (`OverlapJournalMerge.reversal`): the shoe and
    /// photo go back to the run they came from, and what was copied onto the kept run is
    /// cleared — unless the athlete has changed it since. That half is best-effort. The ruling
    /// is already undone by then and the pair is back in the queue; a failure leaves a carried
    /// value on the kept run, where the athlete last saw it, and is logged. The retired run's
    /// restore goes first, so a failure between the two writes leaves a reference on both
    /// rows, never on neither.
    ///
    /// Returns the two journals as they now stand, so the caller can redraw without a
    /// re-read, or nil if the ruling was not undone.
    func undo(
        _ resolution: RunDedupe.OverlapResolution,
        journal transfer: OverlapJournalMerge.Transfer
    ) async -> (kept: RunJournalEntry, retired: RunJournalEntry)? {
        do {
            try await Supa.client
                .from("run_overlap_reviews")
                .delete()
                .eq("run_a", value: resolution.key.low.uuidString)
                .eq("run_b", value: resolution.key.high.uuidString)
                .execute()
        } catch {
            Telemetry.error("overlap.review_delete_failed", error)
            return nil
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
                return nil
            }
        }

        let unchanged = (kept: transfer.kept, retired: transfer.retired)
        guard let retire = resolution.retire, let kept = resolution.kept, !transfer.isEmpty else {
            return unchanged
        }

        let reversalIfUnchanged = OverlapJournalMerge.reversal(of: transfer, keptNow: transfer.kept)
        do {
            try await patch(retire, reversalIfUnchanged.retiredPatch)
        } catch {
            reportJournal("overlap.journal_restore_failed", error)
            return unchanged
        }

        // Re-read the kept run: a carried field the athlete has edited since is theirs now.
        guard let keptNow = await journals(of: [kept])?[kept] else {
            return (kept: transfer.kept, retired: transfer.retiredBefore)
        }
        let reversal = OverlapJournalMerge.reversal(of: transfer, keptNow: keptNow)
        do {
            try await patch(kept, reversal.keptPatch)
        } catch {
            reportJournal("overlap.journal_unfill_failed", error)
            return (kept: keptNow, retired: transfer.retiredBefore)
        }
        return (kept: reversal.kept, retired: transfer.retiredBefore)
    }

    // MARK: - Journal I/O

    private struct JournalRow: Decodable {
        let id: UUID
        let rpe: Int?
        let feel_tags: [String]?
        let notes: String?
        let title: String?
        let photo_path: String?
        let shoe_id: UUID?
    }

    /// The journals of `ids`, read fresh, or nil if the read failed.
    ///
    /// Before migration 0016 there are no journal columns and so nothing to carry. That
    /// answers "no journals", not a failure, so review keeps working without them.
    private func journals(of ids: [UUID]) async -> [UUID: RunJournalEntry]? {
        do {
            let rows: [JournalRow] = try await Supa.client
                .from("runs")
                .select("id," + RunJournalPayload.columns)
                .in("id", values: ids.map(\.uuidString))
                .execute()
                .value
            return Dictionary(rows.map {
                ($0.id, RunJournalEntry(rpe: $0.rpe, feelTags: $0.feel_tags ?? [], notes: $0.notes,
                                        title: $0.title, photoPath: $0.photo_path, shoeID: $0.shoe_id))
            }, uniquingKeysWith: { first, _ in first })
        } catch let error as PostgrestError where RunJournalPayload.isMissingColumn(code: error.code) {
            return [:]
        } catch {
            Telemetry.error("overlap.journal_read_failed", error)
            return nil
        }
    }

    /// A journal write's failure, by Postgres code and message only. `Telemetry.error` logs
    /// the full error, and a constraint error's `details` reads "Failing row contains (…)" —
    /// the athlete's notes, verbatim. Same rule as `RunJournal.report`.
    private func reportJournal(_ event: String, _ error: Error) {
        guard let error = error as? PostgrestError else {
            Telemetry.error(event, error)
            return
        }
        Telemetry.log(.error, event, String(error.message.prefix(200)),
                      context: ["error_type": "PostgrestError", "code": error.code ?? "none"])
    }

    private func patch(_ run: UUID, _ patch: OverlapJournalMerge.Patch) async throws {
        guard !patch.isEmpty else { return }
        try await Supa.client
            .from("runs")
            .update(patch)
            .eq("id", value: run.uuidString)
            .execute()
    }
}
