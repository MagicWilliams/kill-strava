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

    /// How long to wait for a deletion. `Supa`'s session gives up on any request after thirty
    /// seconds, and a long photo journal can take longer to remove than that. Giving up early
    /// reports a deletion that is going fine as one that couldn't be confirmed.
    private static let limit: TimeInterval = 120

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = limit
        config.timeoutIntervalForResource = limit
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Asks the server to delete this account. Throws what the functions client throws,
    /// including a non-2xx, which is how a refused or half-finished deletion arrives.
    ///
    /// A functions client of its own, for `limit` and nothing else: `Supa.client.functions`
    /// would bring the shorter session with it.
    static func deleteAccount() async throws -> AccountDeletion.Outcome {
        let token = try await Supa.client.auth.session.accessToken
        let client = FunctionsClient(
            url: SupabaseConfig.url.appendingPathComponent("functions/v1"),
            headers: ["apikey": SupabaseConfig.publishableKey, "Authorization": "Bearer \(token)"],
            region: Optional<String>.none,
            fetch: { try await session.data(for: $0) }
        )
        let reply: Reply = try await client.invoke(
            function,
            options: FunctionInvokeOptions(body: Request(), timeoutInterval: limit)
        )
        return AccountDeletion.outcome(deleted: reply.deleted)
    }

    /// Whether the account this phone holds a session for still exists, from the auth server
    /// itself. Changes nothing, which is why a launch may ask it (`RunStore.settleDeletion`).
    static func standing() async -> AccountDeletion.Standing {
        do {
            _ = try await Deadline.run { try await Supa.client.auth.user() }
            return .exists
        } catch let error as AuthError {
            return AccountDeletion.standing(authErrorCode: error.errorCode.rawValue)
        } catch {
            return .unknown
        }
    }

    // MARK: - The request, on disk until it is settled

    static var asked: AccountDeletion.Asked? {
        get {
            UserDefaults.standard.data(forKey: AccountDeletion.askedKey)
                .flatMap { try? JSONDecoder().decode(AccountDeletion.Asked.self, from: $0) }
        }
        set {
            guard let data = newValue.flatMap({ try? JSONEncoder().encode($0) }) else {
                UserDefaults.standard.removeObject(forKey: AccountDeletion.askedKey)
                return
            }
            UserDefaults.standard.set(data, forKey: AccountDeletion.askedKey)
        }
    }
}
