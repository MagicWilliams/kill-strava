import Foundation

/// "Start training" (#102): what the intake form collects, whether it is complete, and what
/// it turns into on the way out — the goal + preferences payload `plan` receives, the profile
/// facts written beside it, and the turn the coach reflects back.
///
/// Pure on purpose. The form is ninety seconds of taps that end in a block the athlete trains
/// on for months, and every field that fails to arrive does so silently: a 5K saved as a
/// marathon (the `plan` function has only ever written `"marathon"`), a mid-block week
/// dropped so the plan restarts at week 1, a focus list the coach never sees. None of that
/// crashes; all of it is a wrong number on screen weeks later. So the view only binds to
/// this, and every mapping is pinned in `TrainingIntakeTests`.
struct IntakeAnswers: Equatable {

    // MARK: - Vocabulary
    //
    // Raw values are the wire/database keys (`0014_training_intake.sql` constrains the goal
    // columns to exactly these). Labels are what the form shows.

    enum Situation: String, CaseIterable {
        case midBlock = "mid_block", newBlock = "new_block", justRunning = "just_running"
    }

    /// Every race from the mile to the marathon, plus custom metres for the oddballs.
    /// Named `Distance`, not `RaceDistance`: that one is `TrainingPaces`' four-race enum.
    enum Distance: String, CaseIterable {
        case mile = "1mi", fiveK = "5k", tenK = "10k", fifteenK = "15k", tenMile = "10mi"
        case half, marathon, custom

        /// The source of truth for math (`goals.distance_m`); the raw value is only the label.
        /// Nil for `custom`, whose metres the athlete types.
        var meters: Int? {
            switch self {
            case .mile:     return 1_609
            case .fiveK:    return 5_000
            case .tenK:     return 10_000
            case .fifteenK: return 15_000
            case .tenMile:  return 16_093
            case .half:     return 21_098
            case .marathon: return 42_195
            case .custom:   return nil
            }
        }

        var label: String {
            switch self {
            case .mile: return "1 mi"
            case .fiveK: return "5K"
            case .tenK: return "10K"
            case .fifteenK: return "15K"
            case .tenMile: return "10 mi"
            case .half: return "Half"
            case .marathon: return "Marathon"
            case .custom: return "Custom"
            }
        }

        /// The long-run threshold the "how many long runs" question counts against — 20 mi
        /// for the marathon, its distance-appropriate equivalent for the half (matches #104's
        /// generator). Nil means the question doesn't apply: nobody builds a 5K around 20s.
        var longRunThresholdMiles: Int? {
            switch self {
            case .marathon: return 20
            case .half:     return 12
            default:        return nil
            }
        }
    }

    enum Course: String, CaseIterable {
        case flat, rolling, hilly, trail
        var label: String {
            switch self {
            case .flat: return "Flat road"
            case .rolling: return "Rolling"
            case .hilly: return "Hilly"
            case .trail: return "Trail"
            }
        }
    }

    enum GoalType: String, CaseIterable {
        case time, finish, pr, unsure
        var label: String {
            switch self {
            case .time: return "A time"
            case .finish: return "Just finish"
            case .pr: return "A PR"
            case .unsure: return "Not sure"
            }
        }
    }

    /// Whether a plan for this goal can't be built without a target time. Only a stated time
    /// goal needs one — and a nil type, which is how every goal before the intake (#102) and
    /// every plain chat proposal arrives. "A PR" and "Not sure" ask the coach to *propose* a
    /// target, but right after a race there is often nothing honest to propose; the plan
    /// engine then paces from current fitness exactly as it does for "Just finish".
    ///
    /// The scar: until 2026-10-14 only "finish" could go without a time. David's first intake
    /// after Chicago said "Not sure", the coach (rightly) proposed no time, and Confirm failed
    /// on the phone without ever reaching `/plan`.
    static func requiresTargetTime(_ goalType: String?) -> Bool {
        goalType == nil || goalType == GoalType.time.rawValue
    }

    enum PlanStyle: String, CaseIterable {
        case full, weekly, none
        var label: String {
            switch self {
            case .full: return "Full day-by-day plan"
            case .weekly: return "Weekly targets only"
            case .none: return "No plan, just coaching"
            }
        }
    }

