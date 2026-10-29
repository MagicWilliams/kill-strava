import Foundation
import HealthKit
import CoreLocation

/// Everything the Run Detail page shows for one run, computed from HealthKit series
/// (distance samples → pace curve/splits/time accounting, HR samples → zones,
/// workout route → map + elevation).
struct RunDetail {
    struct SeriesPoint: Identifiable {
        let id: Int
        let miles: Double
        let paceSecPerMile: Double?
        let hr: Double?
        let elevationM: Double?
    }

    typealias Split = SplitTable.Split

    struct RouteSegment: Identifiable {
        let id: Int
        let coords: [CLLocationCoordinate2D]
        let zone: Int            // 0…4 pace bucket → Tokens.Zone.all
    }

    var series: [SeriesPoint] = []
    /// Mile splits and km splits, both cut once at load (#109) so flipping the unit
    /// doesn't recompute anything. Read through `splits(_:)`.
    var mileSplits: [Split] = []
    var kmSplits: [Split] = []
    func splits(_ units: Units) -> [Split] {
        switch units {
        case .mi: return mileSplits
        case .km: return kmSplits
        }
    }
    var routeSegments: [RouteSegment] = []
    var hasRoute: Bool { !routeSegments.isEmpty }

    /// The raw curves the race recap is computed from, as plain parallel arrays so
    /// `RaceRecap` can stay pure: cumulative metres against seconds from the workout start,
    /// and every HR sample against the same clock.
    var cumulativeTimesS: [Double] = []
    var cumulativeMeters: [Double] = []
    var hrTimesS: [Double] = []
    var hrBPM: [Double] = []

    // Time accounting (Garmin-style trio)
    var timerS: Int = 0          // workout duration as recorded
    var movingS: Int = 0         // derived: sample intervals actually moving (timer when no samples)
    /// `SampleMovingTime.movingSeconds`, rounded; nil when the workout had no distance
    /// samples. The Time card compares it with the stored moving time (#237).
    var sampleMovingS: Int?
    var elapsedS: Int = 0        // wall clock start → end

    var miles: Double = 0
    var avgPaceSec: Int?         // per mile, over timer time
    var elapsedPaceSec: Int?     // per mile, over elapsed time
    var bestPaceSec: Int?        // fastest rolling ~30 s
    var avgSpeedMph: Double?

    var avgHR: Int?
    var maxHR: Int?
    var zoneSeconds: [Double] = [0, 0, 0, 0, 0]

    var elevGainM: Double?
    var elevLossM: Double?
    var cadenceSPM: Int?
    var calories: Int?
    var isIndoor = false
    var sourceName = ""

    // Chart normalization bounds (pace clamped to p5–p95 so spikes don't flatten the line)
    var paceBounds: ClosedRange<Double> = 300...900
    var hrBounds: ClosedRange<Double> = 80...200
}

/// Loads and computes a `RunDetail` from HealthKit for a healthkit-sourced run.
/// Returns nil when there's nothing to load (manual runs, missing workout).
final class RunDetailLoader {
    private let store = HKHealthStore()

    func load(run: RunSummary, maxHR: Int) async -> RunDetail? {
        guard run.source == "healthkit",
              let ext = run.externalID, let hkID = UUID(uuidString: ext),
              let workout = try? await workout(uuid: hkID) else { return nil }

        async let distanceSamples = quantitySamples(.distanceWalkingRunning, for: workout)
        async let hrSamples = quantitySamples(.heartRate, for: workout)
        async let stepSamples = quantitySamples(.stepCount, for: workout)
        async let locations = routeLocations(for: workout)

        return compute(
            workout: workout,
            distance: (try? await distanceSamples) ?? [],
            heart: (try? await hrSamples) ?? [],
            steps: (try? await stepSamples) ?? [],
            locations: (await locations) ?? [],
            athleteMaxHR: maxHR,
            displaySeconds: run.corrected ? run.durationS : nil
        )
    }

