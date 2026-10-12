import Foundation
import Supabase

/// The athlete's shoes (#121): read, add, retire, and which pair is the default.
///
/// I/O only. Mileage, the retirement nudge, which default survives a retirement, and what a
/// valid new pair looks like are all decided in `Engine/ShoeMileage.swift` and pinned there.
/// Mileage is not read from here at all — it is summed from the runs `RunStore` already
/// holds, so it moves the moment a run syncs.
///
/// ## Where the default lives
///
/// On this device, in `UserDefaults`, not in the database. `shoes` (0016) has no column for
/// it, and one preference on an iPhone-only app did not justify a schema change. When the
/// Watch arrives and needs the same answer, it moves to `profiles`.
@MainActor
final class ShoeStore: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, unavailable }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var shoes: [Shoe] = []
    @Published private var storedDefaultID: UUID?

    /// Read by the post-run picker too — see `ShoeMileage.resolvedDefault`.
    static let defaultShoeKey = "shoes.defaultShoeID"
    /// Miles at which a pair is nudged toward retirement. Clamped by `ShoeMileage`.
    static let retirementMilesKey = "shoes.retirementMiles"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedDefaultID = defaults.string(forKey: Self.defaultShoeKey).flatMap(UUID.init(uuidString:))
    }

    /// The pair the post-run picker should preselect, or nil.
    var defaultShoeID: UUID? {
        ShoeMileage.resolvedDefault(storedID: storedDefaultID, shoes: shoes)
    }

    // MARK: - Read

    private struct Row: Decodable {
        let id: UUID
        let name: String
        let brand: String?
        let model: String?
        let started_at: Date
        let retired_at: Date?
        let start_mileage_m: Int

        var shoe: Shoe {
            Shoe(id: id, name: name, brand: brand, model: model, startedAt: started_at,
                 retiredAt: retired_at, startMileageM: start_mileage_m)
        }
    }

    private static let columns = "id,name,brand,model,started_at,retired_at,start_mileage_m"

    func load() async {
        if shoes.isEmpty { phase = .loading }
        do {
            // RLS ("own shoes") scopes this to the signed-in athlete.
            let rows: [Row] = try await Supa.client
                .from("shoes")
                .select(Self.columns)
                .execute()
                .value
            shoes = rows.map(\.shoe)
            phase = .ready
        } catch {
            Telemetry.error("shoes.load_failed", error)
            // Keep what was on screen if a refresh fails; only an empty list says so.
            phase = shoes.isEmpty ? .unavailable : .ready
        }
    }

    // MARK: - Write

    /// Insert a new pair. Returns whether it landed; on success it is in `shoes`.
    func add(_ draft: ShoeMileage.Draft) async -> Bool {
        guard let uid = Supa.userID else { return false }
        struct Insert: Encodable {
            let user_id: String
            let name: String
            let start_mileage_m: Int
        }
        do {
            // `started_at` is left to the server's `now()`; `retiredAt(now:startedAt:)`
            // is what keeps a later retirement from falling before it.
            let row: Row = try await Supa.client
                .from("shoes")
                .insert(Insert(user_id: uid.uuidString.lowercased(),
                               name: draft.name,
                               start_mileage_m: draft.startMileageM))
                .select(Self.columns)
                .single()
                .execute()
                .value
            shoes.append(row.shoe)
            phase = .ready
            return true
        } catch {
            Telemetry.error("shoes.add_failed", error)
            return false
        }
    }

    /// Retire a pair. Its runs keep their tag and the pair keeps its mileage; it just stops
    /// being offered after a run. If it was the default, there is no default any more.
    func retire(_ shoe: Shoe) async -> Bool {
        struct Patch: Encodable { let retired_at: String }
        let retiredAt = ShoeMileage.retiredAt(now: .now, startedAt: shoe.startedAt)
        do {
            try await Supa.client
                .from("shoes")
                .update(Patch(retired_at: ISO8601DateFormatter().string(from: retiredAt)))
                .eq("id", value: shoe.id.uuidString)
                .execute()
        } catch {
            Telemetry.error("shoes.retire_failed", error)
            return false
        }
        if let i = shoes.firstIndex(where: { $0.id == shoe.id }) { shoes[i].retiredAt = retiredAt }
        if storedDefaultID == shoe.id { setDefault(nil) }
        return true
    }

    /// Make a pair the default, or clear it with nil.
    func setDefault(_ id: UUID?) {
        storedDefaultID = id
        if let id {
            defaults.set(id.uuidString, forKey: Self.defaultShoeKey)
        } else {
            defaults.removeObject(forKey: Self.defaultShoeKey)
        }
    }
}
