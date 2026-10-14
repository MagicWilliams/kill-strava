import XCTest
@testable import Tempo

/// The mi/km switch on the You tab (#109). #108 added the preference and `Units`; this is
/// every screen, the widgets and the coach actually reading it.
///
/// Almost all of the app's numbers are held in miles (`RunSummary.miles`, plan targets,
/// whole seconds per mile) and stay that way; `UnitsDisplay` converts at the edge. What can
/// go wrong is the usual thing for this codebase: a number that is plausible and wrong. A km
/// pace computed from an already-truncated mile pace, a "32+ km" tile counting against
/// 32.19 km, a widget written before the unit existed that no longer decodes. Each of those
/// is pinned here.
final class UnitsDisplayTests: XCTestCase {

    // MARK: - Mile figures in, the athlete's unit out

    func testAMileFigureConvertsWithoutRounding() {
        // A marathon as the engine holds it, back out in both units.
        XCTAssertEqual(Units.km.distance(miles: 26.2188), 42.195, accuracy: 1e-3)
        XCTAssertEqual(Units.km.formatDistance(miles: 26.2188), "42.2 km")
        XCTAssertEqual(Units.mi.formatDistance(miles: 26.2188), "26.2 mi")
        // Through miles and back to metres is the metres it started as.
        XCTAssertEqual(Units.km.distance(miles: 8_046.7 / Units.metersPerMile), 8.0467, accuracy: 1e-12)
        XCTAssertEqual(Units.km.number(miles: 34.6), "55.7")
        XCTAssertEqual(Units.mi.number(miles: 34.6), "34.6")
        XCTAssertEqual(Units.km.number(meters: 8_046.7, decimals: 2), "8.05")
    }

    func testAPlanPaceInSecondsPerMileReadsInEitherUnit() {
        XCTAssertEqual(Units.mi.formatPace(secondsPerMile: 420), "7:00 /mi")
        XCTAssertEqual(Units.km.formatPace(secondsPerMile: 420), "4:21 /km")
        XCTAssertEqual(Units.km.clock(secondsPerMile: 420), "4:21")
    }

    // MARK: - A run's pace

    /// In miles the label is exactly `TimeAccounting.paceSecPerMile`, the figure the records
    /// rank on, so nothing David has been reading moves when this ships. `runPace` restates
    /// the rule for the widget target's sake; this keeps the two from drifting.
    func testMilePaceIsTheSameNumberTimeAccountingGives() {
        for (seconds, meters) in [(2_908, 10_000), (1_500, 5_000), (3_600, 16_093), (60, 81), (60, 80), (0, 5_000)] {
            let expected = TimeAccounting.paceSecPerMile(seconds: seconds, miles: Double(meters) / Units.metersPerMile)
            XCTAssertEqual(Units.mi.runPace(movingSeconds: seconds, meters: meters), expected.map(Double.init),
                           "\(seconds) s over \(meters) m")
        }
    }

    /// 10 km in 48:28 is 4:50.8 /km, so "4:51 /km". The mile pace truncates to 7:47
    /// (467 s); converting *that* gives 290.18 s, "4:50". The km label has to come from the
    /// run's own metres and seconds, or every km pace carries the mile's truncation.
    func testAKmRunPaceComesFromMetresNotFromTheTruncatedMilePace() throws {
        let pace = try XCTUnwrap(Units.km.runPace(movingSeconds: 2_908, meters: 10_000))
        XCTAssertEqual(Units.km.formatPace(pace), "4:51 /km")
        XCTAssertEqual(Units.mi.formatRunPace(movingSeconds: 2_908, meters: 10_000), "7:47 /mi")

        let viaMiles = Units.km.formatPace(secondsPerMile: try XCTUnwrap(
            TimeAccounting.paceSecPerMile(seconds: 2_908, miles: 10_000 / Units.metersPerMile)))
        XCTAssertEqual(viaMiles, "4:50 /km", "the trap this test exists for")
        XCTAssertEqual(Units.km.formatRunPace(movingSeconds: 60, meters: 50), "—", "under 0.05 mi has no pace")
    }

