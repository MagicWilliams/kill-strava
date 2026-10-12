import XCTest
@testable import Tempo

/// The post-run journal (#120): what gets written to `runs`, and where the photo goes.
///
/// Every failure these pin is silent by design. The journal never blocks the run save, so a
/// photo refused by RLS, a note that would not clear, or a whole row rejected over one bad
/// slider value would surface as nothing at all — the run saves, the journal just isn't
/// there. Same shape as every engine bug before it: no crash, a screen quietly wrong.
final class RunJournalPayloadTests: XCTestCase {

    // MARK: - Photo path

    private let user = UUID(uuidString: "5F0B1C2D-3E4F-4A5B-8C6D-7E8F9A0B1C2D")!
    private let run = UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-EF0123456789")!
    private let photo = UUID(uuidString: "0C0FFEE0-1234-4321-9876-ABCDEFABCDEF")!

    func testPhotoPathStartsWithTheLowercaseUserID() {
        // Migration 0016's storage policies compare the first path segment with
        // `auth.uid()::text`, which Postgres prints lowercase. `uuidString` is uppercase.
        // An uppercase prefix is refused by RLS on every upload, forever, and nothing on
        // screen says so.
        let path = RunJournalPayload.photoPath(userID: user, runID: run, photoID: photo)
        let firstSegment = path.split(separator: "/").first.map(String.init)
        XCTAssertEqual(firstSegment, "5f0b1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d")
        XCTAssertEqual(firstSegment, user.uuidString.lowercased())
        XCTAssertNotEqual(firstSegment, user.uuidString, "the uppercase form is the one RLS refuses")
    }

    func testPhotoPathIsUserRunPhotoJPEG() {
        XCTAssertEqual(
            RunJournalPayload.photoPath(userID: user, runID: run, photoID: photo),
            "5f0b1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d/a1b2c3d4-e5f6-4789-abcd-ef0123456789/0c0ffee0-1234-4321-9876-abcdefabcdef.jpg"
        )
    }

    func testPhotoPathHasNoUppercaseAnywhere() {
        // `storage.foldername` splits on "/", and a case mismatch in any segment makes a
        // second, different object for what should be one photo.
        for _ in 0..<32 {
            let path = RunJournalPayload.photoPath(userID: UUID(), runID: UUID(), photoID: UUID())
            XCTAssertEqual(path, path.lowercased())
            XCTAssertEqual(path.split(separator: "/").count, 3)
            XCTAssertTrue(path.hasSuffix(".jpg"), "the bucket allows image/jpeg only")
        }
    }

    func testRetryingOnePhotoReusesItsPathAndANewPhotoGetsANewOne() {
        // A retry overwrites its own partial upload (upsert); a replacement photo must not
        // overwrite the old object a signed URL may already have cached.
        let first = RunJournalPayload.photoPath(userID: user, runID: run, photoID: photo)
        XCTAssertEqual(first, RunJournalPayload.photoPath(userID: user, runID: run, photoID: photo))
        XCTAssertNotEqual(first, RunJournalPayload.photoPath(userID: user, runID: run, photoID: UUID()))
    }

