import XCTest
@testable import Tempo

/// Pins what overlap review does to the journal when it retires one run of a pair (#152).
///
/// Found while building shoes (#121, PR #149): a run recorded in Tempo (#122) carries the
/// journal — shoe, RPE, notes, photo — and the Garmin export of the same run lands beside it
/// minutes later with the better HR trace. Keep the Garmin copy in overlap review and, before
/// this, the journal stayed on the retired row: the miles left the shoe, the notes and the
/// photo vanished from Run Detail. Nothing was deleted, which is exactly why nothing looked
/// broken. Same shape as every engine bug before it: no crash, a number quietly wrong.
final class OverlapJournalMergeTests: XCTestCase {

    private let pegasus = UUID(uuidString: "6E0A1B2C-3D4E-4F50-8A6B-7C8D9E0FA1B2")!
    private let vaporfly = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    /// The recorder's copy of the run, journal filled in after Save.
    private var recorded: RunJournalEntry {
        RunJournalEntry(
            rpe: 7,
            feelTags: ["heavy legs", "windy"],
            notes: "Last mile into the wind on the bridge.",
            title: "Sunday long run",
            photoPath: "5f0b1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d/a1b2c3d4-e5f6-4789-abcd-ef0123456789/0c0ffee0-1234-4321-9876-abcdefabcdef.jpg",
            shoeID: pegasus
        )
    }

    /// The Garmin export: no journal at all, like every run that predates #120.
    private let garmin = RunJournalEntry()

    private func merge(kept: RunJournalEntry, retired: RunJournalEntry) -> OverlapJournalMerge.Transfer {
        OverlapJournalMerge.transfer(kept: kept, retired: retired)
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The incident

    func testKeepingTheGarminCopyCarriesTheWholeJournalAcross() {
        let t = merge(kept: garmin, retired: recorded)
        XCTAssertEqual(t.kept, recorded, "the kept run ends up with everything the athlete said")
        XCTAssertEqual(t.filled, OverlapJournalMerge.Field.allCases)
    }

    func testShoeMovesSoTheMilesStayOnThePair() {
        // Superseded runs never count toward a shoe (ShoeMileage rule 1), so a shoe left on
        // the retired row is miles gone from the pair.
        let t = merge(kept: garmin, retired: recorded)
        XCTAssertEqual(t.kept.shoeID, pegasus)
        XCTAssertNil(t.retired.shoeID, "moved, not copied — one row claims the run for the pair")
        XCTAssertTrue(t.moved.contains(.shoeID))

        let live = ShoeMileage.Run(shoeID: t.kept.shoeID, distanceM: 32_000)
        let retired = ShoeMileage.Run(shoeID: t.retired.shoeID, distanceM: 32_100, isSuperseded: true)
        let shoe = Shoe(id: pegasus, name: "Pegasus 41", startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(ShoeMileage.tallies([shoe], runs: [live, retired])[pegasus]?.meters, 32_000)
    }

    func testNotesAreCopiedAndTheRetiredRunKeepsItsOwn() {
        // A copy can never lose a word if the second write fails.
        let t = merge(kept: garmin, retired: recorded)
        XCTAssertEqual(t.kept.notes, "Last mile into the wind on the bridge.")
        XCTAssertEqual(t.kept.title, "Sunday long run")
        XCTAssertEqual(t.kept.rpe, 7)
        XCTAssertEqual(t.kept.feelTags, ["heavy legs", "windy"])
        XCTAssertEqual(t.retired.notes, recorded.notes)
        XCTAssertEqual(t.retired.title, recorded.title)
        XCTAssertEqual(t.retired.rpe, recorded.rpe)
        XCTAssertEqual(t.retired.feelTags, recorded.feelTags)
    }

    func testPhotoIsMovedNotDuplicated() {
        let t = merge(kept: garmin, retired: recorded)
        XCTAssertEqual(t.kept.photoPath, recorded.photoPath)
        XCTAssertNil(t.retired.photoPath)
        let holders = [t.kept.photoPath, t.retired.photoPath].compactMap { $0 }
        XCTAssertEqual(holders.count, 1, "exactly one row names the object in run-photos")
    }

    // MARK: - The survivor's word stands

    func testAConflictKeepsTheSurvivorsValueAndLeavesTheRetiredOneWhereItIs() {
        let kept = RunJournalEntry(
            rpe: 5,
            feelTags: ["smooth"],
            notes: "Felt easy.",
            title: "Recovery",
            photoPath: "u/kept/photo.jpg",
            shoeID: vaporfly
        )
        let t = merge(kept: kept, retired: recorded)
        XCTAssertEqual(t.kept, kept, "never overwrite the kept run's own values")
        XCTAssertEqual(t.retired, recorded, "a value that is not carried is not cleared either")
        XCTAssertTrue(t.isEmpty)
        XCTAssertTrue(t.keptPatch.isEmpty)
        XCTAssertTrue(t.retiredPatch.isEmpty)
    }

    func testFeelTagsAreNotUnioned() {
        // Two answers to "how did it feel" is a conflict, not a list.
        let kept = RunJournalEntry(feelTags: ["smooth"])
        let t = merge(kept: kept, retired: recorded)
        XCTAssertEqual(t.kept.feelTags, ["smooth"])
        XCTAssertFalse(t.filled.contains(.feelTags))
    }

    func testAPartialConflictFillsOnlyTheGaps() {
        // The kept run has its own shoe and RPE; notes and photo come from the retired one.
        let kept = RunJournalEntry(rpe: 6, shoeID: vaporfly)
        let t = merge(kept: kept, retired: recorded)
        XCTAssertEqual(t.kept.rpe, 6)
        XCTAssertEqual(t.kept.shoeID, vaporfly)
        XCTAssertEqual(t.kept.notes, recorded.notes)
        XCTAssertEqual(t.kept.photoPath, recorded.photoPath)
        XCTAssertEqual(t.retired.shoeID, pegasus, "a shoe that lost the conflict stays where it was")
        XCTAssertEqual(t.filled, [.feelTags, .notes, .title, .photoPath])
        XCTAssertEqual(t.moved, [.photoPath])
    }

    func testABlankOnTheKeptRunDoesNotBlockARealValue() {
        // Whitespace is "didn't say", the same as RunJournalPayload writes it.
        let kept = RunJournalEntry(feelTags: ["  "], notes: "   \n", title: "", photoPath: "")
        let t = merge(kept: kept, retired: recorded)
        XCTAssertEqual(t.kept.notes, recorded.notes)
        XCTAssertEqual(t.kept.title, recorded.title)
        XCTAssertEqual(t.kept.feelTags, recorded.feelTags)
        XCTAssertEqual(t.kept.photoPath, recorded.photoPath)
    }

    func testABlankOnTheRetiredRunIsNotCarried() {
        let retired = RunJournalEntry(notes: "  ", title: "")
        let t = merge(kept: garmin, retired: retired)
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.kept, garmin)
    }

    func testTwoRunsWithNoJournalMeanNoWrites() {
        // The 2,000+ runs that predate the journal: overlap review must stay two writes.
        let t = merge(kept: garmin, retired: garmin)
        XCTAssertTrue(t.isEmpty)
        XCTAssertTrue(t.keptPatch.isEmpty)
        XCTAssertTrue(t.retiredPatch.isEmpty)
    }

    func testDirectionMatters() {
        // Keeping the journal's own run carries nothing back to it from the empty copy.
        let t = merge(kept: recorded, retired: garmin)
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.kept, recorded)
    }

