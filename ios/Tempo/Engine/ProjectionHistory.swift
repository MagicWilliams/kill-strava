import Foundation

/// The finish projection, replayed over time — pure, no I/O.
///
/// `RunStore.recomputeProjection()` keeps no state between calls. It is a function of
/// exactly three things, the runs on file, the moment you ask, and the race it is asked about:
///
///     fastest run of >= 2.5 mi inside the trailing 42 days
///       → Riegel-extrapolated (`PaceModel.equivalentTime`) to the goal's own distance
///
/// The distance is an argument, never a constant. Until #185 it was hardcoded to 26.2, and
/// with a 5K goal the app quoted a ~4:18 "projected finish" against a 5K on Progress, You
/// and Coach — and every refresh wrote that marathon number back over the 5K one the `plan`
/// function had stored. No default here on purpose: every caller has to say which race.
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
    /// Takes no race distance, because the choice cannot depend on one: Riegel scales every
    /// candidate by the same `d₂^1.06`, so whichever run wins for a marathon wins for a 5K.
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

    /// Projected finish over `raceMeters`, in seconds, as of `asOf`, plus the run it came from.
    ///
    /// Same rule at every distance, the 2.5 mi floor included. Riegel is at its weakest
    /// extrapolating *down* (a 6 mi effort read as a 5K says nothing about top-end speed),
    /// and that is accepted: a rough 5K number is still a 5K number, which a marathon time
    /// quoted against a 5K goal never was.
    static func projection(
        _ runs: [RunSummary],
        asOf: Date,
        raceMeters: Double,
        calendar: Calendar = ProjectionHistory.calendar
    ) -> (run: RunSummary, finishS: Int)? {
        guard raceMeters > 0 else { return nil }
        guard let best = settingRun(runs, asOf: asOf, calendar: calendar),
              let pace = best.paceSecPerMile else { return nil }
        // Effort time is rebuilt from the rounded pace rather than read off `durationS`.
        // That is what `recomputeProjection` has always done; it costs under a second on a
        // marathon extrapolation, and matching it exactly matters more than the second.
        let finish = PaceModel.equivalentTime(
            seconds: Double(pace) * best.miles,
            from: best.miles,
            to: raceMeters / Units.metersPerMile
        )
        return (best, Int(finish))
    }

    // MARK: - Which race

    /// The distance the projection is asked about: the goal's `distance_m`, then its
    /// `distance` label, then the marathon — and the marathon only when there is no goal at
    /// all (just-running mode, where the number answers "what could I run a marathon in").
    ///
    /// Deliberately `RaceRecap.raceMeters(goal:)` and not a second reading of the goal: the
    /// projection, race-day detection and the recap all have to agree on what race this is.
    static func raceMeters(goal: GoalInfo?) -> Double {
        RaceRecap.raceMeters(goal: goal)
    }

    /// The race distance as the detail page says it: "5K", "the half", "the marathon".
    ///
    /// Read off the same metres the math used rather than off the goal's label, so the copy
    /// can never name one race while the number answers for another. A distance that is none
    /// of the standard ones (a custom 30K) is spelled out in the athlete's unit.
    static func distanceName(raceMeters: Double, units: Units) -> String {
        let named: [(meters: Double, name: String)] = [
            (Units.metersPerMile, "the mile"),
            (5_000, "5K"),
            (10_000, "10K"),
            (15_000, "15K"),
            (10 * Units.metersPerMile, "10 miles"),
            (RaceRecap.raceMeters(goalDistance: "half"), "the half"),
            (RaceRecap.marathonMeters, "the marathon"),
        ]
        // `distance_m` is whole metres, so a half arrives as 21,097 or 21,098, a mile as 1,609.
        if let hit = named.first(where: { abs($0.meters - raceMeters) <= 2 }) { return hit.name }
        return units.formatDistance(meters: raceMeters, decimals: 1)
    }

    // MARK: - The stored value

    /// A rewrite smaller than this is a sub-minute wobble, not news, and not worth a write.
    static let rewriteDeadbandS = 30

    /// What `recomputeProjection` should write to `plans.projected_finish_s`, or nil to leave
    /// the stored value alone.
    ///
    /// The goal has to be the plan's own goal. `loadPlan` keeps the previous goal when the
    /// goal read fails, and projecting to *that* race's distance would overwrite a correct
    /// number with one for a different race — #185 again, by another road. With no matching
    /// goal the stored value (written by the `plan` function, at the goal's distance) stands.
    static func rewrite(
        storedFinishS: Int?,
        planGoalID: UUID,
        goal: GoalInfo?,
        runs: [RunSummary],
        asOf: Date,
        calendar: Calendar = ProjectionHistory.calendar
    ) -> Int? {
        guard let goal, goal.id == planGoalID else { return nil }
        guard let projected = projection(runs, asOf: asOf, raceMeters: raceMeters(goal: goal), calendar: calendar)?.finishS
        else { return nil }
        guard abs((storedFinishS ?? 0) - projected) > rewriteDeadbandS else { return nil }
        return projected
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
    ///
    /// Every point is projected to the one `raceMeters` passed in — the race being asked
    /// about now, not whatever the goal was on that date.
    static func series(
        runs: [RunSummary],
        from: Date,
        to: Date,
        raceMeters: Double,
        stepDays: Int = 7,
        calendar: Calendar = ProjectionHistory.calendar
    ) -> [Point] {
        guard stepDays > 0, from <= to, let oldest = runs.map(\.start).min() else { return [] }
        let start = max(from, oldest)
        guard start <= to else { return [] }

        var points: [Point] = []
        var cursor = to
        while cursor >= start {
            if let p = projection(runs, asOf: cursor, raceMeters: raceMeters, calendar: calendar) {
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
