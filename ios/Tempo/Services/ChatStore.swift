import Foundation
import Supabase

/// A write the coach wants to make, pending the athlete's confirmation.
/// Flat shape mirroring the Edge Function's tool params.
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
    enum ActionState: String, Equatable {
        case pending      // card showing Confirm/Dismiss
        case applying     // write in flight — card shows progress
        case applied      // success — card stays as evidence
        case dismissed
        case failed       // error — buttons return, retryable

        /// What gets written to the DB. `applying` deliberately never persists: an app
        /// killed mid-write cannot know whether the write landed, so the row stays
        /// `pending` and the athlete is re-offered the action rather than shown a state
        /// the app can't stand behind.
        var durable: ActionState { self == .applying ? .pending : self }
    }
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
    private static let autoApplyTypes = CoachAcknowledgement.onboardingAutoApplyTypes

    // Wire types
    struct WireMessage: Codable { let role: String; let content: String }
    private struct CoachRequest: Encodable { let messages: [WireMessage]; let context: CoachContext }
    private struct CoachReply: Decodable { let reply: String; let proposed_actions: [ProposedAction]? }
    private struct HistoryRow: Decodable {
        let id: UUID
        let role: String
        let content: String
        let created_at: Date
        let proposed_action: ProposedAction?
        let action_state: String?
    }
    /// `id` is generated on the device rather than left to the column default, so the row
    /// this insert creates is the same row a later Confirm updates. Without it the local
    /// message id and the DB id diverge and there is nothing to target.
    private struct MessageInsert: Encodable {
        let id: String
        let user_id: String
        let role: String
        let content: String
        let proposed_action: ProposedAction?
        let action_state: String?
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
            messages = rows.map { row in
                ChatMessage(
                    id: row.id,
                    role: ChatMessage.Role(rawValue: row.role) ?? .coach,
                    text: row.content,
                    timestamp: row.created_at,
                    action: row.proposed_action,
                    actionState: row.action_state
                        .flatMap(ChatMessage.ActionState.init(rawValue:))?.durable ?? .pending
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

    /// The line Confirm taps stand in, and what `CoachView` reads to stop showing a live
    /// button on a tap it has already banked.
    @Published private(set) var confirmQueue = ConfirmQueue()

    /// Tail of the resolution queue. Everything that ends in a coach round trip — every
    /// confirm, and the acknowledgement a dismiss asks for — waits on its predecessor here,
    /// for the same reason `handleReply` applies onboarding facts sequentially.
    private var resolutionTail: Task<Void, Never>?

    /// Put `work` at the back of the resolution queue; the returned task carries its result.
    ///
    /// Unstructured on purpose: the write must finish even if the view that started it goes
    /// away mid-flight, and a cancelled confirm would leave the card claiming `applying`
    /// forever.
    private func queued<T: Sendable>(_ work: @escaping @MainActor @Sendable () async -> T) -> Task<T, Never> {
        let predecessor = resolutionTail
        let task = Task { @MainActor in
            await predecessor?.value
            return await work()
        }
        resolutionTail = Task { @MainActor in _ = await task.value }
        return task
    }

    /// Execute a confirmed action. The card walks pending → applying → applied/failed.
    ///
    /// One at a time. Two cards on screen means two live Confirm buttons, and tapping both
    /// used to run two writes concurrently plus — since #33 — two coach round trips, the
    /// second reasoning from a context snapshotted mid-write (#38). A tap that arrives while
    /// another confirm is in flight is queued, never dropped: the athlete meant it, and its
    /// card says it is waiting instead of offering a button that does nothing.
    func confirm(_ messageID: UUID, runStore: RunStore) async -> Bool {
        let offered = messages.first { $0.id == messageID && $0.action != nil }?.actionState
        guard confirmQueue.admit(messageID, offering: offered) != .ignore else { return false }
        return await queued { [weak self] () -> Bool in
            guard let self else { return false }
            defer { self.confirmQueue.finish(messageID) }
            return await self.apply(messageID, runStore: runStore)
        }.value
    }

    /// The write itself, once the queue has granted this card its turn. The state is checked
    /// again here rather than trusted from admission time: a card can be resolved while it
    /// waits, and re-applying it would double the write.
    private func apply(_ messageID: UUID, runStore: RunStore) async -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              let action = messages[idx].action,
              messages[idx].actionState.isOpenOffer else { return false }
        errorText = nil
        messages[idx].actionState = .applying
        busyLabel = Self.busyLabel(for: action.type)
        defer { busyLabel = nil }
        // What the action wants said about itself, held until after the confirmation turn is
        // in the transcript. The plan paths are the only ones that narrate; letting them
        // append it themselves is what put the result above the tap that asked for it (#39).
        var narration: String?
        do {
            switch action.type {
            case "amend_run":          try await applyAmend(action)
            case "add_run":            try await applyAdd(action, messageID: messageID)
            case "set_risk_tolerance": try await applyRiskTolerance(action, runStore: runStore)
            case "update_athlete":     try await applyAthleteUpdate(action, runStore: runStore)
            case "create_plan":        narration = try await applyCreatePlan(action, runStore: runStore)
            case "update_plan_settings": narration = try await applyPlanSettings(action, runStore: runStore)
            case "update_session":     try await applyUpdateSession(action, runStore: runStore)
            case "complete_onboarding": await applyCompleteOnboarding(runStore: runStore)
            default:
                messages[idx].actionState = .failed
                persist(.failed, for: messageID)
                errorText = "Unknown action type “\(action.type)”."
                return false
            }
        } catch {
            messages[idx].actionState = .failed
            persist(.failed, for: messageID)
            errorText = "That change didn't go through — Confirm to retry."
            // No acknowledgement on a failure: the retry card is the response.
            return false
        }
        messages[idx].actionState = .applied
        persist(.applied, for: messageID)
        // Causal order: the tap, then what it did. Both go in before the acknowledgement round
        // trip, so the coach is answering a transcript that already reads correctly.
        append(.user, "Confirmed — \(action.displaySummary)")
        if let narration { append(.coach, narration) }
        let reloaded = await runStore.reloadFromSupabase()
        if !reloaded {
            // The write landed; only the re-read didn't. Saying nothing here is what makes
            // a saved edit look discarded — the card goes green and the numbers don't move.
            errorText = "Saved — but your runs couldn't be re-read just now. Pull to refresh on Today."
        }
        // The re-read has to come first. Ask before it and the coach answers out of the
        // pre-correction context — "that puts you at 25 for the week" about the very run it
        // just grew to 8 miles. That ordering is the whole reason this call sits down here.
        busyLabel = nil   // the save is done; what follows is the coach thinking, not the write
        await acknowledgeIfWarranted(
            reloaded ? .applied : .appliedWithStaleContext,
            action: action,
            runStore: runStore
        )
        return true
    }

    /// Dismiss does not queue the way Confirm does, and deliberately so: it writes nothing,
    /// so there is no write to serialize and no reason to make the athlete watch a spinner to
    /// be told "no" was heard. The card greys out on the tap. A second tap is already a no-op
    /// — the card is no longer an open offer.
    ///
    /// Its *acknowledgement* is a different animal. That is a coach round trip appended to the
    /// transcript, which is the half of #38 that dismiss shares, so it joins the same queue as
    /// the confirms rather than racing one.
    func dismiss(_ messageID: UUID, runStore: RunStore) async {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              let action = messages[idx].action,
              messages[idx].actionState.isOpenOffer else { return }
        messages[idx].actionState = .dismissed
        persist(.dismissed, for: messageID)
        append(.user, "Dismissed — \(action.displaySummary)")
        // Nothing was written, so there is nothing to re-read — the current context is current.
        await queued { [weak self] in
            await self?.acknowledgeIfWarranted(.dismissed, action: action, runStore: runStore)
        }.value
    }

    /// One turn of coach reply to a resolved card, when `CoachAcknowledgement` says the
    /// transition earns one.
    ///
    /// Nothing new is sent: `confirm`/`dismiss` have already appended "Confirmed — …" /
    /// "Dismissed — …" as a user turn, so the coach is answering a message that is genuinely
    /// in the transcript. The context is built *here*, at call time, rather than passed in —
    /// a context captured before the write would describe the state the athlete just changed.
    ///
    /// A failed round trip stays quiet. The change landed and the green card says so; an
    /// "unreachable" banner underneath it reads like the save failed, which is worse than the
    /// silence this whole issue is about. `requestReply` logs the failure either way.
    private func acknowledgeIfWarranted(
        _ transition: CoachAcknowledgement.Transition,
        action: ProposedAction,
        runStore: RunStore
    ) async {
        guard CoachAcknowledgement.shouldRequestReply(
            after: transition,
            onboardingMode: onboardingMode,
            actionType: action.type
        ) else { return }
        isThinking = true
        defer { isThinking = false }
        let history = messages.suffix(24).map {
            WireMessage(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        }
        if let reply = await requestReply(
            history: Array(history),
            context: runStore.coachContext(onboarding: onboardingMode)
        ) {
            // `handleReply` may attach a card of its own — legitimate — but it never asks for
            // another reply, which is what stops this from chaining into a monologue.
            handleReply(reply)
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

    /// Log a run the coach proposed. `messageID` is the card the offer came on: it is what
    /// gives the row its identity, so confirming the same offer twice writes one run and not
    /// two (see `Engine/ManualRunIdentity.swift`).
    private func applyAdd(_ action: ProposedAction, messageID: UUID) async throws {
        guard let uid = Supa.userID?.uuidString,
              let start = action.start_time,
              let distance = action.distance_m,
              let duration = action.duration_s else { throw ActionError.badParams }

        struct ManualInsert: Encodable {
            let user_id: String
            var source = ManualRunIdentity.source
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
            external_id: ManualRunIdentity.externalID(forProposalIn: messageID),
            start_time: start,
            distance_m: distance,
            duration_s: duration,
            avg_pace_sec: miles > 0.05 ? Int(Double(duration) / miles) : nil,
            avg_hr: action.avg_hr,
            correction_note: action.note
        )
        // Upsert, not insert, and for the same reason the ingest path does it
        // (`HealthService.sync`): a second Confirm must be a no-op, not an error. A
        // plain insert would raise on the unique constraint, the card would go to `failed`,
        // and the athlete would be invited to retry a write that had already landed — a
        // false failure on top of the duplicate this change exists to prevent.
        try await Supa.client
            .from("runs")
            .upsert(row, onConflict: "user_id,source,external_id", ignoreDuplicates: true)
            .execute()
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

    /// Returns the line to narrate, for the caller to place — see `PlanNarration`.
    private func applyCreatePlan(_ action: ProposedAction, runStore: RunStore) async throws -> String? {
        guard let goalTime = action.goal_time_s, let raceDate = action.race_date else { throw ActionError.badParams }
        return try await invokePlanEngine(goalTimeS: goalTime, raceName: action.race_name, raceDate: raceDate, runStore: runStore)
    }

    /// Returns the line to narrate, for the caller to place — see `PlanNarration`.
    private func applyPlanSettings(_ action: ProposedAction, runStore: RunStore, regenerate: Bool = true) async throws -> String? {
        guard let uid = Supa.userID?.uuidString,
              action.days_per_week != nil || action.long_run_day != nil else { throw ActionError.badParams }
        struct Patch: Encodable { let days_per_week: Int?; let long_run_day: Int? }
        try await Supa.client.from("profiles")
            .update(Patch(days_per_week: action.days_per_week, long_run_day: action.long_run_day))
            .eq("id", value: uid).execute()
        runStore.setPlanSettings(daysPerWeek: action.days_per_week, longRunDay: action.long_run_day)
        guard regenerate else { return nil }
        // Cascade: settings change regenerates the plan forward + recomputes projection.
        if let goal = runStore.goal, let t = goal.goalTimeSeconds, !goal.raceDate.isEmpty {
            return try await invokePlanEngine(goalTimeS: t, raceName: goal.raceName, raceDate: goal.raceDate, runStore: runStore)
        } else if !onboardingMode {
            return PlanNarration.settingsSavedWithoutPlan
        }
        return nil
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

    /// Calls the /plan Edge Function (assessment → shape → generated schedule) and returns
    /// the line describing what came back.
    ///
    /// It deliberately does not append that line itself. It used to, and since it runs inside
    /// the confirmed-action switch, the result landed above the "Confirmed — …" turn that
    /// asked for it (#39). Handing the line back lets the caller — which knows whether a
    /// confirmation turn precedes it — decide where it goes.
    private func invokePlanEngine(goalTimeS: Int, raceName: String?, raceDate: String, runStore: RunStore) async throws -> String? {
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
        return PlanNarration.planIsLive(PlanNarration.PlanResult(
            weeks: rep.weeks,
            archetype: rep.archetype,
            rationale: rep.rationale,
            projectedFinishSeconds: rep.projected_finish_s,
            startWeeklyMiles: rep.start_weekly_mi,
            peakWeeklyMiles: rep.peak_weekly_mi
        ))
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
                                // `regenerate: false` — nothing to narrate; the rebuild below is.
                                _ = try await self.applyPlanSettings(action, runStore: store, regenerate: false)
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
                        // No confirmation turn to sit under here — the interview applied these
                        // silently — so the narration goes in on its own.
                        if let line = try? await self.invokePlanEngine(
                            goalTimeS: t, raceName: goal.raceName, raceDate: goal.raceDate, runStore: store
                        ) {
                            self.append(.coach, line)
                        }
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
        let id = UUID()
        messages.append(ChatMessage(id: id, role: role, text: text, action: action))
        guard let uid = Supa.userID?.uuidString else { return }
        let row = MessageInsert(
            id: id.uuidString,
            user_id: uid,
            role: role.rawValue,
            content: text,
            proposed_action: action,
            action_state: action == nil ? nil : ChatMessage.ActionState.pending.rawValue
        )
        Task { try? await Supa.client.from("coach_messages").insert(row).execute() }
    }

    /// Mirror a card's resolution into the row that proposed it, so a relaunch replays the
    /// outcome instead of re-offering a change the athlete already answered.
    private func persist(_ state: ChatMessage.ActionState, for id: UUID) {
        Task {
            try? await Supa.client.from("coach_messages")
                .update(StatePatch(action_state: state.durable.rawValue))
                .eq("id", value: id.uuidString)
                .execute()
        }
    }
}
