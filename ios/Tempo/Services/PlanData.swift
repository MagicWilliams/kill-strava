import Foundation

// MARK: - Plan models (rows from Supabase; dates are yyyy-MM-dd strings)

struct PlanInfo: Decodable, Identifiable {
    let id: UUID
    let goal_id: UUID
    let start_date: String
    let weeks: Int
    let status: String
    var projected_finish_s: Int?

    var startDate: Date { PlanDates.day.date(from: start_date) ?? .now }
}

struct GoalInfo: Decodable, Identifiable {
    let id: UUID
    let race_name: String?
    let race_date: String?
    let goal_time_seconds: Int?

    var raceName: String? { race_name }
    var raceDate: String { race_date ?? "" }
    var goalTimeSeconds: Int? { goal_time_seconds }
    var raceDay: Date? { race_date.flatMap { PlanDates.day.date(from: $0) } }
}

struct PlanWeekInfo: Decodable, Identifiable {
    let id: UUID
    let week_index: Int
    let phase: String
    let target_mileage: Double?
    let focus: String?
}

struct SessionInfo: Decodable, Identifiable, Hashable {
    struct Structure: Decodable, Hashable { let detail: String? }
    let id: UUID
    var date: String
    let type: String
    let title: String?
    let target_distance_m: Int?
    let target_pace_sec: Int?
    let structure: Structure?
    var status: String
    var run_id: UUID?
    var adapted: Bool = false
    var adaptation_note: String?

    enum CodingKeys: String, CodingKey {
        case id, date, type, title, target_distance_m, target_pace_sec, structure, status, run_id, adapted, adaptation_note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        type = try c.decode(String.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        target_distance_m = try c.decodeIfPresent(Int.self, forKey: .target_distance_m)
        target_pace_sec = try c.decodeIfPresent(Int.self, forKey: .target_pace_sec)
        structure = try c.decodeIfPresent(Structure.self, forKey: .structure)
        status = try c.decode(String.self, forKey: .status)
        run_id = try c.decodeIfPresent(UUID.self, forKey: .run_id)
        adapted = (try c.decodeIfPresent(Bool.self, forKey: .adapted)) ?? false
        adaptation_note = try c.decodeIfPresent(String.self, forKey: .adaptation_note)
    }

    var day: Date { PlanDates.day.date(from: date) ?? .distantPast }
    var isQuality: Bool { ["tempo", "threshold", "interval"].contains(type) }
    var targetMiles: Double? { target_distance_m.map { Double($0) / 1609.34 } }
    var detail: String? { structure?.detail }
}

struct CheckInInfo: Decodable {
    let date: String
    let feels_ok: Bool
    let note: String?

    var feelsOk: Bool { feels_ok }
    // note passthrough with Swift naming
    var noteText: String? { note }
}
extension CheckInInfo {
    var noteOrNil: String? { note }
}

enum PlanDates {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        return f
    }()
    static var todayString: String { day.string(from: .now) }
}

extension PaceModel {
    /// Format a finish time as h:mm:ss.
    static func formatFinish(_ seconds: Int) -> String {
        String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}

// MARK: - Plan loading, matching, check-ins, projection

extension RunStore {

