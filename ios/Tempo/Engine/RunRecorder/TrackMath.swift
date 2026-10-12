import Foundation

/// GPS fixes in, the numbers a live run screen shows out: distance, current and average pace,
/// splits, elevation gain (#112).
///
/// Every number Tempo has shown until now came from somebody else's recorder — Garmin wrote
/// the run, HealthKit stored it, `RunDetailLoader` read it back. The recorder is the first
/// time Tempo itself turns raw CoreLocation fixes into a distance, and raw fixes lie: the
/// first few before a lock can be hundreds of metres off, a tall building or an underpass
/// throws one fix across the street, and altitude wanders by metres while standing still.
/// None of that crashes. It just makes the distance read long and the climb read huge, live,
/// in front of the athlete — the same silent-wrong-number failure every engine bug on this
/// board has had.
///
/// Pure by construction. A `Fix` is a plain value, not a `CLLocation`, so a test can build
/// a whole track out of arithmetic; the service that owns `CLLocationManager` maps one to
/// the other and calls `Track.ingest` per update. Nothing here knows about pause states —
/// that is the state machine's job (#111) — or about mi vs km: the split length comes in
/// as metres, and `Units` (#108) is what will supply it.
///
/// The distance curve is a `[BestEfforts.Point]` on purpose: it is the same cumulative
/// (seconds, metres) shape `RunDetailLoader` builds from HealthKit samples and the PR scan
/// consumes, so a recorded run can go straight into `BestEfforts.efforts` with no adapter.
/// The rolling pace window (≥30 s and ≥100 m) and the boundary interpolation for splits are
/// the same rules `RunDetailLoader.compute` uses for best pace and mile splits; they live
/// here as pure functions rather than a third inline copy.
enum TrackMath {

    // MARK: - Thresholds

    /// A fix claiming worse than this is not used, for distance or anything else.
    ///
    /// An iPhone with a clear sky reports 3–10 m; 25 m is the edge of "it knows roughly which
    /// side of the street you're on". Past that the fix is a guess — the urban canyon and the
    /// cold-start cases — and a guess still carries a precise-looking coordinate, which is
    /// exactly the problem. Dropping it costs nothing on a straight road: the next good fix
    /// bridges the gap with a straight line.
    static let maxHorizontalAccuracyM = 25.0

    /// Faster than this between two fixes is a teleport, not running.
    ///
    /// 7 m/s is 3:50/mi (2:23/km) — faster than David's strides and well beyond any pace he
    /// sustains for even a second between fixes, but under the mile world record, so a real
    /// athlete is never rejected for being quick. A 300 m jump in one second reads as 300 m/s
    /// and goes. Speed is measured from the last *accepted* fix, so a rejection costs no
    /// distance: the next good fix is credited from the last good one, and the allowance
    /// grows with the gap, so a track that genuinely moved recovers by itself.
    static let maxSpeedMps = 7.0

    /// Consecutive accurate, mutually consistent fixes that count as "locked".
    ///
    /// The first fixes after CoreLocation wakes are its worst — a cached position from where
    /// the phone last was, then a few that converge. Three in a row that agree with each
    /// other is the cheapest proof the receiver has settled. Nothing before the lock is used.
    static let lockFixCount = 3

    /// Accepted fixes averaged into one position before distance is measured.
    ///
    /// "Light" smoothing, deliberately: three fixes is about one second of lag at 1 Hz, and
    /// it takes the per-fix jitter out of the zig-zag that otherwise inflates distance. The
    /// averaged position carries the averaged timestamp, so on a steady run the smoothed
    /// track is still on time — splits do not drift late.
    static let positionSmoothingFixes = 3

    /// Distance is credited only once the smoothed position has moved this far from where it
    /// was last credited.
    ///
    /// The fix for a phone standing still at a light: GPS wander of a metre or two each
    /// second adds up to real-looking distance over a minute. Five metres is under two
    /// seconds of running, so the live number never visibly stalls, and on a straight line
    /// or a gentle curve the chord is the path — the credited total does not shrink.
    static let distanceStepM = 5.0

