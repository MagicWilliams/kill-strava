import XCTest
@testable import Tempo

/// A treadmill run put right by its console (#116).
///
/// Indoors the phone counts steps and guesses the distance, 5–15% off either way; the console
/// is the truth. The athlete types it in on the save screen and the whole run is rescaled to
/// it before it reaches Health. What can go wrong is quiet, as every distance bug in this app
/// has been: a total a metre short of what the console said, splits that keep the phone's
/// boundaries under the console's total, a pace left at the phone's speed, a Save on an
/// untouched stepper that marks a run "corrected" by the rounding of its own prefill, or a
/// correction that leaks into a run he never corrected.
final class TreadmillDistanceTests: XCTestCase {

    private typealias Point = BestEfforts.Point

    /// The phone's count on a 40-minute treadmill run: 4.7137 mi (4.71 on screen), steady,
    /// with a two-minute stop for water at 20:00 (the curve is flat across it).
    private let phone: [Point] = {
        var points: [Point] = [Point(t: 0, m: 0)]
        let perS = 4.7137 * Units.metersPerMile / 2_280   // 38 moving minutes
        for s in stride(from: 10.0, through: 1_200, by: 10) { points.append(Point(t: s, m: s * perS)) }
        let atStop = 1_200 * perS
        points.append(Point(t: 1_320, m: atStop))
        for s in stride(from: 1_330.0, through: 2_400, by: 10) {
            points.append(Point(t: s, m: atStop + (s - 1_320) * perS))
        }
        return points
    }()

    private var estimate: Double { phone.last!.m }
    private let console = 5.0 * Units.metersPerMile

    private func correction(_ consoleM: Double) -> TreadmillDistance.Correction {
        TreadmillDistance.Correction(consoleM: consoleM, estimateM: estimate)
    }

    private func rescaled(_ c: TreadmillDistance.Correction?) -> [Point] {
        TreadmillDistance.rescaled(phone, by: c, startedAt: nil, endedAt: nil, pauses: [])
    }

    // MARK: - The rescale

    /// The console said 5.00 mi: the run ends on 5.00 mi to the last bit of the double, not
    /// on `estimate * (console / estimate)`, which can miss it.
    func testTheTotalMatchesTheConsoleExactly() {
        let out = rescaled(correction(console))
        XCTAssertEqual(out.last?.m, console, "exactly, not approximately")
        XCTAssertEqual(out.count, phone.count, "same points, same times")
        XCTAssertEqual(out.map(\.t), phone.map(\.t), "time is never touched")
    }

    /// The phone over-counted — the direction HealthKit could never have fixed after the fact.
    func testAConsoleBelowThePhoneScalesDownToo() {
        let lower = 4.40 * Units.metersPerMile
        let out = rescaled(correction(lower))
        XCTAssertEqual(out.last?.m, lower)
        for (a, b) in zip(out, phone) where b.m > 0 { XCTAssertLessThan(a.m, b.m) }
    }

    /// Every metre stretches by the same factor, so the water stop stays a stop and the curve
    /// never runs backwards.
    func testTheShapeIsKeptPauseAndAll() {
        let out = rescaled(correction(console))
        let k = console / estimate
        for (a, b) in zip(out, phone) { XCTAssertEqual(a.m, b.m * k, accuracy: 1e-6) }
        for (a, b) in zip(out, out.dropFirst()) { XCTAssertLessThanOrEqual(a.m, b.m) }
        let stop = out.filter { $0.t == 1_200 || $0.t == 1_320 }
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual(stop[0].m, stop[1].m, "flat across the water stop")
    }

