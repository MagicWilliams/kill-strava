import XCTest
@testable import Tempo

/// Closing the Chicago 2026 block (#100). There is no race run: David ran it with no watch and
/// the Strava app paused itself mid-race. So the official finish time arrives the only way it
/// can — typed — and that is the path these test first.
///
/// What gets written is the whole contract: the outcome, the time, which run (if any) was the
/// race, and `is_active = false`. A wrong field here does not crash; it files a block under
/// the wrong result forever.
final class BlockCloseoutTests: XCTestCase {

    private let marathon = RaceRecap.marathonMeters
    private let goalID = UUID(uuidString: "2291695A-D680-4A25-A63B-F9E654293288")!
    private let now = Date(timeIntervalSince1970: 1_791_900_000)   // 2026-10-12

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - Typed time (the primary path)

    func testTypedFinishTimeIsReadAsHoursMinutesSeconds() {
        XCTAssertEqual(BlockCloseout.parseFinish("3:28:15", raceMeters: marathon), 12_495)
        XCTAssertEqual(BlockCloseout.parseFinish(" 3:28:15 ", raceMeters: marathon), 12_495, "stray spaces")
        XCTAssertEqual(BlockCloseout.parseFinish("3:05:09", raceMeters: marathon), 11_109)
    }

    /// "3:28" for a marathon is three hours twenty-eight — nobody types the seconds of a time
    /// they're rounding. "18:45" for a 5K is eighteen minutes. The distance settles it.
    func testTwoPartTimeIsReadByWhatTheDistanceMakesPossible() {
        XCTAssertEqual(BlockCloseout.parseFinish("3:28", raceMeters: marathon), 12_480, "h:mm for a marathon")
        XCTAssertEqual(BlockCloseout.parseFinish("18:45", raceMeters: 5_000), 1_125, "m:ss for a 5K")
        XCTAssertEqual(BlockCloseout.parseFinish("5:30", raceMeters: 1_609.34), 330, "m:ss for a mile")
        XCTAssertEqual(BlockCloseout.parseFinish("1:02", raceMeters: 10_000), 3_720,
                       "62 seconds is no 10K, so this is 1:02:00")
        XCTAssertEqual(BlockCloseout.parseFinish("45:30", raceMeters: 10_000), 2_730)
    }

    func testNonsenseIsRejectedNotGuessed() {
        for bad in ["", "abc", "3:75:00", "3:28:75", "1:02:03:04", "0:00:00", "-3:28:00", "3::15", "12495"] {
            XCTAssertNil(BlockCloseout.parseFinish(bad, raceMeters: marathon), "'\(bad)'")
        }
        XCTAssertNil(BlockCloseout.parseFinish("3:28:15", raceMeters: 5_000),
                     "a 3½-hour 5K is a typo for something else — say so rather than save it")
    }

    // MARK: - The goal patch

    /// Chicago as it will actually be closed: raced, time typed, no race run.
    func testClosingARaceWithNoRunWritesTheTypedTimeAndNoRun() throws {
        let patch = try BlockCloseout.goalPatch(outcome: .raced, finishS: 12_495, raceRunID: nil, now: now)
        XCTAssertFalse(patch.is_active)
        XCTAssertEqual(patch.outcome, "raced")
        XCTAssertEqual(patch.result_time_s, 12_495)
        XCTAssertNil(patch.race_run_id)
        XCTAssertEqual(BlockCloseout.timestamp.date(from: patch.completed_at), now)

        let body = try json(patch)
        XCTAssertEqual(body["is_active"] as? Bool, false)
        XCTAssertEqual(body["result_time_s"] as? Int, 12_495)
        XCTAssertTrue(body["race_run_id"] is NSNull, "written as null, not left out")
    }

    func testClosingWithARaceRunRecordsIt() throws {
        let run = UUID()
        let patch = try BlockCloseout.goalPatch(outcome: .raced, finishS: 12_495, raceRunID: run, now: now)
        XCTAssertEqual(patch.race_run_id, run.uuidString)
    }

