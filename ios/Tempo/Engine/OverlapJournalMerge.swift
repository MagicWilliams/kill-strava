import Foundation

/// What happens to the journal when overlap review retires one run of a pair (#152).
///
/// Overlap review (#30) settles a pair by setting `superseded_by` on the loser, and every
/// read filters superseded rows out. Before this, that was all it did — so if the athlete
/// kept the copy *without* the journal (the Garmin export, say, over the recorder's own row
/// that carried the shoe, the notes and the photo from #120), the journal stayed on the
/// retired row. Nothing deleted it; nothing could see it either. The miles left the shoe,
/// and the notes and the photo disappeared from Run Detail.
///
/// The rules, all decided here so they can be pinned:
///
/// 1. **The survivor's word stands.** A field is carried over only where the kept run has
///    nothing. If both runs say something, the kept run's value is the one that shows and the
///    retired run's stays where it is — never overwritten, never blended (feel tags are not
///    unioned: two different answers to one question is a conflict, not a list).
/// 2. **Blank is nothing.** Whitespace-only notes or title, no feel tags, an empty photo key —
///    the same "didn't say" `RunJournalPayload` writes as `null`. A blank on the kept run does
///    not block a real value from the retired one.
/// 3. **What points at something moves; what the athlete wrote is copied.** `shoe_id` and
///    `photo_path` are references — a pair's mileage, an object in the `run-photos` bucket —
///    and exactly one row should claim each, so they are cleared from the retired run once
///    they are on the kept one. RPE, feel, notes and title are copied and left on the retired
///    row too: a copy can never lose a word if a later write fails.
///
/// Undo (`reversal`) puts back exactly what the transfer did, and nothing the athlete has
/// changed since.
enum OverlapJournalMerge {

    /// A journal column, named as `runs` names it.
    enum Field: String, CodingKey, CaseIterable, Hashable {
        case rpe
        case feelTags = "feel_tags"
        case notes
        case title
        case photoPath = "photo_path"
        case shoeID = "shoe_id"

        /// Cleared from the retired run when carried over, rather than duplicated (rule 3).
        var moves: Bool { self == .photoPath || self == .shoeID }
    }

    /// One retirement's effect on the two journals, before and after.
    struct Transfer: Equatable {
        let keptBefore: RunJournalEntry
        let retiredBefore: RunJournalEntry
        /// The kept run's journal once the gaps are filled.
        let kept: RunJournalEntry
        /// The retired run's journal once the moved fields are cleared.
        let retired: RunJournalEntry
        /// Fields carried onto the kept run, in `Field.allCases` order.
        let filled: [Field]

        /// Fields cleared from the retired run.
        var moved: [Field] { filled.filter(\.moves) }

        /// Nothing to carry — the case for the 2,000+ runs that predate the journal.
        var isEmpty: Bool { filled.isEmpty }

        /// The update for the kept row: only the filled columns, so a value the kept run
        /// already holds is never in the payload at all.
        var keptPatch: Patch { Patch(fields: filled, values: kept) }

        /// The update for the retired row: the moved columns, written as explicit `null`.
        var retiredPatch: Patch { Patch(fields: moved, values: retired) }
    }

    /// Carry the retired run's journal onto the kept one, under the rules above.
    static func transfer(kept: RunJournalEntry, retired: RunJournalEntry) -> Transfer {
        var keptAfter = kept
        var retiredAfter = retired
        var filled: [Field] = []
        for field in Field.allCases where !has(field, kept) && has(field, retired) {
            copy(field, from: retired, to: &keptAfter)
            if field.moves { clear(field, in: &retiredAfter) }
            filled.append(field)
        }
        return Transfer(keptBefore: kept, retiredBefore: retired,
                        kept: keptAfter, retired: retiredAfter, filled: filled)
    }

    // MARK: - Undo

    /// The writes that take a transfer back.
    struct Reversal: Equatable {
        /// Put the moved shoe and photo back on the retired run. Written first, so that a
        /// failure part-way leaves a reference on both rows rather than on neither.
        let retiredPatch: Patch
        /// Clear what was carried onto the kept run — only fields still holding exactly what
        /// the transfer put there.
        let keptPatch: Patch
        /// The kept run's journal once `keptPatch` lands.
        let kept: RunJournalEntry
    }