    // MARK: - Thresholds, bands and words

    /// The issue's own example: 20 mi long runs are "32+ km". Rounded down, so the km label
    /// never asks for more than the mile bar does; the half's 12 mi is "19+ km".
    func testLongRunThresholdsReadAsRoundKilometres() {
        XCTAssertEqual(Units.mi.longRunThresholdLabel, "20+ mi")
        XCTAssertEqual(Units.km.longRunThresholdLabel, "32+ km")
        XCTAssertEqual(Units.mi.longRunThresholdLabel(miles: 12), "12+ mi")
        XCTAssertEqual(Units.km.longRunThresholdLabel(miles: 12), "19+ km")
    }

    /// The 3-mile records band stays 3 miles; in km it says what that is rather than
    /// rounding itself into a 5K it isn't. The race-named bands don't change.
    func testTheThreeMileBandSaysItsLengthInKm() {
        XCTAssertEqual(RunHistory.Band.threeMile.label(.mi), "3 mi+")
        XCTAssertEqual(RunHistory.Band.threeMile.label(.km), "4.8 km+")
        XCTAssertEqual(RunHistory.Band.tenK.label(.km), "10K+")
        XCTAssertEqual(RunHistory.Band.half.label(.mi), "Half+")
    }

    func testElevationAndSpeedFollowTheDistanceUnit() {
        XCTAssertEqual(Units.mi.formatElevation(meters: 120), "394 ft")
        XCTAssertEqual(Units.km.formatElevation(meters: 120), "120 m")
        XCTAssertEqual(Units.mi.formatSpeed(milesPerHour: 7.5), "7.5 mph")
        XCTAssertEqual(Units.km.formatSpeed(milesPerHour: 7.5), "12.1 km/h")
    }

    func testTheWordsThatNameAUnitChangeWithIt() {
        XCTAssertEqual(Units.mi.weeklyVolumeTitle, "Weekly mileage")
        XCTAssertEqual(Units.km.weeklyVolumeTitle, "Weekly distance")
        XCTAssertEqual(Units.mi.tileName, "miles")
        XCTAssertEqual(Units.km.tileName, "km")
    }

    // MARK: - Block Review: the 32+ km tile counts 32 km

    /// A km athlete's long run is 32.0 km. Counted against 20 mi (32,186 m) it would miss a
    /// tile labelled "32+ km" by 186 m. The tile counts against its own label; what the coach
    /// is told (`runs_20_plus`) stays the 20-mile count.
    func testTheKmLongRunTileCountsThirtyTwoKilometres() {
        let cal = Calendar.current
        let start = PlanDates.day.date(from: "2026-06-22")!
        let race = PlanDates.day.date(from: "2026-10-11")!
        func run(_ iso: String, _ meters: Int) -> RunSummary {
            RunSummary(id: UUID(), start: cal.date(byAdding: .hour, value: 7, to: PlanDates.day.date(from: iso)!)!,
                       distanceM: meters, durationS: meters / 3, avgHR: nil)
        }
        let r = BlockReview.review(
            runs: [run("2026-09-06", 32_000), run("2026-09-13", 31_999), run("2026-09-20", 32_186)],
            planStart: start, raceDay: race, raceMeters: RaceRecap.marathonMeters,
            planWeeks: [], sessions: [], calendar: cal
        )
        XCTAssertEqual(r.longRunCount(.mi), 1, "only the 20-miler")
        XCTAssertEqual(r.longRunCount(.km), 2, "32.0 km and the 20-miler; 31,999 m is not 32 km")
        XCTAssertEqual(r.twentyPlusCount, 1, "the coach's number does not move with the display unit")
    }

    // MARK: - Transcript lines written in the athlete's unit

