import Foundation
import CoreGraphics

/// What the athlete said about a run after finishing it (#120): effort, feel, notes, a
/// title, a photo, the shoes. Lives on `runs` (migration 0016); the photo itself lives in
/// the private `run-photos` bucket and only its object key is here.
///
/// Every field is optional because every question on the post-run screen is skippable.
/// An empty entry is the normal state for the 2,000+ runs that predate the journal.
struct RunJournalEntry: Hashable, Codable {
    var rpe: Int? = nil
    var feelTags: [String] = []
    var notes: String? = nil
    var title: String? = nil
    /// Object key inside `run-photos`, not a URL — the bucket is private, so a viewer asks
    /// Storage for a short-lived signed URL when it needs to draw the photo.
    var photoPath: String? = nil
    var shoeID: UUID? = nil

    var isEmpty: Bool { self == RunJournalEntry() }
}

/// The decisions behind writing a journal, kept pure so they can be pinned.
/// `Services/RunJournal.swift` does the I/O and nothing else.
enum RunJournalPayload {

    // MARK: - Reading

    /// The journal columns, appended to the archive read once migration 0016 exists.
    static let columns = "rpe,feel_tags,notes,title,photo_path,shoe_id"

    /// Whether a PostgREST error means "you named a column this database doesn't have".
    ///
    /// The archive read is the one read the whole app hangs off. If it asks for `rpe` before
    /// 0016 is applied, PostgREST refuses the entire select — and every screen goes from
    /// 2,000 runs to "Couldn't reach the server", over a column nothing reads yet. So the
    /// read asks for the journal, and on *this* error, and only this one, asks again without
    /// it. Anything else (offline, auth, 5xx) is a real failure and must stay one, or the
    /// fallback would quietly double every failing request.
    ///
    /// `42703` is Postgres's undefined_column, which PostgREST passes through for a select;
    /// `PGRST204` is PostgREST's own "column not in the schema cache".
    static func isMissingColumn(code: String?) -> Bool {
        code == "42703" || code == "PGRST204"
    }

    // MARK: - Writing the fields

    /// The `runs` update for the journal's text fields.
    ///
    /// Two decisions live in here:
    ///
    /// 1. **Every key is written, including the empty ones.** Swift's synthesized `Encodable`
    ///    *omits* a nil optional, and PostgREST reads an omitted key as "leave it alone". A
    ///    note the athlete deleted would then encode as nothing at all, and the old note
    ///    would survive the save. Clearing must be a write of `null`, so `encode(to:)` is
    ///    spelled out by hand.
    ///
    /// 2. **`photo_path` is not in it.** The photo goes up on its own clock, with retries,
    ///    and writes its own key when it lands (`PhotoPathUpdate`). If the fields carried
    ///    `photo_path`, a fields save racing a slow upload could null out the photo the
    ///    upload had just attached.
    struct Fields: Encodable, Equatable {
        let rpe: Int?
        let feelTags: [String]?
        let notes: String?
        let title: String?
        let shoeID: UUID?

        enum CodingKeys: String, CodingKey {
            case rpe, notes, title
            case feelTags = "feel_tags"
            case shoeID = "shoe_id"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(rpe, forKey: .rpe)
            try c.encode(feelTags, forKey: .feelTags)
            try c.encode(notes, forKey: .notes)
            try c.encode(title, forKey: .title)
            // Lowercase, to match how Postgres prints a uuid back — keeps the payload
            // byte-comparable with what a read returns.
            try c.encode(shoeID?.uuidString.lowercased(), forKey: .shoeID)
        }
    }

