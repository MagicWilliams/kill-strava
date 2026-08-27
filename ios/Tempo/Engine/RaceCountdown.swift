import Foundation

/// What the Progress header says about the race — a pure function of the goal and the
/// moment you ask.
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
enum RaceCountdown {

    /// Race dates arrive as `yyyy-MM-dd` parsed at local midnight (`PlanDates.day`), so the
    /// count is over calendar days in the athlete's own time zone — it ticks at midnight,
    /// not at whatever time of day the app happened to launch.
    static let calendar = Calendar(identifier: .iso8601)

    /// Used when a goal exists but carries no race name. Matches PlanView and YouView.
    static let unnamedRace = "Race"

    /// The five things the header can be. Split out from the copy so the decision — is the
    /// race ahead, today, or behind us? — is testable without pinning prose.
    enum State: Equatable {
        /// No goal at all. Progress renders before any plan exists.
        case noGoal
        /// A goal, but no usable race date on it. Nothing to count.
        case undated(race: String)
        case ahead(race: String, weeks: Int)
        case raceDay(race: String)
        /// Race day has passed. Deliberately does *not* carry a week count: see `subtitle`.
        case past(race: String)

        var subtitle: String {
            switch self {
            case .noGoal:
                return "No goal yet — the coach proposes one from your runs"
            case .undated(let race):
                return "\(race) — no race date yet"
            case .ahead(let race, let weeks):
                return "\(weeks) week\(weeks == 1 ? "" : "s") to \(race)"
            case .raceDay(let race):
                return "Race day — \(race)"
            case .past(let race):
                // A countdown past its race is the same defect as the hardcoded date: a
                // number that reads as current and isn't. "0 weeks to Chicago" says the
                // race is this week. So Progress stops counting and points at the only
                // thing left to do — pick the next race.
                return "\(race) is behind you — set the next goal with the coach"
            }
        }
    }

    /// Whole weeks between `now` and race day, rounded up: the last six days before the
    /// race are still "1 week to Chicago", never "0 weeks". Measured start-of-day to
    /// start-of-day so the answer doesn't change halfway through an afternoon.
    ///
    /// Negative once the race is behind us, which is how `state` spots that case.
    static func weeksRemaining(from now: Date, to raceDay: Date, calendar: Calendar = RaceCountdown.calendar) -> Int {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: raceDay)
        ).day ?? 0
        return Int((Double(days) / 7.0).rounded(.up))
    }

    /// `raceName` and `raceDay` come straight off `RunStore.goal`; both are optional there,
    /// and a goal with neither is indistinguishable from no goal — both say "no goal yet".
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
        return .ahead(race: race, weeks: weeksRemaining(from: now, to: raceDay, calendar: calendar))
    }
}
