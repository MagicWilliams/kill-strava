import Foundation

/// The finish projection, replayed over time — pure, no I/O.
///
/// `RunStore.recomputeProjection()` keeps no state between calls. It is a function of
/// exactly two things, the runs on file and the moment you ask:
///
///     fastest run of >= 2.5 mi inside the trailing 42 days
///       → Riegel-extrapolated (`PaceModel.equivalentTime`) to marathon distance
///
/// Because of that, the whole history of what the projection *would have been* is
/// reconstructible right now from the archive already in memory — no new table, no waiting
/// months for a chart to fill. A `projection_history` table would have been strictly worse:
/// it could only ever record the future, and it would start lying the day the formula
/// changed. So this replays the rule instead.
///
/// `recomputeProjection` reads its current value from here too. Two copies of the rule
/// would drift, and the chart would end up disagreeing with the card it was opened from.
enum ProjectionHistory {

    /// How far back the projection looks. Six weeks: long enough to catch a race or a hard
    /// tempo, short enough that what it catches still describes current fitness.
    static let windowDays = 42

    /// A run has to be at least this far before its average pace means anything. A blazing
    /// mile of strides is not evidence you can hold that shape for 26.2.
    static let minQualifyingMiles = 2.5

    /// Training weeks run Mon–Sun. Held here, like `RunHistory.calendar`, so the engine
    /// stays pure — no actor isolation, no store to construct in a test.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        return c
    }()

    /// One replayed projection: what the app would have shown on `date`, and the run it
    /// would have shown it from.
    struct Point: Identifiable, Equatable {
        let date: Date
        let projectedFinishS: Int
        let runID: UUID

        var id: Date { date }
    }

    // MARK: - A single moment

    /// The one effort the projection rests on as of `asOf` — fastest average pace among
    /// qualifying runs in the trailing window. Nil when nothing qualifies.
    ///
    /// Ties break to the more recent run, matching `min(by:)` over `RunStore.runs` (which
    /// is newest-first), so this names the same run the Progress card is quoting.
    ///
    /// The `start <= asOf` half of the filter is the only thing here that `recomputeProjection`
    /// does not do, and it is what makes replay honest: asking what the projection was in
    /// 2024 must not let 2025's runs answer.
    static func settingRun(
        _ runs: [RunSummary],
        asOf: Date,
        calendar: Calendar = ProjectionHistory.calendar
    ) -> RunSummary? {
        guard let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: asOf) else { return nil }
        return runs
            .filter {
                $0.start >= cutoff && $0.start <= asOf
                    && $0.miles >= minQualifyingMiles && $0.paceSecPerMile != nil
            }
            .min { a, b in
                let pa = a.paceSecPerMile ?? .max, pb = b.paceSecPerMile ?? .max
                return pa == pb ? a.start > b.start : pa < pb
            }
    }

    /// Projected marathon finish in seconds as of `asOf`, plus the run it came from.
    static func projection(
        _ runs: [RunSummary],
        asOf: Date,
        calendar: Calendar = ProjectionHistory.calendar
    ) -> (run: RunSummary, finishS: Int)? {
        guard let best = settingRun(runs, asOf: asOf, calendar: calendar),
              let pace = best.paceSecPerMile else { return nil }
        // Effort time is rebuilt from the rounded pace rather than read off `durationS`.
        // That is what `recomputeProjection` has always done; it costs under a second on a
        // marathon extrapolation, and matching it exactly matters more than the second.
        let finish = PaceModel.equivalentTime(
            seconds: Double(pace) * best.miles,
            from: best.miles,
            to: RaceDistance.marathon.miles
        )
        return (best, Int(finish))
    }

    // MARK: - The replay

    /// The projection replayed from `from` to `to` at `stepDays` intervals.
    ///
    /// Anchored on `to` and walked backwards, so the newest point is always exactly the
    /// moment asked for. Stepping forwards from an arbitrary start date would leave the
    /// right edge of the chart up to a week stale, and the right edge is the one point the
    /// athlete will check against the card he tapped to get here.
    ///
    /// A window with no qualifying run yields **no point**. Not a carried-forward value,
    /// not an interpolated one: a gap is six weeks in which nothing was run far enough to
    /// extrapolate from, and drawing a number there would claim a fitness reading that
    /// nobody took.
    ///
    /// `from` may safely be `.distantPast` — it clamps to the oldest run, since no window
    /// ending before that can contain anything.
    static func series(
        runs: [RunSummary],
        from: Date,
        to: Date,
        stepDays: Int = 7,
        calendar: Calendar = ProjectionHistory.calendar
    ) -> [Point] {
        guard stepDays > 0, from <= to, let oldest = runs.map(\.start).min() else { return [] }
        let start = max(from, oldest)
        guard start <= to else { return [] }

        var points: [Point] = []
        var cursor = to
        while cursor >= start {
            if let p = projection(runs, asOf: cursor, calendar: calendar) {
                points.append(Point(date: cursor, projectedFinishS: p.finishS, runID: p.run.id))
            }
            guard let previous = calendar.date(byAdding: .day, value: -stepDays, to: cursor) else { break }
            cursor = previous
        }
        return points.reversed()
    }

    /// Contiguous stretches of a series, split wherever the replay found nothing.
    ///
    /// Charts draw a straight line between adjacent points, which would quietly interpolate
    /// across exactly the gaps this engine refuses to invent. One line per stretch keeps the
    /// holes visible.
    static func segments(
        _ points: [Point],
        stepDays: Int = 7,
        calendar: Calendar = ProjectionHistory.calendar
    ) -> [[Point]] {
        guard let first = points.first else { return [] }
        var stretches: [[Point]] = []
        var current: [Point] = [first]
        for point in points.dropFirst() {
            let gap = calendar.dateComponents([.day], from: current[current.count - 1].date, to: point.date).day ?? 0
            if gap > stepDays {
                stretches.append(current)
                current = [point]
            } else {
                current.append(point)
            }
        }
        stretches.append(current)
        return stretches
    }
}