    enum Quality: String, CaseIterable {
        case intervals, tempo, hills, racePace = "race_pace"
        var label: String {
            switch self {
            case .intervals: return "Intervals"
            case .tempo: return "Tempo"
            case .hills: return "Hills"
            case .racePace: return "Race-pace work"
            }
        }
    }

    /// Distinct keys, not the four groups the form shows them under (David, 2026-10-12): the
    /// coach weights recovery, strength and mental game separately even though one heading
    /// holds all three.
    enum Focus: String, CaseIterable {
        case fueling, pacing, raceDay = "race_day", recovery, strength, mental
        var label: String {
            switch self {
            case .fueling: return "Fueling & nutrition"
            case .pacing: return "Pacing & workouts"
            case .raceDay: return "Race-day strategy"
            case .recovery: return "Recovery & sleep"
            case .strength: return "Strength & injury-proofing"
            case .mental: return "Mental game"
            }
        }
    }

    enum Risk: String, CaseIterable {
        case standard, ambitious
    }

    // MARK: - Answers

    var situation: Situation = .newBlock

    var distance: Distance = .marathon
    var customMeters: Int?
    var raceName = ""
    var raceDate: Date?
    var course: Course = .flat
    var goalType: GoalType = .unsure
    /// Only meaningful for `goalType == .time`; the coach proposes one for every other type.
    var goalTimeSeconds: Int?
    /// Mid-block only: "I'm in week N" (1-based).
    var startedWeek: Int?
    /// Mid-block only: what a week looks like right now, in miles. Optional — real runs are
    /// the anchor; this is the athlete's word for when the sync hasn't caught up.
    var currentWeeklyMiles: Double?

    var planStyle: PlanStyle = .full
    var daysPerWeek = 5
    /// 0 = Sunday … 6 = Saturday — `profiles.long_run_day`'s convention, not the plan grid's.
    var longRunDay = 0
    /// How many long runs at `distance.longRunThresholdMiles` the block should contain.
    var longRunCount = 3
    var quality: Set<Quality> = []
    var wantsStrength = false
    var risk: Risk = .standard

    var focus: Set<Focus> = []
    var notes = ""

    init() {}

    /// Seeded from what's already on the profile, so the form confirms rather than re-asks.
    init(daysPerWeek: Int, longRunDay: Int, risk: String) {
        self.daysPerWeek = min(max(daysPerWeek, 3), 7)
        self.longRunDay = min(max(longRunDay, 0), 6)
        self.risk = Risk(rawValue: risk) ?? .standard
    }

    // MARK: - Derived

    /// Metres for whichever distance is picked; nil when custom has not been filled in.
    var distanceMeters: Int? { distance == .custom ? customMeters : distance.meters }

    /// Whether the "long runs of 20+" question is on screen at all.
    var asksLongRunCount: Bool { distance.longRunThresholdMiles != nil && planStyle != .none }

    /// Whether the workout picker is on screen. "No plan" prescribes no workouts to pick.
    var asksQuality: Bool { planStyle != .none }

    // MARK: - Steps and validation

    enum Step: Int, CaseIterable {
        case situation, race, plan, focus, notes
    }

    enum Issue: Equatable {
        case customDistanceOutOfRange
        case raceDateMissing
        case raceDateNotAhead
        case goalTimeMissing
        case goalTimeImplausible
        case startedWeekMissing
        case startedWeekOutOfRange
        case weeklyMilesOutOfRange
        case daysPerWeekOutOfRange
        case longRunDayOutOfRange
        case longRunCountOutOfRange
        case raceTooSoonForPlan

        var message: String {
            switch self {
            case .customDistanceOutOfRange: return "Enter the race distance in metres (800–50,000)."
            case .raceDateMissing: return "Pick the race date."
            case .raceDateNotAhead: return "The race date needs to be after today."
            case .goalTimeMissing: return "Set your target time, or pick another goal type."
            case .goalTimeImplausible: return "That target time doesn't fit the distance — check it."
            case .startedWeekMissing: return "Which week of the block are you in?"
            case .startedWeekOutOfRange: return "Block week should be between 1 and 30."
            case .weeklyMilesOutOfRange: return "Weekly miles should be between 0 and 200."
            case .daysPerWeekOutOfRange: return "Days per week should be 3 to 7."
            case .longRunDayOutOfRange: return "Pick a long-run day."
            case .longRunCountOutOfRange: return "Long runs should be between 0 and 8."
            case .raceTooSoonForPlan:
                return "Under two weeks out is too close to build a plan — choose No plan, just coaching."
            }
        }