    func testTheIntakeTurnIsWrittenInKmForAKmAthlete() {
        var a = IntakeAnswers()
        a.distance = .marathon
        a.situation = .midBlock
        a.startedWeek = 9
        a.currentWeeklyMiles = 31.6
        a.planStyle = .full
        a.longRunCount = 4
        let km = a.transcriptLine(calendar: .current, units: .km)
        XCTAssertTrue(km.contains("~51 km a week"), km)
        XCTAssertTrue(km.contains("4× 32+ km"), km)
        XCTAssertNil(km.range(of: #"\bmi\b"#, options: .regularExpression), km)
        let mi = a.transcriptLine(calendar: .current)
        XCTAssertTrue(mi.contains("~32 mi a week") && mi.contains("4× 20+ mi"), mi)
    }

    func testTheWeeklyVolumeErrorSaysTheBoundInTheUnitTyped() {
        let issue = IntakeAnswers.Issue.weeklyMilesOutOfRange
        XCTAssertEqual(issue.message(.mi), issue.message)
        XCTAssertEqual(issue.message(.km), "Weekly km should be between 0 and 321.")
        XCTAssertEqual(IntakeAnswers.Issue.raceDateMissing.message(.km), IntakeAnswers.Issue.raceDateMissing.message)
    }

    func testPlanIsLiveSaysTheVolumeInTheAthletesUnit() {
        let result = PlanNarration.PlanResult(weeks: 16, archetype: "base_build", rationale: nil,
                                              projectedFinishSeconds: nil, startWeeklyMiles: 22.4, peakWeeklyMiles: 45.6)
        XCTAssertEqual(PlanNarration.planIsLive(result, units: .km), "Plan is live: 16 weeks (base build). Volume runs 36 → 73 km/wk.")
        XCTAssertEqual(PlanNarration.planIsLive(result), "Plan is live: 16 weeks (base build). Volume runs 22 → 46 mi/wk.")
    }

    func testTheChangeLedgerPrintsDistancesAndPacesInTheAthletesUnit() throws {
        let action = try JSONDecoder().decode(ProposedAction.self, from: Data("""
            {"type":"update_session","session_id":"\(UUID().uuidString)","target_distance_m":16093,"target_pace_sec":420}
            """.utf8))
        let record = ChangeLedger.Record(messageID: UUID(), date: .now, text: "", action: action)
        let km = try XCTUnwrap(ChangeLedger.entries(from: [record], units: .km).first)
        XCTAssertEqual(km.beforeAfter, "Distance 16.09 km · Pace 4:21 /km")
        let mi = try XCTUnwrap(ChangeLedger.entries(from: [record]).first)
        XCTAssertEqual(mi.beforeAfter, "Distance 10.00 mi · Pace 7:00 /mi")
    }

    // MARK: - Widgets

    /// The widget prints the unit the snapshot carries. A snapshot written by a build
    /// before #109 has no unit at all and must still decode, as miles: a snapshot that fails
    /// to decode is a widget that says "Open Tempo" until the next refresh.
    func testTheWidgetSnapshotCarriesTheUnitAndOldSnapshotsStillDecode() throws {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let km = WidgetSnapshot.build(now: now, runs: [.init(start: now, miles: 5)], sessions: [],
                                      weekTargetMiles: 40, nextWeekTargetMiles: nil, coachLine: nil,
                                      previous: nil, units: .km)
        XCTAssertEqual(km.units, "km")
        guard case .current(let week) = WidgetSnapshot.display(km, at: now) else { return XCTFail("not current") }
        XCTAssertEqual(week.units, .km)
        XCTAssertEqual(week.miles, 5, accuracy: 1e-9, "the snapshot still counts in miles")

        let legacy = WidgetSnapshot(generatedAt: now, weekStart: km.weekStart, dayMiles: km.dayMiles,
                                    lastWeekMiles: 0, weekTargetMiles: nil, nextWeekTargetMiles: nil,
                                    upcoming: [], coach: nil)
        let legacyJSON = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: legacyJSON, as: UTF8.self).contains("units"), "the pre-#109 shape")
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: legacyJSON).displayUnits, .mi)

        let unknown = String(decoding: try JSONEncoder().encode(km), as: UTF8.self)
            .replacingOccurrences(of: "\"km\"", with: "\"furlongs\"")
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: Data(unknown.utf8)).displayUnits, .mi,
                       "a unit this build doesn't know reads as miles, not as a decode failure")
    }
}
