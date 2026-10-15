import XCTest
@testable import Tempo

/// Pins the journal on Run Detail (#124): what shows, and what an edit after the fact writes.
///
/// Runs recorded since 13 Oct 2026 carry a title, photo, effort, feel, notes and shoes (#120,
/// #129). Run Detail is where he goes back to them — and every way that can go wrong is
/// quiet. A photo key signed with the wrong case is a hero that never loads and logs an
/// error on every visit. An effort tile reading "—" on 2,000 imported Garmin runs. An edit
/// sheet that hides the retired pair a run was worn in, or picks up today's default shoe on
/// a run he never tagged. A deleted note that survives the save. A failed write shown as
/// saved. Each test below is one of those.
final class RunDetailJournalTests: XCTestCase {

    private let uid = UUID(uuidString: "6F1C2B9A-3E4D-4A5B-8C7D-9E0F1A2B3C4D")!
    private let runID = UUID(uuidString: "A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF")!
    private let photoID = UUID(uuidString: "0D0E0F10-1112-4314-9516-171819202122")!

    private func shoe(_ name: String, retired: Bool = false, started: TimeInterval = 0) -> Shoe {
        Shoe(id: UUID(), name: name, startedAt: Date(timeIntervalSince1970: 1_790_000_000 + started),
             retiredAt: retired ? Date(timeIntervalSince1970: 1_791_000_000) : nil)
    }

    // MARK: - The photo's signed URL

    /// The key the upload wrote is exactly the key that gets signed. Upload and read are two
    /// files apart; if they ever disagree, every photo silently stops appearing.
    func testThePhotoKeyTheUploadWroteIsTheKeyThatIsSigned() {
        let stored = RunJournalPayload.photoPath(userID: uid, runID: runID, photoID: photoID)
        XCTAssertEqual(RunDetailJournal.photoObjectKey(stored, userID: uid), stored)
        XCTAssertTrue(stored.hasPrefix(uid.uuidString.lowercased() + "/"))
    }

    /// Storage's read policy compares the first segment to `auth.uid()::text`, which is
    /// lowercase. An uppercase-uid path would be refused; don't ask.
    func testAPathWithAnUppercaseUIDIsNotSigned() {
        let upper = uid.uuidString + "/" + runID.uuidString.lowercased() + "/" + photoID.uuidString.lowercased() + ".jpg"
        XCTAssertNil(RunDetailJournal.photoObjectKey(upper, userID: uid))
    }

    func testSomeoneElsesPathIsNotSigned() {
        let theirs = RunJournalPayload.photoPath(userID: UUID(), runID: runID, photoID: photoID)
        XCTAssertNil(RunDetailJournal.photoObjectKey(theirs, userID: uid))
    }

    /// Signed out (or not yet signed in at launch): nothing can be signed.
    func testNoSignedInUserMeansNoKey() {
        let stored = RunJournalPayload.photoPath(userID: uid, runID: runID, photoID: photoID)
        XCTAssertNil(RunDetailJournal.photoObjectKey(stored, userID: nil))
    }

    /// The Storage client prefixes the bucket itself; a key that already carries it would be
    /// signed as `run-photos/run-photos/…`, an object that doesn't exist.
    func testABucketPrefixOrLeadingSlashIsTakenOff() {
        let stored = RunJournalPayload.photoPath(userID: uid, runID: runID, photoID: photoID)
        XCTAssertEqual(RunDetailJournal.photoObjectKey("run-photos/" + stored, userID: uid), stored)
        XCTAssertEqual(RunDetailJournal.photoObjectKey("/" + stored, userID: uid), stored)
        XCTAssertEqual(RunDetailJournal.photoObjectKey("  " + stored + "\n", userID: uid), stored)
    }

