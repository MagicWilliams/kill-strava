import Foundation

/// The last N training weeks as a trajectory — pure, no I/O.
///
/// Today's weekly counter says how far you've run *this* week; this says whether that is
/// more or less than you have been running. Strava's Progress chart is the model.
///
/// Three rules, each one a way the chart could quietly lie:
///
/// 1. **Every week in the window is present, empty ones included.** A run-free week is a
///    zero point, not a missing one. Dropping it would draw a line straight across an
///    injury or a holiday and make the gap look like steady training. Gaps are information.
/// 2. **Weeks are assigned by `RunHistory.weekStart` and totalled by `RunHistory.byWeek`.**
///    Not a second grouping rule — the History screen, the coach's weekly context and this
///    chart have to agree on which week a Sunday-night run belongs to.
/// 3. **The average leaves out the current week.** On a Tuesday the current week holds two
///    days of running; averaging it in drags the reference line down every Monday and back
///    up every Sunday, and "this week vs average" would read as a deficit all week long.
///
/// Superseded rows (Garmin re-exports retired by migration 0008) never reach this function:
/// `RunStore.fetchFromSupabase` filters `superseded_by is null` at the read, which is what
/// keeps them out of `byWeek` too. `RunSummary` carries no superseded flag, so there is
/// nothing here to re-check — and re-checking would be a forked rule.
///
/// Takes plain `[RunSummary]` and a `now`, so the widget extension can call it with whatever
/// runs it holds and get the same numbers Today shows.
enum MileageProgression {

    /// Twelve weeks: one training block's worth of trajectory, and few enough points that
    /// each one stays big enough to scrub to with a thumb.
    static let defaultWeekCount = 12

    /// One Mon–Sun week of the window.
    struct WeekPoint: Identifiable, Equatable {
        /// Monday, start of day, in the calendar the window was built with.
        let weekStart: Date
        /// Sunday, start of day — the last *day* of the week, for "Sep 29 – Oct 5" labels.
        let weekEnd: Date
        let miles: Double
        let runCount: Int
        /// Longest single run in the week; 0 for an empty week.
        let longestRunMiles: Double
        /// The week holding `now`. Partial by construction — the days after today are still
        /// to come — so it's emphasised on the chart and left out of the average.
        let isCurrent: Bool

        var id: Date { weekStart }
    }

    /// The window plus the reference numbers drawn against it.
    struct Progression: Equatable {
        /// Oldest → newest. Exactly the requested count; the current week is always last.
        let weeks: [WeekPoint]
        /// Mean miles over the *completed* weeks in the window — every week but the current
        /// one, zero weeks included. 0 when the window has no completed weeks.
        let average: Double

        /// The week holding `now`.
        var current: WeekPoint? { weeks.last }
        /// This week's miles minus the average. Negative early in the week is normal; the
        /// sign is only meaningful by Sunday.
        var currentVsAverage: Double { (current?.miles ?? 0) - average }
        /// The biggest week in the window — the chart's natural ceiling.
        var peak: Double { weeks.map(\.miles).max() ?? 0 }
        /// No runs anywhere in the window. The card still draws (a flat zero line is the
        /// truth), but there is nothing to compare.
        var isEmpty: Bool { weeks.allSatisfy { $0.runCount == 0 } }
    }

    /// The last 12 Mon–Sun weeks ending with the week holding `now`, oldest first.
    static func last12Weeks(
        runs: [RunSummary],
        now: Date = .now,
        calendar: Calendar = RunHistory.calendar
    ) -> [WeekPoint] {
        weeks(defaultWeekCount, runs: runs, now: now, calendar: calendar)
    }

    /// The 12-week window with its average — what the Today card draws.
    static func progression(
        runs: [RunSummary],
        now: Date = .now,
        weekCount: Int = defaultWeekCount,
        calendar: Calendar = RunHistory.calendar
    ) -> Progression {
        let points = weeks(weekCount, runs: runs, now: now, calendar: calendar)
        let completed = points.filter { !$0.isCurrent }
        let average = completed.isEmpty ? 0 : completed.reduce(0) { $0 + $1.miles } / Double(completed.count)
        return Progression(weeks: points, average: average)
    }

    /// The trailing `count` weeks ending with the week holding `now`, oldest first.
    /// Any count ≥ 1; a widget that only has room for four weeks asks for four.
    static func weeks(
        _ count: Int,
        runs: [RunSummary],
        now: Date = .now,
        calendar: Calendar = RunHistory.calendar
    ) -> [WeekPoint] {
        guard count > 0 else { return [] }
        let currentStart = RunHistory.weekStart(of: now, calendar: calendar)

        // Each Monday re-derived through `weekStart` rather than trusted from date
        // arithmetic, so it is bit-for-bit the key `byWeek` produced — across a DST change
        // "Monday minus 7 days" and "the Monday of that week" are not guaranteed equal.
        let starts: [Date] = (0..<count).reversed().map { back in
            let shifted = calendar.date(byAdding: .weekOfYear, value: -back, to: currentStart) ?? currentStart
            return RunHistory.weekStart(of: shifted, calendar: calendar)
        }

        let totals = Dictionary(
            uniqueKeysWithValues: RunHistory.byWeek(runs, calendar: calendar).map { ($0.weekStart, $0) }
        )
        var longest: [Date: Double] = [:]
        for run in runs {
            let key = RunHistory.weekStart(of: run.start, calendar: calendar)
            longest[key] = max(longest[key] ?? 0, run.miles)
        }

        return starts.map { start in
            let week = totals[start]
            let lastDay = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            return WeekPoint(
                weekStart: start,
                weekEnd: lastDay,
                miles: week?.miles ?? 0,
                runCount: week?.runCount ?? 0,
                longestRunMiles: longest[start] ?? 0,
                isCurrent: start == currentStart
            )
        }
    }
}
