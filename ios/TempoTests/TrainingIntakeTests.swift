import XCTest
@testable import Tempo

/// The training intake (#102), between ninety seconds of taps and a block the athlete trains
/// on for months.
///
/// Before this, every plan Tempo ever built was a marathon: the `plan` function writes
/// `distance: "marathon"` on every goal it creates, and the schema allowed four races. The
/// intake is what lets a 5K be a 5K, a mid-block athlete start at week 9, and "no plan, just
/// coaching" mean no plan. Each of those can fail without anything crashing — the payload
/// simply arrives without the field, and the block is built for somebody else. These pin
/// what the answers become, field by field, and that the goal they produce survives being
/// read back and regenerated.
///
/// Fixed clock: Monday 2026-10-12, the day David asked for this, in UTC.
final class TrainingIntakeTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ iso: String) -> Date {
        let p = iso.split(separator: "-").map { Int($0)! }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }

    private var today: Date { day("2026-10-12") }

    /// A complete, valid intake: a 5K Turkey Trot six weeks out, full plan.
    private func fiveK() -> IntakeAnswers {
        var a = IntakeAnswers()
        a.distance = .fiveK
        a.raceName = "Turkey Trot"
        a.raceDate = day("2026-11-26")
        a.course = .rolling
        a.goalType = .pr
        a.planStyle = .full
        a.daysPerWeek = 5
        a.longRunDay = 0
        a.focus = [.pacing, .fueling]
        return a
    }

    private func stamp(_ a: IntakeAnswers) -> IntakeStamp? { a.stamp(today: today, calendar: cal) }

    // MARK: - Distance: the label and the number

    /// The headline failure. A 5K intake must leave as a 5K with 5,000 m on it — not as the
    /// marathon every goal has been until now.
    func testAFiveKLeavesAsAFiveKWithItsMetres() throws {
        let s = try XCTUnwrap(stamp(fiveK()))
        XCTAssertEqual(s.distance, "5k")
        XCTAssertEqual(s.distance_m, 5_000)
        let body = PlanRequest.fromIntake(s, goalTimeS: 1_170, raceName: nil, raceDate: s.race_date)
        XCTAssertEqual(body.distance, "5k")
        XCTAssertEqual(body.distance_m, 5_000)
    }

    /// The app's table and the migration's backfill are two copies of one fact. If they
    /// drift, a goal written today and a goal backfilled by 0013 disagree about how long
    /// the same race is.
    func testEveryDistanceMatchesTheMigrationBackfill() {
        let backfill: [String: Int] = [
            "1mi": 1609, "5k": 5000, "10k": 10000, "15k": 15000,
            "10mi": 16093, "half": 21098, "marathon": 42195,
        ]
        for d in IntakeAnswers.Distance.allCases where d != .custom {
            XCTAssertEqual(d.meters, backfill[d.rawValue], "\(d.rawValue) drifted from 0013_training_intake.sql")
        }
        XCTAssertEqual(Set(IntakeAnswers.Distance.allCases.map(\.rawValue)),
                       ["1mi", "5k", "10k", "15k", "10mi", "half", "marathon", "custom"],
                       "the labels are exactly what goals_distance_check allows")
    }

    func testACustomRaceNeedsItsMetresAndCarriesThem() throws {
        var a = fiveK()
        a.distance = .custom
        a.customMeters = nil
        XCTAssertTrue(a.issues(on: .race, today: today, calendar: cal).contains(.customDistanceOutOfRange))
        XCTAssertNil(stamp(a), "a custom race with no distance never reaches the plan engine")

        a.customMeters = 300
        XCTAssertTrue(a.issues(on: .race, today: today, calendar: cal).contains(.customDistanceOutOfRange))

        a.customMeters = 25_000
        let s = try XCTUnwrap(stamp(a))
        XCTAssertEqual(s.distance, "custom")
        XCTAssertEqual(s.distance_m, 25_000)
    }

    // MARK: - Dates

    func testTheRaceDateIsRequiredAndMustBeAhead() {
        var a = fiveK()
        a.raceDate = nil
        XCTAssertEqual(a.issues(on: .race, today: today, calendar: cal), [.raceDateMissing])
        a.raceDate = today
        XCTAssertEqual(a.issues(on: .race, today: today, calendar: cal), [.raceDateNotAhead])
        a.raceDate = day("2026-10-13")
        XCTAssertEqual(a.issues(on: .race, today: today, calendar: cal), [])
    }

    /// `plan` refuses a race whose week index from this Monday is under 2, with a bare 400
    /// after the coach has already proposed the plan. The form says so first — and leaves
    /// the one style that builds nothing ("in 10 days I race a 5K, just coach me") open.
    func testUnderTwoWeeksOutRefusesAPlanButNotCoaching() {
        var a = fiveK()
        a.raceDate = day("2026-10-25")   // Sunday of next week → week index 1
        for style in [IntakeAnswers.PlanStyle.full, .weekly] {
            a.planStyle = style
            XCTAssertEqual(a.issues(on: .plan, today: today, calendar: cal), [.raceTooSoonForPlan], "\(style)")
        }
        a.planStyle = .none
        XCTAssertEqual(a.issues(on: .plan, today: today, calendar: cal), [])

        a.planStyle = .full
        a.raceDate = day("2026-10-26")   // Monday two weeks on → week index 2, what `plan` accepts
        XCTAssertEqual(a.issues(on: .plan, today: today, calendar: cal), [])
    }

    func testTheRaceDateIsStoredAsTheCalendarDay() throws {
        XCTAssertEqual(try XCTUnwrap(stamp(fiveK())).race_date, "2026-11-26")
    }

    // MARK: - Goal type

    func testATimeGoalNeedsAPlausibleTime() throws {
        var a = fiveK()
        a.goalType = .time
        a.goalTimeSeconds = nil
        XCTAssertEqual(a.issues(on: .race, today: today, calendar: cal), [.goalTimeMissing])

        a.goalTimeSeconds = 5 * 60          // a 5K in 5:00 is a typo
        XCTAssertEqual(a.issues(on: .race, today: today, calendar: cal), [.goalTimeImplausible])

        a.distance = .mile
        a.goalTimeSeconds = 2 * 60          // so is a 2:00 mile
        XCTAssertEqual(a.issues(on: .race, today: today, calendar: cal), [.goalTimeImplausible])

        a.distance = .marathon
        a.goalTimeSeconds = 11_700          // 3:15:00
        XCTAssertEqual(a.issues(on: .race, today: today, calendar: cal), [])
        XCTAssertEqual(try XCTUnwrap(stamp(a)).stated_goal_time_s, 11_700)
    }

    /// A time typed in, then the goal switched to "just finish": the stale time must not ride
    /// along as if it were stated.
    func testOnlyATimeGoalStatesATime() throws {
        var a = fiveK()
        a.goalTimeSeconds = 1_170
        a.goalType = .finish
        let s = try XCTUnwrap(stamp(a))
        XCTAssertNil(s.stated_goal_time_s)
        XCTAssertEqual(s.goal_type, "finish")
    }

    // MARK: - Mid-block

    /// "I'm in week 9" is the whole point of the mid-block import. Dropped, the plan
    /// restarts the athlete at week 1 of a block they are halfway through.
    func testMidBlockCarriesTheWeekAndTheVolume() throws {
        var a = fiveK()
        a.situation = .midBlock
        a.startedWeek = nil
        XCTAssertEqual(a.issues(on: .race, today: today, calendar: cal), [.startedWeekMissing])
        a.startedWeek = 9
        a.currentWeeklyMiles = 32
        let s = try XCTUnwrap(stamp(a))
        XCTAssertEqual(s.started_week, 9)
        XCTAssertEqual(s.start_mileage, 32)
        let body = PlanRequest.fromIntake(s, goalTimeS: 1_170, raceName: nil, raceDate: s.race_date)
        XCTAssertEqual(body.started_week, 9)
    }

    /// Mid-block toggled on, a week filled in, then toggled back to a fresh block.
    func testAFreshBlockNeverCarriesAStartWeek() throws {
        var a = fiveK()
        a.startedWeek = 9
        a.currentWeeklyMiles = 32
        let s = try XCTUnwrap(stamp(a))
        XCTAssertNil(s.started_week)
        XCTAssertNil(s.start_mileage)
    }

    func testMidBlockWeekAndVolumeAreBounded() {
        var a = fiveK()
        a.situation = .midBlock
        a.startedWeek = 0
        XCTAssertEqual(a.issues(on: .race, today: today, calendar: cal), [.startedWeekOutOfRange])
        a.startedWeek = 9
        a.currentWeeklyMiles = 500
        XCTAssertEqual(a.issues(on: .race, today: today, calendar: cal), [.weeklyMilesOutOfRange])
    }

    // MARK: - Preferences

    /// The 20+ question belongs to the half and the marathon, and only when there's a plan
    /// to put the runs in. A 5K with `long_runs_20plus: 3` would be a hard constraint on
    /// something nobody asked for.
    func testLongRunCountOnlyForHalfAndMarathonWithAPlan() throws {
        var a = fiveK()
        a.longRunCount = 3
        XCTAssertNil(try XCTUnwrap(stamp(a)).preferences.long_runs_20plus, "5K")

        a.distance = .marathon
        XCTAssertEqual(try XCTUnwrap(stamp(a)).preferences.long_runs_20plus, 3)
        XCTAssertEqual(IntakeAnswers.Distance.marathon.longRunThresholdMiles, 20)

        a.distance = .half
        a.longRunCount = 4
        XCTAssertEqual(try XCTUnwrap(stamp(a)).preferences.long_runs_20plus, 4)
        XCTAssertEqual(IntakeAnswers.Distance.half.longRunThresholdMiles, 12, "the half's equivalent, per #104")

        a.planStyle = .none
        XCTAssertNil(try XCTUnwrap(stamp(a)).preferences.long_runs_20plus, "no plan, no long-run quota")
    }

    func testNoPlanPrescribesNoWorkouts() throws {
        var a = fiveK()
        a.quality = [.hills, .intervals]
        XCTAssertEqual(try XCTUnwrap(stamp(a)).preferences.quality, ["intervals", "hills"])
        a.planStyle = .none
        let s = try XCTUnwrap(stamp(a))
        XCTAssertEqual(s.preferences.quality, [])
        XCTAssertEqual(s.preferences.plan_style, "none")
    }

    /// Six distinct keys (David, 2026-10-12), so the coach can weight recovery, strength and
    /// mental game separately though the form groups them. Order is fixed, not Set order, so
    /// the same answers always produce the same payload.
    func testFocusIsSixDistinctKeysInAFixedOrder() throws {
        XCTAssertEqual(IntakeAnswers.Focus.allCases.map(\.rawValue),
                       ["fueling", "pacing", "race_day", "recovery", "strength", "mental"])
        var a = fiveK()
        a.focus = [.mental, .raceDay, .fueling]
        XCTAssertEqual(try XCTUnwrap(stamp(a)).preferences.focus, ["fueling", "race_day", "mental"])
    }

    func testNotesAreTrimmedAndBlankMeansNone() throws {
        var a = fiveK()
        a.notes = "  \n "
        XCTAssertNil(try XCTUnwrap(stamp(a)).preferences.notes)
        a.notes = "  Achilles flared in March.\n"
        XCTAssertEqual(try XCTUnwrap(stamp(a)).preferences.notes, "Achilles flared in March.")
    }

    /// The jsonb shape #104 reads: `{v:1, plan_style, long_runs_20plus, course_type,
    /// focus:[...], quality:[...], notes}`.
    func testPreferencesEncodeToTheVersionedShape() throws {
        var a = fiveK()
        a.distance = .marathon
        a.quality = [.tempo]
        a.notes = "Travel in week 6"
        let prefs = try XCTUnwrap(stamp(a)).preferences
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as? [String: Any])
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["plan_style"] as? String, "full")
        XCTAssertEqual(json["long_runs_20plus"] as? Int, 3)
        XCTAssertEqual(json["course_type"] as? String, "rolling")
        XCTAssertEqual(json["focus"] as? [String], ["fueling", "pacing"])
        XCTAssertEqual(json["quality"] as? [String], ["tempo"])
        XCTAssertEqual(json["notes"] as? String, "Travel in week 6")
        XCTAssertEqual(Set(json.keys), ["v", "plan_style", "long_runs_20plus", "course_type", "focus", "quality", "notes"])
    }

    func testJustRunningSavesNothing() {
        var a = fiveK()
        a.situation = .justRunning
        XCTAssertNil(stamp(a))
        XCTAssertTrue(IntakeHandoff(answers: a, stamp: nil).sentToCoach, "nothing to send the coach either")
    }

    // MARK: - Profile half

    /// Days, long-run day, strength and risk are read by `plan` from the profile, so they
    /// are written there — at Confirm, from the card, never at form submit.
    func testTheProfilePatchCarriesTheFormsSettings() throws {
        var a = fiveK()
        a.daysPerWeek = 4
        a.longRunDay = 6
        a.wantsStrength = true
        a.risk = .ambitious
        XCTAssertEqual(try XCTUnwrap(stamp(a)).profilePatch,
                       .init(days_per_week: 4, long_run_day: 6, wants_strength: true, risk_tolerance: "ambitious"))
    }

    func testTheProfileSeedIsClampedToWhatTheSchemaAllows() {
        let a = IntakeAnswers(daysPerWeek: 9, longRunDay: -1, risk: "reckless")
        XCTAssertEqual(a.daysPerWeek, 7)
        XCTAssertEqual(a.longRunDay, 0)
        XCTAssertEqual(a.risk, .standard)
    }

    // MARK: - The plan request

    /// The coach's proposal wins on the goal itself; the athlete's taps win on everything
    /// else. A race name the coach left out falls back to the one typed in the form.
    func testTheCoachsGoalAndTheAthletesEverythingElse() throws {
        let s = try XCTUnwrap(stamp(fiveK()))
        let body = PlanRequest.fromIntake(s, goalTimeS: 1_140, raceName: nil, raceDate: "2026-11-26")
        XCTAssertEqual(body.goal_time_s, 1_140)
        XCTAssertEqual(body.race_name, "Turkey Trot")
        XCTAssertEqual(body.course_type, "rolling")
        XCTAssertEqual(body.goal_type, "pr")
        XCTAssertEqual(body.preferences, s.preferences)
    }

    /// Until #104 deploys, `plan` reads three keys. A request that isn't from the intake must
    /// send exactly those three, not three plus a row of nulls.
    func testABareRequestIsTheBodyPlanAlwaysGot() throws {
        let body = PlanRequest(goal_time_s: 11_700, race_name: "Chicago", race_date: "2026-10-11")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["goal_time_s", "race_name", "race_date"])
    }

    // MARK: - Regeneration keeps the block

    private func goal(raceDate: String = "2026-11-26", startedWeek: Int? = 9) -> GoalInfo {
        GoalInfo(
            id: UUID(), race_name: "Turkey Trot", race_date: raceDate, goal_time_seconds: 1_170,
            distance: "5k", distance_m: 5_000, course_type: "hilly", goal_type: "pr",
            started_week: startedWeek,
            preferences: GoalPreferences(plan_style: "weekly", course_type: "hilly", focus: ["fueling"], quality: [])
        )
    }

    /// `plan` writes a fresh goal row on every run. "Drop me to 4 days" regenerates it — and
    /// without this, the regenerated goal is a marathon with no preferences.
    func testASettingsRegenerationKeepsTheRaceAndAdvancesTheWeek() {
        let body = PlanRequest.carryingForward(
            goal: goal(), planStartDate: "2026-09-21",
            goalTimeS: 1_170, raceName: "Turkey Trot", raceDate: "2026-11-26",
            today: today, calendar: cal
        )
        XCTAssertEqual(body.distance, "5k")
        XCTAssertEqual(body.distance_m, 5_000)
        XCTAssertEqual(body.course_type, "hilly")
        XCTAssertEqual(body.preferences?.plan_style, "weekly")
        XCTAssertEqual(body.started_week, 12, "week 9 on Sep 21 is week 12 three Mondays later")
    }

    func testARegenerationTheSameWeekKeepsTheSameWeek() {
        let body = PlanRequest.carryingForward(
            goal: goal(), planStartDate: "2026-10-12",
            goalTimeS: 1_170, raceName: nil, raceDate: "2026-11-26", today: day("2026-10-15"), calendar: cal
        )
        XCTAssertEqual(body.started_week, 9)
    }

    func testABlockStartedAtWeekOneStaysUnset() {
        let body = PlanRequest.carryingForward(
            goal: goal(startedWeek: nil), planStartDate: "2026-09-21",
            goalTimeS: 1_170, raceName: nil, raceDate: "2026-11-26", today: today, calendar: cal
        )
        XCTAssertNil(body.started_week)
        XCTAssertEqual(body.distance, "5k")
    }

    /// A new race date agreed in chat is a different race. Its distance and course are not
    /// known here, so it goes out bare rather than inheriting the old race's.
    func testANewRaceDateDoesNotInheritTheOldRace() throws {
        let body = PlanRequest.carryingForward(
            goal: goal(), planStartDate: "2026-09-21",
            goalTimeS: 11_700, raceName: "CIM", raceDate: "2026-12-06", today: today, calendar: cal
        )
        XCTAssertEqual(body, PlanRequest(goal_time_s: 11_700, race_name: "CIM", race_date: "2026-12-06"))
    }

    func testNoGoalMeansABareRequest() {
        let body = PlanRequest.carryingForward(
            goal: nil, planStartDate: nil, goalTimeS: 11_700, raceName: nil, raceDate: "2026-12-06",
            today: today, calendar: cal
        )
        XCTAssertEqual(body, PlanRequest(goal_time_s: 11_700, race_name: nil, race_date: "2026-12-06"))
    }

    // MARK: - Reading the goal back

    /// The app ships before 0013 is applied, and the goal query is `select *`. A row with
    /// none of the new columns must decode exactly as it did — a goal that fails to decode is,
    /// on every screen, no goal at all.
    func testAGoalFromBeforeTheMigrationStillDecodes() throws {
        let g = try JSONDecoder().decode(GoalInfo.self, from: Data("""
        {"id":"2291695A-D680-4A25-A63B-F9E654293288","race_name":"Chicago","race_date":"2026-10-11",
         "goal_time_seconds":11700,"distance":"marathon","days_per_week":6,"is_active":true}
        """.utf8))
        XCTAssertEqual(g.goalTimeSeconds, 11_700)
        XCTAssertEqual(g.distance, "marathon")
        XCTAssertNil(g.preferences)
        XCTAssertNil(GoalDetailCoachContext(g), "a pre-intake goal tells the coach nothing it didn't say")
    }

    /// jsonb has more than one writer. A preferences blob in a shape this build doesn't know
    /// loses the preferences — not the goal.
    func testMalformedPreferencesCostThePreferencesNotTheGoal() throws {
        let g = try JSONDecoder().decode(GoalInfo.self, from: Data("""
        {"id":"2291695A-D680-4A25-A63B-F9E654293288","race_name":"Turkey Trot","race_date":"2026-11-26",
         "goal_time_seconds":1170,"distance":"5k","distance_m":5000,"course_type":"rolling",
         "goal_type":"pr","started_week":null,"preferences":{"v":"one","focus":"fueling"}}
        """.utf8))
        XCTAssertEqual(g.raceName, "Turkey Trot")
        XCTAssertEqual(g.distance_m, 5_000)
        XCTAssertNil(g.preferences)
        XCTAssertEqual(GoalDetailCoachContext(g)?.course_type, "rolling")
    }

    func testAnIntakeGoalShowsTheCoachItsFocus() throws {
        let g = try JSONDecoder().decode(GoalInfo.self, from: Data("""
        {"id":"2291695A-D680-4A25-A63B-F9E654293288","race_name":"Turkey Trot","race_date":"2026-11-26",
         "goal_time_seconds":1170,"distance":"5k","distance_m":5000,
         "preferences":{"v":1,"plan_style":"none","focus":["fueling","mental"],"quality":[]}}
        """.utf8))
        let detail = try XCTUnwrap(GoalDetailCoachContext(g))
        XCTAssertEqual(detail.preferences?.focus, ["fueling", "mental"])
        XCTAssertEqual(detail.preferences?.plan_style, "none")
    }

    // MARK: - The card

    private func action(_ json: String) throws -> ProposedAction {
        try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
    }

    /// Only create_plan gets the intake: it is the one write that is the intake's write.
    func testOnlyACreatePlanCardIsStamped() throws {
        let handoff = IntakeHandoff(answers: fiveK(), stamp: stamp(fiveK()))
        let plan = try action(#"{"type":"create_plan","goal_time_s":1140,"race_date":"2026-11-26","summary":"Build my plan"}"#)
        let session = try action(#"{"type":"update_session","session_id":"x","summary":"Move it"}"#)

        XCTAssertEqual(IntakeHandoff.stamping(plan, with: handoff).intake, handoff.stamp)
        XCTAssertNil(IntakeHandoff.stamping(session, with: handoff).intake)
        XCTAssertNil(IntakeHandoff.stamping(plan, with: nil).intake, "no intake in flight, nothing to attach")
    }

    /// A card from an earlier intake keeps its own answers even if a newer intake is in flight.
    func testAStampedCardKeepsItsOwnIntake() throws {
        var older = fiveK()
        older.distance = .tenK
        let first = try XCTUnwrap(stamp(older))
        var plan = try action(#"{"type":"create_plan","goal_time_s":2400,"race_date":"2026-11-26"}"#)
        plan.intake = first
        let newer = IntakeHandoff(answers: fiveK(), stamp: stamp(fiveK()))
        XCTAssertEqual(IntakeHandoff.stamping(plan, with: newer).intake?.distance, "10k")
    }

    /// The card is persisted in `coach_messages.proposed_action`. A relaunch must bring the
    /// intake back with it, and every card written before #102 must still decode.
    func testTheIntakeSurvivesTheCardsRoundTripThroughJsonb() throws {
        var plan = try action(#"{"type":"create_plan","goal_time_s":1140,"race_date":"2026-11-26"}"#)
        plan.intake = stamp(fiveK())
        let reheated = try JSONDecoder().decode(ProposedAction.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(reheated, plan)
        XCTAssertEqual(reheated.intake?.distance_m, 5_000)

        let legacy = try action(#"{"type":"create_plan","goal_time_s":11700,"race_date":"2026-10-11","race_name":"Chicago"}"#)
        XCTAssertNil(legacy.intake)
    }

    // MARK: - What the coach is shown

    func testTheTranscriptTurnSaysWhatWasAskedFor() {
        var a = fiveK()
        a.situation = .midBlock
        a.startedWeek = 9
        a.currentWeeklyMiles = 31.6
        a.notes = "Wedding in week 6"
        let line = a.transcriptLine(calendar: cal)
        for expected in ["5K", "Turkey Trot", "Thu Nov 26, 2026", "rolling", "a pr", "week 9", "~32 mi",
                         "full day-by-day plan", "5 days a week", "long run Sunday",
                         "fueling & nutrition, pacing & workouts", "Wedding in week 6"] {
            XCTAssertTrue(line.contains(expected), "missing “\(expected)” in:\n\(line)")
        }
        XCTAssertFalse(line.contains("20+"), "no long-run quota on a 5K")
    }

    func testAShortGoalTimeReadsAsMinutes() {
        XCTAssertEqual(IntakeAnswers.finishTime(1_170), "19:30")
        XCTAssertEqual(IntakeAnswers.finishTime(11_700), "3:15:00")
    }

    func testTheCoachContextNamesTheLongRunThreshold() throws {
        var a = fiveK()
        a.distance = .marathon
        a.goalType = .time
        a.goalTimeSeconds = 11_700
        let ctx = IntakeCoachContext(try XCTUnwrap(stamp(a)), situation: a.situation)
        XCTAssertEqual(ctx.long_runs_at_threshold, 3)
        XCTAssertEqual(ctx.long_run_threshold_mi, 20)
        XCTAssertEqual(ctx.stated_goal_time, "3:15:00")
        XCTAssertEqual(ctx.long_run_day, "Sunday")
        XCTAssertEqual(ctx.situation, "new_block")
    }
}
