import Foundation

/// What a tab header says about the race — a pure function of the goal and the moment you
/// ask. One day count, one week count, one race label, for Plan, Progress and You.
///
/// Extracted from `ProgressScreen`, which until now counted down to a `static let` pinned
/// to 2026-10-11 with the comment "fixed race target until Goal Setup is wired" (#36).
/// Goal Setup got wired; the constant did not get deleted. It agreed with the real goal
/// only by coincidence, and the day the athlete or the coach moved the race — `create_plan`
/// can do it mid-block — Progress would have gone on counting down to a race nobody was
/// training for, in the confident voice of a number that had never been wrong before.
///
/// So there is no fallback date here on purpose. Every path that cannot name a real race
/// day says so in words instead of guessing one, because a stale date looks authoritative
/// and an empty state does not.
///
/// ── Why all three tabs read this (#230) ──────────────────────────────────────────────
/// On 15 Oct 2026, 12:52, with the race on 27 Nov, Plan said **42 days**, You said
/// **6 weeks**, Progress said **7 weeks**. Three screens, one date, three answers. Plan and
/// You each did their own `dateComponents([.day], from: .now)`: counting from the current
/// *instant* loses a day the moment it is past midnight, and flooring that into weeks loses
/// another. Only Progress measured start-of-day to start-of-day, which is the rule — a
/// countdown ticks at midnight, not at whatever hour the app was opened.
///
/// The right answer was 43 days, 7 weeks. David's call: show both. So the day count lives
/// here, the week count is *derived from it* rather than measured again, and no view does
/// date math.
///
/// And none of the three named the distance, which is why a 5K saved as a marathon (#215)
/// went two weeks unnoticed: every header read "Race", a word that is true of both.
/// `raceLabel` is the fix — named off the same metres the projection uses, so a header
/// cannot name one race while the number answers for another.
enum RaceCountdown {

    /// Race dates arrive as `yyyy-MM-dd` parsed at local midnight (`PlanDates.day`), so the
    /// count is over calendar days in the athlete's own time zone — it ticks at midnight,
    /// not at whatever time of day the app happened to launch.
    static let calendar = Calendar(identifier: .iso8601)

    /// Used where a race has to be named and the goal carries no name: the block review, the
    /// recap header, Run Detail's race banner.
    ///
    /// The three countdown headers do **not** use it any more — they read `raceLabel`, which
    /// always has a distance to fall back on and says "Marathon race" rather than "Race"
    /// (#230 item 3).
    static let unnamedRace = "Race"

    /// How much room the countdown has to say itself in.
    ///
    /// A subtitle is one line under a tab title, and "Turkey Trot · 5K · 43 days · 7 weeks"
    /// does not fit one on an SE. Truncating it drops the *end* — the numbers — and keeps the
    /// part the athlete already knows, so instead the line drops to `compact` whole.
    enum Width: Equatable {
        /// "43 days · 7 weeks"
        case full
        /// "43 days"
        case compact
    }

    /// The five things a header can be. Split out from the copy so the decision — is the
    /// race ahead, today, or behind us? — is testable without pinning prose.
    enum State: Equatable {
        /// No goal at all. Progress renders before any plan exists.
        case noGoal
        /// A goal, but no usable race date on it. Nothing to count.
        case undated(race: String)
        /// `days` is the calendar-day count; `weeks` is derived from it, never measured
        /// separately, so the two can never disagree the way the three tabs did.
        case ahead(race: String, days: Int, weeks: Int)
        case raceDay(race: String)
        /// Race day has passed. Deliberately does *not* carry a count: see `subtitle`.
        case past(race: String)

        /// The race as this header names it; nil only when there is no goal to name.
        var race: String? {
            switch self {
            case .noGoal:
                return nil
            case .undated(let race), .ahead(let race, _, _), .raceDay(let race), .past(let race):
                return race
            }
        }

