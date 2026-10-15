import Foundation
import Supabase

/// I/O for the Block Review (#100): load a block's plan, write its close-out, and fetch and
/// cache the coach's retrospective. Every decision is in `Engine/BlockReview.swift` and
/// `Engine/BlockCloseout.swift`; this file only moves rows.
@MainActor
enum BlockReviewService {

    /// The plan side of a block, as stored. The runs come from `RunStore`, which already
    /// holds the whole archive.
    struct PlanSide {
        let plan: PlanInfo
        let weeks: [PlanWeekInfo]
        let sessions: [BlockReview.PlannedSession]
    }

    /// `distance_m` (0014, applied 2026-10-12) so a closed block's recap and review measure
    /// a 15K or a custom distance at its own length (`RaceRecap.raceMeters(goal:)`, #140).
    static let goalColumns =
        "id,race_name,race_date,goal_time_seconds,distance,distance_m,completed_at,outcome,result_time_s,race_run_id,review"

    // MARK: - Reads

    /// Closed goals, newest first. Nil when the read failed — including before migration 0013,
    /// when the columns it filters on don't exist. Nil is "can't say", not "no blocks".
    static func pastBlocks() async -> [GoalInfo]? {
        guard Supa.userID != nil else { return nil }
        do {
            return try await Supa.client
                .from("goals")
                .select(goalColumns)
                .not("completed_at", operator: .is, value: "null")
                .order("completed_at", ascending: false)
                .execute()
                .value
        } catch {
            Telemetry.error("block.past_unreadable", error)
            return nil
        }
    }

    /// The block's plan: the newest plan written for this goal, its weeks, and **every**
    /// session — `RunStore.sessions` only holds a −7…+14 day window, and adherence is over
    /// the whole block.
    static func planSide(for goal: GoalInfo) async -> PlanSide? {
        do {
            let plans: [PlanInfo] = try await Supa.client
                .from("plans")
                .select("id,goal_id,start_date,weeks,status,projected_finish_s")
                .eq("goal_id", value: goal.id.uuidString)
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value
            guard let plan = plans.first else { return nil }
            let weeks: [PlanWeekInfo] = try await Supa.client
                .from("plan_weeks")
                .select("id,week_index,phase,target_mileage,focus")
                .eq("plan_id", value: plan.id.uuidString)
                .order("week_index")
                .execute()
                .value
            let sessions: [SessionInfo] = try await Supa.client
                .from("sessions")
                .select("id,date,type,status")
                .eq("plan_id", value: plan.id.uuidString)
                .order("date")
                .execute()
                .value
            return PlanSide(plan: plan, weeks: weeks, sessions: sessions.map(BlockReview.PlannedSession.init))
        } catch {
            Telemetry.error("block.plan_unreadable", error)
            return nil
        }
    }

    // MARK: - Close-out

    enum CloseError: LocalizedError {
        case notSignedIn
        case invalid(BlockCloseout.CloseoutError)
        case raceRunFailed
        case goalNotUpdated
        case planNotUpdated

        var errorDescription: String? {
            switch self {
            case .notSignedIn:    return "Not signed in."
            case .invalid:        return "Enter your official finish time, or choose how the race went."
            case .raceRunFailed:  return "Couldn't log the race as a run, so nothing was closed. Try again."
            case .goalNotUpdated: return "Couldn't save the result — nothing was closed. If the database hasn't been updated for block reviews yet (migration 0013), this is why."
            case .planNotUpdated: return "The result saved, but the plan didn't close. Try again — it's safe to repeat."
            }
        }
    }

    struct CloseRequest {
        let goal: GoalInfo
        let planID: UUID?
        let outcome: BlockCloseout.Outcome
        let finishS: Int?
        /// The race run found in history, if any.
        let raceRunID: UUID?
        /// Set when the athlete asked to also log the race as a run. Only honoured for a
        /// raced block with no race run already on file.
        let logRunStart: Date?
    }

    /// Write the close-out. Order matters, and every step is safe to repeat:
    ///   1. the optional race run (upsert on an identity derived from the goal),
    ///   2. the goal's outcome + `is_active = false`,
    ///   3. the plan to `done`.
    /// A failure stops the sequence and says which step, so a retry finishes the job rather
    /// than doing half of it twice.
    ///
    /// Returns the goal as it now stands.
    static func close(_ req: CloseRequest, now: Date = .now) async throws -> GoalInfo {
        guard let uid = Supa.userID?.uuidString else { throw CloseError.notSignedIn }
        let raceMeters = RaceRecap.raceMeters(goal: req.goal)

        var raceRunID = req.raceRunID
        if req.outcome == .raced, raceRunID == nil, let start = req.logRunStart, let finish = req.finishS {
            let row = BlockCloseout.raceRun(
                userID: uid, goalID: req.goal.id,
                raceName: req.goal.raceName ?? RaceCountdown.unnamedRace,
                start: start, raceMeters: raceMeters, finishS: finish
            )
            struct IDRow: Decodable { let id: UUID }
            do {
                let inserted: IDRow = try await Supa.client
                    .from("runs")
                    .upsert(row, onConflict: "user_id,source,external_id")
                    .select("id")
                    .single()
                    .execute()
                    .value
                raceRunID = inserted.id
            } catch {
                Telemetry.error("block.race_run_failed", error)
                throw CloseError.raceRunFailed
            }
        }

        let patch: BlockCloseout.GoalPatch
        do {
            patch = try BlockCloseout.goalPatch(outcome: req.outcome, finishS: req.finishS, raceRunID: raceRunID, now: now)
        } catch let e as BlockCloseout.CloseoutError {
            throw CloseError.invalid(e)
        }

        // `.select` so a write that matched no row (RLS, a stale id) is an error rather than a
        // silent success — the athlete would otherwise see "closed" and come back to it open.
        struct Touched: Decodable { let id: UUID }
        do {
            let touched: [Touched] = try await Supa.client.from("goals")
                .update(patch).eq("id", value: req.goal.id.uuidString).select("id").execute().value
            guard !touched.isEmpty else { throw CloseError.goalNotUpdated }
        } catch {
            Telemetry.error("block.goal_close_failed", error)
            throw CloseError.goalNotUpdated
        }

        if let planID = req.planID {
            do {
                let touched: [Touched] = try await Supa.client.from("plans")
                    .update(BlockCloseout.PlanPatch()).eq("id", value: planID.uuidString).select("id").execute().value
                guard !touched.isEmpty else { throw CloseError.planNotUpdated }
            } catch {
                Telemetry.error("block.plan_close_failed", error)
                throw CloseError.planNotUpdated
            }
        }

        var closed = req.goal
        closed.completed_at = now
        closed.outcome = patch.outcome
        closed.result_time_s = patch.result_time_s
        closed.race_run_id = patch.race_run_id.flatMap(UUID.init(uuidString:))
        return closed
    }

