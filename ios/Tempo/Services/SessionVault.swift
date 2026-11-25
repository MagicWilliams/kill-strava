import Foundation
import Security
import Supabase

/// Session storage that does not let the SDK destroy an account's only key.
///
/// Same items in the same place as the storage it wraps, so an installed build's session is
/// found. Two differences: a removed session is moved to a second slot rather than deleted,
/// and `slot(_:)` can tell "nothing there" from "couldn't look". See `SessionLoss`.
///
/// Wrapped at the storage layer because the launch is not the only caller that loses one. The
/// SDK's refresh timer and the token lookup before every request can hit the same error.
struct SessionVault: AuthLocalStorage {
    let base: any AuthLocalStorage
    /// The key the SDK keeps the session under.
    let key: String
    /// Whether `base` holds an item. Asked separately because the Keychain storage throws for
    /// "not found" and for "locked" alike, with an error type the SDK keeps internal.
    let look: @Sendable (_ key: String) -> SessionLoss.Slot

    private var setAsideKey: String { key + ".set-aside" }

    func store(key: String, value: Data) throws { try base.store(key: key, value: value) }

    func retrieve(key: String) throws -> Data? { try base.retrieve(key: key) }

    func remove(key: String) throws {
        // The SDK also keeps a code verifier, and probes a key from its older versions.
        if key == self.key, look(key) != .empty {
            // Throwing leaves the session where it was, which is the safe way to fail.
            guard let session = try base.retrieve(key: key) else { throw Unreadable() }
            try base.store(key: setAsideKey, value: session)
        }
        try base.remove(key: key)
    }

    var stored: SessionLoss.Slot { look(key) }
    var setAside: SessionLoss.Slot { look(setAsideKey) }

    func setAsideSession() throws -> Data? { try base.retrieve(key: setAsideKey) }

    /// Only once the server has said it opens nothing, or has replaced it.
    func discardSetAside() { try? base.remove(key: setAsideKey) }

    private struct Unreadable: Error {}

    // MARK: - Where

    static let keychainService = "supabase.gotrue.swift"

    /// The SDK's own defaults, spelled out because `look` has to query the same item. If either
    /// drifted, every stored session would read as absent; `SessionVaultTests` pins both.
    static func sdkKey(for url: URL) -> String {
        "sb-\((url.host ?? "").split(separator: ".").first ?? "")-auth-token"
    }

    static func keychain(for url: URL) -> SessionVault {
        SessionVault(base: KeychainLocalStorage(service: keychainService), key: sdkKey(for: url)) { key in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: key,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true,
            ]
            var item: AnyObject?
            return slot(for: SecItemCopyMatching(query as CFDictionary, &item))
        }
    }

    static func slot(for status: OSStatus) -> SessionLoss.Slot {
        switch status {
        case errSecSuccess:      return .held
        case errSecItemNotFound: return .empty
        default:                 return .unreadable
        }
    }
}

/// Carries out `SessionLoss` when `auth.session` has thrown.
struct SessionRecovery {
    let vault: SessionVault
    /// Presents a refresh token to the auth server.
    let refresh: @Sendable (_ refreshToken: String) async -> (SessionLoss.Reply, Data)

    func run(after error: Error) async -> SessionLoss.Verdict {
        switch SessionLoss.step(stored: vault.stored, setAside: vault.setAside, failure: Self.name(error)) {
        case .createAccount(let cause): return .createAccount(cause)
        case .hold(let reason):         return .hold(reason)
        case .askServer:                return await askServer()
        }
    }

    private func askServer() async -> SessionLoss.Verdict {
        guard let data = try? vault.setAsideSession(),
              let old = try? JSONDecoder().decode(Session.self, from: data)
        else { return .hold("set_aside_unreadable") }

        let (reply, body) = await refresh(old.refreshToken)
        let verdict = SessionLoss.verdict(on: reply)
        guard verdict == .restore else { return verdict }

        // Stored the way the SDK stores one. If that fails the old token stays set aside, and
        // auth accepts it again because its replacement was never used.
        guard let session = try? AuthClient.Configuration.jsonDecoder.decode(Session.self, from: body),
              let encoded = try? JSONEncoder().encode(session),
              (try? vault.store(key: vault.key, value: encoded)) != nil
        else { return .hold("restore_failed") }
        vault.discardSetAside()
        return .restore
    }

    /// An error as a stable word: no message, so nothing user-typed can ride along.
    static func name(_ error: Error) -> String {
        if let url = error as? URLError { return "url_\(url.code.rawValue)" }
        if let auth = error as? AuthError { return auth.errorCode.rawValue }
        return String(describing: type(of: error))
    }

    /// The SDK's own refresh call, made directly because the SDK reports several
    /// refusals as one `.sessionMissing`.
    static func refresh(
        url: URL, key: String, session: URLSession
    ) -> @Sendable (String) async -> (SessionLoss.Reply, Data) {
        { refreshToken in
            var request = URLRequest(
                url: url.appending(path: "auth/v1/token")
                    .appending(queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")]))
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "apikey")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2024-01-01", forHTTPHeaderField: "X-Supabase-Api-Version")
            request.httpBody = try? JSONEncoder().encode(["refresh_token": refreshToken])
            guard let (body, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return (.none, Data()) }
            struct Refusal: Decodable { let code: String? }
            let code = try? JSONDecoder().decode(Refusal.self, from: body).code
            return (.http(status: http.statusCode, code: code), body)
        }
    }
}