        /// Calendar days to race day. Nil unless the race is still ahead — nothing else here
        /// has a number to count, and a zero would read as a countdown with time left on it.
        var days: Int? {
            guard case .ahead(_, let days, _) = self else { return nil }
            return days
        }

        /// Whole weeks to race day, rounded up — and nil inside the final week, where a week
        /// count adds nothing the day count has not already said ("6 days", not
        /// "6 days · 1 week"). Nil too unless the race is ahead.
        ///
        /// That rule lives here, in one place, so the subtitle and Plan's hero caption cannot
        /// disagree about when a week count is worth printing.
        var weeks: Int? {
            guard case .ahead(_, let days, let weeks) = self, days >= 7 else { return nil }
            return weeks
        }

        /// "43 days · 7 weeks", or "43 days" where there is less room. Nil unless the race is
        /// ahead. Both widths are days only inside the final week (see `weeks`).
        func countdown(_ width: Width = .full) -> String? {
            guard let days else { return nil }
            guard width == .full, let weeks else { return Self.dayCount(days) }
            return "\(Self.dayCount(days)) · \(Self.weekCount(weeks))"
        }

        /// The line under a tab title: the race and its countdown, or — for every state with
        /// nothing to count — what that state is, in words.
        func subtitle(_ width: Width = .full) -> String {
            switch self {
            case .noGoal:
                // Neutral on purpose (#101): not training for anything is a state the
                // athlete chose, not a step they skipped.
                return "No race on the calendar — just running"
            case .undated(let race):
                return "\(race) — no race date yet"
            case .ahead(let race, _, _):
                return [race, countdown(width)].compactMap { $0 }.joined(separator: " · ")
            case .raceDay(let race):
                return "Race day — \(race)"
            case .past(let race):
                // A countdown past its race is the same defect as the hardcoded date: a
                // number that reads as current and isn't. "0 weeks to Chicago" says the
                // race is this week. So the header stops counting and points at the only
                // thing left to do — pick the next race.
                return "\(race) is behind you — set the next goal with the coach"
            }
        }

        /// Plan's countdown hero: the big number, and the caption under it — ("43",
        /// "days to go · 7 weeks"). Nil unless the race is ahead, because the hero's whole
        /// shape is a number being counted down, and Plan prints `subtitle()` instead.
        var hero: (number: String, caption: String)? {
            guard let days else { return nil }
            let unit = "day\(days == 1 ? "" : "s") to go"
            guard let weeks else { return ("\(days)", unit) }
            return ("\(days)", "\(unit) · \(Self.weekCount(weeks))")
        }

        /// "43 days" / "1 day".
        private static func dayCount(_ days: Int) -> String {
            "\(days) day\(days == 1 ? "" : "s")"
        }

        /// "7 weeks" / "1 week".
        private static func weekCount(_ weeks: Int) -> String {
            "\(weeks) week\(weeks == 1 ? "" : "s")"
        }
    }

    // MARK: - Counting