    // MARK: - The coach's retrospective

    private static var inFlight: Set<UUID> = []

    /// What the `block_review` coach mode is given: the block's numbers and how it ended,
    /// already formatted so the model quotes them rather than re-deriving them.
    struct CoachBlock: Encodable {
        struct WeekLine: Encodable {
            let week: Int
            let planned_mi: Double?
            let actual_mi: Double
            let runs: Int
        }
        let race: String
        let race_date: String
        let distance: String
        let goal_time: String?
        let outcome: String
        let result_time: String?
        let result_vs_goal: String?
        let weeks: [WeekLine]
        let total_miles: Double
        let total_runs: Int
        let peak_week_mi: Double?
        let longest_run_mi: Double?
        let runs_20_plus: Int?
        let sessions_done: String
        let quality_done: String
        let long_runs_done: String
        let taper_drop_pct: Int?
        let projected_at_block_start: String?
        let projected_race_morning: String?
    }

    static func coachBlock(goal: GoalInfo, review r: BlockReview.Review) -> CoachBlock {
        func one(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        func ratio(_ a: BlockReview.Adherence) -> String { "\(a.done) of \(a.planned)" }
        let delta = BlockCloseout.delta(resultS: goal.result_time_s, goalS: goal.goalTimeSeconds)
        return CoachBlock(
            race: goal.raceName ?? RaceCountdown.unnamedRace,
            race_date: goal.raceDate,
            distance: goal.distance ?? "marathon",
            goal_time: goal.goalTimeSeconds.map(PaceModel.formatFinish),
            outcome: goal.outcome ?? "not recorded",
            result_time: goal.result_time_s.map(PaceModel.formatFinish),
            result_vs_goal: delta.map { RaceRecap.formatDelta(Double($0)) },
            weeks: r.weeks.map {
                CoachBlock.WeekLine(week: $0.index + 1, planned_mi: $0.plannedMiles.map(one),
                                    actual_mi: one($0.actualMiles), runs: $0.runCount)
            },
            total_miles: one(r.totalMiles),
            total_runs: r.runCount,
            peak_week_mi: r.peakWeek.map { one($0.actualMiles) },
            longest_run_mi: r.longest.map { one($0.miles) },
            runs_20_plus: r.showsLongRunCount ? r.twentyPlusCount : nil,
            sessions_done: ratio(r.all),
            quality_done: ratio(r.quality),
            long_runs_done: ratio(r.long),
            taper_drop_pct: r.taper.map { Int(($0.drop * 100).rounded()) },
            projected_at_block_start: r.projectedAtStartS.map(PaceModel.formatFinish),
            projected_race_morning: r.projectedRaceMorningS.map(PaceModel.formatFinish)
        )
    }

    /// The cached retrospective, or a fresh one written and cached. Nil on failure — the
    /// screen says so and offers a retry; a failure is never cached as if it were a review.
    ///
    /// `context` is taken as a value, captured before the close-out reloads the store: once
    /// the plan is `done` the store holds no plan, and the coach would be told there isn't one.
    static func retrospective(goal: GoalInfo, review: BlockReview.Review, context: CoachContext) async -> String? {
        if let cached = goal.review?.text, !cached.isEmpty { return cached }
        guard goal.outcome != nil, !inFlight.contains(goal.id) else { return nil }
        inFlight.insert(goal.id)
        defer { inFlight.remove(goal.id) }

        struct Request: Encodable { let mode: String; let block: CoachBlock; let context: CoachContext }
        struct Reply: Decodable { let reply: String }
        let req = Request(mode: "block_review", block: coachBlock(goal: goal, review: review), context: context)

        let reply: Reply
        do {
            reply = try await Supa.client.functions.invoke("coach", options: FunctionInvokeOptions(body: req))
        } catch {
            Telemetry.error("block.review_failed", error)
            return nil
        }
        let text = reply.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        struct Patch: Encodable { let review: BlockRetrospective }
        let cache = BlockRetrospective(text: text, generated_at: BlockCloseout.timestamp.string(from: .now))
        _ = try? await Supa.client.from("goals").update(Patch(review: cache))
            .eq("id", value: goal.id.uuidString).execute()
        return text
    }
}