    /// Just the cumulative-distance curve for one run — no HR, no route, no splits.
    ///
    /// The sub-distance PR scan (#25) needs the distance timeline and nothing else, and it
    /// needs it 1,476 times. `load` would also pull heart rate, step counts and the GPS
    /// route for each of those runs, which is most of the cost of opening a run detail page
    /// and all of it wasted here.
    ///
    /// An empty result is an answer, not a failure: a manual run has no workout behind it,
    /// and some Garmin-written workouts have no distance samples at all. The caller marks
    /// the run scanned either way — see `BestEffortsService`.
    func distanceTimeline(run: RunSummary) async -> [BestEfforts.Point] {
        guard run.source == "healthkit",
              let ext = run.externalID, let hkID = UUID(uuidString: ext),
              let workout = try? await workout(uuid: hkID) else { return [] }

        let samples = (try? await quantitySamples(.distanceWalkingRunning, for: workout)) ?? []
        let start = workout.startDate
        let meterUnit = HKUnit.meter()
        return BestEfforts.timeline(from: samples.map {
            BestEfforts.Sample(
                start: $0.startDate.timeIntervalSince(start),
                end: $0.endDate.timeIntervalSince(start),
                meters: $0.quantity.doubleValue(for: meterUnit)
            )
        })
    }

    /// Moving time by the distance samples, for one workout the sync just wrote (#237).
    ///
    /// One workout lookup and one distance query — no HR, no route, no steps. Nil when the
    /// workout is gone or wrote no distance samples; the caller then keeps the stored clocks.
    func sampleMovingSeconds(workoutID: UUID) async -> Int? {
        guard let workout = try? await workout(uuid: workoutID) else { return nil }
        let samples = (try? await quantitySamples(.distanceWalkingRunning, for: workout)) ?? []
        return SampleMovingTime.movingSeconds(Self.movingTimeSamples(samples, start: workout.startDate))
            .map { Int($0.rounded()) }
    }

    /// HealthKit distance samples in the engine's shape: seconds from the workout start.
    private static func movingTimeSamples(_ samples: [HKQuantitySample], start: Date) -> [SampleMovingTime.Sample] {
        let meterUnit = HKUnit.meter()
        return samples.map {
            SampleMovingTime.Sample(
                start: $0.startDate.timeIntervalSince(start),
                end: $0.endDate.timeIntervalSince(start),
                meters: $0.quantity.doubleValue(for: meterUnit)
            )
        }
    }

    // MARK: - Queries