        /// `message` in the athlete's unit (#109). Only the weekly-volume bound names a
        /// length; it is checked in miles (the answer is stored in miles) and said in km.
        func message(_ units: Units) -> String {
            guard self == .weeklyMilesOutOfRange, units != .mi else { return message }
            let top = Int(units.distance(miles: IntakeAnswers.weeklyMilesRange.upperBound).rounded(.down))
            return "Weekly \(units.abbreviation) should be between 0 and \(top)."
        }
    }

    static let customMetersRange = 800...50_000
    static let startedWeekRange = 1...30
    static let weeklyMilesRange = 0.0...200.0
    static let longRunCountRange = 0...8
    /// Seconds per mile a goal time may imply. 3:00/mi is faster than the mile world record;
    /// 30:00/mi is a walk. Anything outside is a typo, not a goal.
    static let plausiblePace = 180.0...1_800.0
    /// The `plan` function refuses a race whose week index from this Monday is under 2
    /// (`racePlacement(...).weekIndex < 2`). Mirrored here so the form says so up front
    /// instead of the confirm card failing after the coach has already proposed the plan.
    static let minPlanWeeks = 2

    func issues(on step: Step, today: Date, calendar: Calendar) -> [Issue] {
        var out: [Issue] = []
        switch step {
        case .situation, .focus, .notes:
            break
        case .race:
            if distance == .custom,
               customMeters.map({ !Self.customMetersRange.contains($0) }) ?? true {
                out.append(.customDistanceOutOfRange)
            }
            if let raceDate {
                if calendar.startOfDay(for: raceDate) <= calendar.startOfDay(for: today) {
                    out.append(.raceDateNotAhead)
                }
            } else {
                out.append(.raceDateMissing)
            }
            if goalType == .time {
                if let seconds = goalTimeSeconds, seconds > 0 {
                    if let meters = distanceMeters, meters > 0 {
                        let pace = Double(seconds) / (Double(meters) / 1609.34)
                        if !Self.plausiblePace.contains(pace) { out.append(.goalTimeImplausible) }
                    }
                } else {
                    out.append(.goalTimeMissing)
                }
            }
            if situation == .midBlock {
                if let week = startedWeek {
                    if !Self.startedWeekRange.contains(week) { out.append(.startedWeekOutOfRange) }
                } else {
                    out.append(.startedWeekMissing)
                }
                if let miles = currentWeeklyMiles, !Self.weeklyMilesRange.contains(miles) {
                    out.append(.weeklyMilesOutOfRange)
                }
            }
        case .plan:
            if !(3...7).contains(daysPerWeek) { out.append(.daysPerWeekOutOfRange) }
            if !(0...6).contains(longRunDay) { out.append(.longRunDayOutOfRange) }
            if asksLongRunCount, !Self.longRunCountRange.contains(longRunCount) {
                out.append(.longRunCountOutOfRange)
            }
            if planStyle != .none, let raceDate,
               Self.weeksUntil(raceDate, from: today, calendar: calendar) < Self.minPlanWeeks {
                out.append(.raceTooSoonForPlan)
            }
        }
        return out
    }

    /// Every issue on every step, in step order.
    func issues(today: Date, calendar: Calendar) -> [Issue] {
        Step.allCases.flatMap { issues(on: $0, today: today, calendar: calendar) }
    }

    /// Whole Monday-based weeks from this week to race week — `racePlacement`'s `weekIndex`.
    static func weeksUntil(_ raceDate: Date, from today: Date, calendar: Calendar) -> Int {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let raceWeek = calendar.dateInterval(of: .weekOfYear, for: raceDate)?.start else { return 0 }
        return calendar.dateComponents([.weekOfYear], from: thisWeek, to: raceWeek).weekOfYear ?? 0
    }

    // MARK: - Output