    /// No photo, a blank column, or a key that is just a folder: no hero, no request.
    func testNothingToSignMeansNoKey() {
        let me = uid.uuidString.lowercased()
        XCTAssertNil(RunDetailJournal.photoObjectKey(nil, userID: uid))
        XCTAssertNil(RunDetailJournal.photoObjectKey("", userID: uid))
        XCTAssertNil(RunDetailJournal.photoObjectKey("   ", userID: uid))
        XCTAssertNil(RunDetailJournal.photoObjectKey(me, userID: uid))
        XCTAssertNil(RunDetailJournal.photoObjectKey(me + "/", userID: uid))
        XCTAssertNil(RunDetailJournal.photoObjectKey(me + "//x.jpg", userID: uid))
    }

    // MARK: - The hero

    /// The photo takes the hero; the map is still one tap away on it.
    func testThePhotoTakesTheHeroAndTheRouteStaysReachable() {
        XCTAssertEqual(RunDetailJournal.hero(hasPhoto: true, photoFailed: false, hasRoute: true),
                       .photo(routeButton: true))
        XCTAssertEqual(RunDetailJournal.hero(hasPhoto: true, photoFailed: false, hasRoute: false),
                       .photo(routeButton: false), "a treadmill run's photo, with no route to open")
    }

    /// A photo that failed to load gives the hero back, not a grey slab over the route.
    func testAPhotoThatFailedToLoadGivesTheHeroBackToTheMap() {
        XCTAssertEqual(RunDetailJournal.hero(hasPhoto: true, photoFailed: true, hasRoute: true), .map)
        XCTAssertEqual(RunDetailJournal.hero(hasPhoto: true, photoFailed: true, hasRoute: false), .banner)
    }

    /// Every run without a photo — all 2,000 imported ones — looks exactly as it did.
    func testWithoutAPhotoTheHeroIsWhatItWas() {
        XCTAssertEqual(RunDetailJournal.hero(hasPhoto: false, photoFailed: false, hasRoute: true), .map)
        XCTAssertEqual(RunDetailJournal.hero(hasPhoto: false, photoFailed: false, hasRoute: false), .banner)
    }

    // MARK: - The heading

    func testTheTitleReplacesTheDateHeadingAndABlankOneDoesNot() {
        XCTAssertEqual(RunDetailJournal.heading("  Lakefront shakeout \n"), "Lakefront shakeout")
        XCTAssertNil(RunDetailJournal.heading(nil))
        XCTAssertNil(RunDetailJournal.heading(""))
        XCTAssertNil(RunDetailJournal.heading("   "), "a blank heading is worse than the date")
    }

    // MARK: - The tiles

    /// An imported run has no journal. No tile says "—" for an effort he never rated.
    func testAnImportedRunShowsNoJournalTiles() {
        let entry = RunJournalEntry()
        XCTAssertEqual(RunDetailJournal.tiles(entry, shoes: [shoe("Pegasus")]), [])
        XCTAssertEqual(RunDetailJournal.feelLabels(entry), [])
        XCTAssertNil(RunDetailJournal.notes(entry))
        XCTAssertFalse(RunDetailJournal.hasContent(entry, shoes: []))
    }

    func testEffortThenShoes() {
        let pegasus = shoe("Pegasus 41")
        let entry = RunJournalEntry(rpe: 7, shoeID: pegasus.id)
        XCTAssertEqual(RunDetailJournal.tiles(entry, shoes: [shoe("Vaporfly"), pegasus]), [
            .init(value: "7/10", label: "Effort · Hard"),
            .init(value: "Pegasus 41", label: "Shoes"),
        ])
    }

    /// The load model and the coach ignore an RPE off the scale; so does the page.
    func testAnEffortOffTheScaleIsNotATile() {
        XCTAssertEqual(RunDetailJournal.tiles(RunJournalEntry(rpe: 0), shoes: []), [])
        XCTAssertEqual(RunDetailJournal.tiles(RunJournalEntry(rpe: 11), shoes: []), [])
        XCTAssertEqual(RunDetailJournal.tiles(RunJournalEntry(rpe: 10), shoes: []).first?.value, "10/10")
    }