    /// The splits move: a mile is reached sooner on the console's curve than on the phone's,
    /// there are five of them where the phone had four and a bit, and every pace is
    /// recomputed from the new boundaries — with the moving time unchanged, the average pace
    /// is the console's.
    func testSplitsMoveAndPaceIsRecomputed() throws {
        let mile = Units.mi.splitMeters
        let before = TrackMath.splits(timeline: phone, splitMeters: mile)
        let after = TrackMath.splits(timeline: rescaled(correction(console)), splitMeters: mile)

        XCTAssertEqual(before.filter { !$0.isPartial }.count, 4)
        XCTAssertEqual(after.filter { !$0.isPartial }.count, 5, "5.00 mi is five whole miles")
        XCTAssertEqual(after.reduce(0) { $0 + $1.meters }, console, accuracy: 1e-6, "the splits add up to the console")

        // Mile 1 comes sooner, so it is faster: the same seconds per metre, stretched.
        let k = console / estimate
        XCTAssertLessThan(after[0].durationS, before[0].durationS)
        XCTAssertEqual(after[0].paceS, before[0].paceS / k, accuracy: 0.5)

        // Average moving pace: 38 minutes over five miles, 7:36 /mi.
        let moving = 2_400.0 - 120
        XCTAssertEqual(try XCTUnwrap(Units.mi.pace(seconds: moving, meters: try XCTUnwrap(rescaled(correction(console)).last?.m))),
                       456, accuracy: 0.001)
    }

    /// He skipped it, or left the stepper alone: the samples are exactly the phone's.
    func testNoCorrectionLeavesTheSamplesUntouched() {
        XCTAssertEqual(rescaled(nil), phone)
        XCTAssertEqual(DistanceChunks.backlog(timeline: rescaled(nil), flushed: Point(t: 0, m: 0)),
                       DistanceChunks.backlog(timeline: phone, flushed: Point(t: 0, m: 0)),
                       "the workout gets the very samples it would have without the feature")
    }

    /// Phone on the console ledge, or Motion & Fitness off: no steps at all. The console's
    /// distance is spread over the time he was moving, flat across his stop, and still ends
    /// exactly on the console's figure.
    func testNoStepsSpreadsTheConsoleOverMovingTime() throws {
        let start = Date(timeIntervalSince1970: 1_791_725_400)
        let pause = RecorderState.Pause(start: start.addingTimeInterval(1_200),
                                        end: start.addingTimeInterval(1_320), reason: .manual)
        let out = TreadmillDistance.rescaled(
            [Point(t: 0, m: 0)], by: TreadmillDistance.Correction(consoleM: console, estimateM: 0),
            startedAt: start, endedAt: start.addingTimeInterval(2_400), pauses: [pause])

        XCTAssertEqual(out.last?.m, console)
        XCTAssertEqual(out.last?.t, 2_400)
        let atStop = try XCTUnwrap(out.first { $0.t == 1_200 }).m
        let afterStop = try XCTUnwrap(out.first { $0.t == 1_320 }).m
        XCTAssertEqual(atStop, afterStop, "nothing while he was stopped")
        XCTAssertEqual(atStop, console * 1_200 / 2_280, accuracy: 1e-6, "one steady pace over the moving time")
    }

    // MARK: - What counts as a correction

    func testAStepperLeftAloneIsNotACorrection() {
        // The stepper shows the estimate to a hundredth; Save on it hands back the rounded value.
        let shown = Units.mi.meters(distance: (Units.mi.distance(meters: estimate) * 100).rounded() / 100)
        XCTAssertNotEqual(shown, estimate, "the fixture's estimate is not a round hundredth")
        XCTAssertNil(TreadmillDistance.correction(consoleM: shown, estimateM: estimate, units: .mi))
        let shownKm = Units.km.meters(distance: (Units.km.distance(meters: estimate) * 100).rounded() / 100)
        XCTAssertNil(TreadmillDistance.correction(consoleM: shownKm, estimateM: estimate, units: .km))
    }

    func testSkippedOrNonsenseReadingsAreNotCorrections() {
        for reading in [nil, 0, -1_000, .nan, .infinity] as [Double?] {
            XCTAssertNil(TreadmillDistance.correction(consoleM: reading, estimateM: estimate, units: .mi), "\(String(describing: reading))")
        }
    }

