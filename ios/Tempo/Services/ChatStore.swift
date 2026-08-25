import Foundation
import Supabase

/// A write the coach wants to make, pending the athlete's confirmation.
/// Flat shape mirroring the Edge Function's tool params.
///
/// `Encodable` as well as `Decodable` because the proposal is stored verbatim in
/// `coach_messages.proposed_action` so it can be offered again after a relaunch. The
/// synthesized encoder skips nil, so a row holds the handful of keys the coach actually
/// sent rather than thirty mostly-null ones.
struct ProposedAction: Codable, Equatable {
    let type: String            // amend_run | add_run | set_risk_tolerance
    let summary: String?        // one line shown on the confirm card (server guarantees it; belt & suspenders)

    // amend_run / add_run
    let run_id: String?
    let start_time: String?     // ISO 8601, passed straight through to Postgres
    let distance_m: Int?
    let duration_s: Int?
    let avg_hr: Int?
    let note: String?

    // set_risk_tolerance
    let level: String?
    let risk_named: String?

    // update_athlete
    let max_hr: Int?
    let birthdate: String?
    let injury_notes: String?
    let strength_notes: String?
    let wants_strength: Bool?

    // create_plan
    let goal_time_s: Int?
    let race_name: String?
    let race_date: String?
    let rationale: String?

    // update_plan_settings
    let days_per_week: Int?
    let long_run_day: Int?

    // update_session
    let session_id: String?
    let date: String?            // yyyy-MM-dd (move a session)
    let session_type: String?
    let title: String?
    let target_distance_m: Int?
    let target_pace_sec: Int?
    let detail: String?
    let session_status: String?  // planned | skipped

    /// Never-empty line for the confirm card and the confirmation message.
    var displaySummary: String { summary ?? note ?? "Proposed \(type)" }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, coach }
    /// Defined in `Engine/CoachActionState.swift`: the transitions have to survive a
    /// relaunch, which makes them logic, and logic here is pure and pinned by tests.
    typealias ActionState = CoachActionState
    let id: UUID
    let role: Role
    let text: String
    var timestamp: Date = .now
    var action: ProposedAction?
    var actionState: ActionState = .pending
}

