import Foundation

/// A pair of shoes (#121) — one row of `shoes` (migration 0016).
///
/// Distances are metres, as everywhere in storage; miles are a display concern.
struct Shoe: Identifiable, Hashable {
    let id: UUID
    var name: String
    var brand: String? = nil
    var model: String? = nil
    var startedAt: Date
    /// Set when the athlete retires the pair. Retired, never deleted: deleting a shoe nulls
    /// `shoe_id` on every run it was worn for, and its history goes with it.
    var retiredAt: Date? = nil
    /// Metres already on the pair before Tempo saw it — bought used, or worn before the
    /// switch from another app. Without it an old pair reads as new.
    var startMileageM: Int = 0

    var isRetired: Bool { retiredAt != nil }
}

/// Shoe mileage and the "time for a new pair" nudge — pure, no I/O.
///
/// A pair's mileage is `startMileageM` plus the distance of every run tagged with it. That
/// is the whole formula, and the ways it can go quietly wrong are what this file pins:
///
/// 1. **Superseded runs never count.** A Garmin re-export retired by migration 0008 is the
///    same run twice; counting it would put phantom miles on the pair and pull the
///    retirement nudge forward. The archive read already filters `superseded_by is null`,
///    so every `RunSummary` arrives live — but a shoe total is exactly the kind of number
///    that will later be read straight off `runs where shoe_id = …` (a shoe detail page, the
///    Watch), and that read has to get the same answer. So the rule is stated here too, on
///    an input that can carry it.
/// 2. **Every pair has a total, run or no run.** A pair added this morning is "0 mi", not
///    missing from the list.
/// 3. **A tag pointing at a pair that isn't in the list is ignored**, not attributed to
///    anything — the shoe was deleted, or belongs to a different read.
enum ShoeMileage {

    static let metersPerMile = 1609.34

    // MARK: - Input

    /// What mileage needs from a run: which pair, how far, and whether it still counts.
    struct Run: Hashable {
        let shoeID: UUID?
        let distanceM: Int
        /// `superseded_by is not null` — a duplicate kept only so the retirement is
        /// reversible. Never counts.
        var isSuperseded: Bool = false
    }

    // MARK: - Totals

    struct Tally: Equatable {
        /// Start mileage plus every live run tagged with the pair.
        let meters: Int
        /// Live runs tagged with the pair. Start mileage is not a run.
        let runs: Int

        var miles: Double { Double(meters) / ShoeMileage.metersPerMile }
    }

    /// One `Tally` per shoe, keyed by its id — every shoe present, even with no runs.
    static func tallies(_ shoes: [Shoe], runs: [Run]) -> [UUID: Tally] {
        var meters: [UUID: Int] = [:]
        var counts: [UUID: Int] = [:]
        for run in runs where !run.isSuperseded {
            guard let id = run.shoeID else { continue }
            // A negative distance is corrupt data, not a refund.
            meters[id, default: 0] += max(run.distanceM, 0)
            counts[id, default: 0] += 1
        }
        var out: [UUID: Tally] = [:]
        for shoe in shoes {
            out[shoe.id] = Tally(
                meters: max(shoe.startMileageM, 0) + (meters[shoe.id] ?? 0),
                runs: counts[shoe.id] ?? 0
            )
        }
        return out
    }

    /// One pair's tally.
    static func tally(_ shoe: Shoe, runs: [Run]) -> Tally {
        tallies([shoe], runs: runs)[shoe.id] ?? Tally(meters: max(shoe.startMileageM, 0), runs: 0)
    }

    // MARK: - Retirement nudge

    /// Where the nudge fires by default. Most running shoes are rated 300–500 miles; 400 is
    /// the middle of that, and the athlete can move it within the range.
    static let defaultRetirementMiles = 400
    static let retirementMilesRange = 300...500
    /// The choices the setting offers — the range, in 50-mile steps.
    static let retirementMilesOptions = Array(stride(from: retirementMilesRange.lowerBound,
                                                     through: retirementMilesRange.upperBound,
                                                     by: 50))
    /// How far ahead of the threshold "getting close" starts. About two weeks of training,
    /// so the nudge lands in time to buy a pair and break it in, not on the day they die.
    static let nearingWindowMiles = 50

