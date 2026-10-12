import XCTest
@testable import Tempo

/// Pins the recorder's GPS math (#112).
///
/// Until the recorder, every distance Tempo showed was somebody else's — Garmin's, read back
/// out of HealthKit. This is the first time Tempo turns raw fixes into a number the athlete
/// races against, live. Raw fixes lie in a handful of well-known ways: the first few before
/// a lock, the 300 m jump under a building, the stretch where accuracy falls apart, the
/// altitude that wanders while standing on a track. Each one reads as a plausible wrong
/// number rather than a crash, so each one has a fixture here.
///
/// Every fixture is synthetic and deterministic — built from arithmetic and a seeded RNG —
/// so a failure reproduces exactly.
final class TrackMathTests: XCTestCase {

    // MARK: - Fixtures

    /// Grant Park, roughly where the Chicago Marathon starts. Latitude matters: it is what
    /// makes a degree of longitude shorter than a degree of latitude.
    private let lat0 = 41.8756
    private let lon0 = -87.6244
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let mile = 1609.34
    private let km = 1000.0

    /// A position `east`, `north` metres from the origin, on a local flat projection. The
    /// engine measures with haversine, so a fixture built this way is not measured with the
    /// same formula that drew it.
    private func coordinate(east: Double, north: Double) -> (lat: Double, lon: Double) {
        let mPerDegLat = TrackMath.earthRadiusM * .pi / 180
        let mPerDegLon = mPerDegLat * cos(lat0 * .pi / 180)
        return (lat0 + north / mPerDegLat, lon0 + east / mPerDegLon)
    }

    private func fix(
        t: Double,
        east: Double,
        north: Double,
        accuracy: Double = 5,
        altitude: Double? = nil
    ) -> TrackMath.Fix {
        let c = coordinate(east: east, north: north)
        return TrackMath.Fix(
            timestamp: start.addingTimeInterval(t),
            latitude: c.lat,
            longitude: c.lon,
            horizontalAccuracy: accuracy,
            altitude: altitude ?? 0,
            verticalAccuracy: altitude == nil ? -1 : 4
        )
    }

    /// A straight line on a 37° bearing at a constant pace, one fix a second.
    private func straightLine(meters: Double, secPerKm: Double, from t0: Double = 0) -> [TrackMath.Fix] {
        let speed = 1000 / secPerKm
        let duration = meters / speed
        let bearing = 37.0 * .pi / 180
        return stride(from: 0.0, through: duration, by: 1).map { s in
            let d = s * speed
            return fix(t: t0 + s, east: d * sin(bearing), north: d * cos(bearing))
        }
    }

    /// Laps of a 400 m track (a circle — close enough for distance), one fix a second.
    private func loop(laps: Double, secPerKm: Double) -> [TrackMath.Fix] {
        let r = 400 / (2 * Double.pi)
        let speed = 1000 / secPerKm
        let duration = laps * 400 / speed
        return stride(from: 0.0, through: duration, by: 1).map { s in
            let theta = s * speed / r
            return fix(t: s, east: r * sin(theta), north: r - r * cos(theta))
        }
    }

    /// A finished run: every fix ingested, then closed the way the recorder closes it.
    private func record(_ fixes: [TrackMath.Fix]) -> TrackMath.Track {
        var track = TrackMath.Track(start: start)
        for f in fixes { track.ingest(f) }
        track.close()
        return track
    }

    private func percentError(_ measured: Double, _ truth: Double) -> Double {
        abs(measured - truth) / truth * 100
    }

