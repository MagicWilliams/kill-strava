import Foundation
import UIKit

/// The app's report line back to the people improving it.
///
/// Tempo runs on exactly one phone, so there is no user base to aggregate — which is
/// precisely why this matters. Every bug found so far was found by David noticing a wrong
/// number and then reconstructing what happened from memory. These events make that
/// reconstruction unnecessary: the triage agent reads `app_events`, ranks what recurs, and
/// files the issue with the evidence already attached.
///
/// Rules of the road:
///  - **Fire-and-forget.** Never awaits at a call site, never throws, never blocks a screen.
///    Telemetry that can break the app is worse than no telemetry.
///  - **No health data, no PII.** Counts, durations, ids and enum-ish strings only. Never a
///    pace, a heart rate, a route, or free text the athlete typed.
///  - **Stable keys.** `event` is a dot-path that survives refactors, so trends stay readable
///    across versions. Put the changing part in `context`, not the key.
enum Telemetry {

    /// Log an event. Safe to call from anywhere, including failure paths.
    static func log(
        _ level: Level,
        _ event: String,
        _ detail: String? = nil,
        context: [String: String] = [:]
    ) {
        // Detached so a caller's cancellation (a torn-down view, an abandoned refresh)
        // never silences the report about why it was torn down.
        Task.detached(priority: .background) {
            guard let uid = Supa.userID?.uuidString else { return }
            let row = EventInsert(
                user_id: uid,
                level: level.rawValue,
                event: event,
                detail: detail,
                context: context,
                app_version: Self.appVersion,
                os_version: Self.osVersion
            )
            _ = try? await Supa.client.from("app_events").insert(row).execute()
        }
    }

    static func info(_ event: String, _ detail: String? = nil, context: [String: String] = [:]) {
        log(.info, event, detail, context: context)
    }

    static func warn(_ event: String, _ detail: String? = nil, context: [String: String] = [:]) {
        log(.warn, event, detail, context: context)
    }

    /// Records a caught error. Uses the error's type name rather than its localized
    /// description so the key stays stable and nothing user-typed can leak into it.
    static func error(_ event: String, _ error: Error, context: [String: String] = [:]) {
        var ctx = context
        ctx["error_type"] = String(describing: type(of: error))
        log(.error, event, String(describing: error).prefix(300).description, context: ctx)
    }

    enum Level: String { case info, warn, error }

    // MARK: - Private

    private struct EventInsert: Encodable {
        let user_id: String
        let level: String
        let event: String
        let detail: String?
        let context: [String: String]
        let app_version: String?
        let os_version: String?
    }

    private static let appVersion: String? = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return [v, b].compactMap { $0 }.joined(separator: "+").ifEmptyNil
    }()

    private static let osVersion: String? = UIDevice.current.systemVersion
}

private extension String {
    var ifEmptyNil: String? { isEmpty ? nil : self }
}