    /// What the confirm card carries, or nil when there is nothing to save: "just running"
    /// opts out of the intake, and an incomplete form must never reach the plan engine.
    func stamp(today: Date, calendar: Calendar) -> IntakeStamp? {
        guard situation != .justRunning,
              issues(today: today, calendar: calendar).isEmpty,
              let meters = distanceMeters,
              let raceDate else { return nil }
        let midBlock = situation == .midBlock
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return IntakeStamp(
            distance: distance.rawValue,
            distance_m: meters,
            course_type: course.rawValue,
            goal_type: goalType.rawValue,
            started_week: midBlock ? startedWeek : nil,
            start_mileage: midBlock ? currentWeeklyMiles : nil,
            race_name: raceName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            race_date: Self.isoDay(raceDate, calendar: calendar),
            stated_goal_time_s: goalType == .time ? goalTimeSeconds : nil,
            preferences: GoalPreferences(
                plan_style: planStyle.rawValue,
                long_runs_20plus: asksLongRunCount ? longRunCount : nil,
                course_type: course.rawValue,
                // allCases order, not Set order: the payload is stable, so it diffs and tests.
                focus: Focus.allCases.filter(focus.contains).map(\.rawValue),
                quality: asksQuality ? Quality.allCases.filter(quality.contains).map(\.rawValue) : [],
                notes: trimmedNotes.nilIfEmpty
            ),
            days_per_week: daysPerWeek,
            long_run_day: longRunDay,
            wants_strength: wantsStrength,
            risk_tolerance: risk.rawValue
        )
    }

