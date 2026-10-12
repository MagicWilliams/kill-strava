import Foundation
import Supabase
import UIKit

/// The I/O half of the post-run journal (#120): write what the athlete said about a run to
/// its `runs` row, and put their photo in the private `run-photos` bucket.
///
/// What gets written, the photo's path, its size, and which failures are worth retrying are
/// all decided in `Engine/RunJournalPayload.swift` and pinned there.
///
/// ## The journal never blocks the run
///
/// The run is the thing that cannot be lost; the journal is commentary on it. So the order
/// is fixed: **Apple Health save first, journal second**, and the journal is handed off, not
/// awaited. `record` returns immediately with a `Task` the caller may watch or drop, never
/// throws, and retries on its own clock. A dead spot at the end of a run can cost a photo;
/// it can never cost the run.
///
/// The run row must already exist — the recorder writes it straight after the Health save
/// (#122) and passes its id here.
///
/// ## Before migration 0016
///
/// Every write here fails (no columns, no bucket), is reported to telemetry, and is not
/// retried — a missing column is a 4xx, and the retry policy only repeats transient
/// failures. Nothing on screen depends on it yet.
enum RunJournal {

    struct Outcome: Equatable {
        /// The text fields (RPE, feel, notes, title, shoe) landed on the row.
        var fieldsSaved: Bool
        var photo: PhotoOutcome
    }

    enum PhotoOutcome: Equatable {
        case none                 // no photo was chosen
        case attached(String)     // uploaded and `photo_path` set — the object key
        case failed               // upload or path write gave up after retries
    }

