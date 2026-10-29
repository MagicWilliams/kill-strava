import Foundation

/// Where the runner *should* be on a given day of the block: Tempo's expected curve, the
/// thing the Drift Detector measures against (PRD-02 §6.1, item #3).
///
/// Drift has to be measured against this, not against the goal. Measured against the goal,
/// every runner is "off track" in week 2 of a 16-week block, because nobody starts a block
/// already at goal fitness. That is the whole reason this exists: the only "this week"
/// signal Tempo had before was planned mileage, which says what to run, not how fit the
/// running should have made you.
///
/// The shape is deliberately the simplest one that is honest:
/// - a straight line **in finish time** (seconds at the goal distance) from signup fitness,
/// - reaching the goal on the first day of the taper,
/// - flat through the taper to race day.
///
/// Flat through the taper because the taper is where fitness is *banked*, not built: the
/// load comes down and the expectation must not keep moving, or a runner tapering exactly
/// as planned would read as drifting every day of it. Straight in time because there is no
/// evidence here for anything curvier, and a curve with an invented shape would turn its
/// invention into "drift" on screen.
///
/// Everything is in calendar days in the given calendar's time zone, so the expected value
/// is one number per day and a DST change cannot make race day read as 23 or 25 hours.
struct TrajectoryCurve: Equatable {

    /// Why there is no curve. Each is a different empty state for the screen to explain.
    enum Ineligibility: Equatable {
        /// The race is less than `minimumBlockDays` after signup.
        case tooClose
        /// No fitness at signup. Without a start point there is no line, and a borrowed one
        /// (the goal, a default) would show drift against a number the runner never had.
        case noBaseline
    }

    enum Eligibility: Equatable {
        case eligible
        case ineligible(Ineligibility)
    }

    // MARK: - Constants

    /// The Drift Detector's v1 user is at least **8 weeks** out from race day (PRD-02 §5).
    /// Inside that, the block is mostly taper and sharpening, the line from signup to taper
    /// start is a handful of weeks long, and a few days of noise would read as large drift.
    /// Counted in calendar days, so 7 weeks 6 days is too close.
    ///
    /// This is NOT `IntakeAnswers.minPlanWeeks` (2, in TrainingIntake.swift). That gate
    /// answers "can the plan generator build weeks for this race?"; this one answers "is there
    /// enough block for a trajectory to mean anything?". A 4-week plan is legitimate; a 4-week
    /// drift curve is not.
    static let minimumBlockDays = 8 * 7

    /// One distance row's taper, mirrored from `DISTANCES` in
    /// `supabase/functions/plan/generator.ts` (#104). If that table changes, change this one:
    /// the curve has to go flat on the day the plan the runner is following starts tapering.
    struct TaperRow: Equatable {
        let meters: Double
        /// `DistanceProfile.taperWeeks`: taper weeks on a block of `fullTaperBlockWeeks` or more,
        /// race week NOT counted.
        let taperWeeks: Int
        /// `DistanceProfile.shortBlockTaperWeeks`: taper weeks on a shorter block.
        let shortBlockTaperWeeks: Int
    }

    /// Mirror of generator.ts `DISTANCES` (taper columns only), in the same order.
    static let taperTable: [TaperRow] = [
        TaperRow(meters: 1_609, taperWeeks: 0, shortBlockTaperWeeks: 0),    // 1mi
        TaperRow(meters: 5_000, taperWeeks: 0, shortBlockTaperWeeks: 0),    // 5k
        TaperRow(meters: 10_000, taperWeeks: 1, shortBlockTaperWeeks: 1),   // 10k
        TaperRow(meters: 15_000, taperWeeks: 1, shortBlockTaperWeeks: 1),   // 15k
        TaperRow(meters: 16_093, taperWeeks: 1, shortBlockTaperWeeks: 1),   // 10mi
        TaperRow(meters: 21_097, taperWeeks: 1, shortBlockTaperWeeks: 1),   // half
        TaperRow(meters: 42_195, taperWeeks: 2, shortBlockTaperWeeks: 1),   // marathon
    ]

