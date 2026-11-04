import Foundation
import Supabase

/// Holds the athlete's answer about sending data to Anthropic, on the phone and on the server.
/// What the answer means is `CoachConsent`'s; this is the I/O around it.
///
/// A shared instance rather than something hung off `RunStore`, because the thing that has to
/// read it is `CoachGateway`, and that must stay reachable from every service without any of
/// them being handed a store. Not knowing yet reads as `.unknown`, which doesn't send.
@MainActor
final class CoachConsentStore: ObservableObject {
    static let shared = CoachConsentStore()

    @Published private(set) var status: CoachConsent.Status = .unknown

    var maySend: Bool { CoachConsent.maySend(status) }
    var shouldPrompt: Bool { CoachConsent.shouldPrompt(status) }

    private init() {}

    /// Called once per launch before the first screen, so an existing athlete never gets a
    /// flash of the app before the prompt and no background read races the answer.
    func load() async {
        guard let uid = Supa.userID?.uuidString else { return }
        let server = await readServer(uid: uid)
        // The phone's copy is read after the await, not before: an answer given while the read
        // was in flight has to be in this comparison, or the stale result would overwrite it.
        let resolution = CoachConsent.resolve(server: server, local: localRecord(uid: uid))
        status = resolution.status
        if let record = resolution.record { keep(record, uid: uid) }
        if let upload = resolution.upload { await write(upload, uid: uid) }
    }

    /// Look again after a launch that couldn't find out. Otherwise the coach stays off, with
    /// no way to tell, until the next launch.
    func reloadIfUnknown() async {
        guard status == .unknown else { return }
        await load()
    }

    /// Record an answer. On the phone first and in the same tick: the coach can send the moment
    /// this returns, and that can't wait on a round trip that may not land. If the server write
    /// fails, `resolve` sees the disagreement next launch and writes it again.
    func decide(_ decision: CoachConsent.Decision) {
        guard let uid = Supa.userID?.uuidString else { return }
        let record = CoachConsent.Record(decision: decision, at: .now)
        keep(record, uid: uid)
        status = decision == .agreed ? .agreed : .declined
        Telemetry.info("coach.consent_decided", context: ["decision": decision.rawValue])
        Task { await write(record, uid: uid) }
    }

    // MARK: - The phone's copy

    /// By user, so a future account on this phone doesn't inherit someone else's yes.
    private func localKey(uid: String) -> String { "coachConsent.\(uid)" }

    private func localRecord(uid: String) -> CoachConsent.Record? {
        UserDefaults.standard.data(forKey: localKey(uid: uid))
            .flatMap { try? JSONDecoder().decode(CoachConsent.Record.self, from: $0) }
    }

    private func keep(_ record: CoachConsent.Record, uid: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: localKey(uid: uid))
    }

    // MARK: - The server's copy

    /// A query of its own, not part of `loadProfile`'s select: that select decides whether the
    /// app launches at all, and a column from a newer migration must never be able to turn
    /// into "Couldn't load your profile". Same reasoning as `RunStore.loadUnits`.
    private func readServer(uid: String) async -> CoachConsent.ServerRead {
        struct Row: Decodable, Sendable {
            let coach_consent: String?
            let coach_consent_at: Date?
        }
        do {
            let rows: [Row] = try await Deadline.run {
                try await Supa.client
                    .from("profiles")
                    .select("coach_consent,coach_consent_at")
                    .eq("id", value: uid)
                    .limit(1)
                    .execute()
                    .value
            }
            return .record(rows.first.flatMap {
                CoachConsent.record(decision: $0.coach_consent, at: $0.coach_consent_at)
            })
        } catch let error as PostgrestError where RunJournalPayload.isMissingColumn(code: error.code) {
            Telemetry.info("coach.consent_columns_missing")
            return .columnMissing
        } catch {
            Telemetry.errorUnlessCancelled("coach.consent_unreadable", error)
            return .unreadable
        }
    }

    private func write(_ record: CoachConsent.Record, uid: String) async {
        struct Patch: Encodable {
            let coach_consent: String
            let coach_consent_at: String
        }
        do {
            try await Supa.client.from("profiles")
                .update(Patch(
                    coach_consent: record.decision.rawValue,
                    coach_consent_at: ISO8601DateFormatter().string(from: record.at)
                ))
                .eq("id", value: uid)
                .execute()
        } catch let error as PostgrestError where RunJournalPayload.isMissingColumn(code: error.code) {
            Telemetry.info("coach.consent_columns_missing")
        } catch {
            Telemetry.errorUnlessCancelled("coach.consent_write_failed", error)
        }
    }
}
