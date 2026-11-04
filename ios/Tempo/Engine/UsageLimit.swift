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
enum UsageLimit {

    struct Refusal: Equatable {
        let message: String
    }

    /// The refusal in a function's error response, or nil if this is any other failure.
    ///
    /// Recognized by the body's code and not by 429 alone: the Supabase gateway has 429s of
    /// its own, and those really are an outage. Telling an athlete they'd hit their limit
    /// when the platform was throttling would be this same mistake in the other direction.
    static func refusal(status: Int, body: Data) -> Refusal? {
        guard status == 429 else { return nil }
        struct Body: Decodable { let error: String?; let message: String? }
        guard let decoded = try? JSONDecoder().decode(Body.self, from: body),
              decoded.error == "usage_limited" else { return nil }
        let message = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Refusal(message: message.isEmpty ? Copy.fallback : message)
    }

    enum Copy {
        static let fallback = "You've reached the coach's limit for now. It resets on its own. Your data is saved, and this isn't a connection problem."
    }
}
