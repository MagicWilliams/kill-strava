import Foundation

/// The fastest *segment* of each standard distance inside a single run.
///
/// `RunHistory.records` already answers "fastest 10K+ run" — the best **average** pace over
/// a run of at least that far. That is a different number, and a smaller one: a 20-miler with
/// a hard finish holds a 10 K best that whole-run averaging can never surface, because the
/// easy fifteen miles in front of it drag the average down. This file closes that gap (#25).
///
/// Pure by construction, and deliberately so. The input is a cumulative-distance timeline —
/// the shape `RunDetailLoader` already builds out of HealthKit's distance samples — and the
/// output is seven numbers. No HealthKit, no Supabase, no actor. The pass that drives it over
/// 1,476 runs lives in `Services/BestEffortsPass.swift`; the arithmetic that decides what a
/// PR *is* lives here, where a test can pin it.
enum BestEfforts {

    // MARK: - The distances

    /// One standard race distance, in the one place both the app and the migration read it.
    ///
    /// `meters` is the true distance and drives the arithmetic; `key` is the integer stored
    /// in `run_efforts.distance_m` and must match the `check` constraint in migration 0011
    /// exactly. They differ for the mile and the half, where the true distance is fractional
    /// — storing the rounded metre and computing on the exact one keeps the key stable
    /// without quietly shortening the race.
    struct Distance: Identifiable, Equatable {
        let key: Int           // stored in run_efforts.distance_m
        let meters: Double     // what the rolling window actually measures
        let label: String

        var id: Int { key }
    }

    /// 400 m through the marathon — the set David asked for, shortest first.
    /// Order is the display order in the PR table and the coach payload.
    static let distances: [Distance] = [
        Distance(key: 400,   meters: 400,      label: "400 m"),
        Distance(key: 800,   meters: 800,      label: "800 m"),
        Distance(key: 1609,  meters: 1609.34,  label: "1 mi"),
        Distance(key: 5000,  meters: 5000,     label: "5K"),
        Distance(key: 10000, meters: 10000,    label: "10K"),
        Distance(key: 21098, meters: 21097.5,  label: "Half"),
        Distance(key: 42195, meters: 42195,    label: "Marathon"),
    ]

    static func distance(forKey key: Int) -> Distance? {
        distances.first { $0.key == key }
    }

    // MARK: - Input

    /// One point on the run's cumulative-distance curve: seconds from the start of the
    /// workout, and metres covered by then.
    struct Point: Equatable {
        let t: Double
        let m: Double
    }

    /// A distance sample as HealthKit hands it over: a half-open interval and the metres
    /// covered during it.
    struct Sample: Equatable {
        let start: Double      // seconds from the workout start
        let end: Double
        let meters: Double
    }

    /// The cumulative curve, built from raw samples.
    ///
    /// Garmin writes sparsely and irregularly — a sample can span a second or a minute, and
    /// the gaps where the watch was paused carry no samples at all. Both are fine here: a
    /// window that spans a pause simply measures as slow, which is what it was. What is *not*
    /// fine is a curve that goes backwards, so samples are sorted and anything with a
    /// non-positive duration or negative distance is dropped before it can invert the scan.
    ///
    /// `RunDetailLoader.compute` builds the same shape inline and is left alone: its loop
    /// also derives moving time sample-by-sample, and splitting that apart would change a
    /// number on the detail page for no reason this issue asked for.
    static func timeline(from samples: [Sample]) -> [Point] {
        let usable = samples
            .filter { $0.end > $0.start && $0.meters >= 0 && $0.start.isFinite && $0.end.isFinite }
            .sorted { $0.start < $1.start }
        guard !usable.isEmpty else { return [] }

        var points: [Point] = [Point(t: 0, m: 0)]
        var cumulative = 0.0
        var lastT = 0.0
        for s in usable {
            cumulative += s.meters
            // Overlapping samples (two sources writing the same window) must not pull the
            // clock backwards; the curve only ever moves forward.
            lastT = max(lastT, s.end)
            points.append(Point(t: lastT, m: cumulative))
        }
        return points
    }

    // MARK: - Output

    /// The fastest time this run covered one distance.
    struct Effort: Equatable {
        /// `Distance.key` — the integer that goes in `run_efforts.distance_m`.
        let distanceM: Int
        /// Whole seconds, rounded. Sub-second precision is noise at Garmin's sample rate,
        /// and the column is an integer.
        let durationS: Int
    }

    // MARK: - The scan