    /// yyyy-MM-dd in the given calendar — what `goals.race_date` holds.
    static func isoDay(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Wire shapes

/// `goals.preferences` — versioned so a later shape can be read beside this one.
///
/// Every field is optional and stringly typed on purpose: this decodes out of a jsonb column
/// that other writers (the `plan` function, a future v2) also touch. An enum here would turn
/// one unrecognised value into a goal that fails to decode — and a goal that fails to decode
/// reads, everywhere in the app, as no goal at all.
struct GoalPreferences: Codable, Hashable {
    static let currentVersion = 1

    var v: Int? = GoalPreferences.currentVersion
    var plan_style: String?
    var long_runs_20plus: Int?
    var course_type: String?
    var focus: [String]?
    var quality: [String]?
    var notes: String?
}

/// What an intake-born create_plan card carries, persisted inside `coach_messages
/// .proposed_action` so the card means the same thing after a relaunch as before it.
///
/// The coach only ever proposes goal time, race name and race date; everything the athlete
/// tapped rides here, stamped on the card by the app rather than echoed by the model —
/// a model asked to copy a jsonb blob verbatim will, eventually, not.
struct IntakeStamp: Codable, Equatable {
    // → the `plan` request (and through it, the goal row)
    let distance: String
    let distance_m: Int
    let course_type: String
    let goal_type: String
    let started_week: Int?
    let start_mileage: Double?
    // What the athlete typed — the coach's proposal can differ, and its card wins.
    let race_name: String?
    let race_date: String
    let stated_goal_time_s: Int?
    let preferences: GoalPreferences
    // → `profiles`, written on confirm, before `plan` reads them
    let days_per_week: Int
    let long_run_day: Int
    let wants_strength: Bool
    let risk_tolerance: String

    /// The profile half. Written at confirm time, never at form submit: a dismissed card
    /// must leave the athlete's settings — and so the plan they are on — untouched.
    struct ProfilePatch: Encodable, Equatable {
        let days_per_week: Int
        let long_run_day: Int
        let wants_strength: Bool
        let risk_tolerance: String
    }

    /// Whether a create_plan card's goal time is enough to build on. Every goal type needs
    /// one except "just finish", which `plan` builds from current fitness instead.
    func accepts(goalTimeS: Int?) -> Bool {
        goalTimeS != nil || !IntakeAnswers.requiresTargetTime(goal_type)
    }

    var profilePatch: ProfilePatch {
        ProfilePatch(
            days_per_week: days_per_week,
            long_run_day: long_run_day,
            wants_strength: wants_strength,
            risk_tolerance: risk_tolerance
        )
    }
}

/// The body the `plan` function receives.
///
/// Everything after `race_date` is #102's addition, consumed by #104's generator. Nil keys
/// are omitted from the JSON rather than sent as null, so a plan function that predates
/// #104 sees exactly the body it always did.
struct PlanRequest: Encodable, Equatable {
    /// Null only for a "just finish" goal: there is no target, and `plan` (#104) derives the
    /// paces from current fitness instead of from a time nobody chose.
    var goal_time_s: Int?
    var race_name: String?
    var race_date: String
    var distance: String?
    var distance_m: Int?
    var course_type: String?
    var goal_type: String?
    var started_week: Int?
    var start_mileage: Double?
    var preferences: GoalPreferences?

    init(goal_time_s: Int?, race_name: String?, race_date: String) {
        self.goal_time_s = goal_time_s
        self.race_name = race_name
        self.race_date = race_date
    }

    private enum CodingKeys: String, CodingKey {
        case goal_time_s, race_name, race_date, distance, distance_m, course_type, goal_type
        case started_week, start_mileage, preferences
    }

    /// `goal_time_s` always goes out, as an explicit null when there is no target: absent
    /// would read as a malformed request rather than as "just finish". Everything else is
    /// omitted when nil.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(goal_time_s, forKey: .goal_time_s)
        try c.encodeIfPresent(race_name, forKey: .race_name)
        try c.encode(race_date, forKey: .race_date)
        try c.encodeIfPresent(distance, forKey: .distance)
        try c.encodeIfPresent(distance_m, forKey: .distance_m)
        try c.encodeIfPresent(course_type, forKey: .course_type)
        try c.encodeIfPresent(goal_type, forKey: .goal_type)
        try c.encodeIfPresent(started_week, forKey: .started_week)
        try c.encodeIfPresent(start_mileage, forKey: .start_mileage)
        try c.encodeIfPresent(preferences, forKey: .preferences)
    }

    /// A create_plan confirmed off the intake: the coach's goal, the athlete's everything else.
    /// "Just finish" sends no time even if the card carried one — the athlete didn't pick a
    /// target, and the plan shouldn't be built around one.
    static func fromIntake(_ stamp: IntakeStamp, goalTimeS: Int?, raceName: String?, raceDate: String) -> PlanRequest {
        let time = stamp.goal_type == IntakeAnswers.GoalType.finish.rawValue ? nil : goalTimeS
        var r = PlanRequest(goal_time_s: time, race_name: raceName ?? stamp.race_name, race_date: raceDate)
        r.distance = stamp.distance
        r.distance_m = stamp.distance_m
        r.course_type = stamp.course_type
        r.goal_type = stamp.goal_type
        r.started_week = stamp.started_week
        r.start_mileage = stamp.start_mileage
        r.preferences = stamp.preferences
        return r
    }

    /// A regeneration that did not come off the intake — a settings change, or a new goal
    /// time agreed in chat.
    ///
    /// `plan` writes a fresh goal row every time it runs (create-then-retire), so whatever the
    /// request leaves out is gone from the goal. Before #102 that was harmless, because
    /// nothing but the time and date existed; now a "drop me to 5 days" would quietly turn a
    /// 5K block into a marathon one and throw its preferences away.
    ///
    /// Same race date → same block, so carry it all, with the mid-block week advanced by the
    /// weeks since the current plan started (the athlete who said "week 9" three weeks ago is
    /// in week 12 now). A different race date is a different race, and its distance and
    /// course are unknown here; it goes out bare. A create_plan card supplies the distance
    /// itself (`fromChatProposal`), and `plan` refuses a new race that has none (#184).
    static func carryingForward(
        goal: GoalInfo?,
        planStartDate: String?,
        goalTimeS: Int?,
        raceName: String?,
        raceDate: String,
        today: Date,
        calendar: Calendar
    ) -> PlanRequest {
        var r = PlanRequest(goal_time_s: goalTimeS, race_name: raceName, race_date: raceDate)
        guard let goal, goal.race_date == raceDate else { return r }
        r.distance = goal.distance
        r.distance_m = goal.distance_m
        r.course_type = goal.course_type
        r.goal_type = goal.goal_type
        r.preferences = goal.preferences
        if let week = goal.started_week {
            r.started_week = week + weeksElapsed(sincePlanStart: planStartDate, today: today, calendar: calendar)
        }
        return r
    }

    /// A create_plan card proposed in chat rather than off the intake, or nil when there is
    /// nothing to build on.
    ///
    /// `carried` is the request `carryingForward` produced. A `goal_type` on the card wins
    /// over the carried one; "finish" drops any time, because a finish goal with a time is a
    /// time goal wearing the wrong label. Nil when there's still no time and the goal isn't
    /// "just finish" — `plan` would only refuse it.
    ///
    /// The card's `distance` / `distance_m` (#184) replace the carried pair together, never
    /// one of them: a "5k" beside a carried-over 42,195 m would resolve to a marathon, since
    /// `plan` reads the metres first. A known label with no metres gets the label's metres,
    /// the same ones the intake would have stamped; "custom" without metres goes out as is,
    /// and `plan` refuses it.
    static func fromChatProposal(
        _ carried: PlanRequest,
        goalType: String?,
        distance: String? = nil,
        distanceM: Int? = nil
    ) -> PlanRequest? {
        var r = carried
        if let goalType { r.goal_type = goalType }
        if distance != nil || distanceM != nil {
            r.distance = distance
            r.distance_m = distanceM ?? distance.flatMap { IntakeAnswers.Distance(rawValue: $0)?.meters }
        }
        if r.goal_type == IntakeAnswers.GoalType.finish.rawValue {
            r.goal_time_s = nil
            return r
        }
        return r.goal_time_s == nil && IntakeAnswers.requiresTargetTime(r.goal_type) ? nil : r
    }

    /// The request a create_plan card sends, or nil when the card can't be built on. One
    /// function for both Confirm and the card's distance line, so what the card shows is what
    /// Confirm sends.
    ///
    /// The intake stamp outranks the card's payload: it is what the athlete tapped, and the
    /// payload is the model's echo of it. Without a stamp, the payload's distance outranks
    /// whatever carries over from a same-date goal; with neither, the request names no
    /// distance and `plan` answers `distance_required` rather than build a marathon (#184).
    static func forCreatePlanCard(
        _ action: ProposedAction,
        goal: GoalInfo?,
        planStartDate: String?,
        today: Date,
        calendar: Calendar
    ) -> PlanRequest? {
        guard let raceDate = action.race_date else { return nil }
        if let stamp = action.intake {
            guard stamp.accepts(goalTimeS: action.goal_time_s) else { return nil }
            return .fromIntake(stamp, goalTimeS: action.goal_time_s, raceName: action.race_name, raceDate: raceDate)
        }
        let carried = carryingForward(
            goal: goal, planStartDate: planStartDate, goalTimeS: action.goal_time_s,
            raceName: action.race_name, raceDate: raceDate, today: today, calendar: calendar
        )
        return fromChatProposal(carried, goalType: action.goal_type, distance: action.distance, distanceM: action.distance_m)
    }

    /// Whether the active goal can be rebuilt after a settings change: it needs a race date,
    /// and a target time unless it is a "just finish" goal, which has none by design. Before
    /// this, a time-less goal was simply never regenerated — right when no goal could lack
    /// one, wrong once "just finish" exists.
    static func canRegenerate(_ goal: GoalInfo) -> Bool {
        !goal.raceDate.isEmpty
            && (goal.goalTimeSeconds != nil || !IntakeAnswers.requiresTargetTime(goal.goal_type))
    }

    /// Whole weeks from the plan's first Monday to this week's. Zero when unknown or ahead.
    static func weeksElapsed(sincePlanStart start: String?, today: Date, calendar: Calendar) -> Int {
        guard let start, let startDay = parseDay(start, calendar: calendar),
              let startWeek = calendar.dateInterval(of: .weekOfYear, for: startDay)?.start,
              let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return 0 }
        return max(0, calendar.dateComponents([.weekOfYear], from: startWeek, to: thisWeek).weekOfYear ?? 0)
    }

