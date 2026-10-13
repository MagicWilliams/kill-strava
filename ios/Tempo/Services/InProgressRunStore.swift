import Foundation

/// Where the in-progress run snapshot (#115) lives on disk.
///
/// I/O only — every decision about what a snapshot means is in `Engine/RunRecorder/
/// InProgressRun.swift`. This file exists to be boring, because it runs in the worst possible
/// moment: once every ten seconds during a run, on a phone that is about to be killed.
///
/// A file in Application Support rather than `UserDefaults`, which `WidgetSnapshotStore` uses
/// for its few hundred bytes: a marathon's distance curve is tens of kilobytes and rewriting
/// a defaults domain that often is not what it is for. Not in the App Group either — the
/// widgets have no business reading a run that is still happening.
///
/// Writes are atomic. A half-written snapshot is the one thing worse than no snapshot: it
/// decodes as garbage or not at all, and the run it was protecting is the one that gets lost.
enum InProgressRunStore {

    static let fileName = "in-progress-run.json"
    /// Where an unreadable snapshot is moved. One slot, overwritten: it is evidence for
    /// triage, not an archive.
    static let quarantineName = "in-progress-run.unreadable.json"

    /// The snapshot on disk, or nil if there is none, it cannot be read, or it was written by
    /// a build whose schema this one does not understand.
    ///
    /// Anything unreadable is moved aside rather than left in place: left in place it fails
    /// the same way on every launch forever, and deleted it takes the only evidence of why a
    /// run went missing with it.
    static func load() -> InProgressRun? {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let snapshot = try decoder.decode(InProgressRun.self, from: try Data(contentsOf: url))
            guard snapshot.schema == InProgressRun.currentSchema else {
                quarantine(url, why: "schema \(snapshot.schema)")
                return nil
            }
            return snapshot
        } catch {
            quarantine(url, why: String(describing: type(of: error)))
            return nil
        }
    }

    /// Writes the snapshot, replacing whatever was there. Silent on failure by design: the
    /// recorder must not be interrupted because the disk was busy, and the next write is ten
    /// seconds away.
    @discardableResult
    static func save(_ snapshot: InProgressRun) -> Bool {
        guard let url = fileURL else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            return true
        } catch {
            Telemetry.error("recorder.snapshot_write_failed", error)
            return false
        }
    }

    /// Called when the run reaches a resting place — see `InProgressRun.shouldClear`. A
    /// snapshot left behind after a successful save is what turns one run into two.
    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    private static var fileURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return support.appendingPathComponent("Tempo", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static func quarantine(_ url: URL, why: String) {
        let aside = url.deletingLastPathComponent().appendingPathComponent(quarantineName)
        try? FileManager.default.removeItem(at: aside)
        do {
            try FileManager.default.moveItem(at: url, to: aside)
        } catch {
            // Could not even move it. Removing it is still better than failing this way on
            // every launch from here on.
            try? FileManager.default.removeItem(at: url)
        }
        Telemetry.warn("recorder.recovery_failed", "unreadable snapshot", context: ["reason": why])
    }

    /// Default date strategy (seconds since the reference date), not `.iso8601`: ISO-8601
    /// drops the sub-second part, and every instant in a snapshot is an instant a clock is
    /// reconstructed from. A snapshot has to come back as exactly what went in.
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()
}