    // MARK: - What gets written

    func testKeptPatchNamesOnlyTheFilledColumns() throws {
        let kept = RunJournalEntry(rpe: 6, notes: "Mine.", shoeID: vaporfly)
        let body = try json(merge(kept: kept, retired: recorded).keptPatch)
        XCTAssertEqual(Set(body.keys), ["feel_tags", "title", "photo_path"],
                       "a column the kept run already holds is never in the payload")
        XCTAssertEqual(body["title"] as? String, "Sunday long run")
        XCTAssertEqual(body["feel_tags"] as? [String], ["heavy legs", "windy"])
    }

    func testShoeIsWrittenLowercase() throws {
        let body = try json(merge(kept: garmin, retired: recorded).keptPatch)
        XCTAssertEqual(body["shoe_id"] as? String, pegasus.uuidString.lowercased())
    }

    func testRetiredPatchClearsTheMovedColumnsWithExplicitNulls() throws {
        // An omitted key is "leave it alone" to PostgREST; only an explicit null clears.
        let body = try json(merge(kept: garmin, retired: recorded).retiredPatch)
        XCTAssertEqual(Set(body.keys), ["photo_path", "shoe_id"])
        XCTAssertTrue(body["photo_path"] is NSNull)
        XCTAssertTrue(body["shoe_id"] is NSNull)
    }

    // MARK: - Undo

    func testUndoPutsTheShoeAndPhotoBackAndClearsWhatWasCopied() throws {
        let t = merge(kept: garmin, retired: recorded)
        let r = OverlapJournalMerge.reversal(of: t, keptNow: t.kept)
        XCTAssertEqual(r.kept, garmin, "the kept run is as it was before the ruling")

        let restore = try json(r.retiredPatch)
        XCTAssertEqual(restore["shoe_id"] as? String, pegasus.uuidString.lowercased())
        XCTAssertEqual(restore["photo_path"] as? String, recorded.photoPath)

        let clear = try json(r.keptPatch)
        XCTAssertEqual(Set(clear.keys), Set(OverlapJournalMerge.Field.allCases.map(\.rawValue)))
        XCTAssertTrue(clear.values.allSatisfy { $0 is NSNull })
    }

    func testUndoLeavesAFieldTheAthleteChangedSince() throws {
        // Undo is still on screen after leaving and coming back. A note rewritten in between
        // is the athlete's now, not the transfer's.
        let t = merge(kept: garmin, retired: recorded)
        var now = t.kept
        now.notes = "Rewrote this after."
        let r = OverlapJournalMerge.reversal(of: t, keptNow: now)
        XCTAssertEqual(r.kept.notes, "Rewrote this after.")
        XCTAssertNil(r.kept.title, "the untouched fields still go back")
        XCTAssertFalse(try json(r.keptPatch).keys.contains("notes"))
    }

    func testUndoOfAnEmptyTransferWritesNothing() {
        let t = merge(kept: recorded, retired: garmin)
        let r = OverlapJournalMerge.reversal(of: t, keptNow: recorded)
        XCTAssertTrue(r.keptPatch.isEmpty)
        XCTAssertTrue(r.retiredPatch.isEmpty)
        XCTAssertEqual(r.kept, recorded)
    }
}
