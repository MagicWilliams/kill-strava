import XCTest
@testable import Tempo

/// The weekly review's arithmetic and its wording (#91).
///
/// Written against the two ways this feature can be wrong without anyone noticing. The first
/// is the week boundary: a review that measures the week holding today instead of the one
/// that finished describes a week with three days still to run, and it would read as a
/// perfectly ordinary review of a short week. The second is the trigger — a `dueWeek` that
/// moves on any day but Monday writes a second review of the same week, and the screen then
/// has two accounts of it.
///
/// Dates are spelled out rather than derived from the functions under test, and the weekday
/// of each one is named in a comment, because every assertion here depends on which day a
/// date actually was.
final class WeeklyReviewTests: XCTestCase {

    // MARK: - Fixtures

    /// Mon–Sun weeks, the calendar the whole engine groups by.
    private let cal = RunHistory.calendar

    private func date(_ stamp: String) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = stamp.count > 10 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return f.date(from: stamp)!
    }

    private func run(_ stamp: String, miles: Double) -> RunSummary {
        RunSummary(
            id: UUID(),
            start: date(stamp),
            distanceM: Int((miles * 1609.34).rounded()),
            durationS: Int(miles * 540),
            avgHR: nil
        )
    }

    private func session(_ stamp: String, _ type: String, status: String, adapted: Bool = false) -> BlockReview.PlannedSession {
        BlockReview.PlannedSession(day: date(stamp), type: type, status: status, adapted: adapted)
    }

    private func planWeek(_ index: Int, target: Double?, phase: String = "build") -> PlanWeekInfo {
        PlanWeekInfo(id: UUID(), week_index: index, phase: phase, target_mileage: target, focus: nil)
    }

    private func stats(
        miles: Double = 0,
        runs: Int = 0,
        planned: Double? = nil,
        done: Int = 0,
        sessions: Int = 0,
        changed: Int = 0,
        changes: Int = 0,
        formStart: Double? = nil,
        formEnd: Double? = nil
    ) -> WeeklyReview.Stats {
        WeeklyReview.Stats(
            miles: miles, runCount: runs, plannedMiles: planned,
            sessionsDone: done, sessionsPlanned: sessions, sessionsChanged: changed,
            changes: changes, formStart: formStart, formEnd: formEnd
        )
    }

    // MARK: - Which week is owed a review

    /// The week that finished, never the one being run. Monday 2026-11-16 opens this week;
    /// the review is owed for Monday 2026-11-09.
    func testTheDueWeekIsTheOneThatFinished() {
        for day in ["2026-11-16 06:00", "2026-11-18 23:30", "2026-11-22 21:00"] {
            XCTAssertEqual(
                WeeklyReview.dueWeek(now: date(day), calendar: cal),
                date("2026-11-09"),
                day
            )
        }
    }

    /// Sunday night is still last week's review. One minute later it is this week's — the
    /// boundary that decides whether the trigger fires twice for one week.
    func testTheDueWeekTurnsOverOnMondayAndNotBefore() {
        XCTAssertEqual(WeeklyReview.dueWeek(now: date("2026-11-15 23:59"), calendar: cal), date("2026-11-02"))
        XCTAssertEqual(WeeklyReview.dueWeek(now: date("2026-11-16 00:00"), calendar: cal), date("2026-11-09"))
    }

    func testNothingWrittenYetMeansTheFinishedWeekIsOwedOne() {
        XCTAssertEqual(
            WeeklyReview.weekAwaitingReview(latestWeekOf: nil, now: date("2026-11-18 08:00"), calendar: cal),
            date("2026-11-09")
        )
    }

    func testAWeekAlreadyReviewedIsNotOwedASecondOne() {
        XCTAssertNil(WeeklyReview.weekAwaitingReview(
            latestWeekOf: date("2026-11-09"), now: date("2026-11-18 08:00"), calendar: cal
        ))
        // A row from a week that has not finished yet still counts as nothing owed, rather
        // than starting a second review of the week behind it.
        XCTAssertNil(WeeklyReview.weekAwaitingReview(
            latestWeekOf: date("2026-11-16"), now: date("2026-11-18 08:00"), calendar: cal
        ))
    }

    /// A month away comes back to one review, not four: each one is a model round trip.
    func testOnlyTheMostRecentFinishedWeekIsOwedOne() {
        XCTAssertEqual(
            WeeklyReview.weekAwaitingReview(
                latestWeekOf: date("2026-10-12"), now: date("2026-11-18 08:00"), calendar: cal
            ),
            date("2026-11-09")
        )
    }

    // MARK: - The numbers

    /// Sunday night belongs to the week it was run in, and Monday morning starts the next
    /// one. The same boundary `RunHistory.weekStart` draws for History and for Today.
    func testOnlyTheWeeksOwnRunsAreCounted() {
        let measured = WeeklyReview.stats(
            weekStart: date("2026-11-09"),
            runs: [
                run("2026-11-08 18:00", miles: 20),   // the Sunday before: last week's
                run("2026-11-09 07:00", miles: 6),
                run("2026-11-15 19:50", miles: 10),   // Sunday night: still this week
                run("2026-11-16 07:00", miles: 5),    // the next Monday: not this week
            ],
            sessions: [],
            plannedMiles: nil,
            changes: 0,
            formStart: nil,
            formEnd: nil,
            calendar: cal
        )
        XCTAssertEqual(measured.runCount, 2)
        XCTAssertEqual(measured.miles, 16, accuracy: 0.001)
    }

    /// Rest days are not sessions you can miss and the race is the result, not a session —
    /// `PlannedSession.counts`, the rule Block Review already follows.
    func testSessionsCountedExcludeRestAndTheRaceItself() {
        let measured = WeeklyReview.stats(
            weekStart: date("2026-11-09"),
            runs: [],
            sessions: [
                session("2026-11-09", "easy", status: "done"),
                session("2026-11-10", "tempo", status: "done", adapted: true),
                session("2026-11-11", "rest", status: "planned"),
                session("2026-11-12", "easy", status: "planned"),
                session("2026-11-15", "race", status: "planned"),
                session("2026-11-16", "long", status: "planned"),   // next week's session
            ],
            plannedMiles: 24,
            changes: 3,
            formStart: nil,
            formEnd: nil,
            calendar: cal
        )
        XCTAssertEqual(measured.sessionsPlanned, 3)
        XCTAssertEqual(measured.sessionsDone, 2)
        XCTAssertEqual(measured.sessionsChanged, 1)
        XCTAssertEqual(measured.plannedMiles, 24)
        XCTAssertEqual(measured.changes, 3)
    }

    // MARK: - The plan's own weeks

    /// `week_index` counts a seven-day stride from the plan's start date, so a plan that
    /// began Monday 2026-10-05 is in its sixth week (index 5) on Monday 2026-11-09.
    func testThePlanWeekIsIndexedOffThePlansStart() {
        XCTAssertEqual(
            WeeklyReview.planWeekIndex(weekStart: date("2026-11-09"), planStart: date("2026-10-05"), calendar: cal),
            5
        )
        XCTAssertEqual(
            WeeklyReview.planWeekIndex(weekStart: date("2026-10-05"), planStart: date("2026-10-05"), calendar: cal),
            0
        )
        // Before the plan existed, and with no plan at all.
        XCTAssertNil(WeeklyReview.planWeekIndex(weekStart: date("2026-09-28"), planStart: date("2026-10-05"), calendar: cal))
        XCTAssertNil(WeeklyReview.planWeekIndex(weekStart: date("2026-11-09"), planStart: nil, calendar: cal))
    }

    func testThePlannedTargetComesFromThatWeeksRow() {
        let weeks = [planWeek(4, target: 30), planWeek(5, target: 24), planWeek(6, target: 18)]
        XCTAssertEqual(
            WeeklyReview.plannedMiles(weekStart: date("2026-11-09"), planStart: date("2026-10-05"), weeks: weeks, calendar: cal),
            24
        )
        // A week the plan has no row for, and a plan with no target on the row it does have.
        XCTAssertNil(WeeklyReview.plannedMiles(
            weekStart: date("2026-12-07"), planStart: date("2026-10-05"), weeks: weeks, calendar: cal
        ))
        XCTAssertNil(WeeklyReview.plannedMiles(
            weekStart: date("2026-11-09"), planStart: date("2026-10-05"), weeks: [planWeek(5, target: nil)], calendar: cal
        ))
    }

    func testRaceWeekOutranksThePlansPhase() {
        let weeks = [planWeek(5, target: 24, phase: "taper")]
        XCTAssertEqual(
            WeeklyReview.phaseLabel(
                weekStart: date("2026-11-09"), planStart: date("2026-10-05"),
                weeks: weeks, raceDay: date("2026-11-15"), calendar: cal
            ),
            "Race week"
        )
        XCTAssertEqual(
            WeeklyReview.phaseLabel(
                weekStart: date("2026-11-09"), planStart: date("2026-10-05"),
                weeks: weeks, raceDay: date("2026-12-06"), calendar: cal
            ),
            "Taper"
        )
        XCTAssertNil(WeeklyReview.phaseLabel(
            weekStart: date("2026-11-09"), planStart: nil, weeks: [], raceDay: nil, calendar: cal
        ))
    }

    // MARK: - Whether to write one at all

    /// A week with nothing in it is left unwritten rather than sent to the model, which
    /// would answer with a paragraph about a week that did not happen.
    func testAnEmptyWeekIsNotWorthWriting() {
        XCTAssertFalse(WeeklyReview.isWorthWriting(stats()))
        XCTAssertTrue(WeeklyReview.isWorthWriting(stats(miles: 3.1, runs: 1)))
        // No runs, but the plan asked for some: that week is worth saying something about.
        XCTAssertTrue(WeeklyReview.isWorthWriting(stats(sessions: 5)))
        // No runs and no plan, but the coach changed something.
        XCTAssertTrue(WeeklyReview.isWorthWriting(stats(changes: 1)))
    }

    // MARK: - The lines on screen

    func testTheSubtitleNamesTheWeekAndThePhaseWhenThereIsOne() {
        XCTAssertEqual(WeeklyReview.subtitle(weekLabel: "Nov 9", phase: "Taper"), "Week of Nov 9 · Taper")
        XCTAssertEqual(WeeklyReview.subtitle(weekLabel: "Nov 9", phase: nil), "Week of Nov 9")
        XCTAssertEqual(WeeklyReview.subtitle(weekLabel: "Nov 9", phase: "   "), "Week of Nov 9")
    }

    /// "0 of 0" would read as a week that skipped every session; a week with no plan has
    /// nothing to be measured against.
    func testTheSessionsLineIsAbsentWhenNothingWasPlanned() {
        XCTAssertEqual(WeeklyReview.sessionsLine(stats(done: 4, sessions: 5)), "4 of 5")
        XCTAssertNil(WeeklyReview.sessionsLine(stats(done: 0, sessions: 0)))
    }

    func testTheChangedLineCountsOnlyWhatChanged() {
        XCTAssertNil(WeeklyReview.changedLine(stats(changed: 0)))
        XCTAssertEqual(WeeklyReview.changedLine(stats(changed: 1)), "1 changed")
        XCTAssertEqual(WeeklyReview.changedLine(stats(changed: 2)), "2 changed")
    }

    /// The sign is the meaning: positive is rested, negative is carrying fatigue.
    func testFormIsSignedAndItsCaptionSaysWhereItCameFrom() {
        XCTAssertEqual(WeeklyReview.formValue(stats(formEnd: 9.24)), "+9.2")
        XCTAssertEqual(WeeklyReview.formValue(stats(formEnd: -3.14)), "-3.1")
        XCTAssertEqual(WeeklyReview.formValue(stats(formEnd: 0)), "+0.0")
        XCTAssertNil(WeeklyReview.formValue(stats()))

        XCTAssertEqual(WeeklyReview.formCaption(stats(formStart: -3.14, formEnd: 9.2)), "from -3.1")
        // Nothing to say when it did not move, or when one end is missing.
        XCTAssertNil(WeeklyReview.formCaption(stats(formStart: 9.21, formEnd: 9.24)))
        XCTAssertNil(WeeklyReview.formCaption(stats(formEnd: 9.2)))
        XCTAssertNil(WeeklyReview.formCaption(stats(formStart: 9.2)))
    }

    func testTheLedgerLinkCountsTheChangesAndDisappearsAtZero() {
        XCTAssertNil(WeeklyReview.changesLink(stats(changes: 0)))
        XCTAssertEqual(WeeklyReview.changesLink(stats(changes: 1)), "1 change in the ledger")
        XCTAssertEqual(WeeklyReview.changesLink(stats(changes: 2)), "2 changes in the ledger")
    }

    func testTheDiscussDraftNamesTheWeekItIsAbout() {
        XCTAssertEqual(
            WeeklyReview.discussDraft(weekLabel: "Nov 9"),
            "About my review for the week of Nov 9:"
        )
    }

    // MARK: - What is stored

    /// The jsonb keys are what the stored rows are made of, so they are pinned: a renamed
    /// key would read every older review's numbers as zero.
    func testStatsRoundTripThroughTheirStoredKeys() throws {
        let measured = stats(miles: 22.4, runs: 5, planned: 24, done: 4, sessions: 5, changed: 1,
                             changes: 2, formStart: -3.1, formEnd: 9.2)
        let encoded = try JSONEncoder().encode(measured)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["miles", "run_count", "planned_miles", "sessions_done", "sessions_planned",
             "sessions_changed", "changes", "form_start", "form_end"]
        )
        XCTAssertEqual(try JSONDecoder().decode(WeeklyReview.Stats.self, from: encoded), measured)
    }

    /// A review on file outlives the shape that wrote it, so a row missing a field decodes
    /// as that field being absent rather than taking the prose down with it.
    func testStatsDecodeFromARowWrittenByAnOlderShape() throws {
        let sparse = Data(#"{"miles": 12.5, "run_count": 3}"#.utf8)
        let decoded = try JSONDecoder().decode(WeeklyReview.Stats.self, from: sparse)
        XCTAssertEqual(decoded.miles, 12.5, accuracy: 0.001)
        XCTAssertEqual(decoded.runCount, 3)
        XCTAssertNil(decoded.plannedMiles)
        XCTAssertEqual(decoded.sessionsPlanned, 0)
        XCTAssertNil(decoded.formEnd)
    }

    /// The three sections are stored under the keys `review.ts` returns them in.
    func testTheSectionsKeepTheKeysTheEdgeFunctionSends() throws {
        let json = Data(#"{"training": "t", "plan_moved": "p", "next_week": "n"}"#.utf8)
        let sections = try JSONDecoder().decode(WeeklyReview.Sections.self, from: json)
        XCTAssertEqual(sections.training, "t")
        XCTAssertEqual(sections.planMoved, "p")
        XCTAssertEqual(sections.nextWeek, "n")
    }
}
