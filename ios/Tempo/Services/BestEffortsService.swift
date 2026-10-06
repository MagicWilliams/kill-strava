import Foundation

/// The I/O half of sub-distance PRs (#25): read one run's distance timeline out of
/// HealthKit, hand it to `Engine/BestEfforts`, write the answer to `run_efforts`, and
/// remember that the run has been looked at.
///
/// Everything that decides a *number* lives in the engine. What lives here is the part that
/// cannot be pinned by a test: HealthKit queries, Supabase writes, and the pacing that keeps
/// a 1,476-run backfill from holding the phone.
///
/// ## Why it is allowed to be missing
///
/// Migration 0011 ships in the same PR as this file and is applied by hand, so for some
/// window the app is running against a database with no `run_efforts` table and no
/// `efforts_scanned_at` column. Every read here therefore reports *unavailable* rather than
/// *empty*, and the pass does nothing at all until the schema answers. That distinction is
/// the difference between History hiding a card it cannot fill and History showing a
/// confident, empty PR table — the second is the failure mode this codebase keeps
/// relearning.
///
/// It is also why `efforts_scanned_at` is deliberately **not** added to `RunStore`'s main
/// run select: a column PostgREST does not know about turns that read into a 400, and that
/// read is every run the app has.
final class BestEffortsService {

    /// The best anyone has run a distance, and which run holds it.
    struct Best: Equatable {
        let distanceM: Int
        let durationS: Int
        let runID: UUID
    }

    /// What the app knows about best efforts right now.
    struct Snapshot: Equatable {
        /// `BestEfforts.Distance.key` → the standing record.
        var bests: [Int: Best] = [:]
        /// Runs whose timeline has already been read, whether or not it yielded anything.
        var scanned: Set<UUID> = []
        /// False until migration 0011 is applied. Nothing renders and nothing scans while
        /// this is false — an absent table is not an empty one.
        var available = false

        func best(_ key: Int) -> Best? { bests[key] }
        /// Distances this run currently holds the record for — the badge set on run detail.
        func recordDistances(for runID: UUID) -> [Int] {
            BestEfforts.distances.map(\.key).filter { bests[$0]?.runID == runID }
        }
    }

    private let loader = RunDetailLoader()

    // MARK: - Reads

    /// The standing records plus which runs have been scanned.
    ///
    /// Seven ordered reads of one row each rather than pulling ~10,000 effort rows and
    /// taking the minimum on device. The index in migration 0011 exists for exactly this.
    func snapshot() async -> Snapshot {
        guard let scanned = await scannedRunIDs() else { return Snapshot() }

        var snap = Snapshot(bests: [:], scanned: scanned, available: true)
        for d in BestEfforts.distances {
            if let record = await standingBest(forKey: d.key) { snap.bests[d.key] = record }
        }
        return snap
    }

    private struct EffortRow: Decodable {
        let distance_m: Int
        let duration_s: Int
        let run_id: UUID
    }

    private func standingBest(forKey key: Int) async -> Best? {
        // `superseded_by` rows are filtered in the app rather than in SQL: PostgREST cannot
        // express "join runs and exclude the retired ones" on this path, and the caller
        // already holds every live run. A record pointing at a retired duplicate simply
        // doesn't resolve to a run and is dropped by the UI.
        let rows: [EffortRow]? = try? await Supa.client
            .from("run_efforts")
            .select("distance_m,duration_s,run_id")
            .eq("distance_m", value: String(key))
            .order("duration_s", ascending: true)
            .limit(1)
            .execute()
            .value
        guard let row = rows?.first else { return nil }
        return Best(distanceM: row.distance_m, durationS: row.duration_s, runID: row.run_id)
    }

