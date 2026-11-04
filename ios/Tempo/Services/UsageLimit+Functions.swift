import Foundation
import Supabase

extension UsageLimit {
    /// The refusal inside an error from `Supa.client.functions.invoke`, or nil for any other
    /// error, which the caller goes on to handle as the failure it is.
    ///
    /// Logged at `warn` under one name, never through the caller's `Telemetry.error`: a limit
    /// doing its job is not a coach regression, and triage should not have to tell them apart.
    /// `surface` is which caller it was. The message isn't logged, only that it happened.
    static func refusal(from error: Error, surface: String) -> Refusal? {
        guard case let FunctionsError.httpError(code, body) = error,
              let refusal = refusal(status: code, body: body) else { return nil }
        Telemetry.warn("coach.usage_limited", context: ["surface": surface])
        return refusal
    }
}
