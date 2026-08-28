import Foundation

/// Supabase connection for the Tempo project.
///
/// These are **public client credentials** — the publishable key is meant to ship in the app,
/// and all data access is gated by Row-Level Security (a signed-in user only ever sees their
/// own rows). The `service_role` key and the Anthropic key are secrets and live ONLY in
/// Supabase Edge Function secrets — never here, never in git.
enum SupabaseConfig {

    private enum Backend {
        case production, staging

        var url: URL {
            switch self {
            case .production: return URL(string: "https://lpgdhqqroyqdrjsrlodo.supabase.co")!
            case .staging:    return URL(string: "https://lpphooojrxhitlndvulk.supabase.co")!
            }
        }

        var publishableKey: String {
            switch self {
            case .production: return "sb_publishable_sRHj6Ii4x4klM8VXlpsiww_eGMdpvDh"
            case .staging:    return "sb_publishable_1fhrgre1p9T57g72t15Xuw_apimUFma"
            }
        }
    }

    /// The simulator talks to staging. A real device always talks to production.
    ///
    /// This split is what makes the app runnable by anyone who isn't David. Launching Tempo
    /// signs in anonymously, and that is a *write* — pointed at production it would leave a
    /// stray user and profile row in his real project every time someone booted a simulator
    /// to look at a screen. Against staging it costs nothing, which is the whole reason
    /// staging exists.
    ///
    /// Deliberately keyed on the simulator rather than on DEBUG: David runs Debug builds on
    /// his own phone from Xcode, and those must keep showing his real training history. The
    /// question this answers is "is this a throwaway environment", and `#if DEBUG` answers a
    /// different one.
    private static var backend: Backend {
        #if targetEnvironment(simulator)
        return .staging
        #else
        return .production
        #endif
    }

    static var url: URL { backend.url }
    static var publishableKey: String { backend.publishableKey }

    /// For anything that needs to say which environment it is talking to — a debug banner,
    /// a telemetry tag, or a human reading a log and wondering why the archive is empty.
    static var isStaging: Bool { backend.url == Backend.staging.url }
}