    /// Slower than this between two credited points counts as stopped, not moving.
    ///
    /// The same ~60:00/mi line `RunDetailLoader` draws for moving time on Garmin runs, so a
    /// run recorded here and a run imported from the watch split their clocks the same way.
    static let stoppedSpeedMps = 0.45

    /// The current-pace window: at least this long *and* at least this far, the same pair
    /// `RunDetailLoader` uses for best pace. Thirty seconds alone is ~90 m at easy pace, too
    /// short for GPS error to average out; a hundred metres alone is fifteen seconds at
    /// strides, too twitchy to read.
    static let paceWindowS = 30.0
    static let paceWindowM = 100.0

    /// If covering the window takes longer than this, there is no current pace to show.
    /// Standing at a light should read "--", not a pace that slowly decays toward an hour.
    static let paceMaxLookbackS = 120.0

    /// No credited distance for this long means stopped, and a stopped athlete has no
    /// current pace.
    ///
    /// The window ends at the last *credited* point rather than at the wall clock: distance
    /// is credited in `distanceStepM` steps behind a smoothing lag, so "now" is always a
    /// second or two past the last point, and counting that gap as standing still read a
    /// steady 5:00/km as 5:20 in testing. Running at any pace slower than a walk credits a
    /// step every few seconds; ten without one is a stop, not a slow stride.
    static let paceStaleS = 10.0

    /// Altitudes averaged before gain is measured — the trailing version of the smoothing
    /// `RunDetailLoader` applies to imported routes (it averages ±5 around each point; a
    /// live run cannot look ahead, so it looks ten back). Elevation changes slowly enough
    /// that ten seconds of lag costs under a metre at a split boundary, and five was not
    /// enough: with ±3 m of per-fix noise a five-fix mean still swung 3 m often enough to
    /// read a flat 30 minutes as ~50 m of climb.
    static let altitudeSmoothingFixes = 10

    /// The climb has to reverse by this much before it counts as turning.
    ///
    /// GPS altitude wanders by a few metres even on a track. Summing every upward wiggle —
    /// what `RunDetailLoader` does with imported routes — turns a flat 10 K into a hilly one.
    /// With a 3 m hysteresis, noise smaller than that never registers, while a real climb is
    /// still counted in full once it has established itself.
    static let elevationHysteresisM = 3.0

    /// A trailing split shorter than this fraction of a full one is not reported: 30 m past
    /// the last mile marker is not a split, and its pace is noise. `RunDetailLoader` drops
    /// anything under 0.05 mi for the same reason.
    static let minPartialSplitFraction = 0.05

    /// Mean Earth radius (IUGG). Haversine on a sphere is within ~0.3 % of the ellipsoid
    /// everywhere and far tighter than that over the few metres between two fixes.
    static let earthRadiusM = 6_371_008.8

    // MARK: - Input

    /// One CoreLocation update, as plain numbers.
    ///
    /// Accuracy conventions follow `CLLocation`: a negative accuracy means the value is
    /// invalid. The service maps `CLLocation` → `Fix` one-to-one; nothing is pre-filtered.
    struct Fix: Equatable {
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        /// Radius of uncertainty, metres. Negative = no valid position.
        let horizontalAccuracy: Double
        /// Metres above sea level. Only meaningful when `verticalAccuracy >= 0`.
        let altitude: Double
        /// Negative = no valid altitude (`CLLocation`'s convention).
        let verticalAccuracy: Double

        init(
            timestamp: Date,
            latitude: Double,
            longitude: Double,
            horizontalAccuracy: Double,
            altitude: Double = 0,
            verticalAccuracy: Double = -1
        ) {
            self.timestamp = timestamp
            self.latitude = latitude
            self.longitude = longitude
            self.horizontalAccuracy = horizontalAccuracy
            self.altitude = altitude
            self.verticalAccuracy = verticalAccuracy
        }

        var hasAltitude: Bool { verticalAccuracy >= 0 && altitude.isFinite }
    }