    /// Reload plan state. NEVER destructive on failure: a cancelled pull-to-refresh or a
    /// network blip keeps the current state; local state clears only when the server
    /// definitively reports zero active plans.
    func loadPlan() async {
        guard Supa.userID != nil else { return }

        let fetched: [PlanInfo]
        do {
            fetched = try await Supa.client
                .from("plans")
                .select("id,goal_id,start_date,weeks,status,projected_finish_s")
                .eq("status", value: "active")
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value
        } catch {
            // Transient failure — keep whatever we're showing. Reported because a
            // *persistent* run of these looks identical to "the plan vanished" from
            // the athlete's side, and that ambiguity cost days in July.
            Telemetry.error("plan.load_failed", error)
            return
        }

        guard let newPlan = fetched.first else {
            // Definitive: no active plan exists.
            if plan != nil {
                Telemetry.warn("plan.cleared", "server returned zero active plans")
            }
            plan = nil; goal = nil; planWeeks = []; sessions = []
            return
        }

        let newGoal: GoalInfo? = try? await Supa.client
            .from("goals")
            .select("id,race_name,race_date,goal_time_seconds")
            .eq("id", value: newPlan.goal_id.uuidString)
            .single()
            .execute()
            .value
        let newWeeks: [PlanWeekInfo]? = try? await Supa.client
            .from("plan_weeks")
            .select("id,week_index,phase,target_mileage,focus")
            .eq("plan_id", value: newPlan.id.uuidString)
            .order("week_index")
            .execute()
            .value

        let from = Self.cal.date(byAdding: .day, value: -7, to: .now) ?? .now
        let to = Self.cal.date(byAdding: .day, value: 15, to: .now) ?? .now
        let newSessions: [SessionInfo]? = try? await Supa.client
            .from("sessions")
            .select("id,date,type,title,target_distance_m,target_pace_sec,structure,status,run_id,adapted,adaptation_note")
            .eq("plan_id", value: newPlan.id.uuidString)
            .gte("date", value: PlanDates.day.string(from: from))
            .lte("date", value: PlanDates.day.string(from: to))
            .order("date")
            .execute()
            .value

        // Commit only what actually loaded; a partial failure keeps prior data visible.
        plan = newPlan
        if let newGoal { goal = newGoal }
        if let newWeeks { planWeeks = newWeeks }
        if let newSessions { sessions = newSessions }

        if let checkIn: CheckInInfo = try? await Supa.client
            .from("check_ins")
            .select("date,feels_ok,note")
            .eq("date", value: PlanDates.todayString)
            .single()
            .execute()
            .value {
            todayCheckIn = checkIn
        }
    }

    // MARK: Derived plan state

    var todaySession: SessionInfo? {
        sessions.first { $0.date == PlanDates.todayString }
    }

    /// 1-based index of the current plan week.
    var currentPlanWeek: Int? {
        guard let plan else { return nil }
        let days = Self.cal.dateComponents([.day], from: Self.cal.startOfDay(for: plan.startDate), to: Self.cal.startOfDay(for: .now)).day ?? 0
        let week = days / 7 + 1
        return (1...plan.weeks).contains(week) ? week : nil
    }

    var currentPhase: String? {
        guard let week = currentPlanWeek else { return nil }
        return planWeeks.first { $0.week_index == week - 1 }?.phase
    }

    func planContext() -> CoachContext.PlanCtx? {
        guard let plan, let goal else { return nil }
        let week = currentPlanWeek ?? 1
        let target = planWeeks.first { $0.week_index == week - 1 }?.target_mileage
        let today = todaySession.map { s in
            "\(s.title ?? s.type)\(s.detail.map { " — \($0)" } ?? "") (\(s.status))"
        }
        return CoachContext.PlanCtx(
            race: goal.raceName ?? "Race",
            race_date: goal.raceDate,
            goal_time: goal.goalTimeSeconds.map(PaceModel.formatFinish) ?? "—",
            week: week,
            weeks_total: plan.weeks,
            phase: currentPhase ?? "—",
            week_target_mi: target,
            today_session: today,
            projected_finish: plan.projected_finish_s.map(PaceModel.formatFinish),
            sessions_window: sessions.map {
                CoachContext.PlanCtx.SessCtx(
                    id: $0.id.uuidString, date: $0.date, type: $0.type, title: $0.title, status: $0.status
                )
            }
        )
    }

    // MARK: Matcher (Stage D) — completed runs claim their planned sessions

    func matchRunsToSessions() async {
        guard plan != nil else { return }
        let today = PlanDates.todayString
        var changed = false
        for (idx, session) in sessions.enumerated() {
            guard session.status == "planned", session.type != "rest", session.date <= today else { continue }
            guard let match = runs.first(where: {
                PlanDates.day.string(from: $0.start) == session.date
            }) else { continue }
            struct Patch: Encodable { let status: String; let run_id: String }
            if (try? await Supa.client.from("sessions")
                .update(Patch(status: "done", run_id: match.id.uuidString))
                .eq("id", value: session.id.uuidString)
                .execute()) != nil {
                sessions[idx].status = "done"
                sessions[idx].run_id = match.id
                changed = true
            }
        }
        if changed { objectWillChange.send() }
    }

