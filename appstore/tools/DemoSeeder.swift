import Foundation
import HealthKit
import CoreLocation

/// SCRATCH ONLY — never committed. Writes a fictional runner into the simulator's Apple Health
/// so the App Store screenshots come through the real ingest and engine.
enum DemoSeeder {
    static func log(_ m: String) {
        let path = NSTemporaryDirectory() + "seed.log"
        let line = m + "\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8)) }
    }
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-seedHealth") }

    struct RNG { var s: UInt64
        mutating func next() -> Double {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    }

    struct Seg { let meters: Double; let pace: Double; let hr: Double }   // pace = s/mi
    struct Plan { let start: Date; let segs: [Seg]; let rich: Bool; let label: String }

    static let mile = 1609.34
    static let cal: Calendar = { var c = Calendar(identifier: .iso8601); c.timeZone = .current; return c }()

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 7, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Fitness as a pace multiplier: 1.0 is today's runner; early 2023 is about 18% slower.
    static func fitness(at d: Date) -> Double {
        let start = date(2023, 1, 2), end = date(2026, 11, 3)
        let t = max(0, min(1, d.timeIntervalSince(start) / end.timeIntervalSince(start)))
        return 1.0 + 0.18 * pow(1 - t, 1.25)
    }

    /// Weekly volume in miles: builds over the years, cycling through race blocks.
    static func weekly(at d: Date, _ r: inout RNG) -> Double {
        let start = date(2023, 1, 2)
        let weeks = d.timeIntervalSince(start) / (7 * 86400)
        let base = 15 + 17 * min(1, weeks / 170)
        let cycle = 5.5 * sin(weeks / 24 * 2 * .pi - 1.1)
        return max(7, base + cycle + r.range(-3.5, 3.5))
    }

    static func easy(_ miles: Double, _ f: Double, _ r: inout RNG) -> [Seg] {
        let p = 562 * f + r.range(-10, 14)
        return miles.chunks.map { Seg(meters: $0 * mile, pace: p + r.range(-8, 8), hr: 139 + r.range(-3, 4)) }
    }

    /// Every run is a list of ~mile segments; quality days alternate reps and float.
    static func plans() -> [Plan] {
        var r = RNG(s: 20270314)
        var out: [Plan] = []
        // Races, by Sunday, in the fictional athlete's history.
        let races: [String: (Double, Double)] = [
            "2023-10-15": (21097.5, 7040),   // half, 1:57:20
            "2024-04-14": (10000, 2720),     // 10K, 45:20
            "2024-10-20": (42195, 15250),    // marathon, 4:14:10
            "2025-05-04": (21097.5, 6400),   // half, 1:46:40
            "2025-10-19": (42195, 13760),    // marathon, 3:49:20
            "2026-04-19": (10000, 2500),     // 10K, 41:40
            "2026-10-11": (21097.5, 5945),   // half, 1:39:05
        ]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = cal
        let cutoff = date(2026, 11, 3, 5)
        var monday = date(2023, 1, 2, 7)
        while monday < cutoff {
            let k = fitness(at: monday)
            let vol = weekly(at: monday, &r)
            let wk = cal.component(.weekOfYear, from: monday)
            let sunday = cal.date(byAdding: .day, value: 6, to: monday)!
            // A down week after each race.
            let lastSunday = cal.date(byAdding: .day, value: -1, to: monday)!
            let recovering = races[f.string(from: lastSunday)] != nil
            let v = recovering ? vol * 0.45 : vol
            let longShare = recovering ? 0.25 : 0.34
            let longMiles = min(20, v * longShare)
            let rest = v - longMiles
            let dayPlan: [(Int, Double, String)] = recovering
                ? [(1, rest * 0.34, "easy"), (3, rest * 0.33, "easy"), (5, rest * 0.33, "easy")]
                : [(1, rest * 0.30, wk % 2 == 0 ? "tempo" : "interval"), (2, rest * 0.22, "easy"),
                   (3, rest * 0.26, "tempo2"), (5, rest * 0.22, "easy")]
            for (off, miles, kind) in dayPlan where miles >= 2 {
                let day = cal.date(byAdding: .day, value: off, to: monday)!
                let start = cal.date(byAdding: .minute, value: Int(r.range(-25, 40)), to: day)!
                guard start < cutoff else { continue }
                out.append(Plan(start: start, segs: segments(kind, miles, k, &r), rich: false, label: kind))
            }
            let sStart = cal.date(byAdding: .minute, value: Int(r.range(0, 45)), to: sunday)!
            if sStart < cutoff {
                if let race = races[f.string(from: sunday)] {
                    let pace = race.1 / (race.0 / mile)
                    let segs = (race.0 / mile).chunks.map { m in
                        Seg(meters: m * mile, pace: pace + r.range(-5, 5), hr: 168 + r.range(-3, 4))
                    }
                    out.append(Plan(start: sStart, segs: segs, rich: false, label: "race"))
                } else {
                    let p = 575 * k + r.range(-8, 10)
                    let segs = longMiles.chunks.map { Seg(meters: $0 * mile, pace: p + r.range(-9, 9), hr: 146 + r.range(-3, 5)) }
                    out.append(Plan(start: sStart, segs: segs, rich: false, label: "long"))
                }
            }
            monday = cal.date(byAdding: .day, value: 7, to: monday)!
        }
        // The last dozen carry routes and heart rate for Run Detail.
        out.sort { $0.start < $1.start }
        return out.enumerated().map { i, p in
            Plan(start: p.start, segs: p.segs, rich: i >= out.count - 12, label: p.label)
        }
    }

