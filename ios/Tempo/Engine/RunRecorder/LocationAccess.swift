import CoreLocation

/// What Core Location's two answers mean for recording a run (#110).
///
/// Core Location reports permission on two independent axes — *may this app use location*
/// (`CLAuthorizationStatus`) and *how precisely* (`CLAccuracyAuthorization`) — and the pre-run
/// sheet (#126) needs one answer: can this run be recorded outdoors, and if not, what does the
/// athlete do about it. Collapsing the pair here, purely, is what lets that be tested.
///
/// **Reduced accuracy is a refusal for an outdoor run, not a degraded yes.** With Precise
/// Location off, Core Location updates "at most a few times per hour", "usually within 1–20
/// kilometers" (`kCLLocationAccuracyReduced` docs) — distance, pace and splits built from that
/// would be confidently wrong, the exact failure the recorder exists to avoid. So it gets its
/// own state and its own message rather than being lumped in with "granted". Treadmill runs
/// need no location at all and are never blocked by any of this.
enum LocationAccess: Equatable {
    /// Never asked. The pre-run sheet explains, then triggers the system prompt.
    case notDetermined
    /// Refused for Tempo, Location Services off for the whole phone, or Airplane Mode —
    /// Core Location reports all three as `.denied` and can't tell them apart for us.
    case denied
    /// Blocked by Screen Time or a device profile; the athlete may not be able to change it.
    case restricted
    /// Allowed, but Precise Location is off. Unusable outdoors (see above).
    case reducedAccuracy
    /// What Tempo asks for. Enough: a run starts in the foreground, and background updates
    /// keep flowing after the screen locks.
    case whenInUse
    /// More than Tempo asks for — granted some other way. Works the same.
    case always

    static func resolve(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) -> LocationAccess {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorizedWhenInUse, .authorizedAlways:
            // Accuracy only means something once location is allowed at all — before that
            // Core Location's accuracy value is not a decision the athlete made.
            if accuracy == .reducedAccuracy { return .reducedAccuracy }
            return status == .authorizedAlways ? .always : .whenInUse
        @unknown default:
            // A status this build doesn't know. Asking again is harmless — the system only
            // prompts when there is something to decide — and never wrongly records with no GPS.
            return .notDetermined
        }
    }

    /// Whether an outdoor (GPS) run can start right now.
    var canRecordOutdoors: Bool {
        self == .whenInUse || self == .always
    }

    /// Whether tapping "Allow" can produce the system prompt. Once the athlete has answered,
    /// iOS never shows it again; the only way back is Settings.
    var canPrompt: Bool {
        self == .notDetermined
    }

    /// What the pre-run sheet says when an outdoor run can't start; nil when it can, or when
    /// the next step is simply to ask. Every message ends on the way out — treadmill still works.
    var blocker: String? {
        switch self {
        case .notDetermined, .whenInUse, .always:
            return nil
        case .denied:
            return "Tempo can't see your location, so it can't map or measure an outdoor run. Check that Airplane Mode is off, then in Settings › Privacy & Security › Location Services, turn Location Services on and set Tempo to While Using the App. Treadmill runs work without it."
        case .restricted:
            return "Location is restricted on this iPhone (Screen Time or a device profile), so Tempo can't record an outdoor run. Treadmill runs work without it."
        case .reducedAccuracy:
            return "Precise Location is off for Tempo. Approximate location is too coarse to measure distance or pace. Turn on Precise Location in Settings › Privacy & Security › Location Services › Tempo. Treadmill runs work without it."
        }
    }
}
