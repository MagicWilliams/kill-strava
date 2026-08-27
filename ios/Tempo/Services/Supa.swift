import Foundation
import Supabase

/// Shared Supabase client. Auth, Postgres (PostgREST), and Edge Functions all hang off this.
enum Supa {
    static let client = SupabaseClient(
        supabaseURL: SupabaseConfig.url,
        supabaseKey: SupabaseConfig.publishableKey,
        options: SupabaseClientOptions(
            // Opt in to the non-deprecated behavior: always emit the locally stored
            // session immediately (uses the default Keychain storage, so our anonymous
            // session still persists across launches). Silences the supabase-swift
            // deprecation warning; becomes the default in the next major version.
            auth: SupabaseClientOptions.AuthOptions(
                storage: sessionStorage,
                emitLocalSessionAsInitialSession: true
            ),
            global: SupabaseClientOptions.GlobalOptions(session: session)
        )
    )

    /// `URLSession.shared` waits 60s per request and 7 days for a resource. A paused or
    /// unreachable project then reads as a hang rather than a failure — which is exactly
    /// how the 2026-08-23 splash freeze presented. Fail fast enough to show a retry.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false   // offline is an answer, not something to wait for
        return URLSession(configuration: config)
    }()

    /// Where the auth session is persisted.
    ///
    /// supabase-swift stores the session in the Keychain by default. In the iOS Simulator
    /// that write fails silently: `signInAnonymously()` returns a perfectly good session,
    /// and one line later `auth.session` and `auth.currentUser` are both empty — so every
    /// call that guards on `Supa.userID` quietly does nothing, and the launch gate reports
    /// "Couldn't load your profile" for a profile it never asked for.
    ///
    /// The Keychain is right on a device and stays there. This swap is simulator-only,
    /// matching the backend split in SupabaseConfig: the simulator is a throwaway
    /// environment, and an anonymous token in its UserDefaults is not a secret worth
    /// protecting.
    private static var sessionStorage: any AuthLocalStorage {
        #if targetEnvironment(simulator)
        return SimulatorSessionStorage()
        #else
        return AuthClient.Configuration.defaultLocalStorage
        #endif
    }

    /// Current signed-in user id, if any.
    static var userID: UUID? {
        client.auth.currentUser?.id
    }

    /// Ensure a session exists. Beta-of-one: anonymous auth (the session persists in the
    /// keychain across launches). Replaced by Sign in with Apple before TestFlight.
    ///
    /// Returns whether we ended up with a usable session — the launch gate needs to tell
    /// "signed in" from "couldn't reach auth", and a `Bool` is the whole difference between
    /// showing a retry and showing a splash forever.
    @discardableResult
    static func signInAnonymouslyIfNeeded() async -> Bool {
        if (try? await client.auth.session) != nil { return true }
        do {
            _ = try await client.auth.signInAnonymously()
            // Verify the session actually landed rather than trusting the call that made it.
            // A sign-in that succeeds on the wire but cannot be read back is, to every
            // caller downstream, identical to never having signed in — they all guard on
            // `Supa.userID`. Returning `true` there reports a success we cannot back up, and
            // the athlete gets "Couldn't load your profile" for a profile nothing ever asked
            // for. Same rule as LaunchGate: a failure must never wear another failure's face.
            return (try? await client.auth.session) != nil
        } catch {
            Telemetry.error("auth.anonymous_sign_in_failed", error)
            return false
        }
    }

    /// Ensure a `profiles` row exists for the current user (holds risk_tolerance etc.).
    static func ensureProfile() async {
        guard let uid = userID?.uuidString else { return }
        struct ProfileInsert: Encodable { let id: String }
        _ = try? await client
            .from("profiles")
            .upsert(ProfileInsert(id: uid), onConflict: "id", ignoreDuplicates: true)
            .execute()
    }
}

/// UserDefaults-backed session storage. Simulator only — see `Supa.sessionStorage`.
private struct SimulatorSessionStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws { UserDefaults.standard.set(value, forKey: key) }
    func retrieve(key: String) throws -> Data? { UserDefaults.standard.data(forKey: key) }
    func remove(key: String) throws { UserDefaults.standard.removeObject(forKey: key) }
}