    /// What happened to one fix. Every case but `accepted` means the fix contributed nothing.
    enum Verdict: Equatable, Hashable {
        /// Used: it moved the track (or confirmed the athlete is where the track says).
        case accepted
        /// Accurate, but the receiver has not locked yet; held as a lock candidate.
        case awaitingLock
        /// Worse than `maxHorizontalAccuracyM`, or no valid position at all.
        case inaccurate
        /// Older than the start of the run — CoreLocation's cached last-known position.
        case stale
        /// Not after the last fix used — a duplicate or an out-of-order delivery.
        case outOfOrder
        /// Implies running faster than `maxSpeedMps` from the last fix used.
        case tooFast
    }

    /// One altitude on the smoothed elevation curve, seconds from the start of the run.
    struct AltitudePoint: Equatable {
        let t: Double
        let altitudeM: Double
    }

    // MARK: - Output

    /// One mile or one kilometre — whatever `splitMeters` the caller asked for.
    struct Split: Equatable {
        /// 1-based. The last split may be partial.
        let index: Int
        let meters: Double
        let durationS: Double
        /// Seconds per full split length — i.e. per mile or per km.
        let paceS: Double
        /// Net change across the split, end minus start. Nil when no altitude was recorded.
        let elevationDeltaM: Double?
        let isPartial: Bool
    }

    /// Everything the live screen and the post-run summary read, in one value.
    /// Paces are seconds per `unitMeters` (per mile or per km); nil when there is not enough
    /// run yet to divide by.
    struct Summary: Equatable {
        let distanceM: Double
        let elapsedS: Double
        let movingS: Double
        let currentPaceS: Double?
        let averagePaceElapsedS: Double?
        let averagePaceMovingS: Double?
        let splits: [Split]
        let elevationGainM: Double
        let elevationLossM: Double
    }

    // MARK: - The live accumulator

    /// One run's worth of state, fed one fix at a time.
    ///
    /// Incremental so the live screen costs O(1) per fix however long the run gets; every
    /// derived number (pace, splits) is a pure function of the curves it holds.
    struct Track {
        /// The moment the athlete pressed start. t = 0 on every curve.
        let start: Date

        /// Cumulative credited distance against time. Starts at (0, 0) — the clock runs from
        /// the press of start, lock or no lock — and gains a point each time distance is
        /// credited, so a stop shows as one long flat segment.
        private(set) var timeline: [BestEfforts.Point] = [BestEfforts.Point(t: 0, m: 0)]
        /// Smoothed altitude against time, one point per accepted fix that had one.
        private(set) var altitudes: [AltitudePoint] = []
        private(set) var elevationGainM = 0.0
        private(set) var elevationLossM = 0.0
        /// Seconds between credited points that were faster than `stoppedSpeedMps`.
        private(set) var movingS = 0.0
        /// How many fixes each verdict has handed out — diagnostics, and what the tests read.
        private(set) var verdicts: [Verdict: Int] = [:]
        /// Time of the newest fix used, seconds from start.
        private(set) var lastFixT: Double?

        var distanceM: Double { timeline.last?.m ?? 0 }
        var isLocked: Bool { lastAccepted != nil }

        private var lockCandidates: [Fix] = []
        private var lastAccepted: Fix?
        private var recent: [Fix] = []                 // last `positionSmoothingFixes` accepted
        private var anchor: (lat: Double, lon: Double)?
        private var recentAltitudes: [Double] = []
        private var climb = Hysteresis(threshold: TrackMath.elevationHysteresisM)

        init(start: Date) {
            self.start = start
        }

        /// Feed one fix; returns what was done with it.
        @discardableResult
        mutating func ingest(_ fix: Fix) -> Verdict {
            let verdict = judge(fix)
            verdicts[verdict, default: 0] += 1
            return verdict
        }

        private mutating func judge(_ fix: Fix) -> Verdict {
            guard fix.horizontalAccuracy >= 0,
                  fix.horizontalAccuracy <= TrackMath.maxHorizontalAccuracyM,
                  fix.latitude.isFinite, fix.longitude.isFinite else {
                // A bad fix breaks a lock-in-progress: "locked" means consecutive good fixes.
                lockCandidates.removeAll()
                return .inaccurate
            }
            guard fix.timestamp >= start else { return .stale }

            guard let last = lastAccepted else { return considerForLock(fix) }

            guard fix.timestamp > last.timestamp else { return .outOfOrder }
            guard TrackMath.impliedSpeed(from: last, to: fix) <= TrackMath.maxSpeedMps else {
                return .tooFast
            }
            use(fix)
            return .accepted
        }