    private func workout(uuid: UUID) async throws -> HKWorkout? {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: HKQuery.predicateForObject(with: uuid),
                limit: 1, sortDescriptors: nil
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: samples?.first as? HKWorkout)
            }
            store.execute(q)
        }
    }

    /// Samples for a workout. Apple Watch associates samples with the workout object;
    /// third-party writers (Garmin Connect) usually don't — for those, fall back to the
    /// workout's time window, restricted to the same source app so we never mix the
    /// iPhone's own motion estimates into a Garmin run.
    private func quantitySamples(_ id: HKQuantityTypeIdentifier, for workout: HKWorkout) async throws -> [HKQuantitySample] {
        let associated = try await rawSamples(HKQuantityType(id), predicate: HKQuery.predicateForObjects(from: workout))
        if !associated.isEmpty { return associated as? [HKQuantitySample] ?? [] }

        let window = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [])
        let inWindow = (try await rawSamples(HKQuantityType(id), predicate: window)) as? [HKQuantitySample] ?? []
        let sameSource = inWindow.filter { $0.sourceRevision.source == workout.sourceRevision.source }
        return sameSource.isEmpty ? inWindow : sameSource
    }

    private func rawSamples(_ type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: samples ?? [])
            }
            store.execute(q)
        }
    }

    private func routeLocations(for workout: HKWorkout) async -> [CLLocation]? {
        // Association first (Apple Watch), then time-window + same-source (Garmin et al).
        var route = (try? await rawSamples(
            HKSeriesType.workoutRoute(),
            predicate: HKQuery.predicateForObjects(from: workout)
        ))?.first as? HKWorkoutRoute
        if route == nil {
            let window = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [])
            let candidates = ((try? await rawSamples(HKSeriesType.workoutRoute(), predicate: window)) ?? [])
                .compactMap { $0 as? HKWorkoutRoute }
            route = candidates.first { $0.sourceRevision.source == workout.sourceRevision.source } ?? candidates.first
        }
        guard let route else { return nil }

        return await withCheckedContinuation { cont in
            var all: [CLLocation] = []
            let q = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if error != nil { cont.resume(returning: nil); return }
                all.append(contentsOf: locations ?? [])
                if done { cont.resume(returning: all) }
            }
            store.execute(q)
        }
    }

    // MARK: - Computation

    private func compute(
        workout: HKWorkout,
        distance: [HKQuantitySample],
        heart: [HKQuantitySample],
        steps: [HKQuantitySample],
        locations: [CLLocation],
        athleteMaxHR: Int,
        displaySeconds: Int? = nil   // corrected run duration — zones normalize to what the page shows
    ) -> RunDetail {
        var d = RunDetail()
        let start = workout.startDate
        let meterUnit = HKUnit.meter()
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())

        d.timerS = Int(workout.duration)
        d.elapsedS = Int(workout.endDate.timeIntervalSince(start))
        d.isIndoor = (workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? false
        d.sourceName = workout.sourceRevision.source.name
        d.miles = (workout.totalDistance?.doubleValue(for: meterUnit) ?? 0) / 1609.34
        d.calories = (workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())).map { Int($0.rounded()) }

        // ── Cumulative distance timeline ──────────────────────────────────────
        // (t seconds from start, cumulative meters).
        let samples = Self.movingTimeSamples(distance, start: start)
        var timeline: [(t: Double, m: Double)] = [(0, 0)]
        var cum = 0.0
        for s in samples {
            cum += s.meters
            timeline.append((s.end, cum))
        }
        // Moving vs stopped is decided in one place, shared with ingest (#237).
        d.sampleMovingS = SampleMovingTime.movingSeconds(samples).map { Int($0.rounded()) }
        d.movingS = d.sampleMovingS ?? d.timerS
        if !distance.isEmpty {
            d.cumulativeTimesS = timeline.map(\.t)
            d.cumulativeMeters = timeline.map(\.m)
        }

        if d.miles > 0.05 {
            d.avgPaceSec = Int(Double(d.timerS) / d.miles)
            d.elapsedPaceSec = Int(Double(d.elapsedS) / d.miles)
            let hours = Double(max(d.movingS, 1)) / 3600
            d.avgSpeedMph = d.miles / hours
        }

        // ── Best pace: fastest rolling window (TrackMath) ─────────────────────
        d.bestPaceSec = TrackMath.bestPace(
            timeline: timeline.map { BestEfforts.Point(t: $0.t, m: $0.m) },
            unitMeters: Units.mi.meters
        ).map { Int($0) }

        // ── HR stats + zones (Garmin %max bands: 50/60/70/80/90) ─────────────
        let hrPoints: [(t: Double, bpm: Double)] = heart.map {
            ($0.startDate.timeIntervalSince(start), $0.quantity.doubleValue(for: bpmUnit))
        }
        d.hrTimesS = hrPoints.map(\.t)
        d.hrBPM = hrPoints.map(\.bpm)
        if !hrPoints.isEmpty {
            let values = hrPoints.map(\.bpm)
            d.avgHR = Int((values.reduce(0, +) / Double(values.count)).rounded())
            d.maxHR = values.max().map { Int($0.rounded()) }
            // Third-party writers (Garmin) store sparse HR samples — each sample stands in
            // for the gap until the next one (capped so one dropout can't dominate), then the
            // whole distribution is normalized to the run's recorded time so zone minutes
            // add up to the time the athlete actually ran.
            var raw = [0.0, 0, 0, 0, 0]
            for (i, p) in hrPoints.enumerated() {
                let next = i + 1 < hrPoints.count ? hrPoints[i + 1].t : Double(d.timerS)
                let dur = min(max(next - p.t, 1), 600)
                let pct = p.bpm / Double(athleteMaxHR)
                let zone = pct < 0.6 ? 0 : pct < 0.7 ? 1 : pct < 0.8 ? 2 : pct < 0.9 ? 3 : 4
                raw[zone] += dur
            }
            let total = raw.reduce(0, +)
            if total > 1 {
                let scale = Double(displaySeconds ?? d.timerS) / total
                d.zoneSeconds = raw.map { $0 * scale }
            }
        }

        // ── Elevation from route altitudes ────────────────────────────────────
        // The chart and split deltas read a ±5 centred mean (a finished run can look ahead).
        // Gain and loss do not: they go through the recorder's trailing mean + 3 m hysteresis
        // (#144), because summing every upward wiggle of this curve counted GPS altitude
        // noise as climb, and a recorded run and an imported one should agree about a hill.
        let altitudes: [(t: Double, alt: Double)] = locations.map {
            ($0.timestamp.timeIntervalSince(start), $0.altitude)
        }
        var smoothAlt: [(t: Double, alt: Double)] = []
        if altitudes.count > 5 {
            let w = 5
            for i in 0..<altitudes.count {
                let lo = max(0, i - w), hi = min(altitudes.count - 1, i + w)
                let mean = altitudes[lo...hi].map(\.alt).reduce(0, +) / Double(hi - lo + 1)
                smoothAlt.append((altitudes[i].t, mean))
            }
            let climb = TrackMath.elevation(rawAltitudes: altitudes.map(\.alt))
            d.elevGainM = climb.gainM
            d.elevLossM = climb.lossM
        }

        // ── Cadence ───────────────────────────────────────────────────────────
        let totalSteps = steps.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .count()) }
        if totalSteps > 0, d.movingS > 60 {
            d.cadenceSPM = Int((totalSteps / (Double(d.movingS) / 60)).rounded())
        }

        // ── Chart series: resample onto ~180 uniform time points ─────────────
        func cumulativeMeters(at t: Double) -> Double {
            var lo = 0, hi = timeline.count - 1
            if t <= timeline[0].t { return timeline[0].m }
            if t >= timeline[hi].t { return timeline[hi].m }
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if timeline[mid].t <= t { lo = mid } else { hi = mid }
            }
            let a = timeline[lo], b = timeline[hi]
            let f = (t - a.t) / max(b.t - a.t, 0.01)
            return a.m + f * (b.m - a.m)
        }
        func nearest<T>(_ points: [(t: Double, v: T)], at t: Double) -> T? {
            guard !points.isEmpty else { return nil }
            var lo = 0, hi = points.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if points[mid].t <= t { lo = mid } else { hi = mid }
            }
            return abs(points[lo].t - t) < abs(points[hi].t - t) ? points[lo].v : points[hi].v
        }

        if timeline.count > 4, d.elapsedS > 60 {
            let n = 180
            let hrTV = hrPoints.map { (t: $0.t, v: $0.bpm) }
            let altTV = smoothAlt.map { (t: $0.t, v: $0.alt) }
            var pts: [RunDetail.SeriesPoint] = []
            var paces: [Double] = []
            let paceWindow = 30.0
            for i in 0..<n {
                let t = Double(i) / Double(n - 1) * Double(d.elapsedS)
                let m = cumulativeMeters(at: t)
                let m0 = cumulativeMeters(at: max(0, t - paceWindow))
                let dm = m - m0
                let pace: Double? = dm > 15 ? paceWindow / (dm / 1609.34) : nil
                if let pace { paces.append(pace) }
                pts.append(RunDetail.SeriesPoint(
                    id: i,
                    miles: m / 1609.34,
                    paceSecPerMile: pace,
                    hr: nearest(hrTV, at: t),
                    elevationM: nearest(altTV, at: t)
                ))
            }
            if !paces.isEmpty {
                let sorted = paces.sorted()
                let p5 = sorted[Int(Double(sorted.count - 1) * 0.05)]
                let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
                d.paceBounds = min(p5, p95 - 1)...max(p95, p5 + 1)
            }
            if let mn = hrPoints.map(\.bpm).min(), let mx = hrPoints.map(\.bpm).max(), mx > mn {
                d.hrBounds = mn...mx
            }
            d.series = pts
        }

        // ── Splits, in both units (SplitTable) ────────────────────────────────
        if timeline.count > 4, d.miles > 0.2 {
            let hrTV = hrPoints.map { (t: $0.t, v: $0.bpm) }
            let altTV = smoothAlt.map { (t: $0.t, v: $0.alt) }
            let times = timeline.map(\.t), meters = timeline.map(\.m)
            d.mileSplits = SplitTable.splits(times: times, meters: meters, every: Units.mi.splitMeters, hr: hrTV, altitude: altTV)
            d.kmSplits = SplitTable.splits(times: times, meters: meters, every: Units.km.splitMeters, hr: hrTV, altitude: altTV)
        }

        // ── Route segments colored by pace ────────────────────────────────────
        d.routeSegments = Self.routeSegments(locations)

        return d
    }

    /// The map's polyline, cut into runs of one pace colour: fastest stretch Z5, slowest Z1,
    /// relative to this run's own 10th–90th percentile. Static so the post-run save screen
    /// (#129) draws a just-recorded route exactly the way this page will draw it once synced.
    /// Empty for a route too short to colour.
    static func routeSegments(_ locations: [CLLocation]) -> [RunDetail.RouteSegment] {
        if locations.count > 10 {
            let step = max(1, locations.count / 600)
            var sampled: [CLLocation] = []
            for i in stride(from: 0, to: locations.count, by: step) { sampled.append(locations[i]) }

            var pointPaces: [Double?] = [nil]
            for i in 1..<sampled.count {
                let dm = sampled[i].distance(from: sampled[i - 1])
                let dt = sampled[i].timestamp.timeIntervalSince(sampled[i - 1].timestamp)
                pointPaces.append(dm > 1 && dt > 0 ? dt / (dm / 1609.34) : nil)
            }
            let valid = pointPaces.compactMap { $0 }.sorted()
            if valid.count > 10 {
                let p10 = valid[Int(Double(valid.count - 1) * 0.10)]
                let p90 = valid[Int(Double(valid.count - 1) * 0.90)]
                let span = max(p90 - p10, 1)
                func zone(_ pace: Double?) -> Int {
                    guard let pace else { return 1 }
                    // fastest → Z5 color (index 4), slowest → Z1 (index 0)
                    let f = 1 - min(max((pace - p10) / span, 0), 1)
                    return min(4, Int(f * 5))
                }
                var segments: [RunDetail.RouteSegment] = []
                var currentZone = zone(pointPaces[1])
                var coords: [CLLocationCoordinate2D] = [sampled[0].coordinate]
                for i in 1..<sampled.count {
                    let z = zone(pointPaces[i])
                    coords.append(sampled[i].coordinate)
                    if z != currentZone {
                        segments.append(RunDetail.RouteSegment(id: segments.count, coords: coords, zone: currentZone))
                        coords = [sampled[i].coordinate]
                        currentZone = z
                    }
                }
                if coords.count > 1 {
                    segments.append(RunDetail.RouteSegment(id: segments.count, coords: coords, zone: currentZone))
                }
                return segments
            }
        }
        return []
    }
}
