import Foundation
import Supabase

/// Email one-time-code (OTP) auth. No passwords: we email a 6-digit code, the user
/// enters it, and `verifyOTP` establishes a session that supabase-swift persists to
/// the Keychain (so it survives relaunch). The app's routing reacts to `state`.
@MainActor
final class AuthService: ObservableObject {
    enum State: Equatable { case loading, signedOut, signedIn }

    @Published var state: State = .loading

    init() {
        // Drive state from the auth event stream (fires .initialSession on launch).
        Task { [weak self] in
            for await change in Supa.client.auth.authStateChanges {
                guard let self else { return }
                switch change.event {
                case .initialSession:
                    self.state = change.session == nil ? .signedOut : .signedIn
                case .signedIn:
                    self.state = .signedIn
                case .signedOut:
                    self.state = .signedOut
                default:
                    break
                }
            }
        }
    }

    /// Email a fresh 6-digit code, creating the account if it doesn't exist yet.
    func sendCode(to email: String) async throws {
        try await Supa.client.auth.signInWithOTP(email: email, shouldCreateUser: true)
    }

    /// Verify the code; on success the auth stream flips `state` to `.signedIn`.
    func verify(email: String, code: String) async throws {
        try await Supa.client.auth.verifyOTP(email: email, token: code, type: .email)
    }

    func signOut() async {
        try? await Supa.client.auth.signOut()
    }
}