    static func segments(_ kind: String, _ miles: Double, _ k: Double, _ r: inout RNG) -> [Seg] {
        switch kind {
        case "tempo", "tempo2":
            let warm = 1.5, cool = max(1, miles - 4.5)
            let body = stride(from: 0.0, to: 3.0, by: 0.5).map { _ in
                Seg(meters: 0.5 * mile, pace: 448 * k + r.range(-4, 4), hr: 164 + r.range(-2, 4))
            }
            return easy(warm, k, &r) + body + easy(cool, k, &r)
        case "interval":
            var s = easy(1.5, k, &r)
            for _ in 0..<5 {
                s.append(Seg(meters: 800, pace: 408 * k + r.range(-5, 5), hr: 171 + r.range(-2, 4)))
                s.append(Seg(meters: 400, pace: 640 * k + r.range(-8, 8), hr: 148 + r.range(-3, 3)))
            }
            return s + easy(max(1, miles - 5.2), k, &r)
        default:
            return easy(miles, k, &r)
        }
    }

    // MARK: Route — a loop of Central Park's drives, in order.
    static let loop: [CLLocationCoordinate2D] = [
        (40.7681,-73.9812),(40.7712,-73.9796),(40.7745,-73.9762),(40.7790,-73.9727),(40.7830,-73.9695),
        (40.7870,-73.9664),(40.7915,-73.9631),(40.7958,-73.9597),(40.7984,-73.9574),(40.7994,-73.9539),
        (40.7972,-73.9512),(40.7945,-73.9519),(40.7905,-73.9549),(40.7860,-73.9584),(40.7820,-73.9614),
        (40.7780,-73.9648),(40.7745,-73.9680),(40.7705,-73.9714),(40.7672,-73.9736),(40.7654,-73.9762),
        (40.7658,-73.9794),(40.7681,-73.9812)
    ].map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }

