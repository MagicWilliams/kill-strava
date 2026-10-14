import XCTest
@testable import Tempo

/// How an imported (Garmin → HealthKit) run's detail page measures climb and best pace (#144).
///
/// Until #144, `RunDetailLoader.compute` smoothed route altitudes with a ±5 centred mean and
/// then summed every upward step of that curve. There was no dead band, so whatever altitude
/// noise survived the mean was counted as climb — while a run recorded by Tempo itself went
/// through `TrackMath`'s trailing mean and 3 m hysteresis. Same road, two answers, and the
/// imported one inflated. David chose one method everywhere (decision on #144, 2026-10-12),
/// knowing the ELEV GAIN on every historical run page goes down.
///
/// `legacyGain` below is the method that shipped until #144, kept only so these tests can
/// print the before/after and prove the failure being prevented is real.
///
/// Every fixture is synthetic and seeded, one fix a second like a Garmin route in HealthKit.
final class ImportedElevationTests: XCTestCase {

    // MARK: - Fixtures

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
    }

    /// Thirty minutes of a flat road, altitude bouncing ±3 m every fix.
    private func noisyFlat() -> [Double] {
        var rng = SeededRNG(state: 144)
        return (0..<1800).map { _ in 180 + Double.random(in: -3...3, using: &rng) }
    }

    /// 2.1 km at 5:00/km: 30 m up over the first km, 30 m back down over the second, then
    /// flat, with `noise` metres of per-fix wander on top.
    private func hill(noise: Double, seed: UInt64) -> [Double] {
        var rng = SeededRNG(state: seed)
        return (0...630).map { s in
            let d = Double(s) * (1000.0 / 300)
            let ground = d <= 1000 ? 100 + 30 * d / 1000 : 130 - 30 * min(d - 1000, 1000) / 1000
            return ground + Double.random(in: -noise...noise, using: &rng)
        }
    }

    /// What RunDetail reported until #144: ±5 centred mean, every positive delta summed.
    private func legacyGain(_ raw: [Double]) -> (gainM: Double, lossM: Double) {
        guard raw.count > 5 else { return (0, 0) }
        let smooth = raw.indices.map { i -> Double in
            let lo = max(0, i - 5), hi = min(raw.count - 1, i + 5)
            return raw[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        var gain = 0.0, loss = 0.0
        for i in 1..<smooth.count {
            let delta = smooth[i] - smooth[i - 1]
            if delta > 0 { gain += delta } else { loss -= delta }
        }
        return (gain, loss)
    }

    // MARK: - The elevation choice

    /// The incident: a flat imported route read as a climb because the noise that survived
    /// the mean was summed. Now it reads flat.
    func testANoisyFlatImportedRouteReadsFlat() {
        let raw = noisyFlat()
        let before = legacyGain(raw)
        let after = TrackMath.elevation(rawAltitudes: raw)
        print("[#144] noisy flat 30 min: before gain \(before.gainM) m loss \(before.lossM) m; after gain \(after.gainM) m loss \(after.lossM) m")

        XCTAssertLessThan(after.gainM, TrackMath.elevationHysteresisM)
        XCTAssertLessThan(after.lossM, TrackMath.elevationHysteresisM)
        XCTAssertGreaterThan(before.gainM, 20, "the inflation being removed is real")
    }

    /// A real hill must survive the dead band in full — the hysteresis is not allowed to
    /// buy a flat road by shaving real climbs. Both with clean-ish and with ±3 m noise.
    func testARealThirtyMetreHillReadsThirtyMetres() {
        for (noise, seed) in [(1.0, UInt64(30)), (3.0, UInt64(31))] {
            let raw = hill(noise: noise, seed: seed)
            let before = legacyGain(raw)
            let after = TrackMath.elevation(rawAltitudes: raw)
            print("[#144] 30 m hill ±\(noise) m: before gain \(before.gainM) m loss \(before.lossM) m; after gain \(after.gainM) m loss \(after.lossM) m")

            XCTAssertEqual(after.gainM, 30, accuracy: 3, "±\(noise) m noise")
            XCTAssertEqual(after.lossM, 30, accuracy: 3, "±\(noise) m noise")
        }
    }

    /// "One method everywhere" means one: the batch function RunDetail calls gives exactly
    /// the number the live recorder arrives at, fix by fix, on the same altitudes.
    func testImportedAndRecordedRunsAgreeOnTheSameRoad() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let mPerDegLat = TrackMath.earthRadiusM * .pi / 180
        for raw in [noisyFlat(), hill(noise: 1, seed: 30), hill(noise: 3, seed: 31)] {
            var track = TrackMath.Track(start: start)
            for (s, alt) in raw.enumerated() {
                // Due north at 5:00/km, clean positions: every fix is accepted.
                track.ingest(TrackMath.Fix(
                    timestamp: start.addingTimeInterval(Double(s)),
                    latitude: 41.8756 + Double(s) * (1000.0 / 300) / mPerDegLat,
                    longitude: -87.6244,
                    horizontalAccuracy: 5,
                    altitude: alt,
                    verticalAccuracy: 4
                ))
            }
            let batch = TrackMath.elevation(rawAltitudes: raw)
            XCTAssertEqual(batch.gainM, track.elevationGainM, accuracy: 1e-9)
            XCTAssertEqual(batch.lossM, track.elevationLossM, accuracy: 1e-9)
        }
    }

    func testTooFewAltitudesClaimNoClimb() {
        XCTAssertEqual(TrackMath.elevation(rawAltitudes: [100, 110, 120, 130, 140]).gainM, 0,
                       "under one full smoothing window, nothing is measured")
        XCTAssertEqual(TrackMath.elevation(rawAltitudes: []).gainM, 0)
    }

    // MARK: - Best pace moved, not changed

    /// What RunDetail computed inline until #144, verbatim.
    private func legacyBestPace(_ timeline: [(t: Double, m: Double)]) -> Int? {
        guard timeline.count > 2 else { return nil }
        var best = Double.infinity
        var i = 0
        for j in 1..<timeline.count {
            while timeline[j].t - timeline[i].t > 45 { i += 1 }
            let dt = timeline[j].t - timeline[i].t
            let dm = timeline[j].m - timeline[i].m
            if dt >= 25, dm >= 100 { best = min(best, dt / (dm / 1609.34)) }
        }
        return best.isFinite ? Int(best) : nil
    }

    /// Moving best pace into TrackMath must not move the BEST PACE tile on any past run.
    /// A Garmin-shaped run: irregular sample spacing, an 8:00/mi base, a 40 s surge at
    /// ~6:00/mi, and a stop at a light.
    func testBestPaceIsUnchangedByTheMove() throws {
        var rng = SeededRNG(state: 7)
        var timeline: [(t: Double, m: Double)] = [(0, 0)]
        var t = 0.0, m = 0.0
        while t < 1800 {
            let dt = Double.random(in: 2...7, using: &rng)
            let speed: Double
            switch t {
            case 600..<640: speed = 1609.34 / 360     // the surge
            case 900..<960: speed = 0                 // the light
            default: speed = 1609.34 / 480 + Double.random(in: -0.2...0.2, using: &rng)
            }
            t += dt; m += speed * dt
            timeline.append((t, m))
        }
        let moved = TrackMath.bestPace(timeline: timeline.map { BestEfforts.Point(t: $0.t, m: $0.m) },
                                       unitMeters: Units.mi.meters).map { Int($0) }
        XCTAssertEqual(moved, legacyBestPace(timeline))
        XCTAssertEqual(Double(try XCTUnwrap(moved)), 360, accuracy: 30, "the surge is what reads as best")
    }

    func testBestPaceNeedsAQualifyingWindow() {
        // 20 s of running: never 25 s long.
        let short = (0...20).map { BestEfforts.Point(t: Double($0), m: Double($0) * 4) }
        XCTAssertNil(TrackMath.bestPace(timeline: short, unitMeters: Units.mi.meters))
        // A minute of walking: long enough, never 100 m inside 45 s.
        let walk = (0...60).map { BestEfforts.Point(t: Double($0), m: Double($0) * 1.5) }
        XCTAssertNil(TrackMath.bestPace(timeline: walk, unitMeters: Units.mi.meters))
    }
}
