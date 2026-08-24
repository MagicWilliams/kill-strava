import Foundation

/// App-wide source of truth for real training data.
///
/// Read path: Supabase `runs` — it carries user corrections made via the coach,
/// so it wins over raw HealthKit. HealthKit is ingest-only (insert-only sync on
/// every refresh) and the offline display fallback.
@MainActor
final class RunStore: ObservableObject {
    enum Phase: Equatable {
        case idle, loading
        case ready          // runs loaded
        case empty          // readable but no runs found
        case unavailable    // no Health data source / permission failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var runs: [RunSummary] = []   // newest first
    @Published private(set) var riskTolerance = "standard"
    @Published private(set) var maxHR: Int?               // measured, from profile; nil → formula

    // Plan settings (chat-mutable; set during onboarding)
    @Published private(set) var daysPerWeek = 6
    @Published private(set) var longRunDay = 0            // 0 = Sunday … 6 = Saturday

    // Onboarding gate: nil = profile not loaded yet, true = takeover, false = through
    @Published private(set) var needsOnboarding: Bool?
    @Published private(set) var birthdate: String?        // yyyy-MM-dd

    // Load model output (recomputed each refresh) + today's cached coach read
    @Published private(set) var fitness: FitnessMetrics?
    @Published private(set) var todayTakeaway: String?

    // Active plan state (see PlanData.swift)
    @Published var plan: PlanInfo?
    @Published var goal: GoalInfo?
    @Published var planWeeks: [PlanWeekInfo] = []
    @Published var sessions: [SessionInfo] = []           // window: −7d … +14d
    @Published var todayCheckIn: CheckInInfo?

    private let health = HealthService()

    /// Training weeks run Mon–Sun.
    static let cal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        return c
    }()

    func start() async {
        guard phase == .idle else { return }
        phase = .loading
        await Supa.signInAnonymouslyIfNeeded()
        await Supa.ensureProfile()
        await loadRiskTolerance()
        await loadPlan()
        // During onboarding, the Connect step owns the HealthKit moment — don't
        // fire the permission sheet from under the Welcome screen.
        if needsOnboarding != true {
            await refresh()
        }
    }

    func refresh() async {
        var ingested: [RunSummary] = []
        do {
            try await health.requestAuthorization()
            ingested = try await health.fetchSummaries()
        } catch {
            // No Health access — Supabase may still hold previously synced/manual runs.
            Telemetry.error("sync.healthkit_unavailable", error)
        }
        // DB first: ingest dedupes against what's already recorded (Garmin re-exports
        // the same runs under new HK uuids when its Health settings change).
        var dbRuns = try? await fetchFromSupabase()
        if !ingested.isEmpty {
            let inserted = (try? await health.sync(ingested, existing: dbRuns ?? runs)) ?? 0
            if inserted > 0 {
                dbRuns = (try? await fetchFromSupabase()) ?? dbRuns
            }
        }
        if let dbRuns {
            runs = dbRuns
        } else if !ingested.isEmpty {
            runs = ingested                    // offline fallback: uncorrected view
        } else if runs.isEmpty {
            // Nothing from the DB, nothing from Health, nothing cached: the screen goes
            // blank. Worth knowing every time it happens.
            Telemetry.warn("sync.no_data", "no runs from DB, HealthKit, or cache")
            phase = .unavailable
            return
        }
        phase = runs.isEmpty ? .empty : .ready

        // Repair pass: fill avg HR on recent rows that predate HR enrichment
        // (Garmin doesn't associate HR samples with its workouts).
        let hrUpdates = await health.backfillMissingHR(runs)
        for (id, bpm) in hrUpdates {
            if let idx = runs.firstIndex(where: { $0.id == id }) { runs[idx].avgHR = bpm }
        }

        await matchRunsToSessions()
        await autoAdaptMissedQuality()
        await recomputeProjection()
        fitness = LoadModel.compute(runs: runs, checkInOK: todayCheckIn?.feelsOk)
        await loadTodayTakeaway()
    }

