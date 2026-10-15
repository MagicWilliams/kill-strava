import Foundation

/// Every decision on the post-run save screen (#129), between the clock stopping and the run
/// being in Health.
///
/// The screen (`Screens/Recorder/SaveRunView.swift`) is drawn to the signed-off frames 7a/7b
/// (#125, "04 · Post-run"). What it *says* and what it *writes* is decided here, purely,
/// because this is the last place a run can be lost or mislabelled before it is stored: a
/// Save that waits on a question he skipped, a shoe picker whose late load overrides the
/// "no shoes" he already tapped, a blank title written over every run, a saved run that
/// silently never appears on Today.
///
/// Two rules carry the whole screen:
///
/// - **Save is always one tap.** Every journal field is optional. Nothing here can make Save
///   wait: an empty draft is a valid journal, and the defaults (title, shoes) fill in only
///   what the athlete left alone.
/// - **The recorder decides what is showing.** `stage` reads the recorder's phase; no tap on
///   this screen ends, saves or closes a run except through the recorder.
enum PostRun {

    // MARK: - What the screen is showing

    enum Stage: Equatable {
        /// The journal, with Save pinned below it. `saving` while the write is in flight (the
        /// form stays up but locked); `failure` after a write failed, with everything he
        /// wrote kept for the retry.
        case review(saving: Bool, failure: String?)
        /// A race saves itself at the finish with no journal (David, #125 decision 3), so it
        /// never gets the form: progress, and Retry if the save failed.
        case race(saving: Bool, failure: String?)
        /// Saved, but somewhere he won't see it on Today straight away: say where, then Done.
        case saved(note: String)
        /// Nothing left to show — saved onto Today, or discarded. Reset, and the cover closes.
        case close
    }

    /// Where a saved run ended up, from `RecordedRunSaver.Outcome` once the save succeeded.
    enum Landing: Equatable {
        /// It has a `runs` row: it is on Today the moment the cover closes.
        case inTempo
        /// Under `WorkoutRow.minimumDistanceM`. In Apple Health only, by the same rule the
        /// sync applies to every imported workout.
        case tooShort
        /// No connection. In Health and queued on disk; the next refresh writes it.
        case queued
    }

    static func stage(phase: RecorderState.Phase, kind: RecorderState.RunKind, landing: Landing?) -> Stage {
        switch phase {
        case .ending(.review):
            return .review(saving: false, failure: nil)
        case .ending(.saving):
            return kind == .race ? .race(saving: true, failure: nil) : .review(saving: true, failure: nil)
        case .ending(.failed(let reason)):
            return kind == .race ? .race(saving: false, failure: reason) : .review(saving: false, failure: reason)
        case .saved:
            return savedNote(landing).map { .saved(note: $0) } ?? .close
        case .discarded, .idle, .countdown, .running, .paused, .recovering:
            // Only `.discarded` reaches this screen; the rest are the instant the cover takes
            // to leave, and `WorkoutRecorder.reset()` ignores a run that is not over.
            return .close
        }
    }

    /// Why a saved run won't be on Today, or nil when it will be. Without this, a test run
    /// under 200 m or a save in a dead spot closes onto a Today with no run on it, which
    /// reads exactly like a run that was lost.
    static func savedNote(_ landing: Landing?) -> String? {
        switch landing {
        case .tooShort:
            return "It's in Apple Health, but it's too short to count as a run, so it stays out of your training log."
        case .queued:
            return "It's in Apple Health. Tempo couldn't reach the server, so the run and your notes will land the next time it syncs."
        case .inTempo, nil:
            return nil
        }
    }

    // MARK: - Discard

    /// The second confirmation's explanation. Discard is never one tap (#128, frame 5b).
    ///
    /// After Tempo refused the row, the workout is already in Apple Health and a discard
    /// leaves it there (`WorkoutRecorder` never deletes a finished workout; the sync will
    /// ingest it). Telling him the run is gone would be false, and he'd go looking for it
    /// to delete in Health — so the message says what actually goes: his notes.
    static func discardMessage(alreadyInHealth: Bool) -> String {
        alreadyInHealth
            ? "The run is already in Apple Health and stays there. What you wrote here is thrown away."
            : "Nothing from this run will be saved, to Apple Health or to Tempo. This can't be undone."
    }

