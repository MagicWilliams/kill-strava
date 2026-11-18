import Foundation

/// The weekly coach review (#91) — which week is owed one, what its numbers are, and the
/// lines that sit beside them on screen. Pure: no clock, no locale, no network.
///
/// Every other screen in the app is about today or about the race. A week is the unit the
/// training actually moves in, and nothing stepped back to it: what was run against what was
/// planned, what the coach changed and why, what is coming. That is what a review is, and it
/// is written once, at the end of the week, rather than recomputed whenever it is opened.
///
/// That "once" is the reason the numbers are a stored value here and not a function of the
/// archive. The archive moves underneath a finished week: a Garmin re-export supersedes a
/// run (migration 0008), a correction changes a distance, a missing run arrives three days
/// late. A review recomputed on read would quote numbers its own prose contradicts, and the
/// prose is the part nobody can regenerate. So `Stats` is computed when the review is
/// written, stored on the row, and read back as it was.
enum WeeklyReview {

    // MARK: - Which week is owed a review

    /// The week a review is owed for: the most recently *finished* Mon–Sun week.
    ///
    /// Not the week holding `now` — that one is still being run, and a review of a week with
    /// three days left in it would be wrong by Sunday. On any day of this week the answer is
    /// the same week, which is what lets the app ask on every Coach appearance and write at
    /// most one review per week.
    ///
    /// Derived through `RunHistory.weekStart` at both ends rather than by subtracting seven
    /// days, for the reason `MileageProgression.weeks` gives: across a DST change "Monday
    /// minus 7 days" and "the Monday of that week" are not the same instant.
    static func dueWeek(now: Date, calendar: Calendar = RunHistory.calendar) -> Date {
        let thisWeek = RunHistory.weekStart(of: now, calendar: calendar)
        let shifted = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        return RunHistory.weekStart(of: shifted, calendar: calendar)
    }

    /// The week still owed a review, or nil when it has already been written.
    ///
    /// `latestWeekOf` is the newest `week_of` on file. The comparison is `>=` rather than
    /// `==` so a row from a week that has not finished yet — a clock moved forward, a review
    /// written on a device a day ahead — still counts as "nothing owed" instead of starting
    /// a second review of the same week.
    ///
    /// Only ever the one week. An athlete who does not open the app for a month comes back
    /// to one review and not four: each one is a model round trip, and a backlog spent in
    /// one go is what `CoachThreads.awaitingSummary` is careful about too. The weeks in
    /// between stay unwritten, which is honest — nobody was there to read them.
    static func weekAwaitingReview(
        latestWeekOf: Date?,
        now: Date,
        calendar: Calendar = RunHistory.calendar
    ) -> Date? {
        let due = dueWeek(now: now, calendar: calendar)
        if let latest = latestWeekOf, latest >= due { return nil }
        return due
    }

    // MARK: - The numbers

    /// One finished week, measured. Stored as the review's `stats` jsonb.
    ///
    /// Miles, as everywhere in the engine — the screen converts to the athlete's unit (#109).
    struct Stats: Hashable, Codable {
        let miles: Double
        let runCount: Int
        /// The plan's target for the week, when there was a plan. Nil is "nothing was
        /// planned", which is not the same as a target of zero: a coaching-only athlete
        /// (`plan_style: none`) has no number to be short of.
        let plannedMiles: Double?
        let sessionsDone: Int
        let sessionsPlanned: Int
        /// Sessions the coach changed during the week (`sessions.adapted`).
        let sessionsChanged: Int
        /// Ledger entries applied in the week (#88).
        let changes: Int
        /// Form (CTL − ATL) at the start of the week and at its end, from `LoadModel`.
        /// Nil when the load model could not answer — an archive with no paces in it.
        let formStart: Double?
        let formEnd: Double?

        enum CodingKeys: String, CodingKey {
            case miles
            case runCount = "run_count"
            case plannedMiles = "planned_miles"
            case sessionsDone = "sessions_done"
            case sessionsPlanned = "sessions_planned"
            case sessionsChanged = "sessions_changed"
            case changes
            case formStart = "form_start"
            case formEnd = "form_end"
        }

        init(
            miles: Double,
            runCount: Int,
            plannedMiles: Double?,
            sessionsDone: Int,
            sessionsPlanned: Int,
            sessionsChanged: Int,
            changes: Int,
            formStart: Double?,
            formEnd: Double?
        ) {
            self.miles = miles
            self.runCount = runCount
            self.plannedMiles = plannedMiles
            self.sessionsDone = sessionsDone
            self.sessionsPlanned = sessionsPlanned
            self.sessionsChanged = sessionsChanged
            self.changes = changes
            self.formStart = formStart
            self.formEnd = formEnd
        }

