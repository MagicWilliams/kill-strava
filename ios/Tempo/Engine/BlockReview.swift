import Foundation

/// A whole training block, read back — pure, no I/O (#100).
///
/// A block is the plan's `start_date` through race day. Race day itself is **excluded** from
/// every volume number, for the reason `RaceRecap.block` gives: the race is the result of the
/// block, not part of it. Counting it would make every marathon block's longest run the
/// marathon, its race week a "peak", and its taper a build.
///
/// Distance-agnostic on purpose. Races run from the mile to the marathon (#102), and nothing
/// here may assume 42,195 m: the race distance comes in as an argument, read off the goal
/// (`RaceRecap.raceMeters`). What changes with distance is which tiles mean anything — a
/// count of 20-mile runs is the marathon block's signature and noise in a 5K block.
///
/// `RaceRecap.block` (the sixteen weeks shown under a race recap) is built from the same
/// pieces — `runs(in:)` and `raceMorningProjection` — so the two screens cannot disagree
/// about which runs a block holds or what the projection said on race morning.
enum BlockReview {

    // MARK: - Inputs

    /// A planned session, reduced to what adherence needs. `SessionInfo` only decodes, so the
    /// engine takes this instead and stays constructible in a test.
    struct PlannedSession: Equatable {
        let day: Date
        let type: String
        let status: String

        init(day: Date, type: String, status: String) {
            self.day = day
            self.type = type
            self.status = status
        }

        init(_ s: SessionInfo) {
            self.init(day: s.day, type: s.type, status: s.status)
        }

        var isQuality: Bool { ["tempo", "threshold", "interval"].contains(type) }
        var isLong: Bool { type == "long" }
        /// Rest days are not sessions you can miss, and the race is the result, not a
        /// session the block prepared for.
        var counts: Bool { type != "rest" && type != "race" }
        var isDone: Bool { status == "done" }
    }

    // MARK: - Output

    struct Week: Identifiable, Equatable {
        /// 0-based, matching `plan_weeks.week_index`.
        let index: Int
        let start: Date
        let plannedMiles: Double?
        let actualMiles: Double
        let runCount: Int
        /// The week race day falls in. Its actual miles stop the day before the race.
        let isRaceWeek: Bool
        var id: Int { index }
    }

    struct Adherence: Equatable {
        let done: Int
        let planned: Int
        /// Nil when nothing of this kind was planned — "0%" would read as a block that
        /// skipped every quality session rather than one that never had any.
        var fraction: Double? { planned > 0 ? Double(done) / Double(planned) : nil }
    }

    struct Taper: Equatable {
        let peakMiles: Double
        let raceWeekMiles: Double
        /// 0.4 = race week ran 40% below the peak. Negative if race week was bigger.
        var drop: Double { peakMiles > 0 ? 1 - raceWeekMiles / peakMiles : 0 }
    }

    struct Review: Equatable {
        let raceMeters: Double
        let weeks: [Week]
        let totalMiles: Double
        let runCount: Int
        let peakWeek: Week?
        let longest: RunSummary?
        /// Runs of 20 mi or more. Counted for every block; shown only when
        /// `showsLongRunCount`.
        let twentyPlusCount: Int
        /// Runs of 32 km or more: the same tile for an athlete who reads km (#109).
        let thirtyTwoKmPlusCount: Int
        let all: Adherence
        let quality: Adherence
        let long: Adherence
        let taper: Taper?
        /// What the finish projection read the morning the block began, and on race morning.
        /// Projected to the race's own distance — see `projection(_:morningOf:raceMeters:)`.
        let projectedAtStartS: Int?
        let projectedRaceMorningS: Int?

        /// The 20+ tile belongs to half and marathon blocks. A 5K block shows its longest run
        /// and its quality count instead.
        var showsLongRunCount: Bool { raceMeters >= halfMeters }

        /// The long-run tile's number in the athlete's unit, under `Units.longRunThresholdLabel`.
        ///
        /// Counted against the label rather than converted from it. A km athlete runs a
        /// 32.0 km long run; tested against 20 mi (32,186 m) it would miss a tile that reads
        /// "32+ km". What the coach is told stays the 20-mile count (`runs_20_plus`).
        func longRunCount(_ units: Units) -> Int {
            switch units {
            case .mi: return twentyPlusCount
            case .km: return thirtyTwoKmPlusCount
            }
        }
        /// Projection drift across the block. Negative = the projection got faster.
        var projectionChangeS: Int? {
            guard let a = projectedAtStartS, let b = projectedRaceMorningS else { return nil }
            return b - a
        }
    }

    static let halfMeters = 21_097.5

    /// `goals.distance` as a person says it. Same keys as `RaceRecap.raceMeters`.
    static func distanceLabel(_ key: String?) -> String {
        switch key {
        case "1mi":  return "Mile"
        case "5k":   return "5K"
        case "10k":  return "10K"
        case "15k":  return "15K"
        case "10mi": return "10 mile"
        case "half": return "Half marathon"
        default:     return "Marathon"
        }
    }

    /// 20 miles in the units the `runs` table stores: whole metres, **truncated** on ingest
    /// (`Int(totalDistance)` in `HealthService`). `20 * 1609.34` is 32,186.8, so a run Garmin
    /// recorded as exactly 20.00 mi is stored as 32,186 and would miss a `>= 20.0 mi` test by
    /// 0.8 m. The bar is the stored value of 20 miles, not the real-number one.
    static let twentyMilesM = Int(20 * RaceRecap.metersPerMile)

