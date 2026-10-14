import Foundation

/// What the setup interview is told before it asks anything (#167): where the athlete said
/// they are, and which facts they have actually given.
///
/// Pure because both halves failed silently. On 2026-10-14 a fresh install chose "Just
/// running for now"; the coach opened by presenting 6 days a week and a Sunday long run as
/// "locked in" — the profile's column defaults, which nobody had said — then asked about
/// strength, ended on a statement, and never called `complete_onboarding`. No crash; the
/// athlete was simply shut out of the app behind a chat that had nothing left to say.
enum OnboardingFacts {

    /// Step 1's "Where are you right now?", in the coach's vocabulary. `onboarding.starting_point`
    /// on the wire; the prompt keys the just-running interview off it.
    ///
    /// Its own words rather than `IntakeAnswers.Situation`'s raw values: those are database
    /// keys for a goal (`mid_block`, `new_block`), and "just running" has no goal to key.
    enum StartingPoint: String, Equatable {
        case racingNow = "racing_now"
        case wantToTrain = "want_to_train"
        case justRunning = "just_running"

        init(_ situation: IntakeAnswers.Situation) {
            switch situation {
            case .midBlock:    self = .racingNow
            case .newBlock:    self = .wantToTrain
            case .justRunning: self = .justRunning
            }
        }
    }

    /// The profile settings whose columns are `not null default …` (0002, 0004): a fresh
    /// profile reads 6 days, Sunday, "standard" whether or not anyone chose them, so their
    /// value alone can't say whether the athlete gave it.
    enum Setting: Hashable, CaseIterable {
        case daysPerWeek, longRunDay, riskTolerance
    }

    /// `onboarding.known` — facts the athlete has given, so the interview confirms rather than
    /// re-asks. A defaulted setting is left out, not marked: the prompt treats everything in
    /// `known` as the athlete's word, so a default in it is a claim made on their behalf.
    ///
    /// - Parameters:
    ///   - given: settings the athlete answered — recorded in this interview, or confirmed on
    ///     a card — as opposed to read back from a column default.
    ///   - planOnFile: an active goal exists, so the settings were what its plan was built
    ///     from, and count as given.
    ///   - maxHR, birthdate: nullable columns, so present means somebody said so.
    ///   - activePlan: the goal line to keep unless it changes, already worded.
    static func known(
        daysPerWeek: Int,
        longRunDay: Int,
        riskTolerance: String,
        given: Set<Setting>,
        planOnFile: Bool,
        maxHR: Int?,
        birthdate: String?,
        activePlan: String?
    ) -> [String: String] {
        let given = planOnFile ? Set(Setting.allCases) : given
        var known: [String: String] = [:]
        if given.contains(.daysPerWeek) { known["days_per_week"] = "\(daysPerWeek)" }
        if given.contains(.longRunDay) { known["long_run_day"] = IntakeAnswers.weekday(longRunDay) }
        if given.contains(.riskTolerance) { known["risk_tolerance"] = riskTolerance }
        if let maxHR { known["max_hr_measured"] = "\(maxHR)" }
        if let birthdate { known["birthdate"] = birthdate }
        if let activePlan { known["active_plan"] = activePlan }
        return known
    }
}