    /// The shoes load over the network after the page is up. Until they do, the tile is
    /// absent rather than a raw id or a wrong name.
    func testAShoeThatHasNotLoadedIsNotATile() {
        let entry = RunJournalEntry(shoeID: UUID())
        XCTAssertEqual(RunDetailJournal.tiles(entry, shoes: []), [])
        XCTAssertEqual(RunDetailJournal.tiles(entry, shoes: [shoe("Pegasus")]), [])
    }

    /// Retiring a pair doesn't change which shoe an old run was run in.
    func testARetiredPairStillShowsOnTheRunsItWasWornFor() {
        let old = shoe("Clifton 9", retired: true)
        XCTAssertEqual(RunDetailJournal.tiles(RunJournalEntry(shoeID: old.id), shoes: [old]),
                       [.init(value: "Clifton 9", label: "Shoes · retired")])
    }

    func testFeelAndNotesAreShownCleanedUp() {
        let entry = RunJournalEntry(feelTags: ["heavy legs", " windy ", "", "heavy legs"],
                                    notes: "  Headwind on the way back.\n")
        XCTAssertEqual(RunDetailJournal.feelLabels(entry), ["Heavy legs", "Windy"])
        XCTAssertEqual(RunDetailJournal.notes(entry), "Headwind on the way back.")
        XCTAssertTrue(RunDetailJournal.hasContent(entry, shoes: []))
        XCTAssertNil(RunDetailJournal.notes(RunJournalEntry(notes: " \n ")))
    }

    // MARK: - Editing: the starting point

    /// On the save screen an untouched shoe picker means "the default pair". Here it would
    /// mean an untagged run, opened and saved to fix a typo, picks up today's default.
    func testOpeningAndSavingAnUntaggedRunNeverTagsItWithTheDefaultPair() {
        let untagged = RunJournalEntry(rpe: 5, notes: "Easy")
        let draft = RunDetailJournal.draft(from: untagged)
        XCTAssertEqual(draft.shoe, .chosen(nil))
        let plan = RunDetailJournal.plan(draft, original: untagged, photo: .keep)
        XCTAssertNil(plan.entry.shoeID)
        XCTAssertTrue(plan.isNoop)
    }

    func testTheSheetOpensOnExactlyWhatIsStored() {
        let shoeID = UUID()
        let draft = RunDetailJournal.draft(from: RunJournalEntry(
            rpe: 6, feelTags: ["smooth"], notes: "Felt good", title: "Tuesday tempo", shoeID: shoeID))
        XCTAssertEqual(draft, PostRun.Draft(rpe: 6, feelTags: ["smooth"], notes: "Felt good",
                                            title: "Tuesday tempo", shoe: .chosen(shoeID)))
        XCTAssertEqual(RunDetailJournal.draft(from: RunJournalEntry()), PostRun.Draft(shoe: .chosen(nil)))
    }

    /// A tag that isn't one of the eight (carried over from a merged run, say) can be seen
    /// and taken off, rather than kept invisibly.
    func testATagFromElsewhereIsOfferedSoItCanBeTakenOff() {
        let options = RunDetailJournal.feelOptions(current: ["smooth", "rainy"])
        XCTAssertEqual(Array(options.prefix(PostRun.feelTags.count)), PostRun.feelTags)
        XCTAssertEqual(options.last, "rainy")
        XCTAssertEqual(RunDetailJournal.feelOptions(current: ["smooth"]), PostRun.feelTags)
    }

    /// The retired pair this run was worn in is offered (so it shows as picked); other
    /// retired pairs are not.
    func testTheRunsOwnRetiredPairIsOfferedAndNoOtherRetiredPairIs() {
        let worn = shoe("Clifton 9", retired: true)
        let otherRetired = shoe("Ghost 14", retired: true)
        let current = shoe("Pegasus 41", started: 100)
        let options = RunDetailJournal.shoeOptions([worn, otherRetired, current], current: worn.id, defaultID: current.id)
        XCTAssertEqual(options.map(\.name), ["Pegasus 41", "Clifton 9"])
        XCTAssertEqual(RunDetailJournal.shoeOptions([worn, current], current: nil, defaultID: nil).map(\.name),
                       ["Pegasus 41"])
    }

