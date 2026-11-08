import XCTest
@testable import Tempo

/// #226. `RunStore.todayCheckIn` was only ever assigned, never cleared, so a check-in
/// answered yesterday stood in for today's whenever the app survived midnight (iOS
/// permitting, which it is). Today printed "Checked in, good to go", the prompt before a hard
/// session stayed suppressed, readiness kept a stale boolean, and the coach was told
/// yesterday's state was today's. Nothing crashed; from the athlete's side it was invisible.
///
/// Two rules are pinned here, because the bug needed both to be wrong:
///
///  1. **Reading is date-checked**, so a stale value cannot leak even between refreshes.
///  2. **An empty read clears, a failed read does not.** `loadPlan()` is non-destructive on
///     failure by design, and a network blip must not re-prompt the athlete. Post-#224 the
///     read decodes an array, so the two are finally distinguishable.
final class CheckInTodayTests: XCTestCase {

    private func checkIn(_ date: String, feelsOk: Bool = true, note: String? = nil) -> CheckInInfo {
        CheckInInfo(date: date, feels_ok: feelsOk, note: note)
    }

    /// Yesterday through the same formatter the read filters on, so the two cannot disagree
    /// about where the day boundary falls.
    private var yesterdayString: String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: .now)!
        return PlanDates.day.string(from: day)
    }

    // MARK: - Rule 1: reading is date-checked

    func testTodaysCheckInPassesThrough() {
        let today = checkIn("2026-10-29", feelsOk: false, note: "left calf tight")
        let read = CheckInToday.forToday(held: today, today: "2026-10-29")
        XCTAssertEqual(read?.date, "2026-10-29")
        XCTAssertEqual(read?.feelsOk, false)
        XCTAssertEqual(read?.noteText, "left calf tight")
    }

    /// The headline case: the app stayed open past midnight.
    func testYesterdaysCheckInReadsAsNil() {
        XCTAssertNil(CheckInToday.forToday(held: checkIn("2026-10-28"), today: "2026-10-29"))
    }

    func testNothingHeldReadsAsNil() {
        XCTAssertNil(CheckInToday.forToday(held: nil, today: "2026-10-29"))
    }

    /// A date in the future is not today's either. Only reachable by moving the device clock
    /// back, but "equals today" is the rule, not "is not older than today".
    func testTomorrowsCheckInReadsAsNil() {
        XCTAssertNil(CheckInToday.forToday(held: checkIn("2026-10-30"), today: "2026-10-29"))
    }

    /// The boundary runs off `PlanDates.todayString`, the exact string the `check_ins` query
    /// filters on, so the accessor and the read agree on when the day turns over.
    func testTheBoundaryIsPlanDatesTodayString() {
        let today = PlanDates.todayString
        XCTAssertNotNil(CheckInToday.forToday(held: checkIn(today), today: today))
        XCTAssertNil(CheckInToday.forToday(held: checkIn(yesterdayString), today: today))
    }

    // MARK: - Rule 2: an empty read clears, a failed read keeps

    func testADefinitiveEmptyReadClearsWhatIsHeld() {
        XCTAssertNil(CheckInToday.resolve(.rows([]), held: checkIn("2026-10-28")))
    }

    /// A network blip must not blank the answer and ask the athlete again.
    func testAFailedReadKeepsWhatIsHeld() {
        let held = checkIn("2026-10-29", feelsOk: false)
        let kept = CheckInToday.resolve(.unreachable, held: held)
        XCTAssertEqual(kept?.date, "2026-10-29")
        XCTAssertEqual(kept?.feelsOk, false)
    }

    func testARowFromTheServerReplacesWhatIsHeld() {
        let fresh = CheckInToday.resolve(
            .rows([checkIn("2026-10-29", feelsOk: false, note: "slept badly")]),
            held: checkIn("2026-10-28", feelsOk: true)
        )
        XCTAssertEqual(fresh?.date, "2026-10-29")
        XCTAssertEqual(fresh?.feelsOk, false)
        XCTAssertEqual(fresh?.noteText, "slept badly")
    }

    func testAFailedReadWithNothingHeldStaysNil() {
        XCTAssertNil(CheckInToday.resolve(.unreachable, held: nil))
    }

    // MARK: - The two rules together

    /// Why both halves are needed. A failed read at 00:05 keeps yesterday's check-in in the
    /// stored property, which is rule 2 working as intended, and rule 1 is what stops it
    /// reaching a screen or the coach in the meantime.
    func testAKeptStaleValueStillReadsAsNoCheckInToday() {
        let stored = CheckInToday.resolve(.unreachable, held: checkIn("2026-10-28"))
        XCTAssertNotNil(stored, "a failed read is non-destructive")
        XCTAssertNil(
            CheckInToday.forToday(held: stored, today: "2026-10-29"),
            "but nothing reads it as today's"
        )
    }
}