    /// The coach read for today's completed session, previewed on Today.
    /// Cached value shows immediately; if none exists yet, generation kicks off in
    /// the background (fires right after the matcher marks the session done).
    private func loadTodayTakeaway() async {
        guard let session = todaySession, session.status == "done",
              let run = matchedRun(for: session) else {
            todayTakeaway = nil
            return
        }
        struct Row: Decodable { let coach_takeaway: String? }
        let cached: Row? = try? await Supa.client
            .from("runs")
            .select("coach_takeaway")
            .eq("id", value: run.id.uuidString)
            .single()
            .execute()
            .value
        if let takeaway = cached?.coach_takeaway {
            todayTakeaway = takeaway
            return
        }
        // Not generated yet — do it in the background so refresh stays fast; the
        // preview appears on Today the moment it lands.
        Task { [weak self] in
            guard let self else { return }
            if let generated = await TakeawayService.ensureTakeaway(for: run, store: self) {
                self.todayTakeaway = generated
            }
        }
    }

    /// After a confirmed coach edit: re-read Supabase only (no re-ingest needed).
    func reloadFromSupabase() async {
        if let dbRuns = try? await fetchFromSupabase() {
            runs = dbRuns
            phase = runs.isEmpty ? .empty : .ready
        }
    }

    private struct RunRow: Decodable {
        let id: UUID
        let start_time: Date
        let distance_m: Int
        let duration_s: Int
        let avg_hr: Int?
        let corrected: Bool
        let source: String
        let external_id: String?
    }

    private func fetchFromSupabase() async throws -> [RunSummary] {
        let rows: [RunRow] = try await Supa.client
            .from("runs")
            .select("id,start_time,distance_m,duration_s,avg_hr,corrected,source,external_id")
            .order("start_time", ascending: false)
            .execute()
            .value
        return rows.map {
            RunSummary(
                id: $0.id,
                start: $0.start_time,
                distanceM: $0.distance_m,
                durationS: $0.duration_s,
                avgHR: $0.avg_hr,
                corrected: $0.corrected,
                source: $0.source,
                externalID: $0.external_id
            )
        }
    }

    private func loadRiskTolerance() async {
        struct Row: Decodable {
            let risk_tolerance: String
            let max_hr: Int?
            let days_per_week: Int?
            let long_run_day: Int?
            let onboarded_at: Date?
            let birthdate: String?
        }
        if let uid = Supa.userID?.uuidString,
           let row: Row = try? await Supa.client
               .from("profiles")
               .select("risk_tolerance,max_hr,days_per_week,long_run_day,onboarded_at,birthdate")
               .eq("id", value: uid)
               .single()
               .execute()
               .value {
            riskTolerance = row.risk_tolerance
            maxHR = row.max_hr
            daysPerWeek = row.days_per_week ?? 6
            longRunDay = row.long_run_day ?? 0
            birthdate = row.birthdate
            needsOnboarding = row.onboarded_at == nil
        }
    }

    func setBirthdate(_ iso: String?) {
        if let iso { birthdate = iso }
    }

    /// Interview finished (coach called complete_onboarding) — drop the gate and
    /// finish the normal launch sequence.
    func markOnboarded() async {
        guard let uid = Supa.userID?.uuidString else { return }
        struct Patch: Encodable { let onboarded_at: String }
        _ = try? await Supa.client.from("profiles")
            .update(Patch(onboarded_at: ISO8601DateFormatter().string(from: .now)))
            .eq("id", value: uid)
            .execute()
        needsOnboarding = false
        await refresh()
    }

    func setPlanSettings(daysPerWeek: Int?, longRunDay: Int?) {
        if let daysPerWeek { self.daysPerWeek = daysPerWeek }
        if let longRunDay { self.longRunDay = longRunDay }
    }

    func setRiskTolerance(_ level: String) {
        riskTolerance = level
    }

    func setMaxHR(_ bpm: Int) {
        maxHR = bpm
    }