    // MARK: - Editing: the diff

    /// Whitespace that the database would trim anyway is not an edit, and Save just closes.
    func testAnEditThatChangesNothingTheDatabaseWouldSeeIsANoop() {
        let stored = RunJournalEntry(rpe: 4, feelTags: ["tired"], notes: "Slept badly", title: "Recovery jog")
        var draft = RunDetailJournal.draft(from: stored)
        draft.notes = "Slept badly  \n"
        draft.title = " Recovery jog"
        XCTAssertTrue(RunDetailJournal.plan(draft, original: stored, photo: .keep).isNoop)
    }

    /// A deleted note must be written as null — an omitted key is "leave it alone" to
    /// PostgREST, and the old note would survive the save.
    func testDeletingANoteAfterTheFactWritesNull() throws {
        let stored = RunJournalEntry(rpe: 8, notes: "Ran it too hot", title: "Tuesday tempo")
        var draft = RunDetailJournal.draft(from: stored)
        draft.notes = "   "
        let plan = RunDetailJournal.plan(draft, original: stored, photo: .keep)
        XCTAssertTrue(plan.writesFields)
        XCTAssertNil(plan.entry.notes)

        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(RunJournalPayload.fields(for: plan.entry))) as! [String: Any]
        XCTAssertTrue(json["notes"] is NSNull, "the cleared note is sent as an explicit null")
        XCTAssertEqual(json["rpe"] as? Int, 8)
        XCTAssertNil(json["photo_path"], "the fields write never touches the photo")
    }

    /// Unlike the save screen, a cleared title is no title — the page goes back to the date.
    func testClearingTheTitleRemovesItRatherThanDefaultingIt() {
        let stored = RunJournalEntry(title: "Saturday long run")
        var draft = RunDetailJournal.draft(from: stored)
        draft.title = ""
        let plan = RunDetailJournal.plan(draft, original: stored, photo: .keep)
        XCTAssertNil(plan.entry.title)
        XCTAssertTrue(plan.writesFields)
    }

    /// Rating a run he never rated, and tagging it with a pair.
    func testRatingAndTaggingAnImportedRun() {
        let pegasus = UUID()
        var draft = RunDetailJournal.draft(from: RunJournalEntry())
        draft.rpe = PostRun.tappedRPE(6, current: draft.rpe)
        draft.shoe = .chosen(pegasus)
        draft.feelTags = PostRun.toggled("strong", in: draft.feelTags)
        let plan = RunDetailJournal.plan(draft, original: RunJournalEntry(), photo: .keep)
        XCTAssertEqual(plan.entry, RunJournalEntry(rpe: 6, feelTags: ["strong"], shoeID: pegasus))
        XCTAssertTrue(plan.writesFields)
    }

    /// The plan carries the stored photo key untouched: the photo moves on its own write.
    func testThePlanNeverMovesThePhotoKeyItself() {
        let stored = RunJournalEntry(notes: "a", photoPath: "me/run/photo.jpg")
        var draft = RunDetailJournal.draft(from: stored)
        draft.notes = "b"
        XCTAssertEqual(RunDetailJournal.plan(draft, original: stored, photo: .replace).entry.photoPath, "me/run/photo.jpg")
        XCTAssertEqual(RunDetailJournal.plan(draft, original: stored, photo: .remove).entry.photoPath, "me/run/photo.jpg")
    }

    func testPhotoOnlyEdits() {
        let withPhoto = RunJournalEntry(photoPath: "me/run/photo.jpg")
        let replace = RunDetailJournal.plan(RunDetailJournal.draft(from: withPhoto), original: withPhoto, photo: .replace)
        XCTAssertFalse(replace.writesFields)
        XCTAssertFalse(replace.isNoop)
        let remove = RunDetailJournal.plan(RunDetailJournal.draft(from: withPhoto), original: withPhoto, photo: .remove)
        XCTAssertEqual(remove.photo, .remove)
        XCTAssertFalse(remove.isNoop)
        // Removing a photo that isn't there is nothing to do.
        let none = RunDetailJournal.plan(PostRun.Draft(shoe: .chosen(nil)), original: RunJournalEntry(), photo: .remove)
        XCTAssertEqual(none.photo, .keep)
        XCTAssertTrue(none.isNoop)
    }

    // MARK: - After the write

    /// The page shows what the database holds, not what he asked for.
    func testAFailedFieldsWriteLeavesTheOldFieldsOnThePage() {
        let stored = RunJournalEntry(rpe: 5, notes: "old")
        var draft = RunDetailJournal.draft(from: stored)
        draft.notes = "new"
        let plan = RunDetailJournal.plan(draft, original: stored, photo: .keep)
        XCTAssertEqual(RunDetailJournal.applied(plan, to: stored, fieldsSaved: false, photo: .untouched), stored)
        XCTAssertEqual(RunDetailJournal.applied(plan, to: stored, fieldsSaved: true, photo: .untouched).notes, "new")
        XCTAssertEqual(RunDetailJournal.failureMessage(plan, fieldsSaved: false, photo: .untouched),
                       "Couldn't save your changes. Check your connection and try again.")
        XCTAssertNil(RunDetailJournal.failureMessage(plan, fieldsSaved: true, photo: .untouched))
    }

    func testThePhotoKeyMovesOnlyWhenThePhotoWriteLanded() {
        let stored = RunJournalEntry(photoPath: "me/run/old.jpg")
        let replace = RunDetailJournal.plan(RunDetailJournal.draft(from: stored), original: stored, photo: .replace)
        XCTAssertEqual(RunDetailJournal.applied(replace, to: stored, fieldsSaved: true, photo: .attached("me/run/new.jpg")).photoPath,
                       "me/run/new.jpg")
        XCTAssertEqual(RunDetailJournal.applied(replace, to: stored, fieldsSaved: true, photo: .failed).photoPath,
                       "me/run/old.jpg", "a failed upload keeps the photo that was there")
        XCTAssertEqual(RunDetailJournal.failureMessage(replace, fieldsSaved: true, photo: .failed),
                       "The photo didn't upload. Try again.")

        let remove = RunDetailJournal.plan(RunDetailJournal.draft(from: stored), original: stored, photo: .remove)
        XCTAssertNil(RunDetailJournal.applied(remove, to: stored, fieldsSaved: true, photo: .removed).photoPath)
        XCTAssertEqual(RunDetailJournal.applied(remove, to: stored, fieldsSaved: true, photo: .failed).photoPath, "me/run/old.jpg")
        XCTAssertEqual(RunDetailJournal.failureMessage(remove, fieldsSaved: true, photo: .failed),
                       "Couldn't remove the photo. Try again.")
    }

    /// Notes saved, photo didn't: say both halves, so he doesn't retype the notes.
    func testNotesLandedPhotoDidNot() {
        let stored = RunJournalEntry(notes: "old")
        var draft = RunDetailJournal.draft(from: stored)
        draft.notes = "new"
        let plan = RunDetailJournal.plan(draft, original: stored, photo: .replace)
        let landed = RunDetailJournal.applied(plan, to: stored, fieldsSaved: true, photo: .failed)
        XCTAssertEqual(landed.notes, "new")
        XCTAssertNil(landed.photoPath)
        XCTAssertEqual(RunDetailJournal.failureMessage(plan, fieldsSaved: true, photo: .failed),
                       "Your changes are saved, but the photo didn't upload. Try again.")
        XCTAssertEqual(RunDetailJournal.failureMessage(plan, fieldsSaved: false, photo: .failed),
                       "Couldn't save your changes or the photo. Check your connection and try again.")
    }
}
