import Foundation
import Supabase

/// I/O for the weekly coach review (#91): read what is on file, write the review a finished
/// week is owed, and mark one read.
///
/// Every decision is in `Engine/WeeklyReview.swift` — which week is owed one, whether the week
/// had anything in it, what the numbers are. This file reads rows, spends the one model round
/// trip, and stores what comes back.
///
/// Reads degrade rather than throw where the screen can still be honest about it, and throw
/// where it cannot, the rule `CoachThreadService` follows: "no review yet" and "the server did
/// not answer" are different rows on Coach home, and before migration 0026 is applied the read
/// fails outright, which has to read as the former.
@MainActor
enum WeeklyReviewService {

    static let columns = "id,week_of,headline,body,stats,read_at"

    private struct Row: Decodable {
        let id: UUID
        /// A `date` column, so it arrives as "2026-11-09" and is parsed by the day formatter
        /// rather than the client's timestamp decoding, which would reject it.
        let week_of: String
        let headline: String
        let body: WeeklyReview.Sections
        let stats: WeeklyReview.Stats
        let read_at: Date?

        /// Nil for a row whose `week_of` cannot be read as a day, which nothing in the app
        /// writes. A review that cannot say which week it covers is not one.
        var written: WeeklyReview.Written? {
            guard let day = PlanDates.day.date(from: week_of) else { return nil }
            return WeeklyReview.Written(
                id: id,
                weekOf: RunHistory.weekStart(of: day),
                headline: headline,
                sections: body,
                stats: stats,
                readAt: read_at
            )
        }
    }

    // MARK: - Reads

    /// The newest review on file, or nil when there is none at all.
    ///
    /// Throws on an unreadable table, including before migration 0026 is applied. The caller
    /// keeps the Coach home row quiet in that case: a missing table is not a review.
    static func latest() async throws -> WeeklyReview.Written? {
        let rows: [Row] = try await Supa.client
            .from("weekly_reviews")
            .select(columns)
            .order("week_of", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first?.written
    }

    private struct ReadPatch: Encodable { let read_at: String }

    /// Mark a review as read, which is what takes the dot off the Coach home row.
    ///
    /// Fire-and-forget: the athlete is reading the review as this goes out, and making them
    /// wait on it would put a round trip in front of the screen. `is("read_at", nil)` keeps
    /// the first open: re-opening a review should not restamp when it was first read.
    static func markRead(_ id: UUID, at date: Date = .now) {
        Task {
            _ = try? await Supa.client
                .from("weekly_reviews")
                .update(ReadPatch(read_at: ISO8601DateFormatter().string(from: date)))
                .eq("id", value: id.uuidString)
                .is("read_at", value: nil)
                .execute()
        }
    }

    // MARK: - Writing the week that finished

    /// What the store already holds, handed over as a value so the write path reads nothing
    /// it does not have to.
    struct Inputs {
        let runs: [RunSummary]
        let plan: PlanInfo?
        let planWeeks: [PlanWeekInfo]
        let goal: GoalInfo?
        /// Taken as a value, as `BlockReviewService.retrospective` does: the context describes
        /// the athlete at the moment the review is asked for.
        let context: CoachContext
    }

    enum Outcome {
        case written(WeeklyReview.Written)
        /// No week is owed a review, the week had nothing in it, or the coach is off.
        case nothingDue
        case limited(UsageLimit.Refusal)
        case failed
    }

    /// Weeks currently being written up, so two Coach appearances cannot spend two Anthropic
    /// requests on the same week. The unique constraint on `(user_id, week_of)` is the backstop
    /// for the race this does not cover: two devices, or a process restarted mid-write.
    private static var writing: Set<Date> = []

    /// Write the review the finished week is owed, if it is owed one.
    ///
    /// Called when Coach home appears, which is the same trigger the thread write-ups use and
    /// for the same reason: it is the moment the review can be written *and* read. The first
    /// appearance on or after Monday writes last week's; every appearance after that finds the
    /// row already there and spends nothing.
    static func writeIfDue(
        latest: WeeklyReview.Written?,
        inputs: Inputs,
        now: Date = .now
    ) async -> Outcome {
        guard let week = WeeklyReview.weekAwaitingReview(latestWeekOf: latest?.weekOf, now: now) else {
            return .nothingDue
        }
        // The gateway would refuse the call anyway, but only after reading a week of sessions
        // and the whole ledger to build it.
        guard CoachConsentStore.shared.maySend else { return .nothingDue }
        guard !writing.contains(week) else { return .nothingDue }
        writing.insert(week)
        defer { writing.remove(week) }

        let calendar = RunHistory.calendar
        let sessions = await Self.sessions(planID: inputs.plan?.id, from: week, calendar: calendar)
        let applied = (try? await CoachThreadService.applied()) ?? []
        let entries = ChangeLedger.entries(from: applied.map(\.record))
        let recaps = await Self.recaps(inWeek: week, calendar: calendar)

        let weekEnd = calendar.date(byAdding: .day, value: 6, to: week) ?? week
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: week) ?? week
        let weekEntries = entries.filter {
            RunHistory.weekStart(of: $0.date, calendar: calendar) == week
        }
        let stats = WeeklyReview.stats(
            weekStart: week,
            runs: inputs.runs,
            sessions: sessions.map(BlockReview.PlannedSession.init),
            plannedMiles: WeeklyReview.plannedMiles(
                weekStart: week, planStart: inputs.plan?.startDate, weeks: inputs.planWeeks, calendar: calendar
            ),
            changes: weekEntries.count,
            // Form before the week's first run against form after its last: the week's own
            // effect on fatigue, which is what the tile is for. `checkInOK` is nil because it
            // only ever caps readiness, and a check-in made today says nothing about a week
            // that has already finished.
            formStart: LoadModel.compute(runs: inputs.runs, checkInOK: nil, now: dayBefore)?.form,
            formEnd: LoadModel.compute(runs: inputs.runs, checkInOK: nil, now: weekEnd)?.form,
            calendar: calendar
        )
        guard WeeklyReview.isWorthWriting(stats) else { return .nothingDue }

        let payload = Self.coachWeek(
            week: week, stats: stats, sessions: sessions, entries: weekEntries,
            recaps: recaps, inputs: inputs, now: now, calendar: calendar
        )

        struct Request: Encodable { let mode: String; let week: CoachWeek; let context: CoachContext }
        /// All four keys absent is the function saying it had nothing worth storing.
        struct Reply: Decodable {
            let headline: String?
            let training: String?
            let plan_moved: String?
            let next_week: String?
        }

        let reply: Reply
        do {
            reply = try await CoachGateway.invoke(
                .coach, body: Request(mode: "review", week: payload, context: inputs.context)
            )
        } catch is CoachGateway.ConsentRequired {
            return .nothingDue
        } catch {
            if let refusal = UsageLimit.refusal(from: error, surface: "review") { return .limited(refusal) }
            Telemetry.errorUnlessCancelled("coach.weekly_review_failed", error)
            return .failed
        }
        guard let headline = reply.headline, let training = reply.training,
              let planMoved = reply.plan_moved, let nextWeek = reply.next_week,
              !headline.isEmpty, !training.isEmpty, !planMoved.isEmpty, !nextWeek.isEmpty else {
            // Not an error: `review.ts` refuses anything half-formed, and the week is simply
            // offered to the next appearance. Logged because a model that never returns a
            // usable review would otherwise look like a Coach row that just never fills in.
            Telemetry.warn("coach.weekly_review_unusable", "no headline/sections in the reply")
            return .nothingDue
        }

        return await Self.store(
            week: week,
            headline: headline,
            sections: WeeklyReview.Sections(training: training, planMoved: planMoved, nextWeek: nextWeek),
            stats: stats
        )
    }