    /// generator.ts `taperWeeksFor`: a block of 10+ training weeks gets the full taper, a
    /// shorter one the short taper. Only the marathon differs (2 → 1).
    static let fullTaperBlockWeeks = 10

    /// The ISO calendar (Monday-first) by default, matching `RaceCountdown`: the generator's
    /// weeks are Monday-based, and race dates are calendar days in the athlete's time zone.
    static let defaultCalendar = Calendar(identifier: .iso8601)

    // MARK: - Inputs

    /// Fitness at signup, as a race-equivalent finish time in seconds at the goal distance.
    let signupFitness: Double?
    let goalTime: Double
    let signupDate: Date
    let raceDate: Date
    let raceMeters: Double
    let calendar: Calendar

    init(
        signupFitness: Double?,
        goalTime: Double,
        signupDate: Date,
        raceDate: Date,
        raceMeters: Double,
        calendar: Calendar = TrajectoryCurve.defaultCalendar
    ) {
        self.signupFitness = signupFitness
        self.goalTime = goalTime
        self.signupDate = signupDate
        self.raceDate = raceDate
        self.raceMeters = raceMeters
        self.calendar = calendar
    }

    // MARK: - Derived

    /// Calendar days from signup to race day.
    var blockDays: Int { days(from: signupDate, to: raceDate) }

    /// Too close is checked first: it is a fact about the race the runner picked and stays
    /// true however much data arrives, so it is the more useful thing to tell them.
    var eligibility: Eligibility {
        if blockDays < Self.minimumBlockDays { return .ineligible(.tooClose) }
        guard let fitness = signupFitness, fitness.isFinite, fitness > 0 else {
            return .ineligible(.noBaseline)
        }
        return .eligible
    }

    /// The taper row for `raceMeters`: nearest by ratio, as generator.ts `namedDistance`
    /// picks the profile for a custom distance. Non-positive metres fall to the shortest row.
    var taperRow: TaperRow {
        let m = max(raceMeters, 1)
        return Self.taperTable.min { abs(log(m / $0.meters)) < abs(log(m / $1.meters)) }!
    }

    /// Length of the reduced-load window in days, race day included. The generator appends
    /// a race week that holds nothing but the race, so it is itself a week of taper: the
    /// window is (taper weeks + 1) × 7 — 7, 14 or 21 days (see `DistanceProfile.taperWeeks`).
    ///
    /// Block weeks are the generator's own `race.weekIndex` (Monday-based weeks from the
    /// signup week to race week), so the 10-week boundary falls where the plan's does.
    var taperDays: Int {
        let blockWeeks = IntakeAnswers.weeksUntil(raceDate, from: signupDate, calendar: calendar)
        let row = taperRow
        let weeks = blockWeeks >= Self.fullTaperBlockWeeks ? row.taperWeeks : row.shortBlockTaperWeeks
        return (weeks + 1) * 7
    }

    /// The first day of the taper: race day minus `taperDays − 1`, so the window counts race
    /// day as its last day. For a Sunday race that is the Monday the plan's taper starts.
    var taperStart: Date {
        calendar.date(byAdding: .day, value: -(taperDays - 1), to: calendar.startOfDay(for: raceDate))!
    }

    // MARK: - The curve

    /// Expected race-equivalent finish time (seconds at the goal distance) on `date`, or nil
    /// when the curve is ineligible.
    ///
    /// Before signup: signup fitness (clamped, there is no expectation before the block).
    /// After race day: the goal (clamped; the block is over and nothing moves the line).
    func expectedTime(on date: Date) -> Double? {
        guard eligibility == .eligible, let fitness = signupFitness else { return nil }
        let day = days(from: signupDate, to: date)
        let rampDays = days(from: signupDate, to: taperStart)
        if day <= 0 { return fitness }
        if day >= rampDays { return goalTime }
        return fitness + (goalTime - fitness) * Double(day) / Double(rampDays)
    }

    /// Whole calendar days between the two dates' start-of-day, so time of day and DST
    /// never shift the answer.
    private func days(from a: Date, to b: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0
    }
}