    /// SplitMix64 — deterministic noise, so a red test reproduces bit for bit.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func gaussian() -> Double {
            let u1 = Double.random(in: Double.ulpOfOne..<1, using: &self)
            let u2 = Double.random(in: 0..<1, using: &self)
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
    }

    // MARK: - Distance on clean tracks

    /// The baseline: a straight 5 K at 5:00/km reads 5 K, and every pace reads 5:00.
    func testStraightLineAtKnownPaceIsWithinOnePercent() throws {
        let track = record(straightLine(meters: 5000, secPerKm: 300))
        let summary = track.summary(unitMeters: km, now: start.addingTimeInterval(1500))
        let error = percentError(summary.distanceM, 5000)
        print("[TrackMath] straight 5K: \(summary.distanceM) m, error \(error) %")

        XCTAssertLessThan(error, 1)
        XCTAssertEqual(try XCTUnwrap(summary.averagePaceElapsedS), 300, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(summary.averagePaceMovingS), 300, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(summary.currentPaceS), 300, accuracy: 3)
        XCTAssertEqual(summary.movingS, 1500, accuracy: 5)
        XCTAssertEqual(track.verdicts[.tooFast, default: 0], 0, "a clean run is never rejected")
    }

    /// Ten laps of the track: the smoothing and the 5 m credit step both cut corners in
    /// principle, and a 64 m radius is about as tight as a run gets.
    func testTrackLoopIsWithinOnePercent() {
        let track = record(loop(laps: 10, secPerKm: 270))
        let error = percentError(track.distanceM, 4000)
        print("[TrackMath] 10-lap loop: \(track.distanceM) m, error \(error) %")
        XCTAssertLessThan(error, 1)
    }

    /// Real fixes are not exact: they wander a metre or two, slowly. Correlated noise is
    /// what makes a GPS track read long, because every wobble adds sideways distance.
    func testStraightLineWithRealisticJitterIsWithinOnePercent() {
        var rng = SeededRNG(state: 112)
        var nx = 0.0, ny = 0.0
        let rho = 0.9, sigma = 2.0
        let noisy = straightLine(meters: 5000, secPerKm: 300).enumerated().map { i, f -> TrackMath.Fix in
            nx = rho * nx + sqrt(1 - rho * rho) * sigma * rng.gaussian()
            ny = rho * ny + sqrt(1 - rho * rho) * sigma * rng.gaussian()
            let d = Double(i) * (1000.0 / 300)
            let bearing = 37.0 * .pi / 180
            return fix(t: Double(i), east: d * sin(bearing) + nx, north: d * cos(bearing) + ny)
        }
        let track = record(noisy)
        let error = percentError(track.distanceM, 5000)
        print("[TrackMath] jittery 5K (AR(1) sigma 2 m): \(track.distanceM) m, error \(error) %")
        XCTAssertLessThan(error, 1)
    }

    // MARK: - Fixes that lie

    /// One fix thrown 300 m sideways — the underpass, the glass tower. Taking it would add
    /// 600 m to the run (there and back) in one second.
    func testTeleportSpikeIsRejected() {
        var fixes = straightLine(meters: 5000, secPerKm: 300)
        let clean = record(fixes).distanceM
        let i = 600
        let f = fixes[i]
        let c = coordinate(east: 300, north: 0)
        fixes[i] = TrackMath.Fix(
            timestamp: f.timestamp,
            latitude: f.latitude + (c.lat - lat0),
            longitude: f.longitude + (c.lon - lon0),
            horizontalAccuracy: 8                       // it *claims* to be good
        )

        let track = record(fixes)
        print("[TrackMath] 300 m spike: \(track.distanceM) m vs clean \(clean) m, tooFast=\(track.verdicts[.tooFast, default: 0])")
        XCTAssertEqual(track.verdicts[.tooFast], 1, "exactly the spike, nothing else")
        XCTAssertEqual(track.distanceM, clean, accuracy: 5, "the spike adds nothing")
        XCTAssertLessThan(percentError(track.distanceM, 5000), 1)
    }

    /// Ninety seconds where accuracy collapses to 40 m and the positions scatter with it.
    /// Every one of those fixes is dropped; the good fix after the gap bridges it.
    func testFortyMetreAccuracyStretchIsDropped() {
        var rng = SeededRNG(state: 40)
        var fixes = straightLine(meters: 5000, secPerKm: 300)
        for i in 900..<990 {
            let f = fixes[i]
            let c = coordinate(east: Double.random(in: -35...35, using: &rng),
                               north: Double.random(in: -35...35, using: &rng))
            fixes[i] = TrackMath.Fix(
                timestamp: f.timestamp,
                latitude: f.latitude + (c.lat - lat0),
                longitude: f.longitude + (c.lon - lon0),
                horizontalAccuracy: 40
            )
        }

        let track = record(fixes)
        print("[TrackMath] 40 m-accuracy stretch: \(track.distanceM) m, error \(percentError(track.distanceM, 5000)) %")
        XCTAssertEqual(track.verdicts[.inaccurate], 90)
        XCTAssertLessThan(percentError(track.distanceM, 5000), 1)
    }

    /// Cold start: CoreLocation hands over where the phone was last night, then a few fixes
    /// that are accurate-ish but disagree with each other, then settles. None of it counts.
    func testNothingCountsBeforeTheFirstGoodLock() {
        let run = straightLine(meters: 2000, secPerKm: 300, from: 10)
        let cached = TrackMath.Fix(timestamp: start.addingTimeInterval(-3600),
                                   latitude: lat0 + 0.05, longitude: lon0, horizontalAccuracy: 5)
        let coarse = (0..<4).map { fix(t: Double($0), east: 0, north: 0, accuracy: 65) }
        // Accurate by their own claim, but 200 m apart a second apart: still converging.
        let converging = (4..<9).map { fix(t: Double($0), east: Double(($0 + 1) % 2) * 200, north: 0, accuracy: 20) }

        var track = TrackMath.Track(start: start)
        XCTAssertEqual(track.ingest(cached), .stale)
        for f in coarse { XCTAssertEqual(track.ingest(f), .inaccurate) }
        for f in converging { track.ingest(f) }
        XCTAssertFalse(track.isLocked, "five fixes that disagree are not a lock")
        XCTAssertEqual(track.distanceM, 0)

        XCTAssertEqual(track.ingest(run[0]), .awaitingLock)
        XCTAssertEqual(track.ingest(run[1]), .awaitingLock)
        XCTAssertEqual(track.ingest(run[2]), .accepted, "three in a row that agree")
        for f in run.dropFirst(3) { track.ingest(f) }
        track.close()

        XCTAssertLessThan(percentError(track.distanceM, 2000), 1)
    }

    /// A fix delivered twice, or late, can only ever be ignored — the curve never runs back.
    func testDuplicateAndOutOfOrderFixesAreIgnored() {
        let run = straightLine(meters: 500, secPerKm: 300)
        var track = TrackMath.Track(start: start)
        for f in run.prefix(50) { track.ingest(f) }
        XCTAssertEqual(track.ingest(run[49]), .outOfOrder)
        XCTAssertEqual(track.ingest(run[20]), .outOfOrder)
        for f in run.dropFirst(50) { track.ingest(f) }
        track.close()

        XCTAssertEqual(track.timeline.map(\.t), track.timeline.map(\.t).sorted())
        XCTAssertLessThan(percentError(track.distanceM, 500), 1)
    }

    // MARK: - Pace

    /// The current pace follows the athlete: 2 km easy then 1 km hard reads hard at the end,
    /// while the average stays the average.
    func testCurrentPaceFollowsAChangeOfPaceAndAveragesDoNot() throws {
        let easy = straightLine(meters: 2000, secPerKm: 360)
        // Continue the line from where the easy block ended.
        let hardStartT = easy.last!.timestamp.timeIntervalSince(start)
        let bearing = 37.0 * .pi / 180
        let hard = stride(from: 1.0, through: 240, by: 1).map { s -> TrackMath.Fix in
            let d = 2000 + s * (1000.0 / 240)
            return fix(t: hardStartT + s, east: d * sin(bearing), north: d * cos(bearing))
        }
        // Live — not closed. This is the screen mid-run, where distance trails the athlete
        // by a step; the first version of the window counted that trail as standing still
        // and read this 4:00/km as 4:17.
        var track = TrackMath.Track(start: start)
        for f in easy + hard { track.ingest(f) }
        let end = start.addingTimeInterval(hardStartT + 240)
        let summary = track.summary(unitMeters: km, now: end)

        XCTAssertEqual(try XCTUnwrap(summary.currentPaceS), 240, accuracy: 5)
        XCTAssertEqual(try XCTUnwrap(summary.averagePaceElapsedS), (720 + 240) / 3, accuracy: 5)
    }

    /// A minute at a red light — standing still, the fix wandering a metre and a half.
    /// Elapsed keeps counting; distance and moving time do not; current pace goes blank
    /// rather than decaying towards an hour a mile.
    func testStandingAtALightAddsNoDistanceAndNoMovingTime() throws {
        var rng = SeededRNG(state: 7)
        let first = straightLine(meters: 1000, secPerKm: 300)
        let stopAt = first.last!.timestamp.timeIntervalSince(start)
        let bearing = 37.0 * .pi / 180
        let here = (east: 1000 * sin(bearing), north: 1000 * cos(bearing))
        let standing = stride(from: 1.0, through: 120, by: 1).map { s in
            fix(t: stopAt + s,
                east: here.east + Double.random(in: -1.5...1.5, using: &rng),
                north: here.north + Double.random(in: -1.5...1.5, using: &rng))
        }
        var track = TrackMath.Track(start: start)
        for f in first { track.ingest(f) }
        // The first few seconds of standing let the smoothed position catch up to where the
        // athlete actually stopped — that is real distance, the tail of the run. The wander
        // after it is what must add nothing.
        for f in standing.prefix(5) { track.ingest(f) }
        let beforeStop = track.distanceM
        for f in standing.dropFirst(5) { track.ingest(f) }

        print("[TrackMath] 115 s at a light: +\(track.distanceM - beforeStop) m")
        XCTAssertEqual(track.distanceM, beforeStop, accuracy: 0.001, "wander under the 5 m step credits nothing")

        let atLight = track.summary(unitMeters: mile, now: start.addingTimeInterval(stopAt + 120))
        XCTAssertNil(atLight.currentPaceS, "two minutes stopped: no current pace")
        XCTAssertEqual(atLight.elapsedS - atLight.movingS, 120, accuracy: 5)

        let moving = try XCTUnwrap(atLight.averagePaceMovingS)
        let elapsed = try XCTUnwrap(atLight.averagePaceElapsedS)
        XCTAssertGreaterThan(elapsed, moving, "the stop shows in elapsed pace only")
    }

    /// A 400 m rep: live, the distance trails by a step plus the smoothing lag — over 1 % of
    /// something this short. Closing the run credits it, once.
    func testClosingCreditsTheTrailingMetresOnce() {
        var track = TrackMath.Track(start: start)
        for f in straightLine(meters: 400, secPerKm: 200) { track.ingest(f) }
        let live = track.distanceM
        track.close()
        let closed = track.distanceM
        track.close()
        print("[TrackMath] 400 m rep: live \(live) m, closed \(closed) m")

        XCTAssertLessThan(live, 400)
        XCTAssertEqual(closed, 400, accuracy: 0.5)
        XCTAssertEqual(track.distanceM, closed, "a second close adds nothing")
    }

    /// Ten seconds without a credited step is a stop: the pace goes blank rather than
    /// holding the last running number.
    func testCurrentPaceGoesBlankShortlyAfterStopping() throws {
        var track = TrackMath.Track(start: start)
        for f in straightLine(meters: 1000, secPerKm: 300) { track.ingest(f) }
        XCTAssertEqual(try XCTUnwrap(track.summary(unitMeters: km, now: start.addingTimeInterval(300)).currentPaceS),
                       300, accuracy: 3)
        XCTAssertNil(track.summary(unitMeters: km, now: start.addingTimeInterval(315)).currentPaceS)
    }

    func testNoPaceBeforeThereIsAWindow() {
        let track = record(straightLine(meters: 40, secPerKm: 300))
        let s = track.summary(unitMeters: km, now: start.addingTimeInterval(12))
        XCTAssertNil(s.currentPaceS)
        XCTAssertNil(s.averagePaceElapsedS, "under 5 % of a unit has no pace")
    }

    // MARK: - Splits

    /// Splits sit on exact boundaries — a hand-built curve with points right on the mile
    /// markers and between them, negative-split.
    func testSplitsLandOnExactBoundaries() {
        let timeline = [
            BestEfforts.Point(t: 0, m: 0),
            BestEfforts.Point(t: 300, m: 1000),
            BestEfforts.Point(t: 500, m: mile),          // mile 1 at exactly 500 s
            BestEfforts.Point(t: 970, m: 2 * mile),      // mile 2 in 470 s
            BestEfforts.Point(t: 1200, m: 2.5 * mile),   // half a mile at 7:40/mi
        ]
        let splits = TrackMath.splits(timeline: timeline, splitMeters: mile)

        XCTAssertEqual(splits.map(\.index), [1, 2, 3])
        XCTAssertEqual(splits[0].durationS, 500, accuracy: 0.001)
        XCTAssertEqual(splits[1].durationS, 470, accuracy: 0.001)
        XCTAssertEqual(splits[1].paceS, 470, accuracy: 0.001)
        XCTAssertFalse(splits[1].isPartial)

        XCTAssertTrue(splits[2].isPartial)
        XCTAssertEqual(splits[2].meters, 0.5 * mile, accuracy: 0.001)
        XCTAssertEqual(splits[2].paceS, 460, accuracy: 0.001, "a partial reports pace per full mile")
        XCTAssertNil(splits[0].elevationDeltaM, "no altitude recorded, no claim")
    }

    /// The same recorded run, split by mile and by km, from the same curve. The split length
    /// is the only input that changes — which is what `Units` (#108) will supply.
    func testRecordedRunSplitsByMileAndByKilometre() {
        let track = record(straightLine(meters: 6000, secPerKm: 300))
        let byKm = TrackMath.splits(timeline: track.timeline, splitMeters: km)
        let byMile = TrackMath.splits(timeline: track.timeline, splitMeters: mile)
        print("[TrackMath] km splits: \(byKm.map { String(format: "%.1f", $0.durationS) })")

        // 6 km reads as 5 or 6 full kms depending on the last few metres — never a partial
        // stub. Check the full ones.
        for s in byKm where !s.isPartial { XCTAssertEqual(s.durationS, 300, accuracy: 1.5) }
        XCTAssertGreaterThanOrEqual(byKm.filter { !$0.isPartial }.count, 5)

        XCTAssertEqual(byMile.filter { !$0.isPartial }.count, 3)
        for s in byMile.prefix(3) { XCTAssertEqual(s.durationS, 482.8, accuracy: 1.5) }
        XCTAssertEqual(byMile.last?.isPartial, true)
    }

    /// 30 m past the marker is not a split.
    func testATinyTrailingSplitIsNotReported() {
        let timeline = [BestEfforts.Point(t: 0, m: 0), BestEfforts.Point(t: 310, m: 1030)]
        XCTAssertEqual(TrackMath.splits(timeline: timeline, splitMeters: km).count, 1)
    }

    // MARK: - Elevation

    /// Thirty minutes on a flat road with altitude bouncing ±3 m every fix. Summing every
    /// upward wiggle — the naive method — reads a hilly run; the hysteresis reads flat.
    func testFlatRunWithNoisyAltitudeReadsFlat() {
        var rng = SeededRNG(state: 3)
        let altitudes = (0..<1800).map { _ in 180 + Double.random(in: -3...3, using: &rng) }
        let fixes = straightLine(meters: 6000, secPerKm: 300).prefix(1800).enumerated().map { i, f in
            TrackMath.Fix(timestamp: f.timestamp, latitude: f.latitude, longitude: f.longitude,
                          horizontalAccuracy: 5, altitude: altitudes[i], verticalAccuracy: 6)
        }
        let track = record(Array(fixes))

        var naive = 0.0
        for i in 1..<altitudes.count where altitudes[i] > altitudes[i - 1] { naive += altitudes[i] - altitudes[i - 1] }
        print("[TrackMath] noisy flat: gain \(track.elevationGainM) m, loss \(track.elevationLossM) m; naive raw gain \(naive) m")

        XCTAssertLessThan(track.elevationGainM, TrackMath.elevationHysteresisM)
        XCTAssertLessThan(track.elevationLossM, TrackMath.elevationHysteresisM)
        XCTAssertGreaterThan(naive, 1000, "the failure being prevented is real")
    }

    /// A real hill still counts in full: 30 m up over a km, 30 m down over the next, with
    /// a metre of noise. And the km splits say which way each one went.
    func testARealHillIsCountedAndSplitsCarryTheChange() throws {
        var rng = SeededRNG(state: 30)
        let fixes = straightLine(meters: 2100, secPerKm: 300).map { f -> TrackMath.Fix in
            let t = f.timestamp.timeIntervalSince(start)
            let d = t * (1000.0 / 300)
            let ground = d <= 1000 ? 100 + 30 * d / 1000 : 130 - 30 * min(d - 1000, 1000) / 1000
            return TrackMath.Fix(timestamp: f.timestamp, latitude: f.latitude, longitude: f.longitude,
                                 horizontalAccuracy: 5,
                                 altitude: ground + Double.random(in: -1...1, using: &rng),
                                 verticalAccuracy: 4)
        }
        let track = record(fixes)
        print("[TrackMath] 30 m hill: gain \(track.elevationGainM) m, loss \(track.elevationLossM) m")
        XCTAssertEqual(track.elevationGainM, 30, accuracy: 3)
        XCTAssertEqual(track.elevationLossM, 30, accuracy: 3)

        let splits = TrackMath.splits(timeline: track.timeline, altitudes: track.altitudes, splitMeters: km)
        XCTAssertEqual(try XCTUnwrap(splits[0].elevationDeltaM), 30, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(splits[1].elevationDeltaM), -30, accuracy: 3)
    }

    func testHysteresisIgnoresWobbleAndCountsAClimbInFull() {
        XCTAssertEqual(TrackMath.elevation([0, 1, 2, 1, 0, 1, 2, 0]).gainM, 0, "never moved 3 m")

        let climb = TrackMath.elevation(Array(stride(from: 0.0, through: 10, by: 1)))
        XCTAssertEqual(climb.gainM, 10, "all ten metres, not 9")

        let dip = TrackMath.elevation([0, 5, 10, 8, 10, 11])
        XCTAssertEqual(dip.gainM, 11, "a 2 m dip is not a descent")
        XCTAssertEqual(dip.lossM, 0)

        let overTheTop = TrackMath.elevation([0, 5, 10, 6, 2])
        XCTAssertEqual(overTheTop.gainM, 10)
        XCTAssertEqual(overTheTop.lossM, 8)
    }

    // MARK: - The curve is the PR scan's curve

    /// The recorder's timeline is a `[BestEfforts.Point]` so a recorded run feeds the PR scan
    /// with no adapter. Pin that the two agree on a steady 5:00/km.
    func testRecordedTimelineFeedsTheBestEffortsScan() throws {
        let track = record(straightLine(meters: 5200, secPerKm: 300))
        let efforts = BestEfforts.efforts(timeline: track.timeline)
        let fiveK = try XCTUnwrap(efforts.first { $0.distanceM == 5000 })
        XCTAssertEqual(Double(fiveK.durationS), 1500, accuracy: 3)
    }
}
