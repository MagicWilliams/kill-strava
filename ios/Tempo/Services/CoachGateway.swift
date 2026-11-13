import Foundation
import Supabase

/// The only way to the `coach` and `plan` edge functions, both of which call Anthropic's Claude.
///
/// There are five call sites and one of them runs with no screen open at all: a takeaway
/// generated in the background the moment a run syncs. A check on each screen would be a check
/// somebody forgets on the next one, so the check lives here and `CoachConsentTests` fails the
/// build if anything reaches for the functions client from outside the two named gateways.
///
/// The other one is `AccountGateway`, which calls `delete-account` (#295). It is outside this
/// gate because it sends no athlete data and reaches no model, and because a decline must not
/// be able to refuse someone asking to have their data deleted.
enum CoachGateway {
    enum Function: String {
        case coach
        case plan
    }

    /// The athlete hasn't agreed, so nothing was sent. Not a failure of the coach, and callers
    /// don't report it as one: the screens already say why the coach is off.
    struct ConsentRequired: Error {}

    static func invoke<Reply: Decodable>(_ function: Function, body: some Encodable) async throws -> Reply {
        guard await CoachConsentStore.shared.maySend else {
            Telemetry.info("coach.call_blocked", context: ["function": function.rawValue])
            throw ConsentRequired()
        }
        return try await Supa.client.functions.invoke(function.rawValue, options: FunctionInvokeOptions(body: body))
    }
}
