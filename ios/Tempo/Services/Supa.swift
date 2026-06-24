import Foundation
import Supabase

/// Shared Supabase client. Auth, Postgres (PostgREST), and Edge Functions all hang off this.
enum Supa {
    static let client = SupabaseClient(
        supabaseURL: SupabaseConfig.url,
        supabaseKey: SupabaseConfig.publishableKey
    )

    /// Current signed-in user id, if any.
    static var userID: UUID? {
        client.auth.currentUser?.id
    }
}