        private mutating func considerForLock(_ fix: Fix) -> Verdict {
            if let prior = lockCandidates.last {
                if fix.timestamp <= prior.timestamp { return .outOfOrder }
                // A candidate that disagrees with the one before it restarts the count:
                // the receiver is still converging.
                if TrackMath.impliedSpeed(from: prior, to: fix) > TrackMath.maxSpeedMps {
                    lockCandidates.removeAll()
                }
            }
            lockCandidates.append(fix)
            guard lockCandidates.count >= TrackMath.lockFixCount else { return .awaitingLock }

            // Locked. The candidates were good all along — they become the first of the track.
            let settled = lockCandidates
            lockCandidates.removeAll()
            for f in settled { use(f) }
            return .accepted
        }

        private mutating func use(_ fix: Fix) {
            lastAccepted = fix
            let t = fix.timestamp.timeIntervalSince(start)
            lastFixT = t

            // ── Distance: smoothed position, credited in steps ────────────────────────
            recent.append(fix)
            if recent.count > TrackMath.positionSmoothingFixes { recent.removeFirst() }
            let n = Double(recent.count)
            let lat = recent.map(\.latitude).reduce(0, +) / n
            let lon = recent.map(\.longitude).reduce(0, +) / n
            let smoothedT = recent.map { $0.timestamp.timeIntervalSince(start) }.reduce(0, +) / n

            if let a = anchor {
                let step = TrackMath.haversine(a.lat, a.lon, lat, lon)
                if step >= TrackMath.distanceStepM {
                    let prev = timeline[timeline.count - 1]
                    // The smoothed time can trail the previous point only on a pathological
                    // delivery; the curve must never run backwards.
                    let pointT = max(smoothedT, prev.t)
                    let dt = pointT - prev.t
                    if dt > 0, step / dt > TrackMath.stoppedSpeedMps { movingS += dt }
                    timeline.append(BestEfforts.Point(t: pointT, m: prev.m + step))
                    anchor = (lat, lon)
                }
            } else {
                anchor = (lat, lon)
            }

            // ── Elevation: trailing mean, then hysteresis ─────────────────────────────
            if fix.hasAltitude {
                recentAltitudes.append(fix.altitude)
                if recentAltitudes.count > TrackMath.altitudeSmoothingFixes { recentAltitudes.removeFirst() }
                let smoothed = recentAltitudes.reduce(0, +) / Double(recentAltitudes.count)
                altitudes.append(AltitudePoint(t: t, altitudeM: smoothed))
                // Only a full window feeds the climb: the very first altitude is one raw
                // reading, and setting the reference on it would let a single bad fix decide
                // which way the run "started".
                if recentAltitudes.count == TrackMath.altitudeSmoothingFixes { climb.add(smoothed) }
                elevationGainM = climb.gain
                elevationLossM = climb.loss
            }
        }

        /// Credit the last few metres when the run ends.
        ///
        /// Live, distance trails the athlete by up to one `distanceStepM` plus the smoothing
        /// lag — invisible on a screen that updates every second, but on a short run it is
        /// over 1 % of the total, and it should not be left on the road. Idempotent: a
        /// second call has nothing left to credit.
        mutating func close() {
            guard let last = lastAccepted, let a = anchor else { return }
            let tail = TrackMath.haversine(a.lat, a.lon, last.latitude, last.longitude)
            guard tail > 0 else { return }
            let prev = timeline[timeline.count - 1]
            let t = max(last.timestamp.timeIntervalSince(start), prev.t)
            let dt = t - prev.t
            if dt > 0, tail / dt > TrackMath.stoppedSpeedMps { movingS += dt }
            timeline.append(BestEfforts.Point(t: t, m: prev.m + tail))
            anchor = (last.latitude, last.longitude)
        }