    // MARK: - The pieces the review is built from

    /// The plan's sessions for the reviewed week and the one after it, read straight from the
    /// table rather than from `RunStore.sessions`.
    ///
    /// The store holds a −7…+14 day window around today, which is a window that does not
    /// reliably contain last week: a review written on Thursday would be measuring adherence
    /// against the three days of it the window still reaches. This read is anchored on the
    /// week itself.
    private static func sessions(planID: UUID?, from week: Date, calendar: Calendar) async -> [SessionInfo] {
        guard let planID else { return [] }
        let end = calendar.date(byAdding: .day, value: 14, to: week) ?? week
        do {
            return try await Supa.client
                .from("sessions")
                .select("id,date,type,title,target_distance_m,target_pace_sec,structure,status,run_id,adapted,adaptation_note")
                .eq("plan_id", value: planID.uuidString)
                .gte("date", value: PlanDates.day.string(from: week))
                .lt("date", value: PlanDates.day.string(from: end))
                .order("date")
                .execute()
                .value
        } catch {
            // A review without the plan side is still a review of the running; it just cannot
            // say what was planned. Better than no review at all.
            Telemetry.errorUnlessCancelled("coach.weekly_review_sessions_unreadable", error)
            return []
        }
    }

    /// The recaps of conversations that happened during the week, so the review can account
    /// for what was discussed and not only for what was changed.
    private static func recaps(inWeek week: Date, calendar: Calendar) async -> [String] {
        guard let threads = try? await CoachThreadService.threads() else { return [] }
        return threads
            .filter { RunHistory.weekStart(of: $0.lastMessageAt, calendar: calendar) == week }
            .compactMap(CoachThreads.recapText)
    }

    // MARK: - What the coach is told