    // MARK: - The summary

    struct Summary: Equatable {
        /// "6.02", with `distanceUnit` set beside it in its own type.
        let distance: String
        let distanceUnit: String
        /// Moving time, "48:31" or "1:02:07".
        let time: String
        /// Average moving pace, "8:04", or "—" with too little distance to divide by.
        let pace: String
        let paceUnit: String
        /// Wall clock, shown only when pauses make it differ from moving time.
        let elapsed: String?
    }

    /// The three numbers at the top of the screen.
    ///
    /// Pace goes through `Units.runPace`, the archive's own rule, rather than the live
    /// screen's average: a mile athlete's run is stored as whole seconds per mile, and the
    /// number on this screen must be the one Today shows for the same run a second later.
    static func summary(distanceM: Double, movingS: Int, elapsedS: Int, units: Units) -> Summary {
        let pace = units.runPace(movingSeconds: movingS, meters: distanceM).map { Units.clock($0) } ?? Units.missing
        return Summary(
            distance: units.number(meters: max(0, distanceM), decimals: 2),
            distanceUnit: units.abbreviation,
            time: duration(movingS),
            pace: pace,
            paceUnit: units.paceSuffix,
            elapsed: elapsedS > movingS ? duration(elapsedS) : nil
        )
    }

    /// "48:31", or "1:02:07" from an hour up.
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    struct SplitRow: Identifiable, Equatable {
        /// The split's 1-based index.
        let id: Int
        /// "3" for a whole split, "0.4" for the partial one at the end.
        let label: String
        /// "7:45": seconds per whole split, so a partial reads at the same scale.
        let pace: String
        /// Bar length, fastest split = 1.
        let barFraction: Double
    }

    /// The splits table: one row per mile or km in the unit the run was recorded in.
    static func splitRows(_ splits: [TrackMath.Split], splitMeters: Double) -> [SplitRow] {
        let usable = splits.filter { $0.paceS.isFinite && $0.paceS > 0 }
        guard let fastest = usable.map(\.paceS).min() else { return [] }
        return usable.map { split in
            SplitRow(
                id: split.index,
                label: split.isPartial ? Units.fixed(split.meters / splitMeters, decimals: 1) : String(split.index),
                pace: Units.clock(split.paceS),
                barFraction: fastest / split.paceS
            )
        }
    }

    // MARK: - The default title

    /// "Tuesday tempo", "Saturday long run", "Thursday treadmill run", "Sunday morning run".
    ///
    /// Written as the title whenever he leaves the field alone, so a recorded run is never
    /// untitled. Named for the session he set out to run when there was one — whether or not
    /// he hid its target ("run free" hides a number, it doesn't change what the run was) —
    /// otherwise for where and when. The day is the calendar day the run *started*, in his
    /// time zone: a run that crosses midnight is still Tuesday's run.
    static func defaultTitle(
        startedAt: Date, kind: RecorderState.RunKind, target: RecorderState.SessionTarget?,
        calendar: Calendar = .current
    ) -> String {
        let day = weekday(startedAt, calendar: calendar)
        if kind == .race { return day + " race" }
        if let target, !PreRun.isRest(target.type) {
            return day + " " + PreRun.noun(for: target.type)
        }
        if kind == .treadmill { return day + " treadmill run" }
        return day + " " + partOfDay(startedAt, calendar: calendar) + " run"
    }