/// Drives the Coach tab: history persists in Supabase (`coach_messages`),
/// replies come from the `coach` Edge Function — Claude grounded in the
/// athlete's real recent training via `CoachContext`.
///
/// The coach can PROPOSE data edits (tool calls). The function never writes;
/// this store executes the write client-side (RLS-scoped) after the athlete
/// taps Confirm.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isThinking = false
    @Published var errorText: String?

    /// Setup-interview mode: facts auto-apply silently (the athlete's answer IS the
    /// confirmation); only create_plan still gets a confirm card.
    var onboardingMode = false
    weak var runStore: RunStore?

    private var loaded = false
    private static let autoApplyTypes: Set<String> =
        ["update_athlete", "update_plan_settings", "set_risk_tolerance", "complete_onboarding"]

    // Wire types
    struct WireMessage: Codable { let role: String; let content: String }
    private struct CoachRequest: Encodable { let messages: [WireMessage]; let context: CoachContext }
    private struct CoachReply: Decodable { let reply: String; let proposed_actions: [ProposedAction]? }
    private struct HistoryRow: Decodable {
        let id: UUID
        let role: String
        let content: String
        let created_at: Date
        // Both nil for an ordinary message and for every row written before migration 0007.
        // Optional decoding tolerates the columns being absent entirely, so a build running
        // ahead of the migration still replays the conversation.
        let proposed_action: ProposedAction?
        let action_state: String?
    }
    private struct MessageInsert: Encodable { let id: String; let user_id: String; let role: String; let content: String }
    /// A separate shape so a message *without* a proposal never names the two columns
    /// migration 0007 adds. Running this build against an un-migrated database then costs
    /// the confirm cards and nothing else, instead of failing every message insert and
    /// dropping the whole conversation on the floor.
    private struct ProposalInsert: Encodable {
        let id: String
        let user_id: String
        let role: String
        let content: String
        let proposed_action: ProposedAction
        let action_state: String
    }
    private struct StatePatch: Encodable { let action_state: String }

    /// Load persisted history; on a fresh account, open with a data-grounded status read.
    /// In onboarding mode, always (re)open the interview — resuming where it left off.
    func load(context: CoachContext) async {
        guard !loaded else { return }
        loaded = true
        if let rows: [HistoryRow] = try? await Supa.client
            .from("coach_messages")
            .select()
            .order("created_at")
            .limit(200)
            .execute()
            .value {
            messages = rows.map {
                ChatMessage(
                    id: $0.id,
                    role: ChatMessage.Role(rawValue: $0.role) ?? .coach,
                    text: $0.content,
                    timestamp: $0.created_at,
                    action: $0.proposed_action,
                    actionState: .restored(from: $0.action_state)
                )
            }
        }
        let opener: String
        if onboardingMode {
            opener = "Begin (or resume) my onboarding interview. Confirm what you already know from onboarding.known instead of re-asking, and pick up wherever we left off."
        } else if messages.isEmpty {
            opener = "Open the conversation: introduce yourself in one short line, then give me an honest, specific read on my training right now based on my data. Close with one useful question."
        } else {
            return
        }
        // Hidden kickoff — only the coach's reply is shown or persisted.
        isThinking = true
        defer { isThinking = false }
        let history = messages.suffix(12).map {
            WireMessage(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        } + [WireMessage(role: "user", content: opener)]
        if let reply = await requestReply(history: Array(history), context: context) {
            handleReply(reply)
        }
    }

    func send(_ text: String, context: CoachContext) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }
        errorText = nil
        append(.user, trimmed)
        isThinking = true
        defer { isThinking = false }
        let history = messages.suffix(24).map {
            WireMessage(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        }
        if let reply = await requestReply(history: Array(history), context: context) {
            handleReply(reply)
        } else {
            errorText = "Coach unreachable — check your connection and try again."
        }
    }

    // MARK: - Confirm / dismiss proposed actions

    /// What the user is waiting on, shown beside the progress indicator.
    @Published private(set) var busyLabel: String?

    private static func busyLabel(for type: String) -> String {
        switch type {
        case "create_plan":          return "Building your plan — assessing your history (~15s)…"
        case "update_plan_settings": return "Rebuilding your plan with the new structure…"
        case "update_session":       return "Adjusting your session…"
        case "amend_run", "add_run": return "Updating your log…"
        default:                     return "Saving…"
        }
    }

    /// Execute a confirmed action. The card walks pending → applying → applied/failed.
    func confirm(_ messageID: UUID, runStore: RunStore) async -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              let action = messages[idx].action,
              messages[idx].actionState == .pending || messages[idx].actionState == .failed else { return false }
        errorText = nil
        messages[idx].actionState = .applying
        busyLabel = Self.busyLabel(for: action.type)
        defer { busyLabel = nil }
        do {
            switch action.type {
            case "amend_run":          try await applyAmend(action)
            case "add_run":            try await applyAdd(action)
            case "set_risk_tolerance": try await applyRiskTolerance(action, runStore: runStore)
            case "update_athlete":     try await applyAthleteUpdate(action, runStore: runStore)
            case "create_plan":        try await applyCreatePlan(action, runStore: runStore)
            case "update_plan_settings": try await applyPlanSettings(action, runStore: runStore)
            case "update_session":     try await applyUpdateSession(action, runStore: runStore)
            case "complete_onboarding": await applyCompleteOnboarding(runStore: runStore)
            default:
                messages[idx].actionState = .failed
                persistActionState(messageID, .failed)
                errorText = "Unknown action type “\(action.type)”."
                return false
            }
        } catch {
            messages[idx].actionState = .failed
            persistActionState(messageID, .failed)
            errorText = "That change didn't go through — Confirm to retry."
            return false
        }
        messages[idx].actionState = .applied
        persistActionState(messageID, .applied)
        append(.user, "Confirmed — \(action.displaySummary)")
        let reloaded = await runStore.reloadFromSupabase()
        if !reloaded {
            // The write landed; only the re-read didn't. Saying nothing here is what makes
            // a saved edit look discarded — the card goes green and the numbers don't move.
            errorText = "Saved — but your runs couldn't be re-read just now. Pull to refresh on Today."
        }
        return true
    }

    func dismiss(_ messageID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              let action = messages[idx].action,
              messages[idx].actionState == .pending || messages[idx].actionState == .failed else { return }
        messages[idx].actionState = .dismissed
        persistActionState(messageID, .dismissed)
        append(.user, "Dismissed — \(action.displaySummary)")
    }

    /// Record a resolution on the message's own row, so the card comes back resolved rather
    /// than as a live offer the athlete already answered.
    ///
    /// Fire-and-forget: the write the athlete actually cared about has already landed, and
    /// blocking the card on bookkeeping would be the worse trade. If this one fails the card
    /// reopens as pending — the failure mode is being asked twice, never a silent apply.
    private func persistActionState(_ messageID: UUID, _ state: ChatMessage.ActionState) {
        guard let stored = state.persisted else { return }
        let id = messageID.uuidString
        let patch = StatePatch(action_state: stored)
        enqueueWrite("coach.action_state_persist_failed") {
            try await Supa.client.from("coach_messages")
                .update(patch)
                .eq("id", value: id)
                .execute()
        }
    }

    private func applyAmend(_ action: ProposedAction) async throws {
        guard let runID = action.run_id else { throw ActionError.badParams }

        struct Existing: Decodable {
            let distance_m: Int
            let duration_s: Int
            let avg_hr: Int?
            let avg_pace_sec: Int?
            let corrected: Bool
        }
        let existing: Existing = try await Supa.client
            .from("runs")
            .select("distance_m,duration_s,avg_hr,avg_pace_sec,corrected")
            .eq("id", value: runID)
            .single()
            .execute()
            .value

        struct Patch: Encodable {
            var distance_m: Int?
            var duration_s: Int?
            var avg_hr: Int?
            var avg_pace_sec: Int?
            var corrected = true
            var correction_note: String
            var coach_takeaway: AnyJSON = .null   // stale after a correction — regenerates on next open
            var original: Original?
            struct Original: Encodable {
                let distance_m: Int
                let duration_s: Int
                let avg_hr: Int?
                let avg_pace_sec: Int?
            }
        }

        let newDistance = action.distance_m ?? existing.distance_m
        let newDuration = action.duration_s ?? existing.duration_s
        let miles = Double(newDistance) / 1609.34
        var patch = Patch(
            distance_m: action.distance_m,
            duration_s: action.duration_s,
            avg_hr: action.avg_hr,
            avg_pace_sec: miles > 0.05 ? Int(Double(newDuration) / miles) : nil,
            correction_note: action.note ?? action.displaySummary,
            original: nil
        )
        if !existing.corrected {   // preserve the pre-correction snapshot once
            patch.original = Patch.Original(
                distance_m: existing.distance_m,
                duration_s: existing.duration_s,
                avg_hr: existing.avg_hr,
                avg_pace_sec: existing.avg_pace_sec
            )
        }
        try await Supa.client.from("runs").update(patch).eq("id", value: runID).execute()
    }

    private func applyAdd(_ action: ProposedAction) async throws {
        guard let uid = Supa.userID?.uuidString,
              let start = action.start_time,
              let distance = action.distance_m,
              let duration = action.duration_s else { throw ActionError.badParams }

        struct ManualInsert: Encodable {
            let user_id: String
            var source = "manual"
            let external_id: String
            let start_time: String
            let distance_m: Int
            let duration_s: Int
            let avg_pace_sec: Int?
            let avg_hr: Int?
            let correction_note: String?
        }
        let miles = Double(distance) / 1609.34
        let row = ManualInsert(
            user_id: uid,
            external_id: UUID().uuidString,
            start_time: start,
            distance_m: distance,
            duration_s: duration,
            avg_pace_sec: miles > 0.05 ? Int(Double(duration) / miles) : nil,
            avg_hr: action.avg_hr,
            correction_note: action.note
        )
        try await Supa.client.from("runs").insert(row).execute()
    }

    private func applyRiskTolerance(_ action: ProposedAction, runStore: RunStore) async throws {
        guard let uid = Supa.userID?.uuidString,
              let level = action.level, ["standard", "ambitious"].contains(level) else { throw ActionError.badParams }

        struct ProfilePatch: Encodable { let risk_tolerance: String }
        try await Supa.client.from("profiles").update(ProfilePatch(risk_tolerance: level))
            .eq("id", value: uid).execute()

        struct AckInsert: Encodable { let user_id: String; let risk: String }
        let risk = action.risk_named ?? action.displaySummary
        try? await Supa.client.from("risk_acknowledgments").insert(AckInsert(user_id: uid, risk: risk)).execute()

        runStore.setRiskTolerance(level)
    }

    private func applyCreatePlan(_ action: ProposedAction, runStore: RunStore) async throws {
        guard let goalTime = action.goal_time_s, let raceDate = action.race_date else { throw ActionError.badParams }
        try await invokePlanEngine(goalTimeS: goalTime, raceName: action.race_name, raceDate: raceDate, runStore: runStore)
    }

    private func applyPlanSettings(_ action: ProposedAction, runStore: RunStore, regenerate: Bool = true) async throws {
        guard let uid = Supa.userID?.uuidString,
              action.days_per_week != nil || action.long_run_day != nil else { throw ActionError.badParams }
        struct Patch: Encodable { let days_per_week: Int?; let long_run_day: Int? }
        try await Supa.client.from("profiles")
            .update(Patch(days_per_week: action.days_per_week, long_run_day: action.long_run_day))
            .eq("id", value: uid).execute()
        runStore.setPlanSettings(daysPerWeek: action.days_per_week, longRunDay: action.long_run_day)
        guard regenerate else { return }
        // Cascade: settings change regenerates the plan forward + recomputes projection.
        if let goal = runStore.goal, let t = goal.goalTimeSeconds, !goal.raceDate.isEmpty {
            try await invokePlanEngine(goalTimeS: t, raceName: goal.raceName, raceDate: goal.raceDate, runStore: runStore)
        } else if !onboardingMode {
            append(.coach, "Settings saved. No active plan to rebuild yet — they'll shape the plan when we create it.")
        }
    }

    /// Adapt a single session (move it, change its content, or skip it).
    private func applyUpdateSession(_ action: ProposedAction, runStore: RunStore) async throws {
        guard let sessionID = action.session_id else { throw ActionError.badParams }
        if let status = action.session_status, !["planned", "skipped"].contains(status) { throw ActionError.badParams }
        struct Structure: Encodable { let detail: String }
        struct Patch: Encodable {
            let date: String?
            let type: String?
            let title: String?
            let target_distance_m: Int?
            let target_pace_sec: Int?
            let status: String?
            let structure: Structure?
            var adapted = true
            let adaptation_note: String?
        }
        try await Supa.client.from("sessions").update(Patch(
            date: action.date,
            type: action.session_type,
            title: action.title,
            target_distance_m: action.target_distance_m,
            target_pace_sec: action.target_pace_sec,
            status: action.session_status,
            structure: action.detail.map(Structure.init),
            adaptation_note: action.note
        )).eq("id", value: sessionID).execute()
        await runStore.loadPlan()
    }

    /// Calls the /plan Edge Function (assessment → shape → generated schedule) and
    /// narrates the result into the conversation.
    private func invokePlanEngine(goalTimeS: Int, raceName: String?, raceDate: String, runStore: RunStore) async throws {
        struct Req: Encodable { let goal_time_s: Int; let race_name: String?; let race_date: String }
        struct Rep: Decodable {
            let weeks: Int?
            let archetype: String?
            let rationale: String?
            let projected_finish_s: Int?
            let start_weekly_mi: Double?
            let peak_weekly_mi: Double?
        }
        let rep: Rep = try await Supa.client.functions.invoke(
            "plan",
            options: FunctionInvokeOptions(body: Req(goal_time_s: goalTimeS, race_name: raceName, race_date: raceDate))
        )
        await runStore.loadPlan()
        if let weeks = rep.weeks {
            var lines = ["Plan is live: \(weeks) weeks (\((rep.archetype ?? "custom").replacingOccurrences(of: "_", with: " ")))."]
            if let s = rep.start_weekly_mi, let p = rep.peak_weekly_mi {
                lines.append("Volume runs \(String(format: "%.0f", s)) → \(String(format: "%.0f", p)) mi/wk.")
            }
            if let proj = rep.projected_finish_s {
                lines.append("Projection today: \(PaceModel.formatFinish(proj)).")
            }
            if let why = rep.rationale { lines.append(why) }
            append(.coach, lines.joined(separator: " "))
        }
    }

    private func applyAthleteUpdate(_ action: ProposedAction, runStore: RunStore) async throws {
        guard let uid = Supa.userID?.uuidString else { throw ActionError.badParams }
        if let bpm = action.max_hr, !(120...230).contains(bpm) { throw ActionError.badParams }
        let hasFact = action.max_hr != nil || action.birthdate != nil || action.injury_notes != nil
            || action.strength_notes != nil || action.wants_strength != nil
        guard hasFact else { throw ActionError.badParams }

        struct ProfilePatch: Encodable {
            let max_hr: Int?
            let birthdate: String?
            let injury_notes: String?
            let strength_notes: String?
            let wants_strength: Bool?
        }
        try await Supa.client.from("profiles").update(ProfilePatch(
            max_hr: action.max_hr,
            birthdate: action.birthdate,
            injury_notes: action.injury_notes,
            strength_notes: action.strength_notes,
            wants_strength: action.wants_strength
        )).eq("id", value: uid).execute()

        if let bpm = action.max_hr { runStore.setMaxHR(bpm) }
        runStore.setBirthdate(action.birthdate)
    }

    private func applyCompleteOnboarding(runStore: RunStore) async {
        await runStore.markOnboarded()
    }

    private enum ActionError: Error { case badParams }

    // MARK: - Plumbing

    private func handleReply(_ reply: CoachReply) {
        var actions = reply.proposed_actions ?? []

        // Onboarding: small facts apply silently — the athlete's answer was the consent.
        // SEQUENTIAL, and any plan rebuild is coalesced to a single run at the end
        // (parallel applies once raced two simultaneous regenerations).
        if onboardingMode, let store = runStore {
            let silent = actions.filter { Self.autoApplyTypes.contains($0.type) }
            actions.removeAll { Self.autoApplyTypes.contains($0.type) }
            if !silent.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    var settingsTouched = false
                    for action in silent {
                        do {
                            switch action.type {
                            case "update_athlete":       try await self.applyAthleteUpdate(action, runStore: store)
                            case "update_plan_settings":
                                try await self.applyPlanSettings(action, runStore: store, regenerate: false)
                                settingsTouched = true
                            case "set_risk_tolerance":   try await self.applyRiskTolerance(action, runStore: store)
                            case "complete_onboarding":  await store.markOnboarded()
                            default: break
                            }
                        } catch {
                            self.errorText = "Couldn't save that — tell the coach again."
                        }
                    }
                    if settingsTouched, let goal = store.goal, let t = goal.goalTimeSeconds, !goal.raceDate.isEmpty {
                        try? await self.invokePlanEngine(goalTimeS: t, raceName: goal.raceName, raceDate: goal.raceDate, runStore: store)
                    }
                }
            }
        }

        if !reply.reply.isEmpty {
            append(.coach, reply.reply, action: actions.first)
        }
        // Additional proposals (rare) become their own cards.
        for extra in actions.dropFirst() {
            append(.coach, extra.displaySummary, action: extra)
        }
        if reply.reply.isEmpty && actions.isEmpty {
            // The v11 guard is supposed to make this unreachable. If it fires, the guard
            // has a hole — and only telemetry would ever tell us.
            Telemetry.warn("coach.empty_reply", "reached the supposedly-unreachable path")
            errorText = "Coach sent an empty reply — try again."
        }
    }

    private func requestReply(history: [WireMessage], context: CoachContext) async -> CoachReply? {
        do {
            let reply: CoachReply = try await Supa.client.functions.invoke(
                "coach",
                options: FunctionInvokeOptions(body: CoachRequest(messages: history, context: context))
            )
            return reply
        } catch {
            Telemetry.error("coach.invoke_failed", error)
            return nil
        }
    }

    private func append(_ role: ChatMessage.Role, _ text: String, action: ProposedAction? = nil) {
        let message = ChatMessage(id: UUID(), role: role, text: text, action: action)
        messages.append(message)
        guard let uid = Supa.userID?.uuidString else { return }
        // The row id is minted here rather than by Postgres' `default gen_random_uuid()`,
        // because a later Confirm has to be able to find its own row: the card on screen and
        // the row behind it must be one identity, across a relaunch and across the gap
        // between this insert and the read that replays it.
        let id = message.id.uuidString
        let roleValue = role.rawValue
        // Used to be `try?`. A dropped insert now costs a confirmable offer, not just a line
        // of transcript, so it is worth hearing about.
        enqueueWrite("coach.message_persist_failed") {
            let table = Supa.client.from("coach_messages")
            if let action {
                try await table.insert(ProposalInsert(
                    id: id, user_id: uid, role: roleValue, content: text,
                    proposed_action: action,
                    action_state: ChatMessage.ActionState.pending.rawValue
                )).execute()
            } else {
                try await table.insert(MessageInsert(
                    id: id, user_id: uid, role: roleValue, content: text
                )).execute()
            }
        }
    }

    /// Every `coach_messages` write goes through here, and they run one at a time in the
    /// order they were made.
    ///
    /// Ordering is not decoration. A Confirm can land a second after the card appears, and
    /// its state UPDATE would then race the INSERT that created the row — an update that
    /// overtakes its own insert matches nothing, and the card comes back next launch as a
    /// live offer the athlete already took. Which is the bug this whole change exists to fix.
    /// The traffic is a handful of small writes a minute at its very busiest, so a queue
    /// costs nothing worth counting.
    private func enqueueWrite(_ event: String, _ work: @escaping @Sendable () async throws -> Void) {
        let previous = writes
        writes = Task {
            if let previous { await previous.value }
            do {
                try await work()
            } catch {
                Telemetry.error(event, error)
            }
        }
    }

    private var writes: Task<Void, Never>?
}
