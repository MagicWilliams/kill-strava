import XCTest
@testable import Tempo

/// Regression suite for the watch left recording (#229, #237).
///
/// 15 Oct 2026: 8.1 mi came in through Apple Health from a source that wrote no pause
/// events, and ingest stored `HKWorkout.duration` as moving time — 10h24m, 77:00/mi, 42 spm.
/// Its own distance samples said about 1h41m. Nothing crashed; pace, load, the projection
/// and the coach all quietly read the wrong number. These tests pin the line between "the
/// samples outrank the stored duration" and "leave the run alone", from both sides.
final class SampleMovingTimeTests: XCTestCase {

    /// `count` back-to-back samples of `seconds` each, `meters` each, starting at `from`.
    private func samples(from: Double, count: Int, seconds: Double, meters: Double) -> [SampleMovingTime.Sample] {
        (0..<count).map { i in
            let start = from + Double(i) * seconds
            return SampleMovingTime.Sample(start: start, end: start + seconds, meters: meters)
        }
    }

    private func run(durationS: Int, elapsedS: Int? = nil, distanceM: Int = 13_047,
                     corrected: Bool = false, source: String = "healthkit",
                     start: Date = Date(timeIntervalSince1970: 1_792_000_000)) -> RunSummary {
        RunSummary(id: UUID(), start: start, distanceM: distanceM, durationS: durationS,
                   elapsedS: elapsedS, corrected: corrected, source: source)
    }

    // MARK: - The 15 Oct shape

    /// 13,047 m over a 37,459 s wall clock. Half an hour standing at the start (the watch
    /// writes a metre a minute of wrist drift), 50 minutes running, six hours with no samples
    /// at all, 51 more minutes running, standing again until the watch was stopped.
    private var october15: [SampleMovingTime.Sample] {
        let runningM = (13_047.0 - 30 - 30) / 101
        return samples(from: 0, count: 30, seconds: 60, meters: 1)
            + samples(from: 1_800, count: 50, seconds: 60, meters: runningM)
            + samples(from: 1_800 + 3_000 + 21_600, count: 51, seconds: 60, meters: runningM)
            + samples(from: 1_800 + 3_000 + 21_600 + 3_060, count: 30, seconds: 60, meters: 1)
    }

    func testTheOctober15RunIsCorrectedToItsSampleMovingTime() throws {
        let moving = try XCTUnwrap(SampleMovingTime.movingSeconds(october15))
        XCTAssertEqual(moving, 6_060, accuracy: 0.001, "1h41m: the 101 running minutes, nothing else")

        let fixed = try XCTUnwrap(SampleMovingTime.correctedDurations(stored: 37_459, sampleMoving: Int(moving)))
        XCTAssertEqual(fixed.moving, 6_060)
        XCTAssertEqual(fixed.elapsed, 37_459, "the 10h24m is still true — as the wall clock")
    }

    func testTheCorrectedRunReadsAboutTwelveThirtyAMileInsteadOfSeventySeven() throws {
        let stored = run(durationS: 37_459, elapsedS: 37_459)
        XCTAssertEqual(stored.paceSecPerMile, 4_620, "the fixture is the run that read 77:00/mi")

        let fixed = try XCTUnwrap(SampleMovingTime.corrected(stored, sampleMoving: 6_060))
        XCTAssertEqual(fixed.durationS, 6_060)
        XCTAssertEqual(fixed.elapsedS, 37_459)
        XCTAssertEqual(fixed.clocks.stoppedS, 31_399)
        let pace = try XCTUnwrap(fixed.paceSecPerMile)
        XCTAssertTrue((740...760).contains(pace), "about 12:30/mi, got \(pace)s")
        XCTAssertEqual(fixed.id, stored.id)
        XCTAssertEqual(fixed.distanceM, stored.distanceM, "distance is not this fix's business")
    }

    func testAWallClockLongerThanTheStoredDurationIsKeptAsElapsed() throws {
        // A source that wrote *some* pauses: its duration is already shorter than the wall
        // clock. The wall clock stays the elapsed time; it never shrinks to the duration.
        let stored = run(durationS: 30_000, elapsedS: 37_459)
        let fixed = try XCTUnwrap(SampleMovingTime.corrected(stored, sampleMoving: 6_060))
        XCTAssertEqual(fixed.durationS, 6_060)
        XCTAssertEqual(fixed.elapsedS, 37_459)
    }

    // MARK: - Runs that must be left alone

    func testARealRunWithAFourMinuteCafeStopIsUntouched() throws {
        // 1h40m running, four minutes at a café counter, no pause recorded: 6,240 s stored.
        // The run reads four minutes slow, and that is not worth rewriting its clocks for.
        let s = samples(from: 0, count: 50, seconds: 60, meters: 150)
            + samples(from: 3_000, count: 4, seconds: 60, meters: 2)
            + samples(from: 3_240, count: 50, seconds: 60, meters: 150)
        let moving = try XCTUnwrap(SampleMovingTime.movingSeconds(s))
        XCTAssertEqual(moving, 6_000, accuracy: 0.001)
        XCTAssertNil(SampleMovingTime.correctedDurations(stored: 6_240, sampleMoving: Int(moving)))
    }

    func testALongRunWithATwelveMinuteStopIsStillARun() {
        // Clears the ten-minute bar, but 12 of 180 minutes is under a quarter. A 3-hour long
        // run with a bottle stop is overwhelmingly running; its pace reads slow, not absurd.
        XCTAssertNil(SampleMovingTime.correctedDurations(stored: 10_800, sampleMoving: 10_080))
    }