    /// English, whatever the phone's language: the rest of the title and the app are.
    static func weekday(_ date: Date, calendar: Calendar) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[(calendar.component(.weekday, from: date) - 1 + 7) % 7]
    }

    /// Morning 4–11, afternoon 12–16, evening 17–20, night 21–3: a 5 a.m. long run is a
    /// morning run, and a run after dinner is an evening one.
    static func partOfDay(_ date: Date, calendar: Calendar) -> String {
        switch calendar.component(.hour, from: date) {
        case 4..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "night"
        }
    }

    // MARK: - RPE

    static let rpeScale = 1...10

    /// One tap picks; tapping the picked number again clears it. "I don't want to rate this"
    /// must be as reachable as any rating, or the only way out of a mis-tap is a wrong RPE
    /// that then drives his training load (#123).
    static func tappedRPE(_ tapped: Int, current: Int?) -> Int? {
        guard rpeScale.contains(tapped) else { return current }
        return tapped == current ? nil : tapped
    }

    /// The word under the scale.
    static func rpeWord(_ rpe: Int?) -> String {
        switch rpe {
        case nil: return "Tap a number. Leave it if you'd rather not."
        case 1, 2: return "Very easy"
        case 3, 4: return "Easy"
        case 5, 6: return "Moderate"
        case 7, 8: return "Hard"
        case 9: return "Very hard"
        default: return "All out"
        }
    }

    // MARK: - Feel

    /// The tags offered, stored lowercase as written here: they go to the coach verbatim
    /// (`CoachJournal`), and "heavy legs" three runs straight is what it should be able to
    /// spot. Half good, half not, so a good day has as many words as a bad one.
    static let feelTags = ["strong", "smooth", "relaxed", "tired", "heavy legs", "sore", "hot", "windy"]

    /// "Heavy legs".
    static func tagLabel(_ tag: String) -> String {
        tag.prefix(1).uppercased() + tag.dropFirst()
    }

    /// Tap on, tap off. Kept in the order picked.
    static func toggled(_ tag: String, in tags: [String]) -> [String] {
        tags.contains(tag) ? tags.filter { $0 != tag } : tags + [tag]
    }

    // MARK: - Shoes

    /// What he has done with the shoe picker. Kept apart from the default because the shoes
    /// load over the network after the screen is up: if "untouched" and "no shoes" were the
    /// same value, a default arriving late would overwrite the "none" he had already tapped.
    enum ShoeChoice: Equatable {
        case untouched
        /// A pair, or nil for "no shoes".
        case chosen(UUID?)
    }

    /// The pair the run is tagged with: his choice if he made one, else the default
    /// (`ShoeStore.defaultShoeID`, already nil for a retired or deleted pair).
    static func shoeID(_ choice: ShoeChoice, defaultID: UUID?) -> UUID? {
        switch choice {
        case .untouched: return defaultID
        case .chosen(let id): return id
        }
    }

    /// The pairs offered: in service only, the default first, then newest first. A retired
    /// pair is never offered after a run — that is what retiring it means (#121).
    static func shoeOptions(_ shoes: [Shoe], defaultID: UUID?) -> [Shoe] {
        shoes
            .filter { !$0.isRetired }
            .sorted { a, b in
                if (a.id == defaultID) != (b.id == defaultID) { return a.id == defaultID }
                return a.startedAt > b.startedAt
            }
    }

    // MARK: - Draft → journal

    /// What the form holds. Text fields are plain strings because that is what a
    /// `TextField` binds; `journal` turns blanks into "didn't say".
    struct Draft: Equatable {
        var rpe: Int? = nil
        var feelTags: [String] = []
        var notes = ""
        var title = ""
        var shoe: ShoeChoice = .untouched
    }

    /// The journal handed to `WorkoutRecorder.confirmSave`. `RunJournalPayload.fields`
    /// normalizes it again on the way to the database; this is where the screen's own
    /// defaults go in:
    ///
    /// - a blank title is the default title, not no title;
    /// - an untouched shoe picker is the default pair;
    /// - a blank note is nil, and an RPE off the scale is dropped.
    static func journal(_ draft: Draft, defaultTitle: String, defaultShoeID: UUID?) -> RunJournalEntry {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return RunJournalEntry(
            rpe: draft.rpe.flatMap { rpeScale.contains($0) ? $0 : nil },
            feelTags: draft.feelTags,
            notes: notes.isEmpty ? nil : notes,
            title: title.isEmpty ? defaultTitle : title,
            photoPath: nil,
            shoeID: shoeID(draft.shoe, defaultID: defaultShoeID)
        )
    }
}
