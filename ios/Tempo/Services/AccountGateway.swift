import Foundation
import Supabase

/// The only way to the `delete-account` edge function, and the second of the app's two
/// named paths to the functions client.
///
/// Deliberately not routed through `CoachGateway`. That gate asks whether the athlete agreed
/// to send data to Anthropic, and this call sends none: it names no run, no message and no
/// number, and reaches no model. Putting it behind consent would make "stop holding my data"
/// the one request a decline could refuse.
///
/// Two paths and not a free-for-all: `CoachConsentTests` pins the pair by name, so a third
/// file reaching for the functions client still fails the build the way it did when there
/// was one.
enum AccountGateway {
    static let function = "delete-account"

    /// The function reads the caller's id from the JWT and ignores this entirely. It is here
    /// because a request with a body is unambiguously the POST the function accepts.
    private struct Request: Encodable {
        let confirm = true
    }

    /// The reply, read loosely so a body from anything but this function fails closed:
    /// `AccountDeletion.outcome` treats a missing flag as a failure.
    private struct Reply: Decodable {
        let deleted: Bool?
    }

    /// Asks the server to delete this account. Throws what the functions client throws,
    /// including a non-2xx, which is how a refused or half-finished deletion arrives.
    static func deleteAccount() async throws -> AccountDeletion.Outcome {
        let reply: Reply = try await Supa.client.functions.invoke(
            function,
            options: FunctionInvokeOptions(body: Request())
        )
        return AccountDeletion.outcome(deleted: reply.deleted)
    }
}
