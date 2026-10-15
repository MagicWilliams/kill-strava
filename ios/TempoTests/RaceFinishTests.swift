import XCTest
@testable import Tempo

/// Race mode (#117). Chicago, 11 Oct 2026, was run with no watch, and afterwards the recap
/// and the block close-out could only guess which run was the race, from its date and its
/// distance. The next race is recorded in Race mode, and the run says so itself: it is filed
/// as the goal's `race_run_id` and the app lands on its recap.
///
/// Each guard here protects one way that filing goes wrong without anything crashing: the
/// marathon cue firing at 26.2 on a 15K, an ordinary Tuesday filed as the block's race, a
/// closed block's result overwritten, or a recap opened onto a run that isn't stored yet.
final class RaceFinishTests: XCTestCase {

    /// The device's zone, because `GoalInfo.raceDay` parses `race_date` in it
    /// (`PlanDates.day`), and the window is counted in calendar days of that zone.
    private let cal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        return c
    }()

    private func day(_ iso: String, hour: Int = 0) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return cal.date(byAdding: .hour, value: hour, to: f.date(from: iso)!)!
    }

    private func goal(race date: String = "2026-10-11", distance: String = "marathon", meters: Int? = 42_195,
                      raceRunID: UUID? = nil, closed: Bool = false) -> GoalInfo {
        var g = GoalInfo(id: UUID(), race_name: "Chicago", race_date: date, goal_time_seconds: 11_700,
                         distance: distance)
        g.distance_m = meters
        g.race_run_id = raceRunID
        if closed {
            g.completed_at = day("2026-10-12", hour: 9)
            g.outcome = "raced"
        }
        return g
    }

    private func stored(_ id: UUID = UUID(), meters: Int = 42_700) -> RunSummary {
        RunSummary(id: id, start: day("2026-10-11", hour: 7), distanceM: meters, durationS: 11_900, avgHR: 162)
    }

    // MARK: - The cue

    /// The cue is Race mode's: a race hears its goal's distance, anything else hears nothing,
    /// and with no goal there is no distance to say.
    func testTheCueIsForARaceAtItsGoalsDistance() {
        XCTAssertEqual(RaceFinish.cueMeters(kind: .race, goal: goal()), 42_195)
        XCTAssertEqual(RaceFinish.cueMeters(kind: .race, goal: goal(distance: "15k", meters: 15_000)), 15_000)
        XCTAssertEqual(RaceFinish.cueMeters(kind: .race, goal: goal(distance: "custom", meters: 30_000)), 30_000,
                       "a custom 30K is only knowable from distance_m")
        XCTAssertNil(RaceFinish.cueMeters(kind: .outdoor, goal: goal()), "race day, but not Race mode")
        XCTAssertNil(RaceFinish.cueMeters(kind: .treadmill, goal: goal()))
        XCTAssertNil(RaceFinish.cueMeters(kind: .race, goal: nil))
    }

    /// Once, on the update that reaches the mark. Reaching it exactly counts; every update
    /// after it is past the mark and says nothing more.
    func testTheCueFiresOnceOnTheUpdateThatReachesTheMark() {
        let mark = 42_195.0
        XCTAssertFalse(RaceFinish.cuesRaceDistance(cueMeters: mark, previousMeters: 42_180, currentMeters: 42_194.9))
        XCTAssertTrue(RaceFinish.cuesRaceDistance(cueMeters: mark, previousMeters: 42_190, currentMeters: 42_195))
        XCTAssertTrue(RaceFinish.cuesRaceDistance(cueMeters: mark, previousMeters: 42_190, currentMeters: 42_204))
        XCTAssertFalse(RaceFinish.cuesRaceDistance(cueMeters: mark, previousMeters: 42_195, currentMeters: 42_210),
                       "already said")
        XCTAssertFalse(RaceFinish.cuesRaceDistance(cueMeters: nil, previousMeters: 42_190, currentMeters: 42_204))
    }

    // MARK: - The link

    /// The race morning: a Race-mode run with a row files itself against the open goal.
    func testARaceOnRaceDayIsLinkedToTheGoal() {
        let g = goal(), id = UUID()
        XCTAssertEqual(RaceFinish.link(kind: .race, savedRunID: id, goal: g, startedAt: day("2026-10-11", hour: 7),
                                       calendar: cal),
                       RaceFinish.Link(goalID: g.id, runID: id))
    }

    /// The same window the sheet offers Race in (`PreRun.raceEligible`), checked again at the
    /// run's start: a day either side is fine, two days is an ordinary run.
    func testTheLinkKeepsTheSheetsRaceWindow() {
        let g = goal(), id = UUID()
        func linked(_ start: Date) -> Bool {
            RaceFinish.link(kind: .race, savedRunID: id, goal: g, startedAt: start, calendar: cal) != nil
        }
        XCTAssertTrue(linked(day("2026-10-10", hour: 7)), "the day before")
        XCTAssertTrue(linked(day("2026-10-12", hour: 6)), "the day after: a race that ran past midnight")
        XCTAssertFalse(linked(day("2026-10-09", hour: 7)), "two days out")
        XCTAssertFalse(linked(day("2026-10-13", hour: 7)), "two days after")
    }

    /// Nothing to file, or nowhere to file it: no link.
    func testNoLinkWithoutARaceARowAnOpenGoalAndAStart() {
        let id = UUID(), start = day("2026-10-11", hour: 7)
        XCTAssertNil(RaceFinish.link(kind: .outdoor, savedRunID: id, goal: goal(), startedAt: start, calendar: cal),
                     "an ordinary run on race day is never the race by fiat")
        XCTAssertNil(RaceFinish.link(kind: .race, savedRunID: nil, goal: goal(), startedAt: start, calendar: cal),
                     "queued or too short: no row to point at")
        XCTAssertNil(RaceFinish.link(kind: .race, savedRunID: id, goal: nil, startedAt: start, calendar: cal))
        XCTAssertNil(RaceFinish.link(kind: .race, savedRunID: id, goal: goal(closed: true), startedAt: start,
                                     calendar: cal),
                     "a closed block's race is whatever the close-out recorded")
        XCTAssertNil(RaceFinish.link(kind: .race, savedRunID: id, goal: goal(race: ""), startedAt: start,
                                     calendar: cal),
                     "a goal with no race date has no race day to be near")
        XCTAssertNil(RaceFinish.link(kind: .race, savedRunID: id, goal: goal(), startedAt: nil, calendar: cal))
    }

    /// A false start: start, stop, start again. The second Race-mode recording is the race,
    /// so it replaces the first link rather than losing to it.
    func testTheNewestRaceRecordingWins() {
        let first = UUID(), second = UUID()
        let g = goal(raceRunID: first)
        XCTAssertEqual(RaceFinish.link(kind: .race, savedRunID: second, goal: g, startedAt: day("2026-10-11", hour: 7),
                                       calendar: cal)?.runID, second)
    }

    /// The goal in memory takes the link the moment it is written, and only the goal it was
    /// written to: a goal replaced in the meantime is left exactly as it is.
    func testApplyingTheLinkToTheGoalInMemory() {
        let g = goal(), id = UUID()
        let link = RaceFinish.Link(goalID: g.id, runID: id)
        XCTAssertEqual(RaceFinish.applying(link, to: g)?.race_run_id, id)
        let other = goal()
        XCTAssertEqual(RaceFinish.applying(link, to: other), other)
        XCTAssertNil(RaceFinish.applying(link, to: nil))
    }

    // MARK: - Where it lands

    /// A race with a row lands on its recap (frame 9b). Every other save closes onto Today,
    /// including a race whose row isn't in the store: a recap opened on nothing is blank.
    func testARaceLandsOnItsRecapAndEverythingElseOnToday() {
        let race = stored()
        let runs = [stored(meters: 6_000), race]
        let recorded = UUID()
        XCTAssertEqual(RaceFinish.destination(.init(recordingID: recorded, kind: .race, runID: race.id), runs: runs),
                       .raceRecap(race))
        XCTAssertEqual(RaceFinish.destination(.init(recordingID: recorded, kind: .outdoor, runID: race.id), runs: runs),
                       .today, "an ordinary run goes home even on race day")
        XCTAssertEqual(RaceFinish.destination(.init(recordingID: recorded, kind: .race, runID: nil), runs: runs),
                       .today, "saved offline: nothing to draw the recap from yet")
        XCTAssertEqual(RaceFinish.destination(.init(recordingID: recorded, kind: .race, runID: UUID()), runs: runs),
                       .today, "a row the store hasn't read")
    }
}