    /// Hand the journal off and return at once. Call only after the run is safely in Apple
    /// Health and its `runs` row exists.
    ///
    /// Holds a background-task assertion for the duration, because the moment after Save is
    /// exactly when the phone goes back in a pocket. If iOS takes the time back anyway, the
    /// work is suspended, not lost: it resumes the next time the app runs.
    @MainActor
    @discardableResult
    static func record(
        _ entry: RunJournalEntry,
        photo: UIImage?,
        forRun runID: UUID
    ) -> Task<Outcome, Never> {
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "run-journal")
        return Task.detached(priority: .utility) {
            let outcome = await write(entry, photo: photo, forRun: runID)
            await MainActor.run {
                if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
            }
            return outcome
        }
    }

    /// Fields first, then the photo. Each is independent: a refused photo does not undo the
    /// notes, and a failed notes write does not stop the photo.
    static func write(_ entry: RunJournalEntry, photo: UIImage?, forRun runID: UUID) async -> Outcome {
        let fieldsSaved = await saveFields(entry, forRun: runID)
        guard let photo else { return Outcome(fieldsSaved: fieldsSaved, photo: .none) }
        if let path = await attachPhoto(photo, toRun: runID) {
            return Outcome(fieldsSaved: fieldsSaved, photo: .attached(path))
        }
        return Outcome(fieldsSaved: fieldsSaved, photo: .failed)
    }

    // MARK: - Fields

    /// Write RPE, feel tags, notes, title and shoe. Every column is written, so a field the
    /// athlete cleared is cleared (see `RunJournalPayload.Fields`). `photo_path` is not
    /// touched. Returns whether it landed.
    @discardableResult
    static func saveFields(_ entry: RunJournalEntry, forRun runID: UUID) async -> Bool {
        let fields = RunJournalPayload.fields(for: entry)
        do {
            try await withRetry("journal.fields_write_failed") {
                try await Supa.client
                    .from("runs")
                    .update(fields)
                    .eq("id", value: runID.uuidString)
                    .execute()
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Photo

    /// Resize, upload, then point the run at it. Returns the object key, or nil if any step
    /// gave up.
    ///
    /// Upload before the row write, never the other way round: a `photo_path` naming an
    /// object that never arrived is a broken image on Run Detail, whereas an object no row
    /// names is merely an orphan in a private bucket.
    static func attachPhoto(_ image: UIImage, toRun runID: UUID) async -> String? {
        guard let uid = Supa.userID else { return nil }
        guard let jpeg = jpegForUpload(image) else {
            Telemetry.warn("journal.photo_encode_failed")
            return nil
        }
        let path = RunJournalPayload.photoPath(userID: uid, runID: runID, photoID: UUID())

        do {
            try await withRetry("journal.photo_upload_failed", context: ["bytes": "\(jpeg.count)"]) {
                // `upsert: true`: if an attempt landed but its response was lost, the retry
                // overwrites its own object instead of failing as a duplicate.
                _ = try await Supa.client.storage
                    .from(RunJournalPayload.bucket)
                    .upload(path, data: jpeg,
                            options: FileOptions(contentType: "image/jpeg", upsert: true))
            }
            try await withRetry("journal.photo_path_write_failed") {
                try await Supa.client
                    .from("runs")
                    .update(RunJournalPayload.PhotoPathUpdate(photoPath: path))
                    .eq("id", value: runID.uuidString)
                    .execute()
            }
        } catch {
            return nil
        }
        Telemetry.info("journal.photo_attached", context: ["bytes": "\(jpeg.count)"])
        return path
    }

    /// Redraw at ≤ 2048 px on the longest side and encode as JPEG. Drawing through the
    /// renderer also bakes in the EXIF orientation, so a portrait photo is stored upright
    /// for viewers that ignore the tag.
    static func jpegForUpload(_ image: UIImage) -> Data? {
        let pixels = CGSize(width: image.size.width * image.scale,
                            height: image.size.height * image.scale)
        let target = RunJournalPayload.fittedPixelSize(pixels)
        guard target.width > 0, target.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // `target` is already in pixels
        format.opaque = true      // JPEG has no alpha; saying so skips a pointless channel
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: RunJournalPayload.jpegQuality)
    }

    // MARK: - Retry

    /// Run `operation`, retrying transient failures on `RunJournalPayload.retryDelays`.
    /// Logs once, with the final error, when it gives up — not once per attempt.
    private static func withRetry(
        _ event: String,
        context: [String: String] = [:],
        _ operation: () async throws -> Void
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await operation()
                return
            } catch {
                let retryable = !(error is CancellationError)
                    && RunJournalPayload.isRetryable(statusCode: statusCode(of: error))
                guard retryable, attempt < RunJournalPayload.retryDelays.count else {
                    var ctx = context
                    ctx["attempts"] = "\(attempt + 1)"
                    report(event, error, context: ctx)
                    throw error
                }
                let delay = RunJournalPayload.retryDelays[attempt]
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// `Telemetry.error` logs the error's full description, and a Postgres constraint error's
    /// `details` can read "Failing row contains (…)" — the athlete's notes, verbatim. Free
    /// text they typed must never reach `app_events`, so a database error is reported by its
    /// code and message alone.
    private static func report(_ event: String, _ error: Error, context: [String: String]) {
        guard let error = error as? PostgrestError else {
            Telemetry.error(event, error, context: context)
            return
        }
        var ctx = context
        ctx["error_type"] = "PostgrestError"
        ctx["code"] = error.code ?? "none"
        Telemetry.log(.error, event, String(error.message.prefix(200)), context: ctx)
    }

    /// The HTTP status a failure carries, or nil when there was no HTTP answer at all.
    ///
    /// A `PostgrestError` is the database answering — a check constraint, a missing column,
    /// RLS — so it is a definitive no (reported as 400) even though it carries a Postgres
    /// code rather than an HTTP status.
    private static func statusCode(of error: Error) -> Int? {
        switch error {
        case let error as HTTPError:     return error.response.statusCode
        case let error as StorageError:  return error.statusCode.flatMap { Int($0) } ?? 400
        case is PostgrestError:          return 400
        case let error as URLError:      return error.code == .cancelled ? 400 : nil
        default:                         return nil
        }
    }
}