    // MARK: - Fields payload

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any])
    }

    func testAFullEntryEncodesEveryColumnByItsDatabaseName() throws {
        let shoe = UUID(uuidString: "DEADBEEF-0000-4000-8000-000000000001")!
        let entry = RunJournalEntry(rpe: 7, feelTags: ["heavy legs", "smooth"], notes: "Windy on the lakefront.",
                                    title: "Sunday long run", photoPath: nil, shoeID: shoe)
        let body = try json(RunJournalPayload.fields(for: entry))

        XCTAssertEqual(Set(body.keys), ["rpe", "feel_tags", "notes", "title", "shoe_id"])
        XCTAssertEqual(body["rpe"] as? Int, 7)
        XCTAssertEqual(body["feel_tags"] as? [String], ["heavy legs", "smooth"])
        XCTAssertEqual(body["notes"] as? String, "Windy on the lakefront.")
        XCTAssertEqual(body["title"] as? String, "Sunday long run")
        XCTAssertEqual(body["shoe_id"] as? String, "deadbeef-0000-4000-8000-000000000001")
    }

    func testAnEmptyEntryWritesExplicitNullsSoClearingAFieldClearsIt() throws {
        // Synthesized Encodable *omits* nil optionals, and PostgREST reads an omitted key as
        // "leave it alone". A note the athlete deleted would encode as nothing, and the old
        // note would survive the save. Every key must be present, as null.
        let body = try json(RunJournalPayload.fields(for: RunJournalEntry()))
        XCTAssertEqual(Set(body.keys), ["rpe", "feel_tags", "notes", "title", "shoe_id"])
        for (key, value) in body {
            XCTAssertTrue(value is NSNull, "\(key) must be written as null, not omitted")
        }
    }

    func testFieldsNeverCarryThePhotoPath() throws {
        // The photo writes its own key when its upload lands. If the fields carried
        // `photo_path`, a fields save racing a slow upload would null the photo out.
        let entry = RunJournalEntry(notes: "x", photoPath: "u/r/p.jpg")
        let body = try json(RunJournalPayload.fields(for: entry))
        XCTAssertNil(body["photo_path"])
    }

    func testAnOutOfRangeRPEIsDroppedNotSent() {
        // `rpe between 1 and 10` is a check constraint. A rejected update loses the whole
        // row — the notes would go down with a bad slider value.
        for bad in [0, -1, 11, 100] {
            let fields = RunJournalPayload.fields(for: RunJournalEntry(rpe: bad, notes: "keep me"))
            XCTAssertNil(fields.rpe, "RPE \(bad) must not reach the check constraint")
            XCTAssertEqual(fields.notes, "keep me")
        }
        XCTAssertEqual(RunJournalPayload.fields(for: RunJournalEntry(rpe: 1)).rpe, 1)
        XCTAssertEqual(RunJournalPayload.fields(for: RunJournalEntry(rpe: 10)).rpe, 10)
    }

    func testBlankTextIsNullNotAnEmptyString() {
        let fields = RunJournalPayload.fields(for: RunJournalEntry(notes: "  \n ", title: ""))
        XCTAssertNil(fields.notes)
        XCTAssertNil(fields.title)
    }

    func testTextIsTrimmedButOtherwiseTheAthletesOwnWords() {
        let fields = RunJournalPayload.fields(for: RunJournalEntry(notes: "\n  Felt great.\nNo pain.  ", title: " Tempo Tuesday "))
        XCTAssertEqual(fields.notes, "Felt great.\nNo pain.")
        XCTAssertEqual(fields.title, "Tempo Tuesday")
    }

    func testFeelTagsAreTrimmedDedupedInOrderAndEmptyIsNull() {
        let fields = RunJournalPayload.fields(for: RunJournalEntry(feelTags: [" smooth", "tired", "", "smooth ", "  "]))
        XCTAssertEqual(fields.feelTags, ["smooth", "tired"])
        XCTAssertNil(RunJournalPayload.fields(for: RunJournalEntry(feelTags: ["", " "])).feelTags)
    }

    func testPhotoPathUpdateWritesTheKeyAndAnExplicitNullToClear() throws {
        XCTAssertEqual(try json(RunJournalPayload.PhotoPathUpdate(photoPath: "a/b/c.jpg"))["photo_path"] as? String,
                       "a/b/c.jpg")
        let cleared = try json(RunJournalPayload.PhotoPathUpdate(photoPath: nil))
        XCTAssertEqual(Set(cleared.keys), ["photo_path"])
        XCTAssertTrue(cleared["photo_path"] is NSNull)
    }

    // MARK: - Resize

    func testAPhonePhotoIsFittedTo2048OnItsLongestSide() {
        XCTAssertEqual(RunJournalPayload.fittedPixelSize(CGSize(width: 4032, height: 3024)),
                       CGSize(width: 2048, height: 1536))
        XCTAssertEqual(RunJournalPayload.fittedPixelSize(CGSize(width: 3024, height: 4032)),
                       CGSize(width: 1536, height: 2048))
    }

    func testASmallPhotoIsNeverEnlarged() {
        XCTAssertEqual(RunJournalPayload.fittedPixelSize(CGSize(width: 1200, height: 800)),
                       CGSize(width: 1200, height: 800))
        XCTAssertEqual(RunJournalPayload.fittedPixelSize(CGSize(width: 2048, height: 2048)),
                       CGSize(width: 2048, height: 2048))
    }

    func testAPanoramaKeepsItsAspectAndNeverCollapsesToZero() {
        XCTAssertEqual(RunJournalPayload.fittedPixelSize(CGSize(width: 16000, height: 3000)),
                       CGSize(width: 2048, height: 384))
        let sliver = RunJournalPayload.fittedPixelSize(CGSize(width: 100_000, height: 10))
        XCTAssertEqual(sliver.width, 2048)
        XCTAssertGreaterThanOrEqual(sliver.height, 1)
        XCTAssertEqual(RunJournalPayload.fittedPixelSize(.zero), .zero)
    }

    // MARK: - Retry and the pre-0016 read

    func testOnlyTransientFailuresAreRetried() {
        XCTAssertTrue(RunJournalPayload.isRetryable(statusCode: nil), "no answer at all: the dead spot")
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(RunJournalPayload.isRetryable(statusCode: status), "\(status)")
        }
        // RLS refused the path, file over the bucket cap, column not there yet: the same
        // answer every time, and retrying spends the background window on it.
        for status in [400, 401, 403, 404, 409, 413] {
            XCTAssertFalse(RunJournalPayload.isRetryable(statusCode: status), "\(status)")
        }
    }

    func testOnlyAMissingColumnTriggersTheArchiveFallback() {
        // The archive read asks for the journal columns and, before 0016 is applied, gets
        // refused. That one error falls back to the old select; any other error must stay
        // a failure, or a dead network would be asked everything twice.
        XCTAssertTrue(RunJournalPayload.isMissingColumn(code: "42703"))
        XCTAssertTrue(RunJournalPayload.isMissingColumn(code: "PGRST204"))
        for other in [nil, "42501", "PGRST301", "23514", "57014"] {
            XCTAssertFalse(RunJournalPayload.isMissingColumn(code: other), String(describing: other))
        }
    }

    func testEveryJournalColumnIsInTheArchiveRead() {
        let read = Set(RunJournalPayload.columns.split(separator: ",").map(String.init))
        XCTAssertEqual(read, ["rpe", "feel_tags", "notes", "title", "photo_path", "shoe_id"])
    }

    func testAnUntouchedRunHasAnEmptyJournal() {
        let summary = RunSummary(id: UUID(), start: .now, distanceM: 8047, durationS: 2700, avgHR: nil)
        XCTAssertTrue(summary.journal.isEmpty)
        XCTAssertFalse(RunJournalEntry(rpe: 5).isEmpty)
    }
}