    private static func parseDay(_ iso: String, calendar: Calendar) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

// MARK: - What a create_plan card is about to build (#184)

extension PlanRequest {

    /// `plan`'s answer to a new race with no distance. The app shows it as a card that is
    /// missing something, because that is exactly what it is.
    static let distanceRequired = "distance_required"

    /// The race distance this request names, as the card shows it; nil when it names none.
    /// Metres first, as `plan` reads them, and only metres `plan` would accept.
    var distanceLabel: String? {
        if let m = distance_m, (400...100_000).contains(m) {
            let known = IntakeAnswers.Distance.allCases.first { d in
                d.meters.map { abs(Double(m - $0)) / Double($0) < 0.01 } ?? false
            }
            return known?.label ?? "\(m.formatted(.number.locale(Locale(identifier: "en_US")))) m"
        }
        guard let d = distance.flatMap(IntakeAnswers.Distance.init(rawValue:)), d != .custom else { return nil }
        return d.label
    }

    /// "5K · Turkey Trot 2026 · Nov 5" — the race the card will save, read from the request
    /// rather than from the coach's summary. On 2026-10-15 the summary said 5K and the payload
    /// said nothing, and the only place that disagreement could have been seen was the card.
    func cardLine(calendar: Calendar) -> String {
        let name = race_name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = Self.parseDay(race_date, calendar: calendar).map { date -> String in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = "MMM d"
            return f.string(from: date)
        }
        return [distanceLabel, name?.isEmpty == false ? name : nil, day]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The `error` string of a `plan` error body (`{ "error": "distance_required" }`), or nil.
    static func refusal(inErrorBody data: Data) -> String? {
        struct Body: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error
    }
}

// MARK: - What the coach sees

extension IntakeAnswers {

