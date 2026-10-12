import Foundation

/// The Run Detail split table, in either unit (#109).
///
/// Lifted out of `RunDetailLoader.compute`, where it was a loop with `1609.34` written into
/// it four times. A km athlete needs the same table cut every 1000 m, and the way a split
/// table goes wrong is quiet: a boundary placed a few metres late, a partial last split
/// that is counted as a whole one, a pace divided by the wrong length. So the cutting is
/// here, pure, with `SplitTableTests` pinning where the boundaries land in both units.
enum SplitTable {

    struct Split: Identifiable, Equatable {
        /// Split number, 1-based. The last one may be partial.
        let id: Int
        /// How much of one unit this split covers: 1 for every whole split, a fraction for
        /// the partial last one. In the table's unit, never in metres.
        let length: Double
        /// Seconds per unit over this split, truncated the way the mile table always was.
        let paceSec: Int
        let avgHR: Int?
        let elevDeltaM: Double?
    }

    /// Below this fraction of a unit, a trailing partial split is dropped rather than shown
    /// with a pace that a few metres of GPS noise decide.
    static let minimumPartial = 0.05

    /// Splits every `splitMeters` along a cumulative-distance timeline.
    ///
    /// - Parameters:
    ///   - times: seconds from the workout start, ascending, parallel to `meters`.
    ///   - meters: cumulative metres at each of `times`, ascending.
    ///   - splitMeters: `Units.splitMeters`, so 1609.34 or 1000.
    ///   - hr: heart-rate samples as (seconds from start, bpm).
    ///   - altitude: smoothed altitude as (seconds from start, metres).
    ///
    /// Boundary times are interpolated linearly between the two samples either side, so a
    /// split ends at its exact distance rather than at whichever sample happened to cross it.
    static func splits(
        times: [Double],
        meters: [Double],
        every splitMeters: Double,
        hr: [(t: Double, v: Double)] = [],
        altitude: [(t: Double, v: Double)] = [],
        limit: Int = 200
    ) -> [Split] {
        guard times.count == meters.count, times.count > 1, splitMeters > 0,
              let total = meters.last, let lastT = times.last, total > 0 else { return [] }

        func time(atMeters target: Double) -> Double? {
            guard target <= total else { return nil }
            var lo = 0, hi = meters.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if meters[mid] <= target { lo = mid } else { hi = mid }
            }
            let f = (target - meters[lo]) / max(meters[hi] - meters[lo], 0.01)
            return times[lo] + f * (times[hi] - times[lo])
        }

        var out: [Split] = []
        var prevT = 0.0
        var n = 1
        while n <= limit {
            let boundary = Double(n) * splitMeters
            let isPartial = boundary > total
            let endT = isPartial ? lastT : (time(atMeters: boundary) ?? lastT)
            let length = (isPartial ? total - Double(n - 1) * splitMeters : splitMeters) / splitMeters
            if length < minimumPartial { break }
            let hrs = hr.filter { $0.t >= prevT && $0.t <= endT }.map(\.v)
            let elev0 = nearest(altitude, at: prevT)
            let elev1 = nearest(altitude, at: endT)
            out.append(Split(
                id: n,
                length: length,
                paceSec: Int((endT - prevT) / length),
                avgHR: hrs.isEmpty ? nil : Int((hrs.reduce(0, +) / Double(hrs.count)).rounded()),
                elevDeltaM: elev0.flatMap { a in elev1.map { $0 - a } }
            ))
            if isPartial { break }
            prevT = endT
            n += 1
        }
        return out
    }

    /// The sample closest in time to `t`, from a time-sorted list.
    static func nearest(_ points: [(t: Double, v: Double)], at t: Double) -> Double? {
        guard !points.isEmpty else { return nil }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].t <= t { lo = mid } else { hi = mid }
        }
        return abs(points[lo].t - t) < abs(points[hi].t - t) ? points[lo].v : points[hi].v
    }
}
