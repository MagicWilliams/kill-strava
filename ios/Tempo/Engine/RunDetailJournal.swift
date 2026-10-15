import Foundation

/// The journal on Run Detail (#124): what the athlete said about a run — title, photo,
/// effort, feel, notes, shoes — shown on the run's page and editable after the fact.
///
/// Every decision is here, purely, so it can be pinned. `Screens/RunDetailView.swift` and
/// `Screens/RunJournalEditSheet.swift` draw it; `Services/RunJournal.swift` writes it.
///
/// The failures this guards against are all quiet ones. A photo path signed with the wrong
/// case is a hero that never loads and says nothing. A blank title is an empty heading
/// where the date should be. An edit sheet that only offers in-service shoes hides the
/// retired pair the run was actually worn in. A Save that rewrites `photo_path` from a stale
/// copy deletes a photo. A failed write that the screen shows as saved is notes he thinks
/// the coach has read.
enum RunDetailJournal {

    // MARK: - The heading

    /// The run's own title, or nil to fall back to the date heading every other run has.
    /// Whitespace is "no title": a blank heading is worse than the date.
    static func heading(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - The hero

    enum Hero: Equatable {
        /// His photo, full width. `routeButton`: a route exists, so a button on the photo
        /// opens the full map — the photo takes the hero's place, never the map's.
        case photo(routeButton: Bool)
        /// The route, as before the journal existed.
        case map
        /// No photo and no route: the "Indoor run" / "No route data" banner.
        case banner
    }

    /// The photo wins the hero when there is one; the map is one tap away on it. A photo
    /// that failed to load gives the hero back to the map rather than leaving a grey slab
    /// where a run's route used to be.
    static func hero(hasPhoto: Bool, photoFailed: Bool, hasRoute: Bool) -> Hero {
        if hasPhoto && !photoFailed { return .photo(routeButton: hasRoute) }
        return hasRoute ? .map : .banner
    }

    // MARK: - The photo's signed URL

    /// Seconds a signed URL lives. The bucket is private, so every view of the photo asks
    /// Storage for a fresh one; an hour outlasts any time spent on one run's page, and a URL
    /// that leaks (a screenshot of a share sheet, a log) is dead by lunch.
    static let signedURLLifetime = 3600

    /// The object key to sign for a stored `photo_path`, or nil when there is nothing that
    /// could be signed.
    ///
    /// The key is `<uid>/<run>/<photo>.jpg` inside `run-photos` (`RunJournalPayload.photoPath`).
    /// Storage's read policy compares the first segment to `auth.uid()::text`, which Postgres
    /// prints **lowercase**, so a path whose first segment isn't the signed-in athlete's
    /// lowercase uid would be refused — and a refused sign request is a hero that silently
    /// never loads. Asking anyway costs a round trip and an error log per page view, so the
    /// path is checked here and not asked for.
    ///
    /// A key that arrives with the bucket name in front (`run-photos/<uid>/…`) is accepted
    /// without it: the Storage client prefixes the bucket itself, and signing
    /// `run-photos/run-photos/…` names an object that does not exist.
    static func photoObjectKey(_ stored: String?, userID: UUID?) -> String? {
        guard let userID,
              var key = stored?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        while key.hasPrefix("/") { key.removeFirst() }
        let bucketPrefix = RunJournalPayload.bucket + "/"
        if key.hasPrefix(bucketPrefix) { key.removeFirst(bucketPrefix.count) }
        let segments = key.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              segments.allSatisfy({ !$0.isEmpty }),
              segments[0] == userID.uuidString.lowercased() else { return nil }
        return key
    }

    // MARK: - The tiles

    struct Tile: Equatable {
        let value: String
        let label: String
    }

    /// The journal's tiles, in order: effort, then shoes. A tile with nothing true to say is
    /// absent, never "—": an imported Garmin run has no RPE, and a dash would read as "he
    /// rated it nothing".
    ///
    /// - Effort shows only for an RPE on the 1–10 scale — the same rule the load model and
    ///   the coach apply, so the page never shows an effort the numbers ignored.
    /// - Shoes show only once the pair resolves to a name. A tag whose pair hasn't loaded (or
    ///   doesn't exist) is not a tile; a retired pair is, labelled as retired, because it is
    ///   still the shoe the run was run in.
    static func tiles(_ entry: RunJournalEntry, shoes: [Shoe]) -> [Tile] {
        var tiles: [Tile] = []
        if let rpe = entry.rpe, PostRun.rpeScale.contains(rpe) {
            tiles.append(Tile(value: "\(rpe)/10", label: "Effort · " + PostRun.rpeWord(rpe)))
        }
        if let id = entry.shoeID, let shoe = shoes.first(where: { $0.id == id }) {
            tiles.append(Tile(value: shoe.name, label: shoe.isRetired ? "Shoes · retired" : "Shoes"))
        }
        return tiles
    }

    /// Feel tags as shown: trimmed, blanks and repeats dropped, capitalised ("Heavy legs").
    static func feelLabels(_ entry: RunJournalEntry) -> [String] {
        (RunJournalPayload.fields(for: entry).feelTags ?? []).map(PostRun.tagLabel)
    }

    /// The note as shown, or nil when there's nothing but whitespace.
    static func notes(_ entry: RunJournalEntry) -> String? {
        RunJournalPayload.fields(for: entry).notes
    }

    /// Whether the journal card has anything to show. When it doesn't, the page offers a
    /// one-line "add" row instead (if the run can be edited at all), not an empty card.
    static func hasContent(_ entry: RunJournalEntry, shoes: [Shoe]) -> Bool {
        !tiles(entry, shoes: shoes).isEmpty || !feelLabels(entry).isEmpty || notes(entry) != nil
    }

    // MARK: - Editing after the fact

    /// The edit sheet's starting point: exactly what is stored.
    ///
    /// The shoe starts `.chosen`, never `.untouched`. On the save screen "untouched" means
    /// "use the default pair"; here it would mean a run tagged with no shoes, opened and
    /// saved without touching anything, quietly picks up today's default.
    static func draft(from entry: RunJournalEntry) -> PostRun.Draft {
        PostRun.Draft(
            rpe: entry.rpe.flatMap { PostRun.rpeScale.contains($0) ? $0 : nil },
            feelTags: entry.feelTags,
            notes: entry.notes ?? "",
            title: entry.title ?? "",
            shoe: .chosen(entry.shoeID)
        )
    }

    /// The feel tags offered: the save screen's eight, then any tag this run already carries
    /// that isn't one of them, so a tag from elsewhere can be seen and taken off rather than
    /// silently kept or silently dropped.
    static func feelOptions(current: [String]) -> [String] {
        var options = PostRun.feelTags
        for tag in current where !options.contains(tag) && !tag.trimmingCharacters(in: .whitespaces).isEmpty {
            options.append(tag)
        }
        return options
    }

    /// The pairs offered: the save screen's (in service, default first, newest next), plus
    /// the pair this run is already tagged with when that pair has since been retired.
    /// Retiring a shoe stops it being offered for *new* runs (#121); it must not hide which
    /// shoe an old run was worn in, or make re-saving it look like "None".
    static func shoeOptions(_ shoes: [Shoe], current: UUID?, defaultID: UUID?) -> [Shoe] {
        var options = PostRun.shoeOptions(shoes, defaultID: defaultID)
        if let current, !options.contains(where: { $0.id == current }),
           let worn = shoes.first(where: { $0.id == current }) {
            options.append(worn)
        }
        return options
    }

    /// What the edit does to the photo.
    enum PhotoChange: Equatable {
        case keep
        /// He took the photo off. `photo_path` is written as null.
        case remove
        /// A new photo. It uploads as a new object and `photo_path` moves to it.
        case replace
    }

    /// The edit, decided: the journal the run should end up with, and which writes that takes.
    struct Plan: Equatable {
        /// The journal after the edit. `photoPath` is the original's — the photo moves on its
        /// own write, and only once it has landed (see `applied`).
        let entry: RunJournalEntry
        /// Whether the text fields differ from what is stored, once both are normalized the
        /// way the database will see them. "   " → "" is not an edit.
        let writesFields: Bool
        let photo: PhotoChange

        /// Nothing to write: Save just closes the sheet.
        var isNoop: Bool { !writesFields && photo == .keep }
    }

    /// Turn the sheet's draft into a plan.
    ///
    /// Unlike the save screen (`PostRun.journal`), a blank title here is **no title**, not
    /// the default one: he cleared it on purpose, and the page falls back to the date. And
    /// the shoe is whatever the picker says, with no default — see `draft(from:)`.
    static func plan(_ draft: PostRun.Draft, original: RunJournalEntry, photo: PhotoChange) -> Plan {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = RunJournalEntry(
            rpe: draft.rpe.flatMap { PostRun.rpeScale.contains($0) ? $0 : nil },
            feelTags: RunJournalPayload.fields(for: RunJournalEntry(feelTags: draft.feelTags)).feelTags ?? [],
            notes: notes.isEmpty ? nil : notes,
            title: title.isEmpty ? nil : title,
            photoPath: original.photoPath,
            shoeID: PostRun.shoeID(draft.shoe, defaultID: original.shoeID)
        )
        // "Remove" on a run with no photo is nothing to do.
        let photo: PhotoChange = (photo == .remove && original.photoPath == nil) ? .keep : photo
        return Plan(
            entry: entry,
            writesFields: RunJournalPayload.fields(for: entry) != RunJournalPayload.fields(for: original),
            photo: photo
        )
    }

    /// How the photo write went.
    enum PhotoResult: Equatable {
        /// No photo write was attempted.
        case untouched
        /// The new photo is in the bucket and `photo_path` names it.
        case attached(String)
        /// `photo_path` is now null.
        case removed
        /// The upload or the path write gave up.
        case failed
    }

    /// The journal the page should now show: what the database actually holds after the
    /// writes, not what he asked for. A fields write that failed leaves the old fields; a
    /// photo that failed leaves the old photo. Showing the edit as saved when it wasn't is
    /// how notes he thinks the coach has read turn out never to have landed.
    static func applied(_ plan: Plan, to original: RunJournalEntry, fieldsSaved: Bool, photo: PhotoResult) -> RunJournalEntry {
        var result = (plan.writesFields && fieldsSaved) ? plan.entry : original
        switch photo {
        case .attached(let path): result.photoPath = path
        case .removed: result.photoPath = nil
        case .untouched, .failed: result.photoPath = original.photoPath
        }
        return result
    }

    /// What to say when a Save didn't fully land, or nil when it did. Everything he wrote
    /// stays in the sheet for the retry.
    static func failureMessage(_ plan: Plan, fieldsSaved: Bool, photo: PhotoResult) -> String? {
        let fieldsFailed = plan.writesFields && !fieldsSaved
        let photoFailed = photo == .failed
        switch (fieldsFailed, photoFailed) {
        case (true, true): return "Couldn't save your changes or the photo. Check your connection and try again."
        case (true, false): return "Couldn't save your changes. Check your connection and try again."
        case (false, true):
            if plan.photo == .remove { return "Couldn't remove the photo. Try again." }
            return plan.writesFields
                ? "Your changes are saved, but the photo didn't upload. Try again."
                : "The photo didn't upload. Try again."
        case (false, false): return nil
        }
    }
}
