import XCTest
@testable import Tempo

/// Chicago, 11 Oct 2026. The recap will be read once, closely, with the official chip splits
/// open in another app — and every number on it is checkable against them. A mat placed a
/// few hundred metres early does not look broken; it looks like a fast 5K. That is the shape
/// of every past bug in this engine layer: a plausible number, quietly wrong.
///
/// The one decision here with a scar behind it is the GPS overread scaling. Chicago's
/// downtown makes a watch read 26.4–26.8 mi for an honest 26.2, and on raw distance every
/// mat lands early and every split reads fast. These pin both sides of that band.
final class RaceRecapTests: XCTestCase {

    private let marathon = RaceRecap.marathonMeters
    /// 3:15:00 — a round goal so even-pace expectations are easy to read.
    private let goal = 11_700

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func day(_ iso: String, hour: Int = 0, minute: Int = 0) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        let midnight = f.date(from: iso)!
        return cal.date(byAdding: .minute, value: hour * 60 + minute, to: midnight)!
    }

    /// A cumulative distance/time curve built from legs of constant pace, sampled every
    /// 50 m — roughly what a watch writes to Health.
    private func curve(_ legs: [(meters: Double, seconds: Double)]) -> (times: [Double], meters: [Double]) {
        var times: [Double] = [0], meters: [Double] = [0]
        var t = 0.0, m = 0.0
        for leg in legs {
            let steps = max(1, Int((leg.meters / 50).rounded(.up)))
            for i in 1...steps {
                let f = Double(i) / Double(steps)
                times.append(t + leg.seconds * f)
                meters.append(m + leg.meters * f)
            }
            t += leg.seconds
            m += leg.meters
        }
        return (times, meters)
    }

    private func evenCurve(meters: Double, seconds: Double) -> (times: [Double], meters: [Double]) {
        curve([(meters, seconds)])
    }

    private func recap(
        _ c: (times: [Double], meters: [Double]),
        hrTimes: [Double] = [], hrBPM: [Double] = [],
        goalS: Int? = 11_700
    ) -> RaceRecap.Recap {
        RaceRecap.recap(
            times: c.times, meters: c.meters, hrTimes: hrTimes, hrBPM: hrBPM,
            raceMeters: marathon, goalS: goalS
        )!
    }

    // MARK: - isRace

    /// 90% of 42,195 m is 37,975.5 m. The boundary is inclusive; one metre either side of it
    /// decides whether the athlete's marathon gets a recap or a generic page.
    func testIsRaceDistanceBoundaryIsNinetyPercent() {
        let raceDay = day("2026-10-11")
        let start = day("2026-10-11", hour: 7, minute: 30)
        XCTAssertTrue(RaceRecap.isRace(start: start, distanceM: 37_976, raceDay: raceDay, raceMeters: marathon, calendar: cal))
        XCTAssertFalse(RaceRecap.isRace(start: start, distanceM: 37_975, raceDay: raceDay, raceMeters: marathon, calendar: cal),
                       "the race-morning shakeout, or a DNF, is not the race")
    }

    func testIsRaceRequiresTheRaceDayItself() {
        let raceDay = day("2026-10-11")
        XCTAssertFalse(RaceRecap.isRace(start: day("2026-10-10", hour: 23, minute: 59), distanceM: 42_800,
                                        raceDay: raceDay, raceMeters: marathon, calendar: cal))
        XCTAssertFalse(RaceRecap.isRace(start: day("2026-10-12", hour: 0, minute: 1), distanceM: 42_800,
                                        raceDay: raceDay, raceMeters: marathon, calendar: cal))
        XCTAssertTrue(RaceRecap.isRace(start: day("2026-10-11", hour: 23, minute: 59), distanceM: 42_800,
                                       raceDay: raceDay, raceMeters: marathon, calendar: cal),
                      "local calendar day, not a 24-hour window from midnight UTC")
        XCTAssertFalse(RaceRecap.isRace(start: day("2026-10-11", hour: 7), distanceM: 42_800,
                                        raceDay: nil, raceMeters: marathon, calendar: cal),
                       "a goal with no race date has no race")
    }

    /// The `GoalInfo` overload reads the distance off the goal: a 15-mile run on the day of a
    /// goal *half* is that race; the same run on a marathon goal day is not.
    func testIsRaceReadsTheGoalsDistance() {
        let run = RunSummary(id: UUID(), start: day("2026-10-11", hour: 8), distanceM: 21_300, durationS: 5_400, avgHR: nil)
        let half = GoalInfo(id: UUID(), race_name: "Half", race_date: "2026-10-11", goal_time_seconds: 5_400, distance: "half")
        let full = GoalInfo(id: UUID(), race_name: "Chicago", race_date: "2026-10-11", goal_time_seconds: 11_700, distance: "marathon")
        // `GoalInfo.raceDay` parses in the device's zone, so compare in it too.
        XCTAssertTrue(RaceRecap.isRace(run: run, goal: half, calendar: .current))
        XCTAssertFalse(RaceRecap.isRace(run: run, goal: full, calendar: .current))
        XCTAssertFalse(RaceRecap.isRace(run: run, goal: nil, calendar: .current), "no goal, no race")
    }

    // MARK: - Mats

    /// Even pace, exactly 42,195 m in exactly 3:15:00. Every mat should fall where simple
    /// proportion says, every segment at goal pace, every delta zero.
    func testEvenPaceMarathonPlacesEveryMat() {
        let r = recap(evenCurve(meters: marathon, seconds: Double(goal)))
        XCTAssertEqual(r.mats.map(\.label),
                       ["5K", "10K", "15K", "20K", "Half", "25K", "30K", "35K", "40K", "Finish"])
        XCTAssertFalse(r.wasScaled)
        for mat in r.mats {
            XCTAssertEqual(mat.elapsedS, Double(goal) * mat.meters / marathon, accuracy: 0.01, mat.label)
            XCTAssertEqual(mat.deltaS ?? .nan, 0, accuracy: 0.01, mat.label)
            XCTAssertEqual(mat.segmentPaceSecPerMile, Double(goal) / (marathon / 1609.34), accuracy: 0.01, mat.label)
        }
        XCTAssertEqual(r.mats.first { $0.label == "Half" }!.elapsedS, 5_850, accuracy: 0.01)
        XCTAssertEqual(r.finishS, Double(goal), accuracy: 0.01)
        XCTAssertTrue(r.mats.last!.isFinish)
    }

    /// The finish mat is crossed at the start of a standstill, not at its end: someone who
    /// stops on the line to wait for a friend did not finish when they started moving again.
    func testMatIsPlacedAtTheFirstMomentTheDistanceIsReached() {
        let times: [Double] = [0, 1000, 1300, 2000]
        let meters: [Double] = [0, 5000, 5000, 8000]
        XCTAssertEqual(RaceRecap.time(atMeters: 5000, times: times, meters: meters), 1000)
        XCTAssertNil(RaceRecap.time(atMeters: 8001, times: times, meters: meters))
    }

    // MARK: - GPS overread

    /// The Chicago case: watch reads 26.6 mi for a race run at perfectly even pace. Scaled,
    /// the finish lands on exactly 42,195 m at the end of the run, and the 5K mat is where it
    /// really is — not 230 m early.
    func testOverreadInsideTheBandIsScaledOntoTheCourse() {
        let measured = 26.6 * 1609.34   // 42,808 m, 101.5%
        let r = recap(evenCurve(meters: measured, seconds: Double(goal)))

        XCTAssertTrue(r.wasScaled)
        XCTAssertEqual(r.scale, marathon / measured, accuracy: 1e-12)
        XCTAssertEqual(r.measuredMeters, measured, accuracy: 1e-9)

        let finish = r.mats.last!
        XCTAssertEqual(finish.meters, 42_195)
        XCTAssertEqual(finish.elapsedS, Double(goal), accuracy: 0.001, "finish mat = end of the run")
        XCTAssertEqual(finish.deltaS ?? .nan, 0, accuracy: 0.01)

        let n = RaceRecap.normalise(meters: [0, 20_000, measured], raceMeters: marathon)
        XCTAssertEqual(n.meters.last, 42_195, "exactly, not one rounding error short")

        let fiveK = r.mats.first!
        XCTAssertEqual(fiveK.elapsedS, Double(goal) * 5_000 / marathon, accuracy: 0.01,
                       "unscaled, the 5K would read \(Double(goal) * 5_000 / measured)s — a fast split that never happened")
    }

    /// 27.5 mi is 104.9% — too far over to be drift. It is a warm-up or a watch left running,
    /// so distance stays raw and the finish mat sits where the raw curve reaches 42,195 m,
    /// well before the end of the recording.
    func testOverreadOutsideTheBandKeepsRawDistance() {
        let measured = 27.5 * 1609.34
        let r = recap(evenCurve(meters: measured, seconds: Double(goal)))
        XCTAssertFalse(r.wasScaled)
        XCTAssertEqual(r.scale, 1)
        XCTAssertEqual(r.mats.last!.meters, 42_195)
        XCTAssertEqual(r.mats.last!.elapsedS, Double(goal) * marathon / measured, accuracy: 0.01)
    }

    /// The band edges: just under 103% still scales, a hair above does not, and a short reading
    /// is never stretched. A short reading still gets a finish mat — at the end of the run.
    func testOverreadBandEdgesAndShortReadings() {
        XCTAssertTrue(RaceRecap.normalise(meters: [0, marathon * 1.0299], raceMeters: marathon).wasScaled)
        XCTAssertFalse(RaceRecap.normalise(meters: [0, marathon * 1.0301], raceMeters: marathon).wasScaled)
        XCTAssertFalse(RaceRecap.normalise(meters: [0, marathon * 0.99], raceMeters: marathon).wasScaled)

        let short = recap(evenCurve(meters: 39_000, seconds: 11_000))
        XCTAssertEqual(short.mats.map(\.label), ["5K", "10K", "15K", "20K", "Half", "25K", "30K", "35K", "Finish"],
                       "no 40K mat invented past the end of the reading")
        XCTAssertEqual(short.mats.last!.elapsedS, 11_000, "the run's end is the finish line")
    }

    // MARK: - Sign convention

    /// Delta is actual minus goal. Ahead of goal pace is negative ("banked"), behind is
    /// positive ("given back") — the table, the chart and the share card all read this.
    func testDeltaSignConvention() {
        let fast = recap(evenCurve(meters: marathon, seconds: 11_400))   // 5:00 under
        XCTAssertEqual(fast.finishDeltaS ?? .nan, -300, accuracy: 0.01)
        XCTAssertTrue(fast.mats.allSatisfy { ($0.deltaS ?? 0) < 0 }, "every mat banked")
        XCTAssertEqual(RaceRecap.formatDelta(-300), "-5:00")

        let slow = recap(evenCurve(meters: marathon, seconds: 12_000))   // 5:00 over
        XCTAssertEqual(slow.finishDeltaS ?? .nan, 300, accuracy: 0.01)
        XCTAssertEqual(RaceRecap.formatDelta(300), "+5:00")
        XCTAssertEqual(RaceRecap.formatDelta(0.4), "0:00", "dead on carries no sign")
        XCTAssertEqual(RaceRecap.formatDelta(3_725), "+1:02:05")
    }

    func testNoGoalTimeMeansNoDeltasAndNoFade() {
        let r = recap(evenCurve(meters: marathon, seconds: 11_700), goalS: nil)
        XCTAssertTrue(r.mats.allSatisfy { $0.deltaS == nil })
        XCTAssertNil(r.finishDeltaS)
        XCTAssertNil(r.fadePoint)
        XCTAssertNil(recap(evenCurve(meters: marathon, seconds: 11_700), goalS: 0).finishDeltaS,
                     "a goal time of zero is not a goal time")
    }

    // MARK: - Halves

    func testNegativeSplitIsDetected() {
        let half = marathon / 2
        let r = recap(curve([(half, 5_900), (half, 5_780)]))
        XCTAssertEqual(r.halves!.firstS, 5_900, accuracy: 0.01)
        XCTAssertEqual(r.halves!.secondS, 5_780, accuracy: 0.01)
        XCTAssertEqual(r.halves!.splitS, -120, accuracy: 0.01)
        XCTAssertTrue(r.halves!.isNegativeSplit)
    }

    func testPositiveSplitIsNotANegativeSplit() {
        let half = marathon / 2
        let r = recap(curve([(half, 5_700), (half, 6_100)]))
        XCTAssertEqual(r.halves!.splitS, 400, accuracy: 0.01)
        XCTAssertFalse(r.halves!.isNegativeSplit)
    }

    // MARK: - HR drift

    /// Garmin writes HR to Health sparsely, sometimes barely at all. Nineteen samples in the
    /// first half is not enough to call a mean — the drift tile must say so, not guess.
    func testHRDriftIsNilWhenEitherHalfIsSparse() {
        let first = (0..<19).map { Double($0) * 300 }                 // 19 samples before 5,850 s
        let second = (0..<60).map { 5_900 + Double($0) * 90 }         // plenty after
        let times = first + second
        let bpm = times.map { _ in 160.0 }
        let r = recap(evenCurve(meters: marathon, seconds: 11_700), hrTimes: times, hrBPM: bpm)
        XCTAssertNil(r.hrDrift)
    }

    func testHRDriftOnDenseData() {
        let times = stride(from: 0.0, through: 11_700, by: 10).map { $0 }
        let bpm = times.map { $0 < 5_850 ? 150.0 : 159.0 }
        // A post-finish sample that would drag the second half down if it counted.
        let r = recap(evenCurve(meters: marathon, seconds: 11_700),
                      hrTimes: times + [11_800], hrBPM: bpm + [90])
        let drift = r.hrDrift!
        XCTAssertEqual(drift.firstHalfBPM, 150, accuracy: 0.001)
        XCTAssertEqual(drift.secondHalfBPM, 159, accuracy: 0.001)
        XCTAssertEqual(drift.bpm, 9, accuracy: 0.001)
        XCTAssertEqual(drift.percent, 6, accuracy: 0.001)
    }

    // MARK: - Fade point

    func testFadePointIsNilOnARunThatNeverFaded() {
        XCTAssertNil(recap(evenCurve(meters: marathon, seconds: 11_700)).fadePoint, "dead even")
        XCTAssertNil(recap(evenCurve(meters: marathon, seconds: 11_500)).fadePoint,
                     "banking more at every mat — the finish is the most-banked point")
        let half = marathon / 2
        XCTAssertNil(recap(curve([(half, 5_900), (half, 5_700)])).fadePoint, "negative split, strong close")
    }

    /// The classic Chicago: out 2:00 ahead through 30K, then the wall. The fade point is the
    /// 30K mat — the last moment the race was going to plan.
    func testFadePointIsTheMostBankedMatBeforeTimeCameBack() {
        let goalPerMeter = Double(goal) / marathon
        let banked30 = 30_000 * goalPerMeter - 120
        let rest = marathon - 30_000
        let r = recap(curve([(30_000, banked30), (rest, rest * goalPerMeter + 420)]))
        XCTAssertEqual(r.fadePoint?.label, "30K")
        XCTAssertEqual(r.fadePoint?.deltaS ?? .nan, -120, accuracy: 0.01)
        XCTAssertEqual(r.finishDeltaS ?? .nan, 300, accuracy: 0.01)
    }

    func testGivingBackLessThanTheToleranceIsNotAFade() {
        let goalPerMeter = Double(goal) / marathon
        let rest = marathon - 30_000
        let r = recap(curve([(30_000, 30_000 * goalPerMeter - 60), (rest, rest * goalPerMeter + 10)]))
        XCTAssertNil(r.fadePoint, "10 s back from the best point is a bridge, not a wall")
    }

    // MARK: - The block

    /// Sixteen weeks before race day, race day excluded: the race is the result of the block,
    /// not part of it. Counting it would make the longest run of the block the marathon.
    func testBlockCoversSixteenWeeksAndExcludesTheRace() {
        let raceDay = day("2026-10-11")
        func run(_ iso: String, miles: Double, hour: Int = 7) -> RunSummary {
            RunSummary(id: UUID(), start: day(iso, hour: hour), distanceM: Int(miles * 1609.34),
                       durationS: Int(miles * 480), avgHR: nil)
        }
        let race = run("2026-10-11", miles: 26.6)
        let long = run("2026-09-20", miles: 20)
        let edge = run("2026-06-21", miles: 5, hour: 0)      // exactly 112 days before: in
        let stale = run("2026-06-20", miles: 10, hour: 23)   // the evening before that: out
        let block = RaceRecap.block(runs: [race, long, edge, stale], raceDay: raceDay,
                                    raceMeters: marathon, calendar: cal)
        XCTAssertEqual(block.runCount, 2)
        XCTAssertEqual(block.longest?.id, long.id)
        XCTAssertEqual(block.miles, long.miles + edge.miles, accuracy: 0.001)
        XCTAssertNotNil(block.projectedFinishS, "a 20-miler inside six weeks projects a finish")

        let halfBlock = RaceRecap.block(runs: [long], raceDay: raceDay, raceMeters: 21_097.5, calendar: cal)
        XCTAssertNil(halfBlock.projectedFinishS, "the projection only ever speaks to 26.2")
    }
}
