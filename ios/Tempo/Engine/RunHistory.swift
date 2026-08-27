import Foundation

/// Pure aggregation over the whole run archive — grouping, totals, streaks, records.
///
/// Deliberately `RunSummary`-only. Every number here comes from the corrected Supabase
/// rows the app already holds in memory (all 2,000+ of them), so the History screen
/// renders instantly and never touches HealthKit or the network. Per-run series —
/// splits, route, zones — stay in `RunDetailLoader`, which loads exactly one run.
///
/// The "fastest" records are *average pace over a whole run of at least N miles*, not a
/// fastest split within a run. Those two are different numbers and conflating them would
/// quietly overstate the athlete's bests, so the naming says `Run` everywhere and the UI
/// labels them "fastest 10K+ run". True sub-distance bests need the per-run distance
/// timeline and belong in a separate pass.
enum RunHistory {

    /// Training weeks run Mon–Sun. Held here rather than borrowed from `RunStore` so the
    /// engine stays pure — no actor isolation, no store to construct in a test.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        return c
    }()

    // MARK: - Grouping

    /// One calendar month of runs. Totals are stored, not computed on access, because a
    /// SwiftUI list body re-reads them on every frame.
    struct Month: Identifiable, Equatable {
        let start: Date            // first instant of the month
        let runs: [RunSummary]     // newest first
        let miles: Double
        let durationS: Int
        /// Longest single run in the month — the bar scale for that month's rows.
        let maxMiles: Double

        var id: Date { start }
        var runCount: Int { runs.count }

        init(start: Date, runs: [RunSummary]) {
            self.start = start
            self.runs = runs
            self.miles = runs.reduce(0) { $0 + $1.miles }
            self.durationS = runs.reduce(0) { $0 + $1.durationS }
            self.maxMiles = runs.map(\.miles).max() ?? 0
        }
    }

    /// Runs grouped into calendar months, newest month first, newest run first within each.
    static func byMonth(_ runs: [RunSummary], calendar: Calendar = RunHistory.calendar) -> [Month] {
        let groups = Dictionary(grouping: runs) { run -> Date in
            calendar.date(from: calendar.dateComponents([.year, .month], from: run.start)) ?? run.start
        }
        return groups
            .map { Month(start: $0.key, runs: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.start > $1.start }
    }

    /// Runs grouped into Mon–Sun training weeks, newest week first.
    static func byWeek(_ runs: [RunSummary], calendar: Calendar = RunHistory.calendar) -> [WeekSummary] {
        let groups = Dictionary(grouping: runs) { run -> Date in
            calendar.dateInterval(of: .weekOfYear, for: run.start)?.start ?? run.start
        }
        return groups
            .map { start, inWeek in
                WeekSummary(
                    weekStart: start,
                    miles: inWeek.reduce(0) { $0 + $1.miles },
                    runCount: inWeek.count,
                    durationS: inWeek.reduce(0) { $0 + $1.durationS }
                )
            }
            .sorted { $0.weekStart > $1.weekStart }
    }

    // MARK: - Records

    /// A "fastest run" record is scoped to a minimum distance, so a blistering 1-mile
    /// shakeout can't outrank a strong half. Bands are open-ended upward: a marathon
    /// qualifies for every band below it.
    enum Band: String, CaseIterable, Identifiable {
        case threeMile, tenK, half, marathon

        var id: String { rawValue }

        var minMiles: Double {
            switch self {
            case .threeMile: return 3
            case .tenK:      return 6.2
            case .half:      return 13.1
            case .marathon:  return 26.2
            }
        }

        var label: String {
            switch self {
            case .threeMile: return "3 mi+"
            case .tenK:      return "10K+"
            case .half:      return "Half+"
            case .marathon:  return "Marathon"
            }
        }
    }

    struct Records {
        var totalRuns: Int = 0
        var totalMiles: Double = 0
        var totalDurationS: Int = 0

        var longestRun: RunSummary?
        /// Fastest average pace among runs of at least the band's distance.
        var fastestRun: [Band: RunSummary] = [:]
        var biggestWeek: WeekSummary?
        var biggestMonth: Month?

        var currentStreakDays: Int = 0
        var longestStreakDays: Int = 0

        /// Every run that holds at least one record — the badge set for the history list.
        var recordRunIDs: Set<UUID> = []

        var firstRun: Date?
    }

    static func records(
        _ runs: [RunSummary],
        now: Date = .now,
        calendar: Calendar = RunHistory.calendar
    ) -> Records {
        var r = Records()
        guard !runs.isEmpty else { return r }

        r.totalRuns = runs.count
        r.totalMiles = runs.reduce(0) { $0 + $1.miles }
        r.totalDurationS = runs.reduce(0) { $0 + $1.durationS }
        r.firstRun = runs.map(\.start).min()

        // Longest. Ties break to the earlier run — the first time you went that far is
        // the one worth remembering.
        r.longestRun = runs.max { a, b in
            a.miles == b.miles ? a.start > b.start : a.miles < b.miles
        }

        for band in Band.allCases {
            let qualifying = runs.filter { $0.miles >= band.minMiles && $0.paceSecPerMile != nil }
            r.fastestRun[band] = qualifying.min { a, b in
                let pa = a.paceSecPerMile ?? .max, pb = b.paceSecPerMile ?? .max
                return pa == pb ? a.start < b.start : pa < pb
            }
        }

        r.biggestWeek = byWeek(runs, calendar: calendar).max { $0.miles < $1.miles }
        r.biggestMonth = byMonth(runs, calendar: calendar).max { $0.miles < $1.miles }

        let s = streaks(runs, now: now, calendar: calendar)
        r.currentStreakDays = s.current
        r.longestStreakDays = s.longest

        r.recordRunIDs = Set(r.fastestRun.values.map(\.id))
        if let longest = r.longestRun { r.recordRunIDs.insert(longest.id) }

        return r
    }

    // MARK: - Streaks

    /// Consecutive calendar days carrying at least one run.
    ///
    /// The current streak counts back from today, but a day with no run *yet* doesn't
    /// break it — an evening runner would otherwise watch the streak read 0 all morning
    /// and then jump back. It only breaks once yesterday is also empty.
    static func streaks(
        _ runs: [RunSummary],
        now: Date = .now,
        calendar: Calendar = RunHistory.calendar
    ) -> (current: Int, longest: Int) {
        guard !runs.isEmpty else { return (0, 0) }
        let days = Set(runs.map { calendar.startOfDay(for: $0.start) })
        let sorted = days.sorted()

        var longest = 1
        var run = 1
        if sorted.count > 1 {
            for i in 1..<sorted.count {
                let gap = calendar.dateComponents([.day], from: sorted[i - 1], to: sorted[i]).day ?? 0
                run = gap == 1 ? run + 1 : 1
                longest = max(longest, run)
            }
        }

        let today = calendar.startOfDay(for: now)
        var cursor = days.contains(today)
            ? today
            : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        var current = 0
        while days.contains(cursor) {
            current += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        return (current, max(longest, current))
    }

    // MARK: - The wall (calendar heatmap)

    /// One calendar day's training, whether or not anything was run.
    struct Day: Identifiable, Equatable {
        let date: Date          // start of day
        let miles: Double
        let runCount: Int
        let runIDs: [UUID]

        var id: Date { date }
        var didRun: Bool { runCount > 0 }

        /// Intensity bucket for the heatmap, 0 (rest) … 4 (long run).
        ///
        /// Fixed thresholds rather than quantiles of the athlete's own distribution: a
        /// marathoner's easy day and long day mean the same thing in June as in a taper
        /// week, and a relative scale would repaint the whole wall every time a big week
        /// landed. 13.1 is the top band because a half is the shape of a long run.
        var level: Int {
            switch miles {
            case ..<0.05: return 0
            case ..<4:    return 1
            case ..<8:    return 2
            case ..<13.1: return 3
            default:      return 4
            }
        }
    }

    /// A year of the wall, laid out as week columns of 7 weekday rows (Mon…Sun).
    ///
    /// `nil` slots are days outside the year — the leading gap before Jan 1 lands on its
    /// real weekday, and the trailing gap after Dec 31. Without them the grid would shear
    /// by a day or two per year and the weekday rows would stop meaning anything.
    struct YearBlock: Identifiable, Equatable {
        let year: Int
        let weeks: [[Day?]]     // each inner array is exactly 7 entries, Mon…Sun
        let miles: Double
        let runCount: Int

        var id: Int { year }
    }

    /// Per-day totals for every day that carries at least one run.
    static func dayTotals(_ runs: [RunSummary], calendar: Calendar = RunHistory.calendar) -> [Date: Day] {
        Dictionary(grouping: runs) { calendar.startOfDay(for: $0.start) }
            .mapValues { sameDay in
                Day(
                    date: calendar.startOfDay(for: sameDay[0].start),
                    miles: sameDay.reduce(0) { $0 + $1.miles },
                    runCount: sameDay.count,
                    runIDs: sameDay.sorted { $0.start < $1.start }.map(\.id)
                )
            }
    }

    /// The whole archive as year blocks, newest year first.
    static func wall(_ runs: [RunSummary], calendar: Calendar = RunHistory.calendar) -> [YearBlock] {
        guard !runs.isEmpty else { return [] }
        let totals = dayTotals(runs, calendar: calendar)
        let years = Set(runs.map { calendar.component(.year, from: $0.start) }).sorted(by: >)

        return years.compactMap { year -> YearBlock? in
            guard let jan1 = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let dec31 = calendar.date(from: DateComponents(year: year, month: 12, day: 31))
            else { return nil }

            // Weekday index with Monday = 0, matching the calendar's Mon-first weeks.
            func row(_ date: Date) -> Int {
                (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
            }

            var weeks: [[Day?]] = []
            var column = [Day?](repeating: nil, count: 7)
            var cursor = jan1

            while cursor <= dec31 {
                let r = row(cursor)
                column[r] = totals[cursor] ?? Day(date: cursor, miles: 0, runCount: 0, runIDs: [])
                if r == 6 {
                    weeks.append(column)
                    column = [Day?](repeating: nil, count: 7)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            if column.contains(where: { $0 != nil }) { weeks.append(column) }

            let inYear = runs.filter { calendar.component(.year, from: $0.start) == year }
            return YearBlock(
                year: year,
                weeks: weeks,
                miles: inYear.reduce(0) { $0 + $1.miles },
                runCount: inYear.count
            )
        }
    }
}