    /// Measured max HR if the athlete has reported one; else 220 − age from the
    /// profile birthdate; 192 (age 28) as the last resort.
    var effectiveMaxHR: Int {
        if let maxHR { return maxHR }
        if let birthdate, let day = PlanDates.day.date(from: birthdate) {
            let age = Calendar.current.dateComponents([.year], from: day, to: .now).year ?? 28
            return 220 - age
        }
        return 192
    }
    var maxHRIsMeasured: Bool { maxHR != nil }

    // MARK: - Derived

    var lastRun: RunSummary? { runs.first }

    var thisWeekMiles: Double { miles(inWeekOf: .now) }
    var lastWeekMiles: Double {
        guard let lastWeek = Self.cal.date(byAdding: .weekOfYear, value: -1, to: .now) else { return 0 }
        return miles(inWeekOf: lastWeek)
    }

    func miles(inWeekOf date: Date) -> Double {
        guard let week = Self.cal.dateInterval(of: .weekOfYear, for: date) else { return 0 }
        return runs.filter { week.contains($0.start) }.reduce(0) { $0 + $1.miles }
    }

    /// 0 = Mon … 6 = Sun.
    var todayIndex: Int {
        guard let week = Self.cal.dateInterval(of: .weekOfYear, for: .now) else { return 0 }
        return Self.cal.dateComponents([.day], from: week.start, to: Self.cal.startOfDay(for: .now)).day ?? 0
    }

    /// Which days of the current week (0 = Mon … 6 = Sun) have at least one run.
    var runDaysThisWeek: Set<Int> {
        guard let week = Self.cal.dateInterval(of: .weekOfYear, for: .now) else { return [] }
        return Set(runs.filter { week.contains($0.start) }.map {
            Self.cal.dateComponents([.day], from: week.start, to: Self.cal.startOfDay(for: $0.start)).day ?? 0
        })
    }

    /// Trailing `n` weeks including the current one, oldest first.
    func weeklySummaries(_ n: Int) -> [WeekSummary] {
        (0..<n).reversed().compactMap { back in
            guard let ref = Self.cal.date(byAdding: .weekOfYear, value: -back, to: .now),
                  let week = Self.cal.dateInterval(of: .weekOfYear, for: ref) else { return nil }
            let inWeek = runs.filter { week.contains($0.start) }
            return WeekSummary(
                weekStart: week.start,
                miles: inWeek.reduce(0) { $0 + $1.miles },
                runCount: inWeek.count,
                durationS: inWeek.reduce(0) { $0 + $1.durationS }
            )
        }
    }

    /// Runs in the trailing `days` days, newest first.
    func recentRuns(days: Int) -> [RunSummary] {
        guard let cutoff = Self.cal.date(byAdding: .day, value: -days, to: .now) else { return runs }
        return runs.filter { $0.start >= cutoff }
    }
}

// MARK: - Coach grounding

/// Compact, JSON-encodable snapshot of real training state, sent to the coach
/// Edge Function as grounding for every reply. Run ids let the coach propose
/// amendments to specific runs.
struct CoachContext: Encodable {
    struct RunCtx: Encodable {
        let id: String
        let date: String
        let miles: Double
        let pace_per_mile: String?
        let avg_hr: Int?
        let corrected: Bool
    }
    struct WeekCtx: Encodable {
        let week_of: String
        let miles: Double
        let runs: Int
    }

    struct PlanCtx: Encodable {
        struct SessCtx: Encodable {
            let id: String             // for update_session proposals
            let date: String
            let type: String
            let title: String?
            let status: String
        }
        let race: String
        let race_date: String
        let goal_time: String
        let week: Int                  // 1-based current week
        let weeks_total: Int
        let phase: String
        let week_target_mi: Double?
        let today_session: String?     // "Threshold repeats — 3×1 mi @ 7:05 (planned)"
        let projected_finish: String?
        let sessions_window: [SessCtx] // −7d…+14d, for adapting specific sessions
    }
    struct SettingsCtx: Encodable {
        let days_per_week: Int
        let long_run_day: String
    }
    struct OnboardingCtx: Encodable {
        let active: Bool
        let runs_found: Int
        let known: [String: String]   // facts already on file — confirm, don't re-ask
    }

