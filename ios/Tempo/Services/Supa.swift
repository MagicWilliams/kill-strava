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
            auth: SupabaseClientOptions.AuthOptions(emitLocalSessionAsInitialSession: true)
        )
    )

    /// Current signed-in user id, if any.
    static var userID: UUID? {
        client.auth.currentUser?.id
    }

    /// Ensure a session exists. Beta-of-one: anonymous auth (the session persists in the
    /// keychain across launches). Replaced by Sign in with Apple before TestFlight.
    static func signInAnonymouslyIfNeeded() async {
        if (try? await client.auth.session) != nil { return }
        _ = try? await client.auth.signInAnonymously()
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