    /// Run ids already scanned, or nil when the schema isn't there yet.
    ///
    /// Reads the marker column for every run and filters on device. The alternative — a
    /// `not.is.null` filter — would save a few hundred kilobytes once per launch and cost a
    /// PostgREST operator spelling that has to be right the first time; this way the only
    /// thing that can fail is the column not existing, which is precisely the case being
    /// detected.
    private func scannedRunIDs() async -> Set<UUID>? {
        struct MarkerRow: Decodable { let id: UUID; let efforts_scanned_at: Date? }

        var scanned: Set<UUID> = []
        var offset = 0
        while true {
            let page: [MarkerRow]
            do {
                page = try await Supa.client
                    .from("runs")
                    .select("id,efforts_scanned_at")
                    .order("start_time", ascending: false)
                    .range(from: offset, to: offset + RunFetch.pageSize - 1)
                    .execute()
                    .value
            } catch {
                // Expected before the migration lands, so it is not an error event — the
                // feature is simply off. Anything else here reads the same from the app's
                // point of view: no marker column, no pass.
                return nil
            }
            scanned.formUnion(page.filter { $0.efforts_scanned_at != nil }.map(\.id))
            if page.count < RunFetch.pageSize { break }
            offset += RunFetch.pageSize
            if offset >= RunFetch.maxRuns { break }
        }
        return scanned
    }

    /// One run's own efforts — the card on its detail page.
    func efforts(for runID: UUID) async -> [BestEfforts.Effort] {
        let rows: [EffortRow]? = try? await Supa.client
            .from("run_efforts")
            .select("distance_m,duration_s,run_id")
            .eq("run_id", value: runID.uuidString)
            .execute()
            .value
        guard let rows else { return [] }
        let order = BestEfforts.distances.map(\.key)
        return rows
            .map { BestEfforts.Effort(distanceM: $0.distance_m, durationS: $0.duration_s) }
            .sorted { (order.firstIndex(of: $0.distanceM) ?? 0) < (order.firstIndex(of: $1.distanceM) ?? 0) }
    }

    // MARK: - The backfill

    private struct EffortInsert: Encodable {
        let user_id: String
        let run_id: String
        let distance_m: Int
        let duration_s: Int
    }

    private struct ScanMark: Encodable {
        let efforts_scanned_at: String
    }

    /// Scan one slice of the archive and return the run ids it covered.
    ///
    /// Bounded by `BestEfforts.nextSlice`, which is where the "how many" decision is tested.
    /// Cancellation is honoured between runs rather than fought: a killed pass leaves every
    /// run it finished marked, so the next one resumes instead of restarting. That is the
    /// entire reason the marker is a column on `runs` and not "does this run have any effort
    /// rows" — a 2-mile shakeout legitimately produces no 5 K row, and under a row-presence
    /// rule it would be re-read from HealthKit on every launch forever.
    func scanSlice(_ runs: [RunSummary]) async -> Set<UUID> {
        guard let uid = Supa.userID?.uuidString, !runs.isEmpty else { return [] }

        let stamp = ISO8601DateFormatter().string(from: .now)
        var covered: Set<UUID> = []
        for run in runs {
            if Task.isCancelled { break }

            let found = BestEfforts.efforts(timeline: await loader.distanceTimeline(run: run))
            if !found.isEmpty {
                let rows = found.map {
                    EffortInsert(user_id: uid, run_id: run.id.uuidString,
                                 distance_m: $0.distanceM, duration_s: $0.durationS)
                }
                // Idempotent by the unique constraint: a re-scan rewrites the same rows.
                guard (try? await Supa.client
                    .from("run_efforts")
                    .upsert(rows, onConflict: "run_id,distance_m")
                    .execute()) != nil
                else { continue }   // don't mark a run scanned whose efforts we failed to store
            }

            if (try? await Supa.client
                .from("runs")
                .update(ScanMark(efforts_scanned_at: stamp))
                .eq("id", value: run.id.uuidString)
                .execute()) != nil {
                covered.insert(run.id)
            }

            // Let the rest of the app breathe between runs. The HealthKit read is the slow
            // part and it is serial by nature; this is what keeps the phone usable for the
            // length of a 1,476-run pass.
            await Task.yield()
        }
        return covered
    }
}
