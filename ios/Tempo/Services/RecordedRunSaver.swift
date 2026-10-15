import Foundation
import Supabase
import UIKit

/// The I/O half of saving a recorded run to Tempo (#122): write its `runs` row, hand the
/// journal off, and put the run on Today. Every decision — what row, whether to write it at
/// all, what to do after a failure — is in `Engine/RecordedRunSave.swift` and pinned there.
///
/// Call `save` once the workout is in Apple Health (#114 owns that save; this never touches
/// HealthKit). The order is fixed and matches `RunJournal`'s contract: **Health, then row, then
/// journal.** The row write is the part the athlete waits on — Today is redrawn before `save`
/// returns — while the journal is handed off and finishes on its own clock.
@MainActor
enum RecordedRunSaver {

    enum Outcome: Equatable {
        /// The run has a row — written now, or found already there — and the journal is on
        /// its way to it.
        case saved(runID: UUID)
        /// Too short to be a run (`WorkoutRow.minimumDistanceM`). It stays in Health only.
        case tooShort
        /// No answer from the server. Queued on disk; the next refresh tries again.
        case queued
        /// The server refused the row outright. The run is still in Health and the sync will
        /// ingest it; what is lost is the journal.
        case dropped
    }

    /// Write a just-recorded run to Tempo and show it.
    ///
    /// Holds a background-task assertion for the duration: the moment after Save is exactly
    /// when the phone goes back in a pocket.
    @discardableResult
    static func save(
        _ workout: WorkoutRow.Workout,
        journal: RunJournalEntry = RunJournalEntry(),
        photo: UIImage? = nil,
        store: RunStore
    ) async -> Outcome {
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "recorded-run-save")
        defer { if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) } }

        // Queue first, attempt second — see `RecordedRunSave.Pending`.
        let pending = RecordedRunSave.Pending(
            workout: workout,
            journal: journal,
            photoJPEG: photo.flatMap(RunJournal.jpegForUpload),
            queuedAt: .now
        )
        PendingQueue.update { RecordedRunSave.enqueue(pending, into: $0) }

        let outcome = await attempt(pending, photo: photo)
        if case .saved(let runID) = outcome { await store.absorbRecordedRuns([runID]) }
        return outcome
    }

    /// Retry whatever an earlier save left queued. Called at the end of every refresh, so a
    /// run saved in a dead spot lands the next time the app opens or is pulled to refresh.
    ///
    /// By then the sync has usually ingested the run from Health already — same mapping, same
    /// row — so the retry finds it (`.alreadyStored`) and all that is left is the journal.
    static func retryPending(store: RunStore) async {
        let queue = PendingQueue.load()
        guard !queue.isEmpty else { return }
        var landed: [UUID] = []
        for pending in queue {
            if case .saved(let runID) = await attempt(pending, photo: nil) { landed.append(runID) }
        }
        Telemetry.info("recorder.queue_retried", context: ["queued": "\(queue.count)",
                                                           "landed": "\(landed.count)"])
        if !landed.isEmpty { await store.absorbRecordedRuns(landed) }
    }

    // MARK: - One attempt

    /// Workouts with an attempt running, so a refresh's retry and a fresh save of the same
    /// workout never write side by side.
    private static var inFlight: Set<UUID> = []

    private static func attempt(_ pending: RecordedRunSave.Pending, photo: UIImage?) async -> Outcome {
        let uuid = pending.workout.uuid
        guard !inFlight.contains(uuid) else { return .queued }
        inFlight.insert(uuid)
        defer { inFlight.remove(uuid) }

        // Not signed in yet (a launch that hasn't reached Supabase). Stays queued.
        guard let userID = Supa.userID?.uuidString else { return .queued }

        do {
            let nearby = try await fetchNearby(pending.workout)
            let decision = RecordedRunSave.decide(pending.workout, nearby: nearby, userID: userID)
            let runID: UUID
            switch decision {
            case .tooShort:
                PendingQueue.update { RecordedRunSave.removing(uuid, from: $0) }
                Telemetry.info("recorder.run_too_short", context: ["meters": "\(Int(pending.workout.distanceM ?? 0))"])
                return .tooShort
            case .alreadyStored(let id):
                runID = id
                await markCorrected(id, pending.workout)
            case .sameRunAs(let id):
                runID = id
            case .insert(let row):
                runID = try await write(row)
            }
            PendingQueue.update { RecordedRunSave.removing(uuid, from: $0) }
            Telemetry.info("recorder.run_saved", context: ["path": label(decision)])
            handOffJournal(pending, photo: photo, runID: runID)
            return .saved(runID: runID)
        } catch {
            let status = RunJournal.statusCode(of: error)
            if error is CancellationError || RecordedRunSave.keepsAfterFailure(statusCode: status) {
                // Logged as info: offline is the expected case, and this very event will
                // usually fail to send for the same reason.
                Telemetry.info("recorder.run_queued", context: ["status": status.map(String.init) ?? "none"])
                return .queued
            }
            PendingQueue.update { RecordedRunSave.removing(uuid, from: $0) }
            Telemetry.error("recorder.row_write_refused", error)
            return .dropped
        }
    }

    /// Live rows starting within the dedupe window of the workout, newest first — the same
    /// filter and order as the archive read the sync dedupes against, cut to the only slice
    /// that can matter.
    private static func fetchNearby(_ workout: WorkoutRow.Workout) async throws -> [RunSummary] {
        struct Row: Decodable {
            let id: UUID
            let start_time: Date
            let distance_m: Int
            let duration_s: Int
            let elapsed_duration_s: Int?
            let avg_hr: Int?
            let corrected: Bool
            let source: String
            let external_id: String?
        }
        let range = RecordedRunSave.nearbyRange(for: workout)
        let iso = ISO8601DateFormatter()
        let rows: [Row] = try await Supa.client
            .from("runs")
            .select("id,start_time,distance_m,duration_s,elapsed_duration_s,avg_hr,corrected,source,external_id")
            .is("superseded_by", value: nil)
            .gte("start_time", value: iso.string(from: range.lowerBound))
            .lte("start_time", value: iso.string(from: range.upperBound))
            .order("start_time", ascending: false)
            .execute()
            .value
        return rows.map {
            RunSummary(id: $0.id, start: $0.start_time, distanceM: $0.distance_m,
                       durationS: $0.duration_s, elapsedS: $0.elapsed_duration_s, avgHR: $0.avg_hr,
                       corrected: $0.corrected, source: $0.source, externalID: $0.external_id)
        }
    }

    private struct RowMissingAfterWrite: Error {}

    /// The sync's own write — same upsert, same conflict key, `ignoreDuplicates` so a row the
    /// sync wrote a moment earlier is left exactly as it is — then the row's id, looked up by
    /// that key because an ignored duplicate returns nothing.
    private static func write(_ row: RunInsert) async throws -> UUID {
        try await Supa.client
            .from("runs")
            .upsert(row, onConflict: "user_id,source,external_id", ignoreDuplicates: true)
            .execute()
        struct IDRow: Decodable { let id: UUID }
        let found: [IDRow] = try await Supa.client
            .from("runs")
            .select("id")
            .eq("user_id", value: row.user_id)
            .eq("source", value: row.source)
            .eq("external_id", value: row.external_id)
            .limit(1)
            .execute()
            .value
        guard let id = found.first?.id else { throw RowMissingAfterWrite() }
        return id
    }

    /// A console correction onto a row the sync wrote first — see
    /// `RecordedRunSave.correctionPatch`. Best effort: the run and its distance are already
    /// right, and a failure here costs the "corrected" mark, not the journal, so it is
    /// reported and the save goes on.
    private static func markCorrected(_ rowID: UUID, _ workout: WorkoutRow.Workout) async {
        guard let patch = RecordedRunSave.correctionPatch(for: workout) else { return }
        do {
            try await Supa.client
                .from("runs")
                .update(patch)
                .eq("id", value: rowID)
                .eq("corrected", value: false)
                .execute()
        } catch {
            Telemetry.error("recorder.correction_patch_failed", error)
        }
    }

    /// The journal, if the athlete said anything. The original image when this is the save
    /// itself; the queued, already-resized copy when it is a retry after a relaunch.
    private static func handOffJournal(_ pending: RecordedRunSave.Pending, photo: UIImage?, runID: UUID) {
        let image = photo ?? pending.photoJPEG.flatMap(UIImage.init(data:))
        guard !pending.journal.isEmpty || image != nil else { return }
        RunJournal.record(pending.journal, photo: image, forRun: runID)
    }

    private static func label(_ decision: RecordedRunSave.Decision) -> String {
        switch decision {
        case .insert:        return "inserted"
        case .alreadyStored: return "already_stored"
        case .sameRunAs:     return "same_run_as_existing"
        case .tooShort:      return "too_short"
        }
    }

    // MARK: - Disk

    /// The queue, as one JSON file in Application Support. Almost always empty; one entry
    /// after a save in a dead spot. Read and rewritten whole, which is fine at that size.
    private enum PendingQueue {
        static var url: URL {
            URL.applicationSupportDirectory.appending(path: "recorded-runs-pending.json")
        }

        static func load() -> [RecordedRunSave.Pending] {
            guard let data = try? Data(contentsOf: url) else { return [] }
            do {
                return try JSONDecoder().decode([RecordedRunSave.Pending].self, from: data)
            } catch {
                // Reported rather than swallowed: it was the only copy of the journals in it.
                Telemetry.error("recorder.queue_unreadable", error)
                return []
            }
        }

        static func update(_ change: ([RecordedRunSave.Pending]) -> [RecordedRunSave.Pending]) {
            let next = change(load())
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if next.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                } else {
                    // Readable after first unlock: the run often ends with the phone locked.
                    try JSONEncoder().encode(next).write(
                        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            } catch {
                Telemetry.error("recorder.queue_write_failed", error)
            }
        }
    }
}