    /// The run that fulfilled a session, if matched.
    func matchedRun(for session: SessionInfo) -> RunSummary? {
        session.run_id.flatMap { id in runs.first { $0.id == id } }
    }

    // MARK: Auto-adaptation (Stage E, small tweaks) — adapt small silently

    /// If a quality/long session was missed earlier THIS week and a later easy day
    /// remains, the hard session takes the easy slot (the easy day is skipped).
    /// One swap per refresh; each session adapts at most once.
    func autoAdaptMissedQuality() async {
        guard plan != nil,
              let week = Self.cal.dateInterval(of: .weekOfYear, for: .now) else { return }
        let today = PlanDates.todayString
        let weekStart = PlanDates.day.string(from: week.start)
        let weekEnd = PlanDates.day.string(from: week.end)

        guard let missedIdx = sessions.firstIndex(where: {
            ($0.isQuality || $0.type == "long") && $0.status == "planned" && !$0.adapted
                && $0.date >= weekStart && $0.date < today
        }) else { return }
        guard let easyIdx = sessions.firstIndex(where: {
            $0.type == "easy" && $0.status == "planned" && !$0.adapted
                && $0.date > today && $0.date < weekEnd
        }) else { return }

        let missed = sessions[missedIdx]
        let easy = sessions[easyIdx]
        func dayName(_ iso: String) -> String {
            PlanDates.day.date(from: iso).map { $0.formatted(.dateTime.weekday(.wide)) } ?? iso
        }

        struct Patch: Encodable {
            let date: String?
            let status: String?
            var adapted = true
            let adaptation_note: String
        }
        do {
            try await Supa.client.from("sessions").update(Patch(
                date: easy.date, status: nil,
                adaptation_note: "Moved from \(dayName(missed.date)) — it was missed, so it takes \(dayName(easy.date))'s easy slot."
            )).eq("id", value: missed.id.uuidString).execute()
            try await Supa.client.from("sessions").update(Patch(
                date: nil, status: "skipped",
                adaptation_note: "Skipped — its slot went to \(missed.title ?? missed.type)."
            )).eq("id", value: easy.id.uuidString).execute()
        } catch { return }   // adaptation is best-effort; never disturb state on failure

        sessions[missedIdx].date = easy.date
        sessions[missedIdx].adapted = true
        sessions[missedIdx].adaptation_note = "Moved from \(dayName(missed.date))."
        sessions[easyIdx].status = "skipped"
        sessions[easyIdx].adapted = true
        sessions.sort { $0.date < $1.date }
    }

    // MARK: Check-ins (trust mechanism; gates hard days)

    func submitCheckIn(feelsOk: Bool, note: String? = nil) async {
        guard let uid = Supa.userID?.uuidString else { return }
        struct Row: Encodable { let user_id: String; let date: String; let feels_ok: Bool; let note: String? }
        let row = Row(user_id: uid, date: PlanDates.todayString, feels_ok: feelsOk, note: note)
        _ = try? await Supa.client.from("check_ins")
            .upsert(row, onConflict: "user_id,date")
            .execute()
        todayCheckIn = CheckInInfo(date: row.date, feels_ok: feelsOk, note: note)
    }

    // MARK: Projection (Stage F, v1) — recomputed after every refresh

    func recomputeProjection() async {
        guard var plan else { return }
        let cutoff = Self.cal.date(byAdding: .day, value: -42, to: .now) ?? .now
        let candidates = runs.filter { $0.start >= cutoff && $0.miles >= 2.5 }
        guard let best = candidates.min(by: { ($0.paceSecPerMile ?? .max) < ($1.paceSecPerMile ?? .max) }),
              let bestPace = best.paceSecPerMile else { return }
        let projected = Int(PaceModel.equivalentTime(
            seconds: Double(bestPace) * best.miles,
            from: best.miles,
            to: RaceDistance.marathon.miles
        ))
        guard abs((plan.projected_finish_s ?? 0) - projected) > 30 else { return }
        plan.projected_finish_s = projected
        self.plan = plan
        struct Patch: Encodable { let projected_finish_s: Int }
        _ = try? await Supa.client.from("plans")
            .update(Patch(projected_finish_s: projected))
            .eq("id", value: plan.id.uuidString)
            .execute()
    }
}