    /// Densified loop with cumulative metres, so any distance maps to a coordinate.
    static let path: (pts: [CLLocationCoordinate2D], cum: [Double]) = {
        var pts: [CLLocationCoordinate2D] = []
        let n = loop.count
        for i in 0..<(n - 1) {
            let p0 = loop[max(0, i - 1)], p1 = loop[i], p2 = loop[i + 1], p3 = loop[min(n - 1, i + 2)]
            for s in 0..<24 {
                let t = Double(s) / 24
                func cr(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * (2*b + (-a + c)*t + (2*a - 5*b + 4*c - d)*t*t + (-a + 3*b - 3*c + d)*t*t*t)
                }
                pts.append(.init(latitude: cr(p0.latitude, p1.latitude, p2.latitude, p3.latitude),
                                 longitude: cr(p0.longitude, p1.longitude, p2.longitude, p3.longitude)))
            }
        }
        var cum = [0.0]
        for i in 1..<pts.count {
            let a = CLLocation(latitude: pts[i-1].latitude, longitude: pts[i-1].longitude)
            let b = CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude)
            cum.append(cum[i-1] + a.distance(from: b))
        }
        return (pts, cum)
    }()

    static func coordinate(at meters: Double) -> CLLocationCoordinate2D {
        let total = path.cum.last!
        let m = meters.truncatingRemainder(dividingBy: total)
        var lo = 0, hi = path.cum.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if path.cum[mid] < m { lo = mid + 1 } else { hi = mid } }
        return path.pts[lo]
    }

    // MARK: Writing

    static func run() async {
        guard requested else { return }
        try? await Task.sleep(for: .seconds(3))
        log("SEED start")
        let store = HKHealthStore()
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute(),
            HKQuantityType(.distanceWalkingRunning), HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.heartRate), HKQuantityType(.stepCount)]
        let read: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute(),
            HKQuantityType(.distanceWalkingRunning), HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.heartRate), HKQuantityType(.stepCount)]
        do { try await store.requestAuthorization(toShare: share, read: read) }
        catch { log("SEED auth failed \(error)"); return }
        let all = plans()
        log("SEED writing \(all.count) workouts")
        var written = 0
        for p in all {
            do { try await write(p, store) ; written += 1 } catch { log("SEED fail \(error)") }
            if written % 100 == 0 { log("SEED \(written)") }
        }
        log("SEED DONE \(written)")
        UserDefaults.standard.set(true, forKey: "seedDone")
    }

    static func write(_ p: Plan, _ store: HKHealthStore) async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: p.start)
        var t = p.start
        var samples: [HKSample] = []
        var meters = 0.0
        var locations: [CLLocation] = []
        for s in p.segs {
            let secs = s.meters / mile * s.pace
            let end = t.addingTimeInterval(secs)
            samples.append(HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning),
                quantity: HKQuantity(unit: .meter(), doubleValue: s.meters), start: t, end: end))
            if p.rich {
                var c = t
                while c < end {
                    let n = min(end, c.addingTimeInterval(15))
                    let f = c.timeIntervalSince(p.start) / 3600
                    let bpm = s.hr + f * 6 + 2 * sin(c.timeIntervalSince1970 / 47)
                    samples.append(HKQuantitySample(type: HKQuantityType(.heartRate),
                        quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: bpm), start: c, end: c))
                    let spm = 168 + (560 - s.pace) * 0.05
                    samples.append(HKQuantitySample(type: HKQuantityType(.stepCount),
                        quantity: HKQuantity(unit: .count(), doubleValue: spm * n.timeIntervalSince(c) / 60), start: c, end: n))
                    c = n
                }
                var e = 0.0
                while e < secs {
                    let m = meters + s.meters * e / secs
                    let co = coordinate(at: m)
                    let alt = 28 + 9 * sin(m / 900) + 5 * sin(m / 310)
                    locations.append(CLLocation(coordinate: co, altitude: alt, horizontalAccuracy: 5, verticalAccuracy: 4,
                                                course: -1, speed: mile / s.pace, timestamp: t.addingTimeInterval(e)))
                    e += 4
                }
            }
            meters += s.meters
            t = end
        }
        samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: meters / mile * 105), start: p.start, end: t))
        try await builder.addSamples(samples)
        try await builder.endCollection(at: t)
        guard let workout = try await builder.finishWorkout() else { return }
        if !locations.isEmpty {
            let route = HKWorkoutRouteBuilder(healthStore: store, device: .local())
            try await route.insertRouteData(locations)
            _ = try await route.finishRoute(with: workout, metadata: nil)
        }
    }
}

private extension Double {
    /// Whole miles, then the remainder — the shape `distance` samples take.
    var chunks: [Double] {
        var left = self, out: [Double] = []
        while left > 0.01 { let c = Swift.min(1, left); out.append(c); left -= c }
        return out
    }
}
