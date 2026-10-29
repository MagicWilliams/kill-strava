import XCTest
@testable import Tempo

/// The fitness estimate is the number the Drift Detector measures (#244, PRD-02 item #2).
/// Every past engine bug on this board corrupted a number on screen without crashing, and
/// this one would do it worse: a quiet error here reads as drift, and drift is the verdict.
///
/// The fixtures are the 21 named in `docs/spike-fitness-formula.md` ("Test fixtures"),
/// plus the sparse-block case added at calibration. "Unchanged" means within 0.01 VDOT.
/// All athletes here are synthetic: easy running at 9:30/mi, quality work near VDOT 45.
final class FitnessEstimateTests: XCTestCase {

    // MARK: - Fixture plumbing

    /// Fixed calendar + fixed "now" so nothing here depends on when the suite runs.
    private let cal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var asOf: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 27; c.hour = 12
        return cal.date(from: c)!
    }

    private func daysAgo(_ n: Int, from base: Date? = nil) -> Date {
        cal.date(byAdding: .day, value: -n, to: base ?? asOf)!
    }

    private let easyPace = 570   // 9:30/mi: the median every fixture classifies against

    /// A run raced at `vdot` over `meters`, with the duration the formula says it took.
    private func quality(_ ago: Int, vdot: Double, meters: Int = 10_000,
                         rpe: Int? = nil, avgHR: Int? = nil) -> RunSummary {
        let s = FitnessEstimate.finishSeconds(vdot: vdot, meters: Double(meters))
        var r = RunSummary(id: UUID(), start: daysAgo(ago), distanceM: meters,
                           durationS: Int(s.rounded()), avgHR: avgHR)
        r.journal.rpe = rpe
        return r
    }

    private func easy(_ ago: Int, miles: Double = 5, pace: Int? = nil) -> RunSummary {
        RunSummary(id: UUID(), start: daysAgo(ago), distanceM: Int(miles * 1609.34),
                   durationS: Int(miles * Double(pace ?? easyPace)), avgHR: nil)
    }

    /// Five easy runs, enough for a baseline at exactly `easyPace`.
    private func easyBase(_ days: [Int] = [2, 4, 6, 9, 11, 13]) -> [RunSummary] {
        days.map { easy($0) }
    }

    /// Fixture 4's block: 8 weeks, one 10K-ish quality run a week near VDOT 45 (±0.3),
    /// four easy runs around each. Top three: 45.3 (day 29), 45.2 (day 8), 45.1 (day 43).
    private let steadyQuality: [(ago: Int, vdot: Double)] = [
        (1, 45.0), (8, 45.2), (15, 44.8), (22, 44.9), (29, 45.3), (36, 44.7), (43, 45.1), (50, 45.0),
    ]

    private func steadyBlock(maxQualityAgo: Int = 50) -> [RunSummary] {
        var runs: [RunSummary] = []
        for q in steadyQuality where q.ago <= maxQualityAgo {
            runs.append(quality(q.ago, vdot: q.vdot))
            for offset in [1, 2, 4, 5] { runs.append(easy(q.ago + offset)) }
        }
        return runs
    }

    private func estimate(_ runs: [RunSummary], efforts: [UUID: [BestEfforts.Effort]] = [:],
                          asOf when: Date? = nil, maxHR: Int? = nil) -> FitnessEstimate.Result {
        FitnessEstimate.estimate(runs: runs, efforts: efforts, asOf: when ?? asOf,
                                 measuredMaxHR: maxHR, calendar: cal)
    }

    private func reading(_ result: FitnessEstimate.Result,
                         file: StaticString = #filePath, line: UInt = #line) -> FitnessEstimate.Reading? {
        guard case .reading(let r) = result else {
            XCTFail("expected a reading, got \(result)", file: file, line: line)
            return nil
        }
        return r
    }

    private func hms(_ h: Int, _ m: Int, _ s: Int) -> Double { Double(h * 3600 + m * 60 + s) }

    // MARK: - 1. Formula pins

    func testFormulaPinsTheSpikesTwoReferenceEfforts() {
        XCTAssertEqual(FitnessEstimate.vdot(meters: 5_000, seconds: 1_200), 49.8, accuracy: 0.01)
        XCTAssertEqual(FitnessEstimate.vdot(meters: 10_000, seconds: 2_700), 45.26, accuracy: 0.005)
    }

    /// The Daniels–Gilbert equations against the printed VDOT 50 row of *Daniels' Running
    /// Formula*: 19:57 / 41:21 / 1:31:35 / 3:10:49. The equations give 19:56 / 41:20 /
    /// 1:31:31 / 3:10:40 — the table rounds from a slightly different solve, which is why
    /// the pin is 0.25% and not one second.
    func testVDOTFiftyMatchesThePublishedRowWithinAQuarterPercent() {
        let row: [(meters: Double, table: Double, formula: Double)] = [
            (5_000, hms(0, 19, 57), hms(0, 19, 56)),
            (10_000, hms(0, 41, 21), hms(0, 41, 20)),
            (21_097.5, hms(1, 31, 35), hms(1, 31, 31)),
            (42_195, hms(3, 10, 49), hms(3, 10, 40)),
        ]
        for cell in row {
            let t = FitnessEstimate.finishSeconds(vdot: 50, meters: cell.meters)
            XCTAssertEqual(t, cell.table, accuracy: cell.table * 0.0025, "\(cell.meters) m vs the table")
            XCTAssertEqual(t.rounded(), cell.formula, accuracy: 0.5, "\(cell.meters) m vs the equations")
        }
    }

    /// A second row, at the slow end where Riegel and VDOT part ways: VDOT 30 is printed as
    /// 30:40 / 63:46 / 2:21:04 / 4:49:17.
    func testVDOTThirtyMatchesThePublishedRowWithinAQuarterPercent() {
        let row: [(meters: Double, table: Double)] = [
            (5_000, hms(0, 30, 40)), (10_000, hms(1, 3, 46)),
            (21_097.5, hms(2, 21, 4)), (42_195, hms(4, 49, 17)),
        ]
        for cell in row {
            let t = FitnessEstimate.finishSeconds(vdot: 30, meters: cell.meters)
            XCTAssertEqual(t, cell.table, accuracy: cell.table * 0.0025, "\(cell.meters) m")
        }
    }

    // MARK: - 2. Round trip

    func testFinishInvertsVDOTToTheSecondFromFiveKToTheMarathon() {
        let cases: [(Double, Double)] = [
            (5_000, 1_200), (5_000, 1_800), (10_000, 2_700), (10_000, 3_900),
            (21_097.5, 6_000), (21_097.5, 8_400), (42_195, 11_400), (42_195, 17_000),
        ]
        for (m, t) in cases {
            let back = FitnessEstimate.finishSeconds(vdot: FitnessEstimate.vdot(meters: m, seconds: t), meters: m)
            XCTAssertEqual(back, t, accuracy: 1, "\(m) m in \(t) s")
        }
    }

    // MARK: - 3. Agrees with Riegel

    /// The spike's comparison: on race-relevant inputs the formula change is about 1%, so
    /// the move to VDOT is not itself what moves the number. 5K 20:00 → 30:00, read out to
    /// the marathon, within 1.5% of `PaceModel.equivalentTime`.
    func testVDOTAgreesWithRiegelWithinOneAndAHalfPercentFromFiveK() {
        for minutes in 20...30 {
            let t = Double(minutes * 60)
            let viaVDOT = FitnessEstimate.finishSeconds(vdot: FitnessEstimate.vdot(meters: 5_000, seconds: t),
                                                        meters: 42_195)
            let viaRiegel = PaceModel.equivalentTime(seconds: t, from: 5_000, to: 42_195)
            XCTAssertEqual(viaRiegel / viaVDOT, 1, accuracy: 0.015, "5K in \(minutes):00")
        }
        // The table's own first row: 5K 20:00 → 3:11:17 by VDOT.
        let m = FitnessEstimate.finishSeconds(vdot: FitnessEstimate.vdot(meters: 5_000, seconds: 1_200), meters: 42_195)
        XCTAssertEqual(m, hms(3, 11, 17), accuracy: 1)
    }

    // MARK: - 4. Steady block

    func testASteadyBlockReadsNearFortyFiveFromThreeEfforts() {
        guard let r = reading(estimate(steadyBlock())) else { return }
        XCTAssertEqual(r.vdot, 45, accuracy: 0.3)
        XCTAssertEqual(r.counted.count, 3)
        XCTAssertNil(r.heldOut)
        XCTAssertEqual(r.baselinePaceSecPerMile, Double(easyPace), accuracy: 0.5)
        XCTAssertEqual(r.counted.map(\.date), r.counted.map(\.date).sorted(by: >), "newest first")
        XCTAssertTrue(r.counted.allSatisfy { $0.source == .wholeRun })
        XCTAssertEqual(r.finishSeconds(meters: 10_000),
                       Int(FitnessEstimate.finishSeconds(vdot: r.vdot, meters: 10_000).rounded()))
    }

    // MARK: - 5–7. Slow outliers change nothing

    /// A hot day: today's 10K at 47:15, 5% slower than 45:00. Still `quality` against a
    /// 9:30 baseline, so it is in the pool — and nowhere near the top three.
    func testAHeatWaveTenKChangesNothing() {
        let block = steadyBlock()
        let hot = RunSummary(id: UUID(), start: asOf, distanceM: 10_000, durationS: 2_835, avgHR: nil)
        guard let before = reading(estimate(block)), let after = reading(estimate(block + [hot])) else { return }
        XCTAssertEqual(after.vdot, before.vdot, accuracy: 0.01)
        XCTAssertFalse(after.counted.contains { $0.runID == hot.id })
    }

    func testAHillyQualityRunYesterdayChangesNothing() {
        let block = steadyBlock()
        let hilly = easy(1, miles: 8, pace: 470)   // quality by pace, slow for the effort
        guard let before = reading(estimate(block)), let after = reading(estimate(block + [hilly])) else { return }
        XCTAssertEqual(after.vdot, before.vdot, accuracy: 0.01)
    }

    func testARunEightPercentSlowerIsRecoveryAndChangesNothing() {
        let block = steadyBlock()
        let slow = easy(1, miles: 5, pace: Int((Double(easyPace) * 1.08).rounded()))
        XCTAssertEqual(
            FitnessEstimate.classify(paceSecPerMile: Double(slow.durationS) / slow.miles, baseline: Double(easyPace),
                                     avgHR: nil, measuredMaxHR: nil, rpe: nil),
            .recovery
        )
        guard let before = reading(estimate(block)), let after = reading(estimate(block + [slow])) else { return }
        XCTAssertEqual(after.vdot, before.vdot, accuracy: 0.01)
    }

    // MARK: - 8. Missed week

    /// Exponential weights keep their ratios when every effort ages by the same amount, so a
    /// week off changes nothing — provided nothing crosses day 56 (oldest effort here is 43
    /// days old, 50 a week later).
    func testAMissedWeekChangesNothingWhenNothingAgesOut() {
        let block = steadyBlock(maxQualityAgo: 43)
        guard let now = reading(estimate(block)),
              let later = reading(estimate(block, asOf: cal.date(byAdding: .day, value: 7, to: asOf)!))
        else { return }
        XCTAssertEqual(later.vdot, now.vdot, accuracy: 0.01)
        XCTAssertEqual(later.counted.map(\.runID), now.counted.map(\.runID))
    }

    /// When an effort does cross day 56, the step is exactly its weight share times its
    /// distance from what remains — small, because its weight at day 52 is already 0.18.
    func testAnEffortLeavingTheWindowStepsByNoMoreThanItsWeightShare() {
        let leaving = quality(52, vdot: 45.6)
        let runs = [leaving, quality(5, vdot: 45.0), quality(12, vdot: 44.8)] + easyBase([3, 7, 10, 14, 18, 22, 26])
        guard let now = reading(estimate(runs)),
              let later = reading(estimate(runs, asOf: cal.date(byAdding: .day, value: 7, to: asOf)!))
        else { return }

        XCTAssertTrue(now.counted.contains { $0.runID == leaving.id })
        XCTAssertFalse(later.counted.contains { $0.runID == leaving.id })

        let share = now.counted.first(where: { $0.runID == leaving.id })!.weight / now.counted.map(\.weight).reduce(0, +)
        let leavingVDOT = now.counted.first(where: { $0.runID == leaving.id })!.vdot
        XCTAssertLessThanOrEqual(abs(later.vdot - now.vdot), share * abs(leavingVDOT - later.vdot) + 1e-9)
        XCTAssertLessThan(abs(later.vdot - now.vdot) / now.vdot, 0.005, "inside the PRD's 0.5% movement tolerance")
    }

    // MARK: - 9. Sparse

    func testOneQualityEffortIsTooFewAndTwoGiveAReading() {
        let one = easyBase() + [quality(7, vdot: 45)]
        XCTAssertEqual(estimate(one), .insufficient(.tooFewEfforts(found: 1)))

        let two = one + [quality(14, vdot: 45)]
        guard let r = reading(estimate(two)) else { return }
        XCTAssertEqual(r.counted.count, 2)
        XCTAssertEqual(r.vdot, 45, accuracy: 0.02)
    }

    /// The documented weakness, pinned so a change to it is deliberate: with only three
    /// efforts the hot one is in the mean, and as the newest it weighs the most. 45 (day 14),
    /// 45 (day 7) and a hot 42.75 today give 44.08 — the spike's 44.07, about −2.1% VDOT.
    func testTwoEffortsPlusAHotOneReadTheDocumentedDip() {
        let runs = easyBase() + [quality(14, vdot: 45), quality(7, vdot: 45), quality(0, vdot: 42.75)]
        guard let r = reading(estimate(runs)) else { return }
        XCTAssertEqual(r.counted.count, 3)
        XCTAssertEqual(r.vdot, 44.08, accuracy: 0.01)
    }

    // MARK: - 10. Layoff

    func testANewestEffortTwentyTwoDaysOldIsStaleUntilAFreshOneArrives() {
        let old = [quality(22, vdot: 45.0), quality(30, vdot: 45.2), quality(35, vdot: 45.1)]
        let base = easyBase([23, 26, 29, 33, 38, 41])
        XCTAssertEqual(estimate(base + old), .insufficient(.stale(lastEffort: daysAgo(22))))

        // One fresh effort brings a reading back, and step 7 keeps it in even though it is
        // the slowest of the four.
        let fresh = quality(2, vdot: 44.0)
        guard let r = reading(estimate(base + old + [fresh])) else { return }
        XCTAssertEqual(r.counted.first?.runID, fresh.id)
        XCTAssertEqual(r.counted.count, 3)
        XCTAssertFalse(r.counted.contains { $0.runID == old[0].id }, "the lowest old peak made room")
    }

    // MARK: - 11. Decline

    /// Three 46s at days 30–40 and two 44s at days 3 and 10. Without step 7 the old peaks
    /// would win and the reading would sit at 46 while the runner got slower.
    func testADeclineReadsBelowTheOldPeaksAndIncludesTheNewestEffort() {
        let recent = quality(3, vdot: 44)
        let runs = easyBase() + [quality(30, vdot: 46), quality(35, vdot: 46), quality(40, vdot: 46),
                                 recent, quality(10, vdot: 44)]
        guard let r = reading(estimate(runs)) else { return }
        XCTAssertLessThan(r.vdot, 46)
        XCTAssertEqual(r.vdot, 44.86, accuracy: 0.01, "the spike's 44.9")
        XCTAssertTrue(r.counted.contains { $0.runID == recent.id })
    }

    // MARK: - 12. No baseline

    func testFourRunsInSixtyDaysIsNoBaselineAndOldHistoryCannotRescueIt() {
        let recent = [easy(3), easy(10), quality(5, vdot: 45), quality(12, vdot: 45)]
        let longAgo = (61...90).map { easy($0) }
        XCTAssertEqual(estimate(recent + longAgo), .insufficient(.noBaseline(runs: 4)))
        XCTAssertNil(FitnessEstimate.baselinePace(recent + longAgo, asOf: asOf, calendar: cal))
    }

    // MARK: - 13–14. Artefacts (#227, #229)

    /// The #227 row: 13,047 m over 37,459 s, a watch left recording (77:00/mi). It is not a
    /// candidate, and the 5:02/mi "5K" inside it — a car, by the look of it — goes with it.
    /// Without the parent-run rule that segment would read about VDOT 66.
    func testAWatchLeftRecordingAndItsSegmentsAreIgnored() {
        let block = steadyBlock()
        let leftRunning = RunSummary(id: UUID(), start: daysAgo(3), distanceM: 13_047, durationS: 37_459, avgHR: nil)
        let efforts = [leftRunning.id: [BestEfforts.Effort(distanceM: 5_000, durationS: 938)]]
        XCTAssertEqual(estimate(block + [leftRunning], efforts: efforts), estimate(block),
                       "not a candidate, not in the baseline, and no held-out segment either")
    }

    /// The same 938 s 5K inside an otherwise normal easy run is a segment of a plausible
    /// run, so only the hold-out can catch it — and does.
    func testACarSegmentInANormalRunIsHeldOut() {
        let block = steadyBlock()
        let normal = easy(3, miles: 8)
        let efforts = [normal.id: [BestEfforts.Effort(distanceM: 5_000, durationS: 938)]]
        guard let before = reading(estimate(block)),
              let after = reading(estimate(block + [normal], efforts: efforts)) else { return }
        XCTAssertEqual(after.heldOut?.runID, normal.id)
        XCTAssertEqual(after.heldOut?.source, .segment(distanceKey: 5_000))
        XCTAssertEqual(after.heldOut?.weight, 0)
        XCTAssertEqual(after.vdot, before.vdot, accuracy: 0.01)
    }

    // MARK: - 15. Breakthrough

    func testABreakthroughIsHeldOutUntilASecondEffortConfirmsIt() {
        let block = steadyBlock()
        let breakthrough = quality(0, vdot: 48.0)
        guard let alone = reading(estimate(block + [breakthrough])),
              let base = reading(estimate(block)) else { return }
        XCTAssertEqual(alone.heldOut?.runID, breakthrough.id)
        XCTAssertEqual(alone.vdot, base.vdot, accuracy: 0.01)

        let confirm = quality(3, vdot: 47.6)
        guard let confirmed = reading(estimate(block + [breakthrough, confirm])) else { return }
        XCTAssertNil(confirmed.heldOut)
        XCTAssertTrue(confirmed.counted.contains { $0.runID == breakthrough.id })
        XCTAssertTrue(confirmed.counted.contains { $0.runID == confirm.id })
        XCTAssertEqual(confirmed.vdot, 47.4, accuracy: 0.05)
    }

    // MARK: - 16–17. Segments, once per run

    /// A 16-miler at an easy average with the last 10K at VDOT 45. Whole-run averaging can't
    /// see that 10K; `run_efforts` can. The easy-paced half inside it doesn't count.
    func testAHardFinishInALongRunCountsOnceAsItsTenK() {
        let long = easy(3, miles: 16, pace: 560)
        let tenK = Int(FitnessEstimate.finishSeconds(vdot: 45, meters: 10_000).rounded())
        let efforts = [long.id: [
            BestEfforts.Effort(distanceM: 5_000, durationS: tenK / 2),
            BestEfforts.Effort(distanceM: 10_000, durationS: tenK),
            BestEfforts.Effort(distanceM: 21_098, durationS: 7_600),
        ]]
        guard let r = reading(estimate(easyBase() + [long, quality(10, vdot: 45)], efforts: efforts)) else { return }
        let fromLong = r.counted.filter { $0.runID == long.id }
        XCTAssertEqual(fromLong.count, 1)
        XCTAssertEqual(fromLong.first?.source, .segment(distanceKey: 10_000))
    }

    func testAQualifyingRunContributesOnceAtItsHighestVDOT() {
        let half = quality(4, vdot: 45, meters: 21_098)
        let efforts = [half.id: [
            BestEfforts.Effort(distanceM: 5_000, durationS: 1_300),
            BestEfforts.Effort(distanceM: 10_000, durationS: 2_670),
        ]]
        let candidates = [
            FitnessEstimate.vdot(meters: 21_098, seconds: Double(half.durationS)),
            FitnessEstimate.vdot(meters: 5_000, seconds: 1_300),
            FitnessEstimate.vdot(meters: 10_000, seconds: 2_670),
        ]
        guard let r = reading(estimate(easyBase() + [half, quality(10, vdot: 45)], efforts: efforts)) else { return }
        let fromHalf = r.counted.filter { $0.runID == half.id }
        XCTAssertEqual(fromHalf.count, 1)
        XCTAssertEqual(fromHalf.first?.vdot ?? 0, candidates.max()!, accuracy: 1e-9)
    }

    // MARK: - 18. RPE outranks pace

    func testRPEDemotesButNeverPromotes() {
        let base = Double(easyPace)
        XCTAssertEqual(FitnessEstimate.classify(paceSecPerMile: 450, baseline: base, avgHR: nil, measuredMaxHR: nil, rpe: 3), .easy)
        XCTAssertEqual(FitnessEstimate.classify(paceSecPerMile: 450, baseline: base, avgHR: nil, measuredMaxHR: nil, rpe: 2), .recovery)
        XCTAssertEqual(FitnessEstimate.classify(paceSecPerMile: 570, baseline: base, avgHR: nil, measuredMaxHR: nil, rpe: 8), .easy)
        XCTAssertEqual(FitnessEstimate.classify(paceSecPerMile: 450, baseline: base, avgHR: nil, measuredMaxHR: nil, rpe: 8), .quality)
    }

    /// RPE rates the whole session, so it removes a run's segments as well as the run.
    func testAnEasyRPEKeepsTheRunAndItsSegmentsOutOfThePool() {
        let rated = quality(4, vdot: 45, rpe: 3)
        let efforts = [rated.id: [BestEfforts.Effort(distanceM: 5_000, durationS: 1_300)]]
        XCTAssertEqual(estimate(easyBase() + [rated, quality(10, vdot: 45)], efforts: efforts),
                       .insufficient(.tooFewEfforts(found: 1)))
    }

    // MARK: - 19. HR demotion

    func testLowHRDemotesOnlyAgainstAMeasuredMax() {
        let base = Double(easyPace)
        XCTAssertEqual(FitnessEstimate.classify(paceSecPerMile: 450, baseline: base, avgHR: 135, measuredMaxHR: 190, rpe: nil), .easy,
                       "135 is 71% of 190")
        XCTAssertEqual(FitnessEstimate.classify(paceSecPerMile: 450, baseline: base, avgHR: 135, measuredMaxHR: nil, rpe: nil), .quality,
                       "no measured max, no HR rule")
    }

    /// The run's average HR includes the easy miles around the segment, so the segment
    /// skips the HR rule even when the whole run is demoted by it.
    func testASegmentSkipsTheHRRule() {
        let run = easy(4, miles: 8, pace: 440)
        var withHR = run
        withHR.avgHR = 135
        let tenK = Int((440 * 10_000 / 1609.34).rounded())   // the same pace as the whole run
        let efforts = [run.id: [BestEfforts.Effort(distanceM: 10_000, durationS: tenK)]]
        let runs = easyBase() + [withHR, quality(10, vdot: 45)]

        guard let measured = reading(estimate(runs, efforts: efforts, maxHR: 190)),
              let unmeasured = reading(estimate(runs, efforts: efforts, maxHR: nil)) else { return }
        XCTAssertEqual(measured.counted.first { $0.runID == run.id }?.source, .segment(distanceKey: 10_000))
        XCTAssertEqual(unmeasured.counted.first { $0.runID == run.id }?.source, .wholeRun,
                       "at the same pace the longer whole run has the higher VDOT")
    }

    // MARK: - 20. Replay honesty

    func testEffortsAfterAsOfDoNotChangeTheReading() {
        let block = steadyBlock()
        let tomorrow = RunSummary(id: UUID(), start: cal.date(byAdding: .day, value: 1, to: asOf)!,
                                  distanceM: 10_000, durationS: 2_400, avgHR: nil)
        let efforts = [tomorrow.id: [BestEfforts.Effort(distanceM: 5_000, durationS: 1_150)]]
        XCTAssertEqual(estimate(block + [tomorrow], efforts: efforts), estimate(block))
    }

    // MARK: - 21. Edges

    /// `distance_m` is whole metres, so 2.5 mi arrives as 4,023 — and qualifies.
    func testTwoAndAHalfMilesExactlyQualifies() {
        let other = quality(10, vdot: 42)
        func short(_ meters: Int) -> RunSummary {
            RunSummary(id: UUID(), start: daysAgo(3), distanceM: meters,
                       durationS: Int(Double(meters) / 1609.34 * 450), avgHR: nil)
        }
        XCTAssertEqual(short(4_023).distanceM, Int(ProjectionHistory.minQualifyingMiles * 1609.34))

        let atFloor = short(4_023)
        guard let r = reading(estimate(easyBase() + [other, atFloor])) else { return }
        XCTAssertTrue(r.counted.contains { $0.runID == atFloor.id })
        XCTAssertEqual(estimate(easyBase() + [other, short(4_022)]), .insufficient(.tooFewEfforts(found: 1)))
    }

    /// The ceiling bites where a slow run could otherwise count: the baseline. 20:00/mi
    /// exactly is a run-walk and counts; 20:01 does not.
    func testTwentyMinutesAMileQualifiesAndTwentyOhOneDoesNot() {
        func walk(_ ago: Int, durationS: Int) -> RunSummary {
            RunSummary(id: UUID(), start: daysAgo(ago), distanceM: 4_828, durationS: durationS, avgHR: nil)
        }
        let atCeiling = (1...5).map { walk($0, durationS: 3_600) }
        XCTAssertEqual(atCeiling[0].paceSecPerMile, 1_200)
        XCTAssertNotNil(FitnessEstimate.baselinePace(atCeiling, asOf: asOf, calendar: cal))

        let oneOver = Array(atCeiling.prefix(4)) + [walk(5, durationS: 3_603)]
        XCTAssertEqual(oneOver[4].paceSecPerMile, 1_201)
        XCTAssertEqual(estimate(oneOver), .insufficient(.noBaseline(runs: 4)))
    }

    /// 4:00/mi qualifies; 3:59 is a car or a GPS jump. Whole runs and segments alike.
    func testFourMinutesAMileQualifiesAndThreeFiftyNineDoesNot() {
        func blur(_ ago: Int, durationS: Int) -> RunSummary {
            RunSummary(id: UUID(), start: daysAgo(ago), distanceM: 8_046, durationS: durationS, avgHR: nil)
        }
        let fast = [blur(3, durationS: 1_200), blur(5, durationS: 1_200)]
        XCTAssertEqual(fast[0].paceSecPerMile, 240)
        guard let r = reading(estimate(easyBase() + fast)) else { return }
        XCTAssertEqual(r.counted.count, 2)

        let tooFast = blur(5, durationS: 1_195)
        XCTAssertEqual(tooFast.paceSecPerMile, 239)
        XCTAssertEqual(estimate(easyBase() + [fast[0], tooFast]), .insufficient(.tooFewEfforts(found: 1)))

        // A 5K segment in 746 s is 4:00/mi; in 745 s it is 3:59.
        let host = easy(7, miles: 6)
        let other = quality(10, vdot: 85, meters: 8_046)
        XCTAssertEqual(
            reading(estimate(easyBase() + [host, other],
                             efforts: [host.id: [BestEfforts.Effort(distanceM: 5_000, durationS: 746)]]))?
                .counted.contains { $0.runID == host.id },
            true
        )
        XCTAssertEqual(estimate(easyBase() + [host, other],
                                efforts: [host.id: [BestEfforts.Effort(distanceM: 5_000, durationS: 745)]]),
                       .insufficient(.tooFewEfforts(found: 1)))
    }

    func testExactlyNinetyFourPercentOfBaselineIsQuality() {
        func cls(_ p: Double) -> FitnessEstimate.RunClass {
            FitnessEstimate.classify(paceSecPerMile: p, baseline: 500, avgHR: nil, measuredMaxHR: nil, rpe: nil)
        }
        XCTAssertEqual(cls(470), .quality)
        XCTAssertEqual(cls(470.01), .easy)
        XCTAssertEqual(cls(530), .recovery)
        XCTAssertEqual(cls(529.99), .easy)
    }

    // MARK: - Calibration: a sparse recent block

    /// Added at calibration (#244): four runs in 56 days, one of them a watch left recording.
    /// The artefact can't count toward the baseline, so three plausible runs are all there
    /// is, and an older archive doesn't rescue it. The answer is a named state, not a number
    /// — and specifically not one read off the one quality run on file.
    func testASparseRecentBlockWithARecordingArtefactIsInsufficient() {
        let leftRunning = RunSummary(id: UUID(), start: daysAgo(15), distanceM: 13_047, durationS: 37_459, avgHR: nil)
        let recent = [quality(5, vdot: 45), easy(10), easy(20), leftRunning]
        let archive = (70...150).filter { $0 % 3 == 0 }.map { easy($0) }
        let efforts = [leftRunning.id: [BestEfforts.Effort(distanceM: 5_000, durationS: 938)]]
        XCTAssertEqual(estimate(recent + archive, efforts: efforts), .insufficient(.noBaseline(runs: 3)))
    }
}
