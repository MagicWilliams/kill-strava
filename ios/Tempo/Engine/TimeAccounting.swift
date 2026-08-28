import Foundation

/// Moving time vs elapsed time — the two clocks every run is recorded against.
///
/// Strava's vocabulary, and the reason one run now carries two numbers:
///
///  - **Moving time** excludes the seconds the athlete was stopped — a light, a shoelace,
///    a photo. It is what pace is computed from everywhere in this app, because it is the
///    number that describes how fast the *running* was.
///  - **Elapsed time** is the wall clock, start to finish. It is the honest answer to "how
///    long were you out", and the number a race clock shows.
///
/// The gap between them is **stopped time**, and it is a coaching signal on its own. A
/// 16-miler with 14 minutes of standing around is a different session from the same
/// distance run continuously, even though both report the same moving pace. That is why
/// this is stored rather than derived on the fly and thrown away.
///
/// ── Why this became a duplicate-run problem ──────────────────────────────────────────
/// For a stretch of 2021–2022 the two clocks arrived in Apple Health as *two separate
/// HKWorkout objects*: identical distance to the meter, identical start second, two
/// different durations. Ingest had no way to know they were one run, so it stored both,
/// and every all-time total counted that run twice. Migration 0009 folds those pairs back
/// into a single run carrying both numbers — which is what this type models.
///
/// Pure and deterministic: the numbers on the detail page are only as trustworthy as this
/// file, and a wrong answer here is invisible rather than loud.
enum TimeAccounting {

    /// Stopped time below this is measurement noise, not a stop.
    ///
    /// When the two clocks arrived as two records, their durations disagree by a second or
    /// two purely from rounding — the archive is full of pairs differing by 1s, 2s, 3s.
    /// Reporting "3 seconds stopped" on a 40-minute run is worse than reporting nothing,
    /// so anything under this threshold is treated as a run with no stops.
    static let noiseFloorSeconds = 30

    /// Two clocks for one run, with the invariants already enforced.
    struct Clocks: Equatable {
        /// Time actually running. Always the number pace is computed from.
        let movingS: Int
        /// Wall clock, start to finish. Never less than `movingS`.
        let elapsedS: Int

        /// Seconds spent stopped. Zero when the run was continuous or only one clock is known.
        var stoppedS: Int { elapsedS - movingS }

        /// Whether the stop is worth putting on screen — see `noiseFloorSeconds`.
        var hasMeaningfulStop: Bool { stoppedS >= TimeAccounting.noiseFloorSeconds }
    }

    /// Reconcile whatever the two sources gave us into a coherent pair.
    ///
    /// Three things can go wrong, and all three resolve to "trust moving time":
    ///  - elapsed is unknown (every run ingested before this shipped),
    ///  - elapsed is *shorter* than moving, which is physically impossible and means the
    ///    two numbers came from records that disagree,
    ///  - elapsed is absurdly longer — the watch was left running for hours after the run.
    ///
    /// The last one is deliberately **not** filtered here. A run with 40 minutes of stopped
    /// time is real data about a real run, and the athlete's own record outranks our
    /// intuition about what a plausible stop looks like. The detail page shows it; nothing
    /// downstream computes on it.
    static func resolve(movingS: Int, elapsedS: Int?) -> Clocks {
        let moving = max(movingS, 0)
        guard let elapsedS, elapsedS > moving else {
            return Clocks(movingS: moving, elapsedS: moving)
        }
        return Clocks(movingS: moving, elapsedS: elapsedS)
    }

    /// Seconds per mile over a given clock. Nil for distances too short to divide by.
    ///
    /// The same guard as `RunSummary.paceSecPerMile` — a 0.02 mi GPS blip produces a pace
    /// in the hours and there is nothing useful to say about it.
    static func paceSecPerMile(seconds: Int, miles: Double) -> Int? {
        guard miles > 0.05, seconds > 0 else { return nil }
        return Int(Double(seconds) / miles)
    }

    /// Whether two records are one run recorded against both clocks, rather than two runs.
    ///
    /// The signature is exact-distance agreement: two genuinely different runs do not cover
    /// the same number of *meters*, and one activity exported twice always does, because
    /// both exports describe the same GPS trace. Start times are allowed to differ by a few
    /// seconds — the pair in the archive dated 2026-01-10 is one second apart — but the
    /// distance test is what carries the decision.
    ///
    /// Deliberately strict. Near-miss distances (within a percent or two) are a *different*
    /// phenomenon: two devices recording the same outing, with their own GPS and their own
    /// idea of when it started. Those are not two clocks on one record and folding them
    /// together here would silently destroy one of the two recordings.
    static func isSameRunTwoClocks(
        distanceA: Int, startA: Date, durationA: Int,
        distanceB: Int, startB: Date, durationB: Int,
        startTolerance: TimeInterval = 60
    ) -> Bool {
        distanceA == distanceB
            && durationA != durationB
            && abs(startA.timeIntervalSince(startB)) <= startTolerance
    }
}