    let today: String
    let goal: String
    let risk_tolerance: String
    let max_hr: Int
    let max_hr_basis: String       // "measured" | "estimated (220 − age)"
    struct FitnessCtx: Encodable {
        let readiness: Int         // 0–100, from the load model (pace/volume EWMAs)
        let fitness_ctl: Double
        let fatigue_atl: Double
        let form: Double
    }

    let settings: SettingsCtx
    let plan: PlanCtx?             // nil until the athlete confirms a goal → create_plan
    let fitness: FitnessCtx?
    let onboarding: OnboardingCtx? // present only while the setup interview runs
    let check_in_today: String?
    let recent_runs: [RunCtx]      // last 21 days
    let weekly_mileage: [WeekCtx]  // last 8 weeks, oldest first
}

extension RunStore {
    /// v1 beta: the goal is fixed to the reference athlete until Goal Setup is wired.
    static let goalDescription =
        "Sub-3:15 at the Chicago Marathon on 2026-10-11. Rebuilding from a small base after an inconsistent year — currently in base-building."

    func coachContext(onboarding: Bool = false) -> CoachContext {
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return CoachContext(
            today: Date.now.formatted(day),
            goal: goal.map { g in
                "\(g.raceName ?? "Race") on \(g.raceDate), target \(PaceModel.formatFinish(g.goalTimeSeconds ?? 0))"
            } ?? Self.goalDescription + " (no plan yet — assess and propose one when the athlete is ready)",
            risk_tolerance: riskTolerance,
            max_hr: effectiveMaxHR,
            max_hr_basis: maxHRIsMeasured ? "measured" : "estimated (220 − age)",
            settings: CoachContext.SettingsCtx(
                days_per_week: daysPerWeek,
                long_run_day: Calendar.current.weekdaySymbols[longRunDay]
            ),
            plan: planContext(),
            fitness: fitness.map {
                CoachContext.FitnessCtx(
                    readiness: $0.readiness,
                    fitness_ctl: ($0.ctl * 10).rounded() / 10,
                    fatigue_atl: ($0.atl * 10).rounded() / 10,
                    form: ($0.form * 10).rounded() / 10
                )
            },
            onboarding: onboarding ? onboardingContext() : nil,
            check_in_today: todayCheckIn.map { $0.feelsOk ? "feeling okay" + ($0.note.map { " — \($0)" } ?? "") : "something's off" + ($0.note.map { " — \($0)" } ?? "") },
            recent_runs: recentRuns(days: 21).map {
                CoachContext.RunCtx(
                    id: $0.id.uuidString,
                    date: $0.start.formatted(day),
                    miles: ($0.miles * 10).rounded() / 10,
                    pace_per_mile: $0.paceSecPerMile.map(PaceModel.format),
                    avg_hr: $0.avgHR,
                    corrected: $0.corrected
                )
            },
            weekly_mileage: weeklySummaries(8).map {
                CoachContext.WeekCtx(
                    week_of: $0.weekStart.formatted(day),
                    miles: ($0.miles * 10).rounded() / 10,
                    runs: $0.runCount
                )
            }
        )
    }

    /// Facts already on file, so the interview confirms instead of re-asking.
    private func onboardingContext() -> CoachContext.OnboardingCtx {
        var known: [String: String] = [
            "days_per_week": "\(daysPerWeek)",
            "long_run_day": Calendar.current.weekdaySymbols[longRunDay],
            "risk_tolerance": riskTolerance,
        ]
        if let maxHR { known["max_hr_measured"] = "\(maxHR)" }
        if let birthdate { known["birthdate"] = birthdate }
        if let goal, let t = goal.goalTimeSeconds {
            known["active_plan"] = "\(goal.raceName ?? "race") on \(goal.raceDate), goal \(PaceModel.formatFinish(t)) — keep unless the goal changes"
        }
        return CoachContext.OnboardingCtx(active: true, runs_found: runs.count, known: known)
    }
}