    /// Undo `transfer`, given what the kept run holds *now*.
    ///
    /// `keptNow` is read fresh at undo time, not taken from the transfer. If the athlete has
    /// since changed a carried-over field — rewritten the note, picked a different shoe — that
    /// field is theirs now and stays. Clearing it would delete something they wrote after the
    /// decision.
    static func reversal(of transfer: Transfer, keptNow: RunJournalEntry) -> Reversal {
        var keptAfter = keptNow
        var cleared: [Field] = []
        for field in transfer.filled where same(field, keptNow, transfer.kept) {
            copy(field, from: transfer.keptBefore, to: &keptAfter)
            cleared.append(field)
        }
        return Reversal(
            retiredPatch: Patch(fields: transfer.moved, values: transfer.retiredBefore),
            keptPatch: Patch(fields: cleared, values: transfer.keptBefore),
            kept: keptAfter
        )
    }

    // MARK: - Payload

    /// A partial `runs` update: exactly `fields`, with their values taken from `values`.
    ///
    /// PostgREST leaves an omitted key alone and sets an explicit `null`, which is both
    /// halves of what is needed — untouched columns stay out of the payload, and a cleared
    /// one goes in as `null`. Encoded by hand because synthesized `Encodable` drops nil
    /// optionals (see `RunJournalPayload.Fields`).
    struct Patch: Encodable, Equatable {
        let fields: [Field]
        let values: RunJournalEntry

        var isEmpty: Bool { fields.isEmpty }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Field.self)
            for field in fields {
                switch field {
                case .rpe:       try c.encode(values.rpe, forKey: .rpe)
                case .feelTags:  try c.encode(values.feelTags.isEmpty ? nil : values.feelTags, forKey: .feelTags)
                case .notes:     try c.encode(values.notes, forKey: .notes)
                case .title:     try c.encode(values.title, forKey: .title)
                case .photoPath: try c.encode(values.photoPath, forKey: .photoPath)
                // Lowercase, as Postgres prints a uuid and as `RunJournalPayload` writes it.
                case .shoeID:    try c.encode(values.shoeID?.uuidString.lowercased(), forKey: .shoeID)
                }
            }
        }
    }

    // MARK: - Fields

    /// Whether `entry` says anything for `field` (rule 2).
    static func has(_ field: Field, _ entry: RunJournalEntry) -> Bool {
        switch field {
        case .rpe:       return entry.rpe != nil
        case .feelTags:  return entry.feelTags.contains { !isBlank($0) }
        case .notes:     return !isBlank(entry.notes)
        case .title:     return !isBlank(entry.title)
        case .photoPath: return !isBlank(entry.photoPath)
        case .shoeID:    return entry.shoeID != nil
        }
    }

    private static func same(_ field: Field, _ a: RunJournalEntry, _ b: RunJournalEntry) -> Bool {
        switch field {
        case .rpe:       return a.rpe == b.rpe
        case .feelTags:  return a.feelTags == b.feelTags
        case .notes:     return a.notes == b.notes
        case .title:     return a.title == b.title
        case .photoPath: return a.photoPath == b.photoPath
        case .shoeID:    return a.shoeID == b.shoeID
        }
    }

    private static func copy(_ field: Field, from source: RunJournalEntry, to target: inout RunJournalEntry) {
        switch field {
        case .rpe:       target.rpe = source.rpe
        case .feelTags:  target.feelTags = source.feelTags
        case .notes:     target.notes = source.notes
        case .title:     target.title = source.title
        case .photoPath: target.photoPath = source.photoPath
        case .shoeID:    target.shoeID = source.shoeID
        }
    }

    private static func clear(_ field: Field, in entry: inout RunJournalEntry) {
        copy(field, from: RunJournalEntry(), to: &entry)
    }

    private static func isBlank(_ text: String?) -> Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}