    /// Every standard distance this run actually covered, with the fastest segment of each.
    ///
    /// A rolling minimum over the cumulative curve: for each sample, walk the window start
    /// forward until it is at least `D` metres back, then interpolate the exact instant the
    /// athlete crossed `end − D` and take the elapsed time. The window end sits on a real
    /// sample and only the start is interpolated — that is the resolution HealthKit gives us,
    /// and claiming more would be inventing precision.
    ///
    /// **A distance the run did not cover emits nothing.** A 3-mile run holds no half PR, and
    /// an absent row and a row reading zero are not the same claim. The pass stores exactly
    /// what comes back here.
    static func efforts(timeline points: [Point]) -> [Effort] {
        guard points.count > 1, let total = points.last?.m, total > 0 else { return [] }

        return distances.compactMap { d -> Effort? in
            guard total >= d.meters else { return nil }   // never ran that far
            guard let seconds = fastest(d.meters, in: points) else { return nil }
            return Effort(distanceM: d.key, durationS: Int(seconds.rounded()))
        }
    }

    /// Fastest elapsed time over `meters`, or nil if the curve never spans that far.
    private static func fastest(_ meters: Double, in points: [Point]) -> Double? {
        var best = Double.infinity
        var i = 0
        for j in 1..<points.count {
            let target = points[j].m - meters
            guard target >= 0 else { continue }
            // Advance the window start to the last point at or before the crossing.
            while i + 1 < j, points[i + 1].m <= target { i += 1 }
            guard let crossing = time(atMeters: target, between: points[i], and: points[i + 1]) else { continue }
            best = min(best, points[j].t - crossing)
        }
        return best.isFinite && best > 0 ? best : nil
    }

    /// Linear interpolation of the instant `target` metres was crossed, inside one segment.
    /// A segment that covers no ground (a pause) reports its start: the athlete was already
    /// there, and charging the pause to the window would make a stop look like running.
    private static func time(atMeters target: Double, between a: Point, and b: Point) -> Double? {
        guard target >= a.m - 0.000_1, target <= b.m + 0.000_1 else { return nil }
        let span = b.m - a.m
        guard span > 0 else { return a.t }
        let f = (target - a.m) / span
        return a.t + f * (b.t - a.t)
    }

    // MARK: - The backlog

    /// How many runs one backfill slice reads from HealthKit before yielding.
    ///
    /// Small for the same reason `SyncPass.hrEnrichmentLimit` is small: the number of serial
    /// HealthKit queries any one pass can make must not scale with the size of the archive.
    /// The whole archive still gets scanned — a slice at a time, resuming where it stopped —
    /// but no single slice can hold the phone.
    static let sliceSize = 40

    /// Which runs the next slice should read, newest first.
    ///
    /// Newest first on purpose: the runs most likely to *hold* a current PR are the recent
    /// ones, so the table on screen converges on the right numbers early instead of spending
    /// its first thousand reads in 2021. Manual runs are skipped outright — there is no
    /// distance timeline behind them, only a total, and a total cannot hold a segment best.
    static func nextSlice(
        rows: [RunSummary],
        scanned: Set<UUID>,
        limit: Int = sliceSize
    ) -> [RunSummary] {
        rows.filter { $0.source == "healthkit" && $0.externalID != nil && !scanned.contains($0.id) }
            .sorted { $0.start > $1.start }
            .prefix(limit)
            .map { $0 }
    }

    /// How complete the archive scan is, as the History screen reports it.
    ///
    /// A PR table that is 40 % backfilled must say so rather than show a confident wrong
    /// number — the same failure mode as every past engine bug on this board. `isComplete`
    /// is what the UI gates the caveat on, and it is a count comparison rather than a
    /// "did the last pass finish" flag so that a killed pass can never report done.
    struct Progress: Equatable {
        let scanned: Int
        let total: Int

        var isComplete: Bool { scanned >= total }
        /// 0…1. An empty archive is complete, not zero percent of nothing.
        var fraction: Double { total > 0 ? min(1, Double(scanned) / Double(total)) : 1 }
        var percent: Int { Int((fraction * 100).rounded()) }
    }

    static func progress(rows: [RunSummary], scanned: Set<UUID>) -> Progress {
        let scannable = rows.filter { $0.source == "healthkit" && $0.externalID != nil }
        return Progress(
            scanned: scannable.filter { scanned.contains($0.id) }.count,
            total: scannable.count
        )
    }

    // MARK: - Formatting

    /// `h:mm:ss` past an hour, `m:ss` under it. A 400 reads 1:12; a marathon reads 3:14:07.
    static func formatTime(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Pace per mile for an effort, so the table can say what the segment felt like.
    static func paceSecPerMile(_ effort: Effort) -> Int? {
        guard let d = distance(forKey: effort.distanceM), d.meters > 0 else { return nil }
        return Int((Double(effort.durationS) / (d.meters / 1609.34)).rounded())
    }
}
