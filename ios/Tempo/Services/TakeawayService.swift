import Foundation
import Supabase

/// Generates and caches the per-run coach takeaway (`runs.coach_takeaway`).
///
/// Two callers: the Run Detail page (passes its already-loaded detail), and
/// RunStore right after a run matches today's session — so the coach's read is
/// already waiting on Today without the athlete ever opening the run.
@MainActor
enum TakeawayService {
    private static var inFlight: Set<UUID> = []

    /// Returns the cached takeaway, or generates + caches one. Nil on failure
    /// (or when another generation for the same run is already running).
    static func ensureTakeaway(for run: RunSummary, detail: RunDetail? = nil, store: RunStore) async -> String? {
        struct Row: Decodable { let coach_takeaway: String?; let correction_note: String? }
        let row: Row? = try? await Supa.client
            .from("runs")
            .select("coach_takeaway,correction_note")
            .eq("id", value: run.id.uuidString)
            .single()
            .execute()
            .value
        if let cached = row?.coach_takeaway { return cached }

        guard !inFlight.contains(run.id) else { return nil }
        inFlight.insert(run.id)
        defer { inFlight.remove(run.id) }

        let d: RunDetail?
        if let detail { d = detail } else { d = await RunDetailLoader().load(run: run, maxHR: store.effectiveMaxHR) }

        struct RunPayload: Encodable {
            let date: String
            let miles: Double
            let avg_pace: String?
            let best_pace: String?
            let moving_time_s: Int?
            let elapsed_time_s: Int?
            let avg_hr: Int?
            let max_hr: Int?
            let zone_minutes: [Double]?
            let elev_gain_ft: Int?
            let cadence_spm: Int?
            let splits: [String]?
            let corrected_note: String?
        }
        struct Request: Encodable { let mode: String; let run: RunPayload; let context: CoachContext }
        struct Reply: Decodable { let reply: String }

        // Corrected DB totals win over raw HealthKit (which only saw the recorded portion).
        let payload = RunPayload(
            date: run.start.formatted(date: .abbreviated, time: .shortened),
            miles: ((run.corrected ? run.miles : (d?.miles ?? run.miles)) * 100).rounded() / 100,
            avg_pace: (run.corrected ? run.paceSecPerMile : (d?.avgPaceSec ?? run.paceSecPerMile)).map(PaceModel.format),
            best_pace: d?.bestPaceSec.map(PaceModel.format),
            moving_time_s: d?.movingS,
            elapsed_time_s: d?.elapsedS,
            avg_hr: run.avgHR ?? d?.avgHR,
            max_hr: d?.maxHR,
            zone_minutes: d.map { $0.zoneSeconds.map { ($0 / 60 * 10).rounded() / 10 } },
            elev_gain_ft: d?.elevGainM.map { Int($0 * 3.28084) },
            cadence_spm: d?.cadenceSPM,
            splits: d.map { $0.splits.map { s in "mi \(s.id): \(PaceModel.format(s.paceSec))\(s.avgHR.map { " @ \($0) bpm" } ?? "")" } },
            corrected_note: row?.correction_note
        )

        guard let reply: Reply = try? await Supa.client.functions.invoke(
            "coach",
            options: FunctionInvokeOptions(body: Request(mode: "takeaway", run: payload, context: store.coachContext()))
        ), !reply.reply.isEmpty else { return nil }

        struct Patch: Encodable { let coach_takeaway: String }
        _ = try? await Supa.client.from("runs").update(Patch(coach_takeaway: reply.reply))
            .eq("id", value: run.id.uuidString).execute()
        return reply.reply
    }
}