    /// A stored or typed threshold pulled into the range. A stray 0 from an unset
    /// preference must not make every pair "due", and a 5,000 must not silence the nudge.
    static func clampedThreshold(_ miles: Int?) -> Int {
        guard let miles, miles > 0 else { return defaultRetirementMiles }
        return min(max(miles, retirementMilesRange.lowerBound), retirementMilesRange.upperBound)
    }

    enum Wear: Equatable {
        /// Plenty left, or the pair is already retired — nothing to say.
        case fine
        /// Inside the window before the threshold. Whole miles left, rounded up so the hint
        /// never reads "0 mi left" while the pair is still short of it.
        case nearing(milesLeft: Int)
        /// At or past the threshold.
        case due
    }

    static func wear(_ tally: Tally, thresholdMiles: Int, retired: Bool) -> Wear {
        guard !retired else { return .fine }
        let threshold = Double(clampedThreshold(thresholdMiles))
        let left = threshold - tally.miles
        if left <= 0 { return .due }
        if left <= Double(nearingWindowMiles) { return .nearing(milesLeft: Int(left.rounded(.up))) }
        return .fine
    }

    // MARK: - Default pair

    /// The pair the post-run picker preselects: the stored choice, but only while that pair
    /// is still in the list and still in service. Retiring the default leaves no default —
    /// silently moving it to another pair would tag runs with shoes the athlete never chose.
    static func resolvedDefault(storedID: UUID?, shoes: [Shoe]) -> UUID? {
        guard let storedID, let shoe = shoes.first(where: { $0.id == storedID }), !shoe.isRetired
        else { return nil }
        return storedID
    }

    // MARK: - Ordering

    /// In service first, newest pair on top; then retired, most recently retired first.
    static func ordered(_ shoes: [Shoe]) -> (active: [Shoe], retired: [Shoe]) {
        let active = shoes.filter { !$0.isRetired }
            .sorted { ($0.startedAt, $0.name) > ($1.startedAt, $1.name) }
        let retired = shoes.filter(\.isRetired)
            .sorted { ($0.retiredAt ?? .distantPast, $0.name) > ($1.retiredAt ?? .distantPast, $1.name) }
        return (active, retired)
    }

    // MARK: - Writing

    /// A new pair as the add form collected it, normalized for the insert.
    struct Draft: Equatable {
        let name: String
        let startMileageM: Int
    }

    /// Nil when there is nothing to save. The name is trimmed (the column refuses a blank
    /// one, and a refused insert loses the whole form); miles already on the pair are
    /// optional, never negative, and stored as metres.
    static func draft(name: String, startMiles: Double?) -> Draft? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let miles = startMiles.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        return Draft(name: trimmed, startMileageM: Int((miles * metersPerMile).rounded()))
    }

    /// The `retired_at` to write. `shoes` checks `retired_at >= started_at`, and `started_at`
    /// was stamped by the *server's* clock — a phone running a few seconds behind, retiring a
    /// pair it added a moment ago, would be refused. So: never earlier than the start, and
    /// when the start wins, a second past it — the write goes out as ISO-8601 text, which
    /// drops the microseconds Postgres stamped, and the start itself truncated would land
    /// just *before* the start.
    static func retiredAt(now: Date, startedAt: Date) -> Date {
        max(now, startedAt.addingTimeInterval(1))
    }
}

extension ShoeMileage.Run {
    /// From the in-memory archive. `RunStore` reads only `superseded_by is null`, so every
    /// `RunSummary` is live by construction.
    init(_ run: RunSummary) {
        self.init(shoeID: run.journal.shoeID, distanceM: run.distanceM, isSuperseded: false)
    }
}