    /// The athlete's turn in the transcript when the form is sent: the whole intake, readable.
    ///
    /// Visible rather than a hidden kickoff, so the coach's reflect-back answers a message
    /// that is actually in the history — and so a relaunch, or David scrolling back a month
    /// later, shows what was asked for beside what was proposed.
    ///
    /// Written in the athlete's unit, since it is their turn in the chat. The answers
    /// themselves stay in miles (`currentWeeklyMiles`, the 20/12-mile bar).
    func transcriptLine(calendar: Calendar, units: Units = .mi) -> String {
        var lines: [String] = []

        let distanceText = distance == .custom
            ? (customMeters.map { "\($0.formatted()) m" } ?? "Custom distance")
            : distance.label
        var race = "Training for: \(distanceText)"
        let name = raceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { race += " — \(name)" }
        if let raceDate { race += ", \(Self.humanDay(raceDate, calendar: calendar))" }
        race += " · \(course.label.lowercased())"
        lines.append(race)

        var goal = "Goal: "
        if goalType == .time, let t = goalTimeSeconds {
            goal += Self.finishTime(t)
        } else {
            goal += goalType.label.lowercased()
        }
        lines.append(goal)

        if situation == .midBlock, let week = startedWeek {
            var mid = "Already mid-block: week \(week)"
            if let miles = currentWeeklyMiles { mid += ", ~\(Int(units.distance(miles: miles).rounded())) \(units.abbreviation) a week" }
            lines.append(mid)
        }

        var plan = "Plan: \(planStyle.label.lowercased()), \(daysPerWeek) days a week, long run \(Self.weekday(longRunDay))"
        if asksLongRunCount, let threshold = distance.longRunThresholdMiles {
            plan += ", \(longRunCount)× \(units.longRunThresholdLabel(miles: threshold))"
        }
        lines.append(plan)

        if asksQuality {
            let picked = Quality.allCases.filter(quality.contains).map { $0.label.lowercased() }
            lines.append("Workouts: " + (picked.isEmpty ? "your call" : picked.joined(separator: ", ")))
        }
        lines.append("Strength: \(wantsStrength ? "yes" : "no") · Risk: \(risk.rawValue)")

        let focusLabels = Focus.allCases.filter(focus.contains).map { $0.label.lowercased() }
        if !focusLabels.isEmpty { lines.append("Coach me on: " + focusLabels.joined(separator: ", ")) }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty { lines.append("Also: \(trimmedNotes)") }

        return lines.joined(separator: "\n")
    }

    /// 0 = Sunday — the profile's convention, read with a fixed English list so the coach's
    /// input doesn't change with the phone's language.
    static func weekday(_ index: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names.indices.contains(index) ? names[index] : "Sunday"
    }

    /// h:mm:ss for an hour or more, m:ss under it — a 5K goal reads "19:30", not "0:19:30".
    static func finishTime(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func humanDay(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEE MMM d, yyyy"
        return f.string(from: date)
    }
}

/// `<athlete_context>.intake` — present from the moment the form is sent until the card it
/// produces is confirmed. The coach prompt keys its reflect-back turn off this being here.
struct IntakeCoachContext: Encodable, Equatable {
    let situation: String
    let distance: String
    let distance_m: Int
    let race_name: String?
    let race_date: String
    let course_type: String
    let goal_type: String
    let stated_goal_time: String?
    let started_week: Int?
    let stated_weekly_mi: Double?
    let plan_style: String
    let days_per_week: Int
    let long_run_day: String
    let long_runs_at_threshold: Int?
    let long_run_threshold_mi: Int?
    let quality: [String]
    let wants_strength: Bool
    let risk_tolerance: String
    let focus: [String]
    let notes: String?

