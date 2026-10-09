import Foundation

/// The App Group hand-off between the app (writer) and `TempoWidgets` (reader).
///
/// Kept apart from `WidgetSnapshot.swift` because this is the only part that touches I/O.
/// A snapshot that fails to decode — a field added in a later build, a truncated write —
/// reads as `nil`, which the widget renders as "Open Tempo", never as zeros.
enum WidgetSnapshotStore {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.appGroup) }

    static func load() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: WidgetSnapshot.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: WidgetSnapshot.defaultsKey)
    }
}
