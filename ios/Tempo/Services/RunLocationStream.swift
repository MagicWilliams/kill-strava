import CoreLocation
import Foundation

/// GPS for a recording run (#114): the real `RunLocationStreaming`.
///
/// Its own `CLLocationManager`, separate from `LocationPermission`'s, which only ever asks.
/// Every setting here is a guard against a run that silently stops measuring:
///
/// - `pausesLocationUpdatesAutomatically = false`. The default lets iOS decide the athlete
///   has stopped and quietly suspend updates. A recorder that pauses itself is how Chicago
///   was lost (#111); only the athlete pauses a run.
/// - `allowsBackgroundLocationUpdates = true`, set only while a run is recording, so updates
///   keep flowing with the phone locked in a pocket (blue pill). Needs the `location`
///   background mode (project.yml, #110) and When In Use, which a run started from the
///   foreground has.
/// - Updates keep flowing while the run is paused. Restarting them from the background is
///   not allowed with When In Use, so stopping on pause could mean never getting them back.
///   The recorder ignores fixes while paused instead.
/// - Best accuracy, no distance filter, `.fitness`: every fix goes to `TrackMath`, which does
///   all of the filtering, in one place, under test.
@MainActor
final class RunLocationStream: NSObject, RunLocationStreaming {
    var onLocations: (([CLLocation]) -> Void)?
    var onAccess: ((LocationAccess) -> Void)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }
}

extension RunLocationStream: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.onLocations?(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let access = LocationAccess.resolve(status: manager.authorizationStatus,
                                            accuracy: manager.accuracyAuthorization)
        Task { @MainActor in self.onAccess?(access) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `.locationUnknown` is transient ("keep trying"); the recorder already treats a
        // gap in fixes as a gap. A real denial arrives through the authorization callback.
    }
}
