import Foundation

/// Supabase connection for the Tempo project.
///
/// These are **public client credentials** — the publishable key is meant to ship in the app,
/// and all data access is gated by Row-Level Security (a signed-in user only ever sees their
/// own rows). The `service_role` key and the Anthropic key are secrets and live ONLY in
/// Supabase Edge Function secrets — never here, never in git.
enum SupabaseConfig {
    static let url = URL(string: "https://lpgdhqqroyqdrjsrlodo.supabase.co")!
    static let publishableKey = "sb_publishable_sRHj6Ii4x4klM8VXlpsiww_eGMdpvDh"
}
