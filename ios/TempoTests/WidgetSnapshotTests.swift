import XCTest
@testable import Tempo

/// The widgets (#76) render times the app never sees: Monday 00:00 after a weekend away from
/// the phone, the morning after the last sync, a Lock Screen glance two days on. Nobody can
/// watch those moments happen, so the decisions behind them are pinned here.
///
/// The failure every test below guards against is the same one: a widget that keeps showing a
/// confident number after it stopped being true. Last week's 42 miles still sitting under
/// "This week" on Monday morning reads exactly like a great Monday.
final class WidgetSnapshotTests: XCTestCase {

    /// Fixed zone so the week boundary doesn't move with the machine running the tests.
    private let cal: Calendar = {
        var c = WidgetSnapshot.weekCalendar
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    /// Week of Mon 2026-10-05 … Sun 2026-10-11.
    private func at(_ day: Int, _ hour: Int = 9, _ minute: Int = 0, month: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func run(_ day: Int, _ miles: Double, hour: Int = 7, month: Int = 10) -> WidgetSnapshot.RunInput {
        .init(start: at(day, hour, month: month), miles: miles)
    }

    private func session(_ day: Int, _ type: String = "easy", status: String = "planned",
                         title: String? = nil, miles: Double? = 6) -> WidgetSnapshot.SessionInput {
        .init(day: cal.startOfDay(for: at(day)), type: type, title: title, status: status,
              targetMiles: miles, targetPaceSec: nil, detail: nil)
    }

    private func build(
        now: Date,
        runs: [WidgetSnapshot.RunInput] = [],
        sessions: [WidgetSnapshot.SessionInput] = [],
        target: Double? = nil,
        nextTarget: Double? = nil,
        coach: WidgetSnapshot.CoachLine? = nil,
        previous: WidgetSnapshot? = nil
    ) -> WidgetSnapshot {
        WidgetSnapshot.build(now: now, runs: runs, sessions: sessions,
                             weekTargetMiles: target, nextWeekTargetMiles: nextTarget,
                             coachLine: coach, previous: previous, calendar: cal)
    }

    private func week(_ display: WidgetSnapshot.Display, file: StaticString = #filePath, line: UInt = #line) -> WidgetSnapshot.Week? {
        guard case .current(let week) = display else {
            XCTFail("expected a current week, got \(display)", file: file, line: line)
            return nil
        }
        return week
    }

    // MARK: - Counting the week

    /// Same Mon–Sun buckets as Today's "This week" card, so the two can be checked against
    /// each other on the phone: Monday's run is index 0, Sunday's is index 6, and the run the
    /// Sunday before belongs to last week.
    func testRunsLandInTheirMondayFirstDayAndLastWeekIsCountedSeparately() {
        let snap = build(now: at(9), runs: [
            run(5, 5.0), run(7, 8.0), run(7, 2.0, hour: 18), run(9, 6.2),
            run(4, 12.0), run(28, 6.0, month: 9),          // last week: Sun 10-04, Mon 09-28
            run(27, 20.0, month: 9),                        // two weeks back — in neither
        ])
        XCTAssertEqual(snap.weekStart, cal.startOfDay(for: at(5)))
        XCTAssertEqual(snap.dayMiles, [5.0, 0, 10.0, 0, 6.2, 0, 0])
        XCTAssertEqual(snap.weekMiles, 21.2, accuracy: 0.001)
        XCTAssertEqual(snap.lastWeekMiles, 18.0, accuracy: 0.001)
    }

    /// A run at 23:30 Sunday is Sunday's, not Monday's — the boundary is local midnight.
    func testALateSundayRunIsStillThisWeek() {
        let snap = build(now: at(11, 23, 45), runs: [.init(start: at(11, 23, 30), miles: 3)])
        XCTAssertEqual(snap.dayMiles[6], 3)
    }

    // MARK: - Week rollover

    /// The headline case. The app synced on Sunday night and wasn't opened again. At Monday
    /// 00:00 the widget's own timeline entry must zero the week and move what was "this week"
    /// into "last week" — never present 42 miles of last week as this week's total.
    func testMondayMidnightZeroesTheWeekWithoutTheApp() throws {
        let sundayNight = at(11, 21)
        let snap = build(now: sundayNight, runs: [run(5, 10), run(8, 12), run(11, 20)],
                         target: 40, nextTarget: 44)
        let monday = cal.startOfDay(for: at(12))

        XCTAssertTrue(WidgetSnapshot.entryDates(for: snap, now: sundayNight, calendar: cal).contains(monday),
                      "the timeline has to schedule the rollover itself")

        let before = try XCTUnwrap(week(WidgetSnapshot.display(snap, at: monday.addingTimeInterval(-1), calendar: cal)))
        XCTAssertEqual(before.miles, 42, accuracy: 0.001)

        let after = try XCTUnwrap(week(WidgetSnapshot.display(snap, at: monday, calendar: cal)))
        XCTAssertEqual(after.miles, 0, "last week's miles must not be shown as this week's")
        XCTAssertEqual(after.dayMiles, Array(repeating: 0, count: 7))
        XCTAssertEqual(try XCTUnwrap(after.lastWeekMiles), 42, accuracy: 0.001)
        XCTAssertEqual(after.todayIndex, 0)
        XCTAssertEqual(after.gaugeTarget, 44, "the new week measures against the new week's target")
        XCTAssertEqual(after.gaugeBasis, .plan)
    }

    /// Rollover without a plan: the week just finished becomes the bar to beat.
    func testRolloverWithoutAPlanMeasuresAgainstTheWeekJustFinished() throws {
        let snap = build(now: at(11, 21), runs: [run(9, 15)])
        let after = try XCTUnwrap(week(WidgetSnapshot.display(snap, at: at(12, 6), calendar: cal)))
        XCTAssertEqual(after.gaugeBasis, .lastWeek)
        XCTAssertEqual(after.gaugeTarget, 15)
    }

    // MARK: - No plan

    /// Before the coach has proposed a plan there is no session and no target. The widget
    /// says so rather than borrowing one, and the gauge falls back to last week.
    func testNoPlanMeansNoSessionAndTheGaugeIsAgainstLastWeek() throws {
        let snap = build(now: at(9), runs: [run(5, 4), run(1, 20)])
        XCTAssertTrue(snap.upcoming.isEmpty)
        XCTAssertNil(snap.weekTargetMiles)

        let w = try XCTUnwrap(week(WidgetSnapshot.display(snap, at: at(9), calendar: cal)))
        XCTAssertNil(w.nextSession)
        XCTAssertEqual(w.gaugeBasis, .lastWeek)
        XCTAssertEqual(w.gaugeTarget, 20)
        XCTAssertEqual(w.gaugeFraction, 0.2, accuracy: 0.0001)
    }

    /// No plan and nothing last week: there is nothing honest to measure against, so the
    /// gauge has no target instead of a target of zero (which would read as "done").
    func testNoPlanAndNoLastWeekLeavesTheGaugeEmpty() throws {
        let snap = build(now: at(9), runs: [run(5, 4)])
        let w = try XCTUnwrap(week(WidgetSnapshot.display(snap, at: at(9), calendar: cal)))
        XCTAssertNil(w.gaugeTarget)
        XCTAssertNil(w.gaugeBasis)
        XCTAssertEqual(w.gaugeFraction, 0)
    }

    func testWithAPlanTheGaugeIsAgainstThePlanAndCapsAtFull() throws {
        let snap = build(now: at(9), runs: [run(5, 30), run(1, 10)], target: 25)
        let w = try XCTUnwrap(week(WidgetSnapshot.display(snap, at: at(9), calendar: cal)))
        XCTAssertEqual(w.gaugeBasis, .plan)
        XCTAssertEqual(w.gaugeTarget, 25)
        XCTAssertEqual(w.gaugeFraction, 1)
    }

    // MARK: - Next session

    /// Done, skipped and rest days are not "next". Neither is a session already behind us.
    func testNextSessionSkipsDoneRestSkippedAndPast() {
        let snap = build(now: at(9, 18), sessions: [
            session(8, "threshold"),                    // yesterday, missed — behind us
            session(9, "easy", status: "done"),         // today, already run
            session(10, "rest", miles: nil),
            session(11, "long", status: "skipped"),
            session(12, "easy", title: "Recovery jog", miles: 4),
            session(13, "interval"),
        ])
        XCTAssertEqual(snap.upcoming.map(\.type), ["easy", "interval"])
        XCTAssertEqual(snap.upcoming.first?.name, "Recovery jog")
    }

    /// Today's session is still next until it's run, and the widget steps past it at midnight
    /// on its own.
    func testTheNextSessionAdvancesAtMidnight() throws {
        let snap = build(now: at(9, 6), sessions: [session(9, "tempo"), session(10, "long", miles: 16)])
        let morning = try XCTUnwrap(week(WidgetSnapshot.display(snap, at: at(9, 6), calendar: cal)))
        XCTAssertEqual(morning.nextSession?.type, "tempo")
        XCTAssertEqual(WidgetSnapshot.dayLabel(for: morning.nextSession!.day, at: at(9, 6), calendar: cal), "Today")

        let tomorrow = try XCTUnwrap(week(WidgetSnapshot.display(snap, at: cal.startOfDay(for: at(10)), calendar: cal)))
        XCTAssertEqual(tomorrow.nextSession?.type, "long")
        XCTAssertEqual(WidgetSnapshot.dayLabel(for: tomorrow.nextSession!.day, at: at(9, 6), calendar: cal), "Tomorrow")
    }

    // MARK: - Coach line

    func testNoCoachLineEver() throws {
        let snap = build(now: at(9))
        XCTAssertNil(snap.coach)
        XCTAssertNil(try XCTUnwrap(week(WidgetSnapshot.display(snap, at: at(9), calendar: cal))).coach)
    }

    /// The takeaway only exists on a day with a completed session. On a rest day the medium
    /// widget keeps the latest one, dated, rather than going blank every other day.
    func testTheLatestCoachLineIsCarriedForwardWithItsDate() {
        let tuesday = WidgetSnapshot.CoachLine(text: "Strong close on the long run.", day: cal.startOfDay(for: at(6)))
        let first = build(now: at(6, 20), coach: tuesday)
        let next = build(now: at(7, 8), coach: nil, previous: first)
        XCTAssertEqual(next.coach, tuesday)

        let wednesday = WidgetSnapshot.CoachLine(text: "Easy means easy.", day: cal.startOfDay(for: at(7)))
        XCTAssertEqual(build(now: at(7, 20), coach: wednesday, previous: next).coach, wednesday)
    }

    func testAnEmptyTakeawayDoesNotBlankTheCarriedLine() {
        let kept = WidgetSnapshot.CoachLine(text: "Good work.", day: at(6))
        let previous = build(now: at(6), coach: kept)
        let blank = WidgetSnapshot.CoachLine(text: "  \n ", day: at(7))
        XCTAssertEqual(build(now: at(7), coach: blank, previous: previous).coach, kept)
    }

    func testTheCoachLineIsTwoSentencesAtMost() {
        let clipped = WidgetSnapshot.clip("Held 7.5 mi at 8:05/mi. That's threshold work done right! Tomorrow, keep it easy.")
        XCTAssertEqual(clipped, "Held 7.5 mi at 8:05/mi. That's threshold work done right!",
                       "decimals and pace colons are not sentence ends")
    }

    func testALongCoachLineIsCutOnAWordWithAnEllipsis() throws {
        let long = String(repeating: "steady aerobic running ", count: 20)
        let clipped = try XCTUnwrap(WidgetSnapshot.clip(long))
        XCTAssertLessThanOrEqual(clipped.count, WidgetSnapshot.coachLineMaxLength)
        XCTAssertTrue(clipped.hasSuffix("\u{2026}"))
        XCTAssertFalse(clipped.dropLast().hasSuffix(" "))
    }

    // MARK: - Staleness

    /// Under 36 hours the week is current; past it, the widget says "Open Tempo to refresh"
    /// and shows no numbers at all.
    func testStaleThreshold() throws {
        let synced = at(7, 7)
        let snap = build(now: synced, runs: [run(5, 10)])
        XCTAssertNotNil(week(WidgetSnapshot.display(snap, at: synced.addingTimeInterval(35 * 3600), calendar: cal)))
        XCTAssertEqual(WidgetSnapshot.display(snap, at: synced.addingTimeInterval(36 * 3600), calendar: cal).isCurrent, true,
                       "exactly 36h is still inside the window")
        XCTAssertEqual(WidgetSnapshot.display(snap, at: synced.addingTimeInterval(37 * 3600), calendar: cal),
                       .stale(asOf: synced))
    }

    /// The stale moment needs its own entry; otherwise the widget keeps the old picture until
    /// the next midnight — up to another 24 hours of a week that stopped updating.
    func testTheTimelineSchedulesTheStaleMoment() {
        let synced = at(7, 7)
        let snap = build(now: synced)
        let dates = WidgetSnapshot.entryDates(for: snap, now: synced, calendar: cal)
        XCTAssertEqual(dates.first, synced)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertTrue(dates.contains { $0 > synced.addingTimeInterval(WidgetSnapshot.staleAfter) &&
                                       $0 < synced.addingTimeInterval(WidgetSnapshot.staleAfter + 60) })
    }

    func testNoSnapshotIsEmptyNotZero() {
        XCTAssertEqual(WidgetSnapshot.display(nil, at: at(9), calendar: cal), .empty)
    }

    // MARK: - Plumbing

    /// Written by one process, read by another, possibly by a different build.
    func testTheSnapshotSurvivesTheAppGroupRoundTrip() throws {
        let snap = build(now: at(9), runs: [run(5, 4)], sessions: [session(10)], target: 30,
                         coach: .init(text: "Nice.", day: at(9)))
        let data = try JSONEncoder().encode(snap)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data), snap)
    }

    func testWidgetLinksRouteToTodayAndCoachOnly() {
        XCTAssertEqual(WidgetLink(url: URL(string: "tempo://today")!), .today)
        XCTAssertEqual(WidgetLink(url: URL(string: "tempo://coach")!), .coach)
        XCTAssertNil(WidgetLink(url: URL(string: "tempo://plan")!))
        XCTAssertNil(WidgetLink(url: URL(string: "https://coach")!))
        for link in WidgetLink.allCases { XCTAssertEqual(WidgetLink(url: link.url), link) }
    }
}

private extension WidgetSnapshot.Display {
    var isCurrent: Bool { if case .current = self { return true } else { return false } }
}
