import Foundation

/// What Race mode does that an ordinary run doesn't (#117), decided purely.
///
/// The pre-run sheet offers Race only near an open block's race day (`PreRun.raceEligible`),
/// and the reducer saves a race by itself at the finish. This file is the rest: the voice cue
/// at the race distance, which goal the saved run is filed against, and where the app goes
/// once the save lands. Before this, the recap and the block close-out could only guess which
/// run was the race from its date and distance (`RaceRecap.isRace`); a Race-mode run says so.
///
/// `WorkoutRecorder` asks the first two; the app root asks the third. None of it touches
/// HealthKit, Supabase or SwiftUI.
enum RaceFinish {

    // MARK: - The cue at the race distance

    /// The distance the race cue fires at, or nil for no cue: not a race, or no goal to say
    /// how far the race is. Read off the goal, `distance_m` first (`RaceRecap.raceMeters`),
    /// so a 15K or a custom 30K cues at its own distance and not at a marathon's.
    static func cueMeters(kind: RecorderState.RunKind, goal: GoalInfo?) -> Double? {
        guard kind == .race, let goal else { return nil }
        return RaceRecap.raceMeters(goal: goal)
    }

    /// Whether this distance update is the one that says "twenty-six point two".
    ///
    /// It fires once, when the watch reaches the race distance, and that is not the finish.
    /// GPS overreads a race: the course is measured on the shortest legal line and nobody
    /// runs it, so the phone passes 26.2 a few hundred metres before the mat (Chicago reads
    /// 26.4–26.8 for an honest 26.2; see `RaceRecap.overreadBand`). The cue's last sentence
    /// (`CueText.raceDistance`) says so, because "26.2" in his ear sounds like "done" at the
    /// moment he can least afford to ease off.
    static func cuesRaceDistance(cueMeters: Double?, previousMeters: Double, currentMeters: Double) -> Bool {
        guard let cueMeters else { return false }
        return CueText.crossed(cueMeters, previousMeters: previousMeters, currentMeters: currentMeters)
    }

    // MARK: - Filing the run against the goal

    /// `goals.race_run_id = runID where id = goalID`.
    struct Link: Equatable {
        let goalID: UUID
        let runID: UUID
    }

    /// The link to write once a race is saved, or nil for none.
    ///
    /// - Parameters:
    ///   - savedRunID: the `runs` row the save produced. Nil when there isn't one yet (queued
    ///     offline, too short): nothing to link, and the date-and-distance guess still finds
    ///     the run once the sync lands it.
    ///   - startedAt: when the race started. Eligibility is checked again against it, so a
    ///     race-kind run that reaches a save by another road (a relaunch after a kill, a goal
    ///     replaced mid-run) never files an ordinary day as the block's race.
    ///
    /// A closed block is never relinked: its race is whatever the close-out recorded. An open
    /// goal that already names a race run is relinked — the newest Race-mode recording wins,
    /// because the case that happens is a false start (start, stop, start again), and the
    /// second recording is the race.
    static func link(
        kind: RecorderState.RunKind,
        savedRunID: UUID?,
        goal: GoalInfo?,
        startedAt: Date?,
        calendar: Calendar = RaceCountdown.calendar
    ) -> Link? {
        guard kind == .race, let savedRunID, let goal, let startedAt else { return nil }
        let blockClosed = goal.completed_at != nil || goal.outcome != nil
        guard PreRun.raceEligible(raceDay: goal.raceDay, blockClosed: blockClosed,
                                  now: startedAt, calendar: calendar) else { return nil }
        return Link(goalID: goal.id, runID: savedRunID)
    }

    /// The goal as it reads once `link` is written, so the screens that read the link (the
    /// recap door, the block close-out) agree with the database before the next refresh.
    static func applying(_ link: Link, to goal: GoalInfo?) -> GoalInfo? {
        guard var goal, goal.id == link.goalID else { return goal }
        goal.race_run_id = link.runID
        return goal
    }

    // MARK: - After the save

    /// A save that landed, as the app root reads it. Kept by `WorkoutRecorder` past its
    /// `reset()`, because the save screen (#129) resets the recorder the moment a run is in
    /// Tempo, and the landing must not depend on which of the two hears the save first.
    struct SavedRun: Equatable {
        /// The recording, so two saves in a row are two changes even when both land on Today.
        let recordingID: UUID?
        let kind: RecorderState.RunKind
        /// The `runs` row, when the save produced one.
        let runID: UUID?
    }

    /// Where the app goes once a run is saved.
    enum Destination: Equatable {
        /// Back where he started: the cover closes onto Today.
        case today
        /// The race recap for the run he just raced (Figma frame 9b, "Race finish").
        case raceRecap(RunSummary)
    }

    /// A race finish goes to its recap (EM, #117: it auto-saves and goes straight there). Any
    /// other run, and a race with no `runs` row to show (queued offline, too short), closes
    /// onto Today: the recap is drawn from the stored run, and with none it would open blank.
    ///
    /// The save screen (#129) owns `.ending` and `.saved`; this only says where to land after.
    static func destination(_ saved: SavedRun, runs: [RunSummary]) -> Destination {
        guard saved.kind == .race, let runID = saved.runID,
              let run = runs.first(where: { $0.id == runID }) else { return .today }
        return .raceRecap(run)
    }
}