        /// Every field optional on the way in, each missing one read as "nothing there".
        ///
        /// A review is stored once and read for as long as the account lives, so the rows on
        /// file outlive the shape that wrote them: a field added here later would otherwise
        /// make every older review fail to decode, and the screen would lose the prose along
        /// with the number. The same reason `SessionInfo` decodes by hand (#100, #123).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            miles = try c.decodeIfPresent(Double.self, forKey: .miles) ?? 0
            runCount = try c.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
            plannedMiles = try c.decodeIfPresent(Double.self, forKey: .plannedMiles)
            sessionsDone = try c.decodeIfPresent(Int.self, forKey: .sessionsDone) ?? 0
            sessionsPlanned = try c.decodeIfPresent(Int.self, forKey: .sessionsPlanned) ?? 0
            sessionsChanged = try c.decodeIfPresent(Int.self, forKey: .sessionsChanged) ?? 0
            changes = try c.decodeIfPresent(Int.self, forKey: .changes) ?? 0
            formStart = try c.decodeIfPresent(Double.self, forKey: .formStart)
            formEnd = try c.decodeIfPresent(Double.self, forKey: .formEnd)
        }
    }

    /// Measure one week.
    ///
    /// `sessions` is every session the plan holds for the week, done or not, and `runs` is
    /// the whole archive — both are filtered to the week here so a caller cannot hand in a
    /// window that disagrees with `RunHistory.weekStart` about which week a Sunday-night run
    /// belongs to.
    static func stats(
        weekStart: Date,
        runs: [RunSummary],
        sessions: [BlockReview.PlannedSession],
        plannedMiles: Double?,
        changes: Int,
        formStart: Double?,
        formEnd: Double?,
        calendar: Calendar = RunHistory.calendar
    ) -> Stats {
        let inWeek = Self.runs(in: weekStart, runs: runs, calendar: calendar)
        let planned = sessions.filter {
            RunHistory.weekStart(of: $0.day, calendar: calendar) == weekStart && $0.counts
        }
        return Stats(
            miles: inWeek.reduce(0) { $0 + $1.miles },
            runCount: inWeek.count,
            plannedMiles: plannedMiles,
            sessionsDone: planned.filter(\.isDone).count,
            sessionsPlanned: planned.count,
            sessionsChanged: planned.filter(\.adapted).count,
            changes: changes,
            formStart: formStart,
            formEnd: formEnd
        )
    }

    /// The runs that belong to the Mon–Sun week opening at `weekStart`.
    static func runs(
        in weekStart: Date,
        runs: [RunSummary],
        calendar: Calendar = RunHistory.calendar
    ) -> [RunSummary] {
        runs.filter { RunHistory.weekStart(of: $0.start, calendar: calendar) == weekStart }
    }

    /// Which of the plan's weeks covers the calendar week opening at `weekStart`.
    ///
    /// A plan counts its weeks as a seven-day stride from `start_date` — `week_index` 0 is
    /// the week the plan began, whatever day that was (`BlockReview.review` walks the same
    /// stride). A review covers a Mon–Sun calendar week. The two line up exactly when the
    /// plan starts on a Monday, which is how the generator builds them; when one does not,
    /// the index returned is the plan week holding that Monday, which is the only honest
    /// answer available and is off by at most a day of sessions.
    ///
    /// Nil when there is no plan, or when the week falls before it started.
    static func planWeekIndex(
        weekStart: Date,
        planStart: Date?,
        calendar: Calendar = RunHistory.calendar
    ) -> Int? {
        guard let planStart else { return nil }
        let from = calendar.startOfDay(for: planStart)
        let days = calendar.dateComponents([.day], from: from, to: weekStart).day ?? -1
        guard days >= 0 else { return nil }
        return days / 7
    }

    /// The plan's mileage target for the week, when it has one on file.
    static func plannedMiles(
        weekStart: Date,
        planStart: Date?,
        weeks: [PlanWeekInfo],
        calendar: Calendar = RunHistory.calendar
    ) -> Double? {
        guard let index = planWeekIndex(weekStart: weekStart, planStart: planStart, calendar: calendar) else {
            return nil
        }
        return weeks.first { $0.week_index == index }?.target_mileage
    }

    /// The phase beside the week on the screen: "Race week" when the race fell inside it,
    /// otherwise the plan's own phase for that week ("Taper"). Nil when neither applies.
    ///
    /// Race week wins because it is the more specific thing to say, and because a race week
    /// and the taper around it are usually the same plan phase.
    static func phaseLabel(
        weekStart: Date,
        planStart: Date?,
        weeks: [PlanWeekInfo],
        raceDay: Date?,
        calendar: Calendar = RunHistory.calendar
    ) -> String? {
        if let raceDay, RunHistory.weekStart(of: raceDay, calendar: calendar) == weekStart {
            return "Race week"
        }
        guard let index = planWeekIndex(weekStart: weekStart, planStart: planStart, calendar: calendar),
              let phase = weeks.first(where: { $0.week_index == index })?.phase,
              !phase.isEmpty else { return nil }
        return phase.capitalized
    }

    /// Whether this week is worth a review at all.
    ///
    /// A week with no runs, no planned sessions and no changes has nothing in it to write
    /// about, and asking the model anyway produces a paragraph about a week that did not
    /// happen — the same reason an empty thread is skipped by the summarize queue. The week
    /// then stays unwritten, which is a state the Coach row already shows.
    ///
    /// One run is enough. "You ran once" is a real week, and the athlete is the one who gets
    /// to decide what it meant.
    static func isWorthWriting(_ stats: Stats) -> Bool {
        stats.runCount > 0 || stats.sessionsPlanned > 0 || stats.changes > 0
    }

    // MARK: - What a review says

    /// The three sections, as stored in `weekly_reviews.body` and as `review.ts` returns
    /// them. Written together or not at all: the edge function refuses a half-formed review,
    /// so a row always has all three.
    struct Sections: Hashable, Codable {
        let training: String
        let planMoved: String
        let nextWeek: String

        enum CodingKeys: String, CodingKey {
            case training
            case planMoved = "plan_moved"
            case nextWeek = "next_week"
        }
    }

    /// A review as it stands on file.
    struct Written: Hashable, Identifiable {
        let id: UUID
        /// The Monday of the week reviewed.
        let weekOf: Date
        let headline: String
        let sections: Sections
        let stats: Stats
        /// When the athlete opened it. Nil is the whole of "unread".
        let readAt: Date?

        var isUnread: Bool { readAt == nil }
    }

    // MARK: - The lines on screen

    /// The screen's subtitle: "Week of Oct 5", with the plan's phase when there is one.
    ///
    /// `weekLabel` arrives formatted, like `CoachThreads.pickingUpNote`'s day: what a date
    /// reads as depends on the athlete's calendar and locale, which is what a pure function
    /// must not reach for.
    static func subtitle(weekLabel: String, phase: String?) -> String {
        let week = "Week of \(weekLabel)"
        guard let phase = phase?.trimmingCharacters(in: .whitespacesAndNewlines), !phase.isEmpty else {
            return week
        }
        return "\(week) · \(phase)"
    }

    /// "4 of 5" under the sessions tile, or nil when the week had no plan to follow.
    static func sessionsLine(_ stats: Stats) -> String? {
        guard stats.sessionsPlanned > 0 else { return nil }
        return "\(stats.sessionsDone) of \(stats.sessionsPlanned)"
    }

    /// "1 changed" under the sessions tile.
    ///
    /// The ledger's own word for what happened to a session (`CoachThreads.tags` writes
    /// "Session changed"), so a count here and an entry there read as the same event.
    static func changedLine(_ stats: Stats) -> String? {
        guard stats.sessionsChanged > 0 else { return nil }
        return "\(stats.sessionsChanged) changed"
    }

    /// Form at the end of the week, signed: "+9.2", "-3.1", "0.0".
    ///
    /// Signed because the sign is the whole meaning — positive is rested, negative is
    /// carrying fatigue — and unitless, because form is a number in the load model's own
    /// scale and not a distance.
    static func formValue(_ stats: Stats) -> String? {
        stats.formEnd.map { String(format: "%+.1f", $0) }
    }

    /// "from -3.1": where form stood when the week began.
    ///
    /// Nil when either end is missing, or when the two round to the same number — "from
    /// +9.2" under a tile reading "+9.2" is a caption that says nothing.
    static func formCaption(_ stats: Stats) -> String? {
        guard let start = stats.formStart, let end = stats.formEnd,
              (start * 10).rounded() != (end * 10).rounded() else { return nil }
        return "from " + String(format: "%.1f", start)
    }

    /// "2 changes in the ledger", the link under "How the plan moved".
    static func changesLink(_ stats: Stats) -> String? {
        switch stats.changes {
        case 0: return nil
        case 1: return "1 change in the ledger"
        default: return "\(stats.changes) changes in the ledger"
        }
    }

    /// What the composer opens with when the athlete taps Discuss this review.
    ///
    /// Prefilled and unsent, the same hand-off "Change race or date" makes (#233): the
    /// athlete reads it, edits it, or backs out. It names the week rather than quoting the
    /// review back at the coach, which already has the week's numbers in its context.
    static func discussDraft(weekLabel: String) -> String {
        "About my review for the week of \(weekLabel):"
    }
}