    func testAWorkoutWithNoDistanceSamplesIsUntouched() {
        // Some Garmin-written workouts carry none. "No samples" is unknown, not "never moved".
        XCTAssertNil(SampleMovingTime.movingSeconds([]))
        XCTAssertNil(SampleMovingTime.correctedDurations(stored: 37_459, sampleMoving: nil))
        XCTAssertNil(SampleMovingTime.corrected(run(durationS: 37_459), sampleMoving: nil))
    }

    func testSamplesThatNeverMoveDoNotZeroARun() {
        // Every sample slower than a walk: the watch wrote drift, and zero moving seconds is
        // not a number to put a pace on.
        let drift = samples(from: 0, count: 600, seconds: 60, meters: 1)
        XCTAssertEqual(SampleMovingTime.movingSeconds(drift), 0)
        XCTAssertNil(SampleMovingTime.correctedDurations(stored: 36_000, sampleMoving: 0))
    }

    func testSampleMovingLongerThanStoredChangesNothing() {
        XCTAssertNil(SampleMovingTime.correctedDurations(stored: 3_000, sampleMoving: 3_100))
        XCTAssertNil(SampleMovingTime.correctedDurations(stored: 3_000, sampleMoving: 3_000))
    }

    // MARK: - Both thresholds, at their edges

    func testTheTenMinuteBarIsStrict() {
        // 2,000 s stored: a 600 s gap is 30%, so only the ten-minute bar is being tested.
        XCTAssertNil(SampleMovingTime.correctedDurations(stored: 2_000, sampleMoving: 1_400),
                     "exactly 10:00 unaccounted for is not more than ten minutes")
        XCTAssertNotNil(SampleMovingTime.correctedDurations(stored: 2_000, sampleMoving: 1_399))
    }

    func testTheQuarterShareIsStrict() {
        // 4,000 s stored: a 1,000 s gap clears ten minutes, so only the share is being tested.
        XCTAssertNil(SampleMovingTime.correctedDurations(stored: 4_000, sampleMoving: 3_000),
                     "exactly 25% unaccounted for is not more than a quarter")
        XCTAssertNotNil(SampleMovingTime.correctedDurations(stored: 4_000, sampleMoving: 2_999))
    }

    func testTheThresholdsAreTheNumbersTheIssueAgreed() {
        XCTAssertEqual(SampleMovingTime.minimumUnrecordedStopS, 600)
        XCTAssertEqual(SampleMovingTime.minimumUnrecordedStopShare, 0.25)
    }

    // MARK: - The moving/stopped line

    func testTheStoppedLineIsStrictlyAboveZeroPointFourFiveMetresPerSecond() {
        let atLine = [SampleMovingTime.Sample(start: 0, end: 100, meters: 45)]
        let justOver = [SampleMovingTime.Sample(start: 0, end: 100, meters: 46)]
        XCTAssertEqual(SampleMovingTime.movingSeconds(atLine), 0)
        XCTAssertEqual(SampleMovingTime.movingSeconds(justOver), 100)
    }

    func testGapsBetweenSamplesAreNotMovingTime() {
        let s = [SampleMovingTime.Sample(start: 0, end: 60, meters: 150),
                 SampleMovingTime.Sample(start: 3_600, end: 3_660, meters: 150)]
        XCTAssertEqual(SampleMovingTime.movingSeconds(s), 120)
    }

    func testAZeroLengthSampleDoesNotDivideByZero() throws {
        let s = [SampleMovingTime.Sample(start: 10, end: 10, meters: 3)]
        XCTAssertEqual(try XCTUnwrap(SampleMovingTime.movingSeconds(s)), 0.01, accuracy: 1e-9)
    }

    func testTheRecorderSplitsItsClocksOnTheSameLine() {
        // One definition: a run recorded in Tempo and one imported from a watch must agree
        // about what stopping is.
        XCTAssertEqual(TrackMath.stoppedSpeedMps, SampleMovingTime.stoppedSpeedMps)
    }

    // MARK: - Which new runs get a sample read

    func testOnlyRunsLongEnoughToCorrectAreRead() {
        // A 9-minute run cannot hide more than ten minutes of stop; reading its samples
        // would be a HealthKit query that can only answer "leave it".
        let short = run(durationS: 540), long = run(durationS: 3_600)
        XCTAssertEqual(SampleMovingTime.ingestTargets(written: [short, long]).map(\.id), [long.id])
    }

    func testCorrectedAndNonHealthKitRunsAreNeverRead() {
        let rows = [run(durationS: 37_459, corrected: true), run(durationS: 37_459, source: "manual")]
        XCTAssertTrue(SampleMovingTime.ingestTargets(written: rows).isEmpty)
    }

    func testAFirstSyncOfTheWholeArchiveReadsOnlyTheNewestFew() {
        // A new phone writes ~2,000 rows in one pass. That archive is part 2's review card;
        // here it must cost at most `ingestCheckLimit` reads, newest first.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let archive = (0..<2_000).map { run(durationS: 3_000, start: base.addingTimeInterval(Double($0) * 86_400)) }
        let targets = SampleMovingTime.ingestTargets(written: archive.shuffled())
        XCTAssertEqual(targets.count, SampleMovingTime.ingestCheckLimit)
        XCTAssertEqual(targets.map(\.id), archive.suffix(SampleMovingTime.ingestCheckLimit).reversed().map(\.id))
    }

    func testNothingWrittenMeansNothingRead() {
        // The healthy refresh: every workout already stored, nothing written, no sample reads.
        XCTAssertTrue(SampleMovingTime.ingestTargets(written: []).isEmpty)
        XCTAssertTrue(SampleMovingTime.ingestTargets(written: [run(durationS: 3_600)], limit: 0).isEmpty)
    }
}