    /// The week as the model reads it: the numbers already computed, the sessions as planned
    /// and as they ended, the changes the coach itself applied, and what the plan says next.
    ///
    /// The runs themselves are not repeated here. `CoachContext.recent_runs` already carries
    /// the last 21 days with paces, heart rates and whatever the athlete said after each one,
    /// and the review is sent with that context — a second copy would be the same rows in two
    /// shapes, against a request size the function caps (#276).
    struct CoachWeek: Encodable {
        struct SessionLine: Encodable {
            let date: String
            let type: String
            let status: String
            /// Present only when the coach changed this session, with its own note for why.
            let changed: String?
        }
        struct ChangeLine: Encodable {
            let date: String
            let kind: String
            let title: String
            let detail: String?
            let why: String?
        }
        struct NextWeek: Encodable {
            let phase: String?
            let planned_mi: Double?
            let sessions: [SessionLine]
        }
        struct Race: Encodable {
            let name: String
            let date: String
            let days_away: Int
        }

        let week_of: String
        let phase: String?
        let miles: Double
        let planned_mi: Double?
        let runs: Int
        /// "4 of 5", or absent when the week had no plan to follow.
        let sessions_done: String?
        let sessions: [SessionLine]
        let changes: [ChangeLine]
        let conversations: [String]
        let form_start: Double?
        let form_end: Double?
        let next_week: NextWeek?
        let race: Race?
    }

    private static func coachWeek(
        week: Date,
        stats: WeeklyReview.Stats,
        sessions: [SessionInfo],
        entries: [ChangeLedger.Entry],
        recaps: [String],
        inputs: Inputs,
        now: Date,
        calendar: Calendar
    ) -> CoachWeek {
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted)
        func one(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        func line(_ s: SessionInfo) -> CoachWeek.SessionLine {
            CoachWeek.SessionLine(
                date: s.day.formatted(day),
                type: s.type,
                status: s.status,
                changed: s.adapted ? (s.adaptation_note ?? "changed") : nil
            )
        }

        let nextWeekStart = calendar.date(byAdding: .day, value: 7, to: week) ?? week
        let thisWeek = sessions.filter { RunHistory.weekStart(of: $0.day, calendar: calendar) == week }
        let next = sessions.filter { RunHistory.weekStart(of: $0.day, calendar: calendar) == nextWeekStart }
        let raceDay = inputs.goal?.raceDay

        return CoachWeek(
            week_of: week.formatted(day),
            phase: WeeklyReview.phaseLabel(
                weekStart: week, planStart: inputs.plan?.startDate,
                weeks: inputs.planWeeks, raceDay: raceDay, calendar: calendar
            ),
            miles: one(stats.miles),
            planned_mi: stats.plannedMiles.map(one),
            runs: stats.runCount,
            sessions_done: WeeklyReview.sessionsLine(stats),
            sessions: thisWeek.map(line),
            changes: entries.map {
                CoachWeek.ChangeLine(
                    date: $0.date.formatted(day),
                    kind: $0.kind.label,
                    title: $0.title,
                    detail: $0.changes.isEmpty ? nil : $0.beforeAfter,
                    why: $0.why
                )
            },
            conversations: recaps,
            form_start: stats.formStart.map(one),
            form_end: stats.formEnd.map(one),
            next_week: next.isEmpty && inputs.plan == nil ? nil : CoachWeek.NextWeek(
                phase: WeeklyReview.phaseLabel(
                    weekStart: nextWeekStart, planStart: inputs.plan?.startDate,
                    weeks: inputs.planWeeks, raceDay: raceDay, calendar: calendar
                ),
                planned_mi: WeeklyReview.plannedMiles(
                    weekStart: nextWeekStart, planStart: inputs.plan?.startDate,
                    weeks: inputs.planWeeks, calendar: calendar
                ).map(one),
                sessions: next.map(line)
            ),
            race: raceDay.map { raceDay in
                CoachWeek.Race(
                    name: inputs.goal?.raceName ?? RaceCountdown.unnamedRace,
                    date: raceDay.formatted(day),
                    days_away: calendar.dateComponents(
                        [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: raceDay)
                    ).day ?? 0
                )
            }
        )
    }

    // MARK: - Storing it

    private struct Insert: Encodable {
        let user_id: String
        let week_of: String
        let headline: String
        let body: WeeklyReview.Sections
        let stats: WeeklyReview.Stats
    }

    /// Insert the review and hand back the row as stored.
    ///
    /// A unique violation is the expected failure, not an error: it means another appearance
    /// (or another device) wrote this week's review first. The winner's row is what the screen
    /// should show, so the loser re-reads instead of reporting a failure.
    private static func store(
        week: Date,
        headline: String,
        sections: WeeklyReview.Sections,
        stats: WeeklyReview.Stats
    ) async -> Outcome {
        guard let uid = Supa.userID?.uuidString else { return .failed }
        let row = Insert(
            user_id: uid,
            week_of: PlanDates.day.string(from: week),
            headline: headline,
            body: sections,
            stats: stats
        )
        do {
            let stored: Row = try await Supa.client
                .from("weekly_reviews")
                .insert(row)
                .select(columns)
                .single()
                .execute()
                .value
            guard let written = stored.written else { return .failed }
            return .written(written)
        } catch {
            if let existing = try? await latest(), existing.weekOf == week {
                return .written(existing)
            }
            Telemetry.error("coach.weekly_review_unsaved", error)
            return .failed
        }
    }
}