        /// The numbers to show at `now` (wall clock). Elapsed runs to `now`, not to the last
        /// fix, so a GPS dropout does not freeze the clock.
        func summary(unitMeters: Double, now: Date) -> Summary {
            let elapsed = max(0, now.timeIntervalSince(start))
            let distance = distanceM
            return Summary(
                distanceM: distance,
                elapsedS: elapsed,
                movingS: movingS,
                currentPaceS: TrackMath.currentPace(timeline: timeline, at: elapsed, unitMeters: unitMeters),
                averagePaceElapsedS: TrackMath.averagePace(meters: distance, seconds: elapsed, unitMeters: unitMeters),
                averagePaceMovingS: TrackMath.averagePace(meters: distance, seconds: movingS, unitMeters: unitMeters),
                splits: TrackMath.splits(timeline: timeline, altitudes: altitudes, splitMeters: unitMeters),
                elevationGainM: elevationGainM,
                elevationLossM: elevationLossM
            )
        }
    }

    // MARK: - Geometry

    /// Great-circle distance in metres.
    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad
        let dLon = (lon2 - lon1) * rad
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusM * asin(min(1, sqrt(a)))
    }

    static func distance(_ a: Fix, _ b: Fix) -> Double {
        haversine(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// Metres per second between two fixes; infinite when they share a timestamp but not a
    /// position, which is a teleport by definition.
    static func impliedSpeed(from a: Fix, to b: Fix) -> Double {
        let d = distance(a, b)
        let dt = b.timestamp.timeIntervalSince(a.timestamp)
        guard dt > 0 else { return d > 0 ? .infinity : 0 }
        return d / dt
    }

    // MARK: - Reading the curve

    /// Metres covered by time `t`, linearly interpolated; flat past the last point.
    static func meters(atTime t: Double, in timeline: [BestEfforts.Point]) -> Double {
        guard let first = timeline.first, let last = timeline.last else { return 0 }
        if t <= first.t { return first.m }
        if t >= last.t { return last.m }
        // First point at or after t.
        var lo = 0, hi = timeline.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if timeline[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        let a = timeline[lo - 1], b = timeline[lo]
        let span = b.t - a.t
        guard span > 0 else { return b.m }
        return a.m + (t - a.t) / span * (b.m - a.m)
    }

    /// The instant `target` metres was first reached, linearly interpolated; nil if the run
    /// never got that far. A flat stretch (a stop) is charged to the time *before* the
    /// crossing, never after — the athlete reached the marker when they reached it.
    static func time(atMeters target: Double, in timeline: [BestEfforts.Point]) -> Double? {
        guard let first = timeline.first, let last = timeline.last, target <= last.m else { return nil }
        if target <= first.m { return first.t }
        // First point at or past target.
        var lo = 0, hi = timeline.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if timeline[mid].m < target { lo = mid + 1 } else { hi = mid }
        }
        let a = timeline[lo - 1], b = timeline[lo]
        let span = b.m - a.m
        guard span > 0 else { return b.t }
        return a.t + (target - a.m) / span * (b.t - a.t)
    }

    // MARK: - Pace

    /// Seconds per `unitMeters` over the most recent ≥`paceWindowS` *and* ≥`paceWindowM`,
    /// ending at the last credited point.
    ///
    /// Nil before there is a full window, once nothing has been credited for `paceStaleS`
    /// (stopped), and when covering the window took longer than `paceMaxLookbackS`.
    static func currentPace(timeline: [BestEfforts.Point], at now: Double, unitMeters: Double) -> Double? {
        guard let end = timeline.last, now - end.t <= paceStaleS,
              end.m >= paceWindowM, end.t >= paceWindowS,
              let crossing = time(atMeters: end.m - paceWindowM, in: timeline) else { return nil }
        let startT = min(end.t - paceWindowS, crossing)
        guard end.t - startT <= paceMaxLookbackS else { return nil }
        let dm = end.m - meters(atTime: startT, in: timeline)
        guard dm > 0 else { return nil }
        return (end.t - startT) / (dm / unitMeters)
    }

    /// Seconds per `unitMeters`. Nil under 5 % of a unit — the same guard as
    /// `TimeAccounting.paceSecPerMile`: a 50 m blip produces a pace in the hours.
    static func averagePace(meters: Double, seconds: Double, unitMeters: Double) -> Double? {
        guard unitMeters > 0, meters > unitMeters * 0.05, seconds > 0 else { return nil }
        return seconds / (meters / unitMeters)
    }

    // MARK: - Splits

    /// Every full `splitMeters` the run has covered, plus the partial one in progress when it
    /// is at least `minPartialSplitFraction` long.
    ///
    /// Each boundary's time is interpolated at exactly `k × splitMeters` — the same rule as
    /// `RunDetailLoader`'s mile splits — so a mile split is a mile, not "the credited point
    /// nearest a mile". Elevation change is read off the smoothed altitude curve at those
    /// same two instants.
    static func splits(
        timeline: [BestEfforts.Point],
        altitudes: [AltitudePoint] = [],
        splitMeters: Double
    ) -> [Split] {
        guard splitMeters > 0, let last = timeline.last, last.m > 0 else { return [] }
        var out: [Split] = []
        var prevT = timeline[0].t
        var index = 1
        while true {
            let boundary = Double(index) * splitMeters
            let isPartial = boundary > last.m
            let meters = isPartial ? last.m - Double(index - 1) * splitMeters : splitMeters
            if isPartial, meters < splitMeters * minPartialSplitFraction { break }
            let endT = isPartial ? last.t : (time(atMeters: boundary, in: timeline) ?? last.t)
            let duration = endT - prevT
            let elevation: Double? = {
                guard let a = altitude(at: prevT, in: altitudes),
                      let b = altitude(at: endT, in: altitudes) else { return nil }
                return b - a
            }()
            out.append(Split(
                index: index,
                meters: meters,
                durationS: duration,
                paceS: duration / (meters / splitMeters),
                elevationDeltaM: elevation,
                isPartial: isPartial
            ))
            if isPartial { break }
            prevT = endT
            index += 1
        }
        return out
    }

    /// Smoothed altitude at `t`, linearly interpolated and clamped to the ends.
    static func altitude(at t: Double, in points: [AltitudePoint]) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if t <= first.t { return first.altitudeM }
        if t >= last.t { return last.altitudeM }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        let a = points[lo - 1], b = points[lo]
        let span = b.t - a.t
        guard span > 0 else { return b.altitudeM }
        return a.altitudeM + (t - a.t) / span * (b.altitudeM - a.altitudeM)
    }

    // MARK: - Elevation

    /// Gain and loss with a dead band.
    ///
    /// Until the altitude has moved `threshold` from where it started, nothing counts. Once
    /// a direction is established, every metre further in that direction counts at once —
    /// so a real 30 m hill reads 30 m, not 27 — and the direction only flips after a
    /// reversal of at least `threshold`. Noise smaller than the band can wobble forever and
    /// add nothing.
    struct Hysteresis: Equatable {
        enum Direction: Equatable { case unknown, up, down }

        let threshold: Double
        private(set) var gain = 0.0
        private(set) var loss = 0.0
        private(set) var direction = Direction.unknown
        /// The extreme of the current leg (or the starting altitude before one is set).
        private var reference: Double?

        init(threshold: Double) {
            self.threshold = threshold
        }

        mutating func add(_ altitude: Double) {
            guard altitude.isFinite else { return }
            guard let ref = reference else { reference = altitude; return }
            switch direction {
            case .unknown:
                if altitude - ref >= threshold {
                    gain += altitude - ref; direction = .up; reference = altitude
                } else if ref - altitude >= threshold {
                    loss += ref - altitude; direction = .down; reference = altitude
                }
            case .up:
                if altitude > ref {
                    gain += altitude - ref; reference = altitude
                } else if ref - altitude >= threshold {
                    loss += ref - altitude; direction = .down; reference = altitude
                }
            case .down:
                if altitude < ref {
                    loss += ref - altitude; reference = altitude
                } else if altitude - ref >= threshold {
                    gain += altitude - ref; direction = .up; reference = altitude
                }
            }
        }
    }

    /// Gain and loss over a whole altitude series — the batch form of what `Track` does live.
    static func elevation(_ altitudes: [Double], threshold: Double = elevationHysteresisM) -> (gainM: Double, lossM: Double) {
        var h = Hysteresis(threshold: threshold)
        for a in altitudes { h.add(a) }
        return (h.gain, h.loss)
    }
}
