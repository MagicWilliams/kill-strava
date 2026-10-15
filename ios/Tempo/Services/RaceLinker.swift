import Foundation
import Supabase

/// The I/O half of filing a Race-mode run as its block's race (#117): one column on one goal.
/// Which goal, which run, and whether at all is `RaceFinish.link`.
@MainActor
enum RaceLinker {

    /// `goals.race_run_id = link.runID`, then the same on the goal in memory so the recap door
    /// and the close-out read it before the next refresh.
    ///
    /// Through the athlete's own session, so the "own goals" policy (0001) scopes the write:
    /// a goal id that isn't his matches nothing. `completed_at is null` keeps it off a block
    /// closed in the meantime, whose race is the close-out's to record.
    ///
    /// Best-effort. A failure costs the explicit link and nothing else: the run is saved, and
    /// the recap and the close-out still find it by date and distance (`RaceRecap.isRace`).
    static func link(_ link: RaceFinish.Link, store: RunStore) async {
        struct Patch: Encodable { let race_run_id: String }
        struct IDRow: Decodable { let id: UUID }
        do {
            let updated: [IDRow] = try await Supa.client
                .from("goals")
                .update(Patch(race_run_id: link.runID.uuidString))
                .eq("id", value: link.goalID.uuidString)
                .is("completed_at", value: nil)
                .select("id")
                .execute()
                .value
            // No row back: closed since the run started, or not his. Nothing was written, so
            // nothing changes on screen either.
            guard !updated.isEmpty else {
                Telemetry.warn("recorder.race_link_unmatched")
                return
            }
            store.goal = RaceFinish.applying(link, to: store.goal)
            Telemetry.info("recorder.race_linked")
        } catch {
            Telemetry.error("recorder.race_link_failed", error)
        }
    }
}
