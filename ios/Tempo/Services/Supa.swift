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
            auth: SupabaseClientOptions.AuthOptions(emitLocalSessionAsInitialSession: true),
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
            return true
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
