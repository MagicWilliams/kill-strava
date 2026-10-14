import CoreLocation
import Foundation

/// The newest fix's accuracy, for the GPS pill on the pre-run sheet and the countdown (#126).
///
/// Its own `CLLocationManager`, separate from the recorder's `RunLocationStream`: the
/// recorder only wakes GPS at the countdown, and the sheet has to say what the signal is
/// before that. Foreground only — no background updates, no blue pill — and stopped as soon
/// as the countdown is over, when the recorder's own stream has taken over. It never asks for
/// permission; that is `LocationPermission`'s job, after the explainer.
///
/// What the reading *means* is `PreRun.signal`; this only reports it.
@MainActor
final class GPSSignalWatcher: NSObject, ObservableObject {
    /// The newest fix's `horizontalAccuracy`, metres. Negative: no position.
    @Published private(set) var accuracyM: Double?
    @Published private(set) var fixAt: Date?

    private let manager = CLLocationManager()
    private var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
    }

    /// Starts only with permission to use location: started without it, Core Location
    /// would do nothing, and on some releases asks — which must only happen after the
    /// explainer.
    func start(access: LocationAccess) {
        guard access.canRecordOutdoors, !running else { return }
        running = true
        manager.startUpdatingLocation()
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
    }

    /// The pill's state at `now`.
    func signal(access: LocationAccess, now: Date) -> PreRun.Signal {
        PreRun.signal(access: access, accuracyM: accuracyM, age: fixAt.map { now.timeIntervalSince($0) })
    }
}

extension GPSSignalWatcher: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let accuracy = last.horizontalAccuracy, at = last.timestamp
        Task { @MainActor in
            self.accuracyM = accuracy
            self.fixAt = at
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `.locationUnknown` is "keep trying": the pill goes to "Finding GPS…" by itself once
        // the last fix is stale. A refusal arrives through `LocationPermission`.
    }
}