    /// Normalize what the post-run screen collected into the row that gets written.
    ///
    /// - An RPE outside 1–10 is **dropped, not sent**. The column's check constraint would
    ///   reject it, and a rejected update loses the whole row — the athlete's notes would go
    ///   down with a bad slider value.
    /// - Whitespace-only text is "didn't say", so it is written as `null`, not as a blank
    ///   string the Run Detail page would then render as an empty card.
    /// - Feel tags are trimmed, blanks dropped, duplicates removed in the order picked.
    ///   No tags is `null`, the same "didn't say" as every other field.
    static func fields(for entry: RunJournalEntry) -> Fields {
        Fields(
            rpe: entry.rpe.flatMap { (1...10).contains($0) ? $0 : nil },
            feelTags: normalizedTags(entry.feelTags),
            notes: trimmedOrNil(entry.notes),
            title: trimmedOrNil(entry.title),
            shoeID: entry.shoeID
        )
    }

    /// The second write, once the photo is in Storage. `nil` clears it — encoded explicitly
    /// for the same reason as `Fields`.
    struct PhotoPathUpdate: Encodable, Equatable {
        let photoPath: String?

        enum CodingKeys: String, CodingKey { case photoPath = "photo_path" }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(photoPath, forKey: .photoPath)
        }
    }

    // MARK: - The photo

    static let bucket = "run-photos"

    /// Where a run's photo lives in the bucket: `<user>/<run>/<photo>.jpg`.
    ///
    /// The first segment is the whole security model. Migration 0016's policies compare it
    /// to `auth.uid()::text`, which Postgres prints **lowercase** — and `UUID.uuidString` is
    /// **uppercase**. Built naively, every upload would be refused by RLS, and because the
    /// journal never blocks the run save, nothing on screen would say so: the photo would
    /// just never appear. So every segment is lowercased here, where a test can see it.
    ///
    /// A fresh `photoID` per chosen photo, rather than one fixed name per run: replacing a
    /// photo then writes a new object instead of overwriting one a signed URL may already
    /// have cached. Retries of the *same* photo reuse its id, so they overwrite their own
    /// partial upload instead of piling up copies.
    static func photoPath(userID: UUID, runID: UUID, photoID: UUID) -> String {
        [userID, runID].map { $0.uuidString.lowercased() }.joined(separator: "/")
            + "/" + photoID.uuidString.lowercased() + ".jpg"
    }

    /// Longest side, in pixels, of anything uploaded. A phone photo is 4032 × 3024; at
    /// 2048 it still fills a Pro Max screen edge to edge and weighs a quarter as much on
    /// cellular at the end of a run.
    static let maxPhotoDimension: CGFloat = 2048

    static let jpegQuality: CGFloat = 0.8

    /// The pixel size to render a photo at before upload: aspect kept, longest side at most
    /// `maxDimension`, never enlarged, never rounded down to zero.
    static func fittedPixelSize(_ size: CGSize, maxDimension: CGFloat = maxPhotoDimension) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let longest = max(size.width, size.height)
        guard longest > maxDimension else {
            return CGSize(width: size.width.rounded(), height: size.height.rounded())
        }
        let scale = maxDimension / longest
        return CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }

    // MARK: - Retry

    /// Seconds to wait before each retry. Three retries, about twenty seconds in all: long
    /// enough to ride out a dead spot at the end of a run, short enough to finish inside the
    /// background time iOS grants when the athlete pockets the phone straight after saving.
    static let retryDelays: [TimeInterval] = [1, 4, 15]

    /// Whether a failed write is worth trying again.
    ///
    /// `nil` is a transport failure — no HTTP answer at all — which is the cellular dead
    /// spot this retry exists for. 408, 429 and 5xx are the server saying "not now". Every
    /// other 4xx is a "no" that will be a "no" next time too (RLS refused the path, the file
    /// is over the bucket limit, the column doesn't exist yet), and retrying those just
    /// burns the background window.
    static func isRetryable(statusCode: Int?) -> Bool {
        guard let status = statusCode else { return true }
        return status == 408 || status == 429 || (500...599).contains(status)
    }

    // MARK: - Private

    private static func trimmedOrNil(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedTags(_ tags: [String]) -> [String]? {
        var seen: Set<String> = []
        let kept = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return kept.isEmpty ? nil : kept
    }
}
