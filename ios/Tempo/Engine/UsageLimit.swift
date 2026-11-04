import Foundation

/// `coach` or `plan` saying this athlete has used up an allowance for now (migration 0024).
///
/// It gets its own state rather than falling into each caller's catch, because every one of
/// those catches says some version of "couldn't reach the coach". The server was reached and
/// nothing is wrong with the connection, so an athlete who read that would check their signal
/// and try again, for hours. The `LaunchGate` rule: a failure never wears another failure's
/// face.
///
/// The words come from the server, which is the one that knows the limit and when it ends.
///
/// A request over the size cap (`_shared/request_size.ts`) arrives the same way, for the same
/// reason. Nothing real should ever reach it, but if something does, "unreachable" would be
/// just as wrong.
enum UsageLimit {

    struct Refusal: Equatable {
        enum Cause: Equatable {
            /// `usage_limited`: an allowance is used up, and it comes back on its own.
            case allowance
            /// `request_too_large`: this exact request will be refused every time.
            case tooLarge
        }

        let message: String
        var cause: Cause = .allowance

        /// Whether the next request is any more likely to get through than this one was. A
        /// used-up allowance refuses everything behind it, so a backlog should stop and wait.
        /// A request that's too large says nothing about the ones behind it.
        var appliesToLaterRequests: Bool { cause == .allowance }
    }

    /// The refusal in a function's error response, or nil if this is any other failure.
    ///
    /// Recognized by the body's code and not by the status alone: the Supabase gateway has 429s
    /// of its own, and those really are an outage. Telling an athlete they'd hit their limit
    /// when the platform was throttling would be this same mistake in the other direction.
    static func refusal(status: Int, body: Data) -> Refusal? {
        let (code, cause, fallback): (String, Refusal.Cause, String)
        switch status {
        case 429: (code, cause, fallback) = ("usage_limited", .allowance, Copy.fallback)
        case 413: (code, cause, fallback) = ("request_too_large", .tooLarge, Copy.tooLargeFallback)
        default: return nil
        }
        struct Body: Decodable { let error: String?; let message: String? }
        guard let decoded = try? JSONDecoder().decode(Body.self, from: body),
              decoded.error == code else { return nil }
        let message = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Refusal(message: message.isEmpty ? fallback : message, cause: cause)
    }

    enum Copy {
        static let fallback = "You've reached the coach's limit for now. It resets on its own. Your data is saved, and this isn't a connection problem."
        static let tooLargeFallback = "That's more than the coach can read at once. Your data is saved, and this isn't a connection problem."
    }
}
