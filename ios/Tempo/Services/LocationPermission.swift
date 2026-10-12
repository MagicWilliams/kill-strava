import CoreLocation
import Foundation

/// Location permission for the run recorder, as one `LocationAccess` value (#110).
///
/// Exists so the pre-run sheet (#126) can explain *why* before iOS asks: the system prompt
/// appears once, ever — an athlete who taps "Don't Allow" on a prompt that came out of nowhere
/// can only undo it in Settings. Nothing here starts location updates; that is the recorder's
/// job (#114), on its own manager.
///
/// When In Use only, never Always. See `NSLocationWhenInUseUsageDescription` in project.yml.
@MainActor
final class LocationPermission: NSObject, ObservableObject {
    @Published private(set) var access: LocationAccess

    private let manager: CLLocationManager
    private var waiting: CheckedContinuation<LocationAccess, Never>?

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        access = LocationAccess.resolve(status: manager.authorizationStatus,
                                        accuracy: manager.accuracyAuthorization)
        super.init()
        manager.delegate = self
    }

    /// Shows the system prompt if the athlete has never answered, and returns once they have.
    /// Otherwise returns the current answer at once: iOS won't prompt twice, and asking again
    /// would never call back (Core Location only reports *changes*), leaving this hung.
    @discardableResult
    func request() async -> LocationAccess {
        guard access.canPrompt else { return access }
        return await withCheckedContinuation { continuation in
            // A second tap while the prompt is up: settle the first caller, keep the newest.
            waiting?.resume(returning: access)
            waiting = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    private func update(_ next: LocationAccess) {
        access = next
        // Creating the manager also calls back, with `.notDetermined` — not an answer.
        guard !next.canPrompt, let waiting else { return }
        self.waiting = nil
        waiting.resume(returning: next)
    }
}

extension LocationPermission: CLLocationManagerDelegate {
    /// Fires on creation and on every change, including ones made in Settings while Tempo
    /// was in the background — so `access` stays current without polling.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let next = LocationAccess.resolve(status: manager.authorizationStatus,
                                          accuracy: manager.accuracyAuthorization)
        Task { @MainActor in self.update(next) }
    }
}