    /// Calendar days between `now` and race day, start-of-day to start-of-day: the count
    /// ticks over at midnight, not at the hour the app was opened. Negative once the race is
    /// behind us, which is how `state` spots that case.
    ///
    /// This is the one measurement. `weeksRemaining` divides it; nothing measures again.
    static func daysRemaining(from now: Date, to raceDay: Date, calendar: Calendar = RaceCountdown.calendar) -> Int {
        calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: raceDay)
        ).day ?? 0
    }

    /// Whole weeks between `now` and race day, rounded up: the last six days before the
    /// race are still "1 week to Chicago", never "0 weeks".
    static func weeksRemaining(from now: Date, to raceDay: Date, calendar: Calendar = RaceCountdown.calendar) -> Int {
        Int((Double(daysRemaining(from: now, to: raceDay, calendar: calendar)) / 7.0).rounded(.up))
    }

    // MARK: - Naming the race

    /// The race distance as a label names it — "5K", "Half", "Marathon" — read off metres.
    ///
    /// Metres, not `goals.distance`: the label column and `distance_m` can disagree, and when
    /// they did it cost a 5K block (#184). The projection reads the metres, so the header
    /// reads them too. `IntakeAnswers.Distance` already holds this vocabulary keyed by the
    /// metres the coach writes, so this matches against those rather than spelling out a
    /// fourth list of race distances. A distance that is none of them — a custom 30K — is
    /// spelled out in the athlete's own unit.
    static func distanceLabel(raceMeters: Double, units: Units) -> String {
        // Within 1%: a half arrives as 21,097 or 21,098 and a mile as 1,609 or 1,609.34,
        // depending which of the app's constants wrote it. The same tolerance the confirm
        // card uses (`PlanRequest.distanceLabel`).
        let known = IntakeAnswers.Distance.allCases.first { d in
            d.meters.map { abs(raceMeters - Double($0)) / Double($0) < 0.01 } ?? false
        }
        return known?.label ?? units.formatDistance(meters: raceMeters, decimals: 1)
    }

    /// "Turkey Trot · 5K" — the race, named once, for every header that names it.
    ///
    /// Nil only when there is no goal. A goal always has a distance to name
    /// (`RaceRecap.raceMeters` falls back to the marathon), so a goal with no `race_name`
    /// reads "Marathon race" rather than a bare "Race": #215 sat unnoticed for two weeks
    /// because no header said what distance the plan was built for, and "Race" says no more
    /// than nothing at all.
    ///
    /// The distance is left off a name that already carries it, so "Chicago Marathon" does
    /// not become "Chicago Marathon · Marathon".
    ///
    /// `includingRole` appends the race's role (#238) — "Turkey Trot · 5K · tune-up". You is
    /// the only header that prints it; Plan and Progress ask without it.
    static func raceLabel(goal: GoalInfo?, units: Units, includingRole: Bool = false) -> String? {
        guard let goal else { return nil }
        let distance = distanceLabel(raceMeters: RaceRecap.raceMeters(goal: goal), units: units)
        let name = goal.raceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let named: String
        if let name, !name.isEmpty {
            named = name.localizedCaseInsensitiveContains(distance) ? name : "\(name) · \(distance)"
        } else {
            named = "\(distance) race"
        }
        guard includingRole, let role = goal.raceRole.label else { return named }
        return "\(named) · \(role)"
    }

    // MARK: - The state

    /// `raceName` and `raceDay` come straight off `RunStore.goal`; both are optional there,
    /// and a goal with neither is indistinguishable from no goal — both say "no goal yet".
    ///
    /// The three countdown headers call `state(goal:now:units:)` instead, which names the race
    /// first. This stays the primitive the tests pin, and the "Race" fallback with it: a
    /// caller that has only a name and a date still gets a usable header.
    static func state(
        raceName: String?,
        raceDay: Date?,
        now: Date,
        calendar: Calendar = RaceCountdown.calendar
    ) -> State {
        let named = raceName.flatMap { $0.isEmpty ? nil : $0 }
        let race = named ?? unnamedRace
        guard let raceDay else {
            return named == nil ? .noGoal : .undated(race: race)
        }
        let raceStart = calendar.startOfDay(for: raceDay)
        let today = calendar.startOfDay(for: now)
        if raceStart == today { return .raceDay(race: race) }
        if raceStart < today { return .past(race: race) }
        return .ahead(
            race: race,
            days: daysRemaining(from: now, to: raceDay, calendar: calendar),
            weeks: weeksRemaining(from: now, to: raceDay, calendar: calendar)
        )
    }

    /// `goal`'s header state, with the race named as `raceLabel` names it. What Plan,
    /// Progress and You each call, so all three count the same days and name the same race.
    static func state(
        goal: GoalInfo?,
        now: Date,
        units: Units,
        includingRole: Bool = false,
        calendar: Calendar = RaceCountdown.calendar
    ) -> State {
        state(
            raceName: raceLabel(goal: goal, units: units, includingRole: includingRole),
            raceDay: goal?.raceDay,
            now: now,
            calendar: calendar
        )
    }
}