    static func isTwentyPlus(_ run: RunSummary) -> Bool { run.distanceM >= twentyMilesM }

    /// 32 km in stored whole metres. No truncation question here: 32,000 is already whole.
    static let thirtyTwoKmM = 32_000

    static func isThirtyTwoKmPlus(_ run: RunSummary) -> Bool { run.distanceM >= thirtyTwoKmM }

    // MARK: - Shared with RaceRecap.block

    /// Runs from the start of `from`'s day up to — not including — race day.
    static func runs(
        in runs: [RunSummary],
        from: Date,
        raceDay: Date,
        calendar: Calendar = .current
    ) -> [RunSummary] {
        let lo = calendar.startOfDay(for: from)
        let hi = calendar.startOfDay(for: raceDay)
        return runs.filter { $0.start >= lo && $0.start < hi }
    }

    /// The finish projection as of the instant `day` began, replayed through the same rule
    /// Progress uses (`ProjectionHistory`), so it is the number the app was showing that
    /// morning rather than one that has since seen later runs.
    ///
    /// Projected to the race's own `raceMeters`. This used to be gated to the marathon,
    /// because the projection could only extrapolate to 26.2; since #185 it answers for any
    /// distance, so a 10K block gets a 10K projection to set beside its 10K result.
    static func projection(
        _ runs: [RunSummary],
        morningOf day: Date,
        raceMeters: Double,
        calendar: Calendar = .current
    ) -> Int? {
        let asOf = calendar.startOfDay(for: day).addingTimeInterval(-1)
        return ProjectionHistory.projection(runs, asOf: asOf, raceMeters: raceMeters)?.finishS
    }

    // MARK: - The review

    static func review(
        runs allRuns: [RunSummary],
        planStart: Date,
        raceDay: Date,
        raceMeters: Double,
        planWeeks: [PlanWeekInfo],
        sessions: [PlannedSession],
        calendar: Calendar = .current
    ) -> Review {
        let blockStart = calendar.startOfDay(for: planStart)
        let raceStart = calendar.startOfDay(for: raceDay)
        let inBlock = runs(in: allRuns, from: blockStart, raceDay: raceStart, calendar: calendar)

        // Weeks: the plan's own seven-day stride from its start date, up to and including the
        // week race day falls in. Not calendar weeks — the plan's `week_index` is counted from
        // `start_date`, and the planned bars have to line up with it.
        let daysToRace = calendar.dateComponents([.day], from: blockStart, to: raceStart).day ?? -1
        let weekCount = daysToRace >= 0 ? daysToRace / 7 + 1 : 0
        let targets = Dictionary(planWeeks.map { ($0.week_index, $0.target_mileage) }, uniquingKeysWith: { a, _ in a })

        var weeks: [Week] = []
        for i in 0..<weekCount {
            guard let lo = calendar.date(byAdding: .day, value: 7 * i, to: blockStart),
                  let hi = calendar.date(byAdding: .day, value: 7 * (i + 1), to: blockStart) else { continue }
            let these = inBlock.filter { $0.start >= lo && $0.start < hi }
            weeks.append(Week(
                index: i,
                start: lo,
                plannedMiles: targets[i] ?? nil,
                actualMiles: these.reduce(0) { $0 + $1.miles },
                runCount: these.count,
                isRaceWeek: i == weekCount - 1
            ))
        }

        // Taper: race week against the biggest week *before* it. Race week's own miles stop
        // the day before the race (see the type comment), so a marathon week doesn't read as
        // the peak of the block.
        let raceWeek = weeks.last
        let buildPeak = weeks.dropLast().max { $0.actualMiles < $1.actualMiles }
        let taper: Taper? = {
            guard let raceWeek, let buildPeak, buildPeak.actualMiles > 0 else { return nil }
            return Taper(peakMiles: buildPeak.actualMiles, raceWeekMiles: raceWeek.actualMiles)
        }()

        let counted = sessions.filter { $0.counts && $0.day >= blockStart && $0.day < raceStart }
        func adherence(_ s: [PlannedSession]) -> Adherence {
            Adherence(done: s.filter(\.isDone).count, planned: s.count)
        }

        return Review(
            raceMeters: raceMeters,
            weeks: weeks,
            totalMiles: inBlock.reduce(0) { $0 + $1.miles },
            runCount: inBlock.count,
            peakWeek: weeks.max { $0.actualMiles < $1.actualMiles }.flatMap { $0.actualMiles > 0 ? $0 : nil },
            longest: inBlock.max { $0.distanceM < $1.distanceM },
            twentyPlusCount: inBlock.filter(isTwentyPlus).count,
            thirtyTwoKmPlusCount: inBlock.filter(isThirtyTwoKmPlus).count,
            all: adherence(counted),
            quality: adherence(counted.filter(\.isQuality)),
            long: adherence(counted.filter(\.isLong)),
            taper: taper,
            projectedAtStartS: projection(allRuns, morningOf: blockStart, raceMeters: raceMeters, calendar: calendar),
            projectedRaceMorningS: projection(allRuns, morningOf: raceStart, raceMeters: raceMeters, calendar: calendar)
        )
    }
}