    init(_ stamp: IntakeStamp, situation: IntakeAnswers.Situation) {
        self.situation = situation.rawValue
        distance = stamp.distance
        distance_m = stamp.distance_m
        race_name = stamp.race_name
        race_date = stamp.race_date
        course_type = stamp.course_type
        goal_type = stamp.goal_type
        stated_goal_time = stamp.stated_goal_time_s.map(IntakeAnswers.finishTime)
        started_week = stamp.started_week
        stated_weekly_mi = stamp.start_mileage
        plan_style = stamp.preferences.plan_style ?? IntakeAnswers.PlanStyle.full.rawValue
        days_per_week = stamp.days_per_week
        long_run_day = IntakeAnswers.weekday(stamp.long_run_day)
        long_runs_at_threshold = stamp.preferences.long_runs_20plus
        long_run_threshold_mi = stamp.preferences.long_runs_20plus == nil
            ? nil
            : IntakeAnswers.Distance(rawValue: stamp.distance)?.longRunThresholdMiles
        quality = stamp.preferences.quality ?? []
        wants_strength = stamp.wants_strength
        risk_tolerance = stamp.risk_tolerance
        focus = stamp.preferences.focus ?? []
        notes = stamp.preferences.notes
    }
}

/// `<athlete_context>.goal_detail` — what the active goal says about the race and the athlete
/// beyond time and date. The coach prompt weights its advice toward `preferences.focus`.
///
/// Absent, not empty, for a goal that predates the intake: an empty focus list would read as
/// "this athlete wants no particular coaching", which nobody said.
struct GoalDetailCoachContext: Encodable, Equatable {
    let distance: String?
    let distance_m: Int?
    let course_type: String?
    let goal_type: String?
    let started_week: Int?
    let preferences: GoalPreferences?

    init?(_ goal: GoalInfo?) {
        guard let goal,
              goal.preferences != nil || goal.course_type != nil || goal.goal_type != nil
                || goal.started_week != nil else { return nil }
        distance = goal.distance
        distance_m = goal.distance_m
        course_type = goal.course_type
        goal_type = goal.goal_type
        started_week = goal.started_week
        preferences = goal.preferences
    }
}

extension TodayMode {
    /// `CoachContext.mode`, given the goal as well as the plan.
    ///
    /// "No plan, just coaching" (#102) saves a race and no plan. Today has no sessions to show,
    /// so it rightly takes the feed — but `coachMode` alone would then tell the coach
    /// "just_running", whose prompt rule is *don't ask about a race*, about an athlete who
    /// is training for one. A goal that chose no plan is training.
    static func coachMode(_ mode: TodayMode, goal: GoalInfo?) -> String {
        if mode == .justRunning, goal?.preferences?.plan_style == IntakeAnswers.PlanStyle.none.rawValue {
            return TodayMode.training.coachMode
        }
        return mode.coachMode
    }
}

/// The intake on its way from the form to the confirm card. Lives on `RunStore` because the
/// form and the coach are different screens, and `ChatStore` is rebuilt with the Coach tab.
struct IntakeHandoff: Equatable {
    let id = UUID()
    let answers: IntakeAnswers
    /// Nil for "just running" — nothing to save, only something for the interview to know.
    let stamp: IntakeStamp?
    /// Set once the coach has been sent the intake, so revisiting the tab doesn't send it twice.
    var sentToCoach = false

    init(answers: IntakeAnswers, stamp: IntakeStamp?) {
        self.answers = answers
        self.stamp = stamp
        // "Just running" has no turn to send.
        self.sentToCoach = stamp == nil
    }

    /// Attach the intake to a create_plan card. Only create_plan: it is the one action whose
    /// write is the intake's write. Every other card passes through untouched, and a card
    /// that already carries a stamp keeps it.
    static func stamping(_ action: ProposedAction, with handoff: IntakeHandoff?) -> ProposedAction {
        guard action.type == "create_plan", action.intake == nil, let stamp = handoff?.stamp else { return action }
        var stamped = action
        stamped.intake = stamp
        return stamped
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
