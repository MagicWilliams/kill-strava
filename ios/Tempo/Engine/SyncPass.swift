import Foundation

/// The pure decisions inside one sync pass: what a completed write says about itself,
/// how much HealthKit work is allowed to follow it, and when a dropped candidate is worth
/// saying out loud.
///
/// This file exists because of a bug that never crashed and never logged (#37). HR
/// enrichment used to run *between* the dedupe and the insert — one serial HealthKit query
/// per new run — on the written premise that "kept is small: only new runs". On a phone
/// with a five-year archive that premise was false: `kept` was 348. Every refresh spent
/// itself on 348 HealthKit statistics queries, the upsert was never reached, nothing was
/// written, no error was thrown, and the identical 348 were recomputed on the next launch.
/// Three telemetry events five minutes and four hours apart carried byte-identical counts.
///
/// The rule that came out of it: **the write happens first, and every step after it is
/// bounded by a number a test can see.** That bound lives here rather than inline in
/// `HealthService` so it can be pinned without a HealthKit store to query.
enum SyncPass {

    // MARK: - What was actually written

    /// The rows that reached the database, and the span of training they cover.
    ///
    /// Reported *after* the upsert, deliberately. "Kept" and "written" silently disagreeing
    /// for weeks is precisely what hid #37 — the only number the app ever emitted was the
    /// one computed before the write. An event that cannot be produced until the write
    /// returns makes that disagreement impossible again.
    struct WriteReport: Equatable {
        let count: Int
        /// `yyyy-MM-dd`, or nil when nothing was written. Dates only: the events table
        /// carries counts and ids, never a pace, a heart rate or a route.
        let oldest: String?
        let newest: String?
    }

    static func writeReport(for written: [RunSummary]) -> WriteReport {
        let starts = written.map(\.start).sorted()
        return WriteReport(
            count: written.count,
            oldest: starts.first.map { day($0) },
            newest: starts.last.map { day($0) }
        )
    }

    // MARK: - Work that follows the write

    /// How many HR lookups one refresh may make. Small on purpose: a backlog drains over a
    /// handful of refreshes, and no single refresh can stall behind it.
    static let hrEnrichmentLimit = 25

    /// How far back an HR lookup is worth making. Heart rate on a run from three years ago
    /// changes nothing on screen; heart rate on last Tuesday's run does.
    static let hrEnrichmentDays = 90

    /// Stored rows worth an HR lookup this pass, in the order they should be attempted.
    ///
    /// Bounded by construction, and that is the whole point: the number of HealthKit
    /// queries a refresh can make must not scale with the size of the archive. Feed this
    /// the 348-run backlog from #37 and it answers with at most `limit` — or, when they are
    /// old runs, with none at all.
    ///
    /// Corrected rows are never touched: an HR the coach or the athlete set outranks
    /// anything recomputed from a time window.
    static func hrEnrichmentTargets(
        rows: [RunSummary],
        now: Date = .now,
        limit: Int = hrEnrichmentLimit,
        withinDays: Int = hrEnrichmentDays
    ) -> [RunSummary] {
        // Plain seconds rather than calendar arithmetic: a DST hour cannot move a 90-day
        // cutoff enough to matter, and this keeps the function testable against a fixed date.
        let cutoff = now.addingTimeInterval(-Double(withinDays) * 86_400)
        return rows
            .filter { $0.avgHR == nil && !$0.corrected && $0.source == "healthkit" && $0.start >= cutoff }
            .prefix(max(0, limit))
            .map { $0 }
    }

    // MARK: - When a drop is worth saying out loud

    /// Below this, a handful of unexplained near-duplicates is ordinary clock drift.
    static let reExportFloor = 5

    /// Whether this refresh's unexplained drops deserve a `sync.dedupe_dropped` event.
    ///
    /// The old rule fired whenever anything at all was dropped, which meant every healthy
    /// refresh: a full HealthKit read re-offers the entire archive, dedupe drops the ~1,690
    /// workouts already stored, and the app announced "re-export suspected" each time. That
    /// was the first event the telemetry table ever recorded, and it was noise (#37). The
    /// comment above it claimed the signal was "silent when healthy". It was not.
    ///
    /// Two corrections. Only candidates carrying a uuid we have never stored count — a
    /// workout already in the database is not evidence of anything. And a *standing*
    /// condition is reported once rather than forever: David's phone holds ~220 unexplained
    /// near-duplicates that will still be there on the next refresh and the one after it,
    /// so the event fires when that number moves. A real re-export moves it, because a
    /// re-export is a batch of familiar runs arriving under brand-new uuids.
    ///
    /// - Parameter lastSeen: the unexplained count from the previous refresh on this
    ///   device, or nil if none has been recorded yet.
    static func reExportSignal(
        unexplained: Int,
        lastSeen: Int?,
        floor: Int = reExportFloor
    ) -> Bool {
        unexplained >= floor && unexplained != lastSeen
    }

    // MARK: - Private

    private static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