    /// Re-closing as "didn't start" after first saving a time must *clear* the time and the
    /// run. A synthesized encoder drops nil keys, which would leave the old time in the row
    /// and trip 0013's `result_time_s … outcome = 'raced'` check.
    func testDidNotStartClearsTimeAndRunExplicitly() throws {
        let patch = try BlockCloseout.goalPatch(outcome: .didNotStart, finishS: 12_495, raceRunID: UUID(), now: now)
        XCTAssertEqual(patch.outcome, "did_not_start")
        XCTAssertNil(patch.result_time_s, "a time typed before switching to DNS is not a result")
        XCTAssertNil(patch.race_run_id)

        let body = try json(patch)
        XCTAssertEqual(Set(body.keys), ["is_active", "completed_at", "outcome", "result_time_s", "race_run_id"])
        XCTAssertTrue(body["result_time_s"] is NSNull)
        XCTAssertTrue(body["race_run_id"] is NSNull)
    }

    func testDNFKeepsNoClock() throws {
        let patch = try BlockCloseout.goalPatch(outcome: .didNotFinish, finishS: 9_000, raceRunID: nil, now: now)
        XCTAssertEqual(patch.outcome, "did_not_finish")
        XCTAssertNil(patch.result_time_s)
    }

    func testRacedWithoutATimeIsRefused() {
        XCTAssertThrowsError(try BlockCloseout.goalPatch(outcome: .raced, finishS: nil, raceRunID: nil, now: now)) {
            XCTAssertEqual($0 as? BlockCloseout.CloseoutError, .missingFinishTime)
        }
        XCTAssertThrowsError(try BlockCloseout.goalPatch(outcome: .raced, finishS: 0, raceRunID: nil, now: now))
    }

    func testOutcomeRawValuesMatchTheCheckConstraint() {
        XCTAssertEqual(BlockCloseout.Outcome.allCases.map(\.rawValue),
                       ["raced", "did_not_start", "did_not_finish", "abandoned"])
        XCTAssertEqual(try json(BlockCloseout.PlanPatch()) as NSDictionary, ["status": "done"])
    }

    // MARK: - Logging the race as a run

    /// Distance comes off the goal, never an assumed 42,195 m; both clocks are the chip time.
    func testRaceRunUsesTheGoalsDistanceAndTheChipTime() {
        let start = Date(timeIntervalSince1970: 1_791_811_800)
        let full = BlockCloseout.raceRun(userID: "u", goalID: goalID, raceName: "Chicago",
                                         start: start, raceMeters: marathon, finishS: 12_495)
        XCTAssertEqual(full.distance_m, 42_195)
        XCTAssertEqual(full.duration_s, 12_495)
        XCTAssertEqual(full.elapsed_duration_s, 12_495)
        XCTAssertEqual(full.avg_pace_sec, 477, "7:57 /mi")
        XCTAssertEqual(full.source, "manual")

        let half = BlockCloseout.raceRun(userID: "u", goalID: goalID, raceName: "Half",
                                         start: start, raceMeters: RaceRecap.raceMeters(goalDistance: "half"), finishS: 5_700)
        XCTAssertEqual(half.distance_m, 21_098)
    }

    /// A retry after a lost response must upsert the same run, not log Chicago twice — the
    /// identity comes from the goal, as `ManualRunIdentity` does for coach-proposed runs.
    func testRaceRunIdentityIsTheGoal() {
        let a = BlockCloseout.raceRun(userID: "u", goalID: goalID, raceName: "Chicago", start: now, raceMeters: marathon, finishS: 12_495)
        let b = BlockCloseout.raceRun(userID: "u", goalID: goalID, raceName: "Chicago", start: now, raceMeters: marathon, finishS: 12_500)
        XCTAssertEqual(a.external_id, b.external_id)
        XCTAssertEqual(a.external_id, "race:2291695A-D680-4A25-A63B-F9E654293288")
        XCTAssertNotEqual(a.external_id, BlockCloseout.raceRunExternalID(goalID: UUID()))
    }

    // MARK: - Against the goal

    func testDeltaUsesTheRaceClockSignConvention() {
        XCTAssertEqual(BlockCloseout.delta(resultS: 11_400, goalS: 11_700), -300, "under goal is negative")
        XCTAssertEqual(BlockCloseout.delta(resultS: 12_495, goalS: 11_700), 795)
        XCTAssertNil(BlockCloseout.delta(resultS: nil, goalS: 11_700), "didn't race, no delta")
        XCTAssertNil(BlockCloseout.delta(resultS: 12_495, goalS: nil))
    }
}
