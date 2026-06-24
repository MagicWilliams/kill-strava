import SwiftUI

/// Top-level gate. You only reach Home (RootTabView) once you have BOTH a session
/// AND a connected data source (profiles.health_connected == true).
///
///   loading            → Splash
///   signed out         → AuthView (email OTP)
///   signed in, ?       → load profile flag
///   signed in, !conn   → ConnectView (grant HealthKit + first sync)
///   signed in, conn    → RootTabView (the app)
struct RootView: View {
    @StateObject private var auth = AuthService()
    @StateObject private var health = HealthService()
    @State private var connected: Bool? = nil   // nil = not yet loaded

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                SplashView()
            case .signedOut:
                AuthView()
            case .signedIn:
                switch connected {
                case .none:
                    SplashView().task { await refreshConnected() }
                case .some(false):
                    ConnectView { connected = true }
                case .some(true):
                    RootTabView()
                }
            }
        }
        .environmentObject(auth)
        .environmentObject(health)
        .onChange(of: auth.state) { _, newValue in
            if newValue != .signedIn { connected = nil }   // reset gate on sign-out
        }
    }

    /// Read the per-user connection flag from Supabase (RLS scopes it to this user).
    private func refreshConnected() async {
        guard let uid = Supa.userID?.uuidString else { connected = false; return }
        do {
            let profile: Profile = try await Supa.client
                .from("profiles")
                .select()
                .eq("id", value: uid)
                .single()
                .execute()
                .value
            connected = profile.healthConnected
        } catch {
            connected = false
        }
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Tempo").font(Tokens.Font.display(36)).foregroundStyle(Tokens.Palette.volt)
                ProgressView().tint(Tokens.Palette.textTertiary)
            }
        }
    }
}