    func testOneHundredthEitherWayIsACorrection() throws {
        let shown = (Units.mi.distance(meters: estimate) * 100).rounded() / 100
        for hundredths in [-1.0, 1.0] {
            let reading = Units.mi.meters(distance: shown + hundredths / 100)
            let c = try XCTUnwrap(TreadmillDistance.correction(consoleM: reading, estimateM: estimate, units: .mi))
            XCTAssertEqual(c, TreadmillDistance.Correction(consoleM: reading, estimateM: estimate))
        }
        XCTAssertEqual(TreadmillDistance.correction(consoleM: console, estimateM: 0, units: .mi),
                       TreadmillDistance.Correction(consoleM: console, estimateM: 0), "no steps: the console is the run")
    }

    // MARK: - Counting steps

    /// Core Motion's total keeps counting through a pause. The walk to the water fountain
    /// moves the baseline, not the curve.
    func testStepsWhilePausedAreNotCredited() {
        var steps = TreadmillDistance.Steps()
        var curve = [Point(t: 0, m: 0)]
        func feed(_ total: Double, _ t: Double, running: Bool) {
            if let p = steps.credit(totalM: total, t: t, running: running, after: curve.last!) { curve.append(p) }
        }
        feed(100, 30, running: true)
        feed(200, 60, running: true)
        feed(230, 90, running: false)   // walked 30 m to the fountain
        feed(300, 120, running: true)
        XCTAssertEqual(curve, [Point(t: 0, m: 0), Point(t: 30, m: 100), Point(t: 60, m: 200), Point(t: 120, m: 270)])
    }

    /// A total that drops (the counter restarted) is never negative running.
    func testACounterThatGoesBackwardsTakesNothingAway() {
        var steps = TreadmillDistance.Steps()
        let last = Point(t: 60, m: 500)
        XCTAssertEqual(steps.credit(totalM: 500, t: 60, running: true, after: Point(t: 0, m: 0)), Point(t: 60, m: 500))
        XCTAssertNil(steps.credit(totalM: 20, t: 70, running: true, after: last))
        XCTAssertEqual(steps.credit(totalM: 50, t: 80, running: true, after: last), Point(t: 80, m: 530))
    }

    // MARK: - What the run says about it

    func testTheNoteIsInTheUnitHeRanIn() {
        XCTAssertEqual(TreadmillDistance.note(correction(console), units: .mi),
                       "Treadmill console: 5.00 mi (phone estimated 4.71 mi)")
        XCTAssertEqual(TreadmillDistance.note(TreadmillDistance.Correction(consoleM: 8_000, estimateM: 7_480), units: .km),
                       "Treadmill console: 8.00 km (phone estimated 7.48 km)")
        XCTAssertEqual(TreadmillDistance.note(TreadmillDistance.Correction(consoleM: 8_000, estimateM: 0), units: .km),
                       "Treadmill console: 8.00 km (phone counted no steps)")
    }

    /// The correction rides in the workout's own metadata, so every path that reads the
    /// workout back — the save, a queued retry after a relaunch, a run found in Health after
    /// a kill — sees the same correction.
    func testTheCorrectionRoundTripsThroughWorkoutMetadata() {
        let c = correction(console)
        let metadata = RecordingMetadata.atSave(state: RecorderState(), correction: c, units: .mi)
        XCTAssertEqual(RecordingMetadata.correction(from: metadata),
                       WorkoutRow.Workout.Correction(consoleM: console, estimateM: estimate,
                                                     note: "Treadmill console: 5.00 mi (phone estimated 4.71 mi)"))
        XCTAssertNil(RecordingMetadata.correction(from: RecordingMetadata.atSave(state: RecorderState())))
        XCTAssertTrue(RecordingMetadata.atSave(state: RecorderState()).isEmpty, "an uncorrected free run adds nothing")
        var partial = metadata
        partial[RecordingMetadata.correctionNoteKey] = nil
        XCTAssertNil(RecordingMetadata.correction(from: partial), "half a correction is not one")
    }
}
