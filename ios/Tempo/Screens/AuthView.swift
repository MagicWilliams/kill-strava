import SwiftUI

/// Passwordless email OTP: enter email → receive a 6-digit code → enter it → in.
struct AuthView: View {
    @EnvironmentObject private var auth: AuthService

    enum Phase { case email, code }
    @State private var phase: Phase = .email
    @State private var email = ""
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Spacer()
                Text("Tempo").font(Tokens.Font.display(40)).foregroundStyle(Tokens.Palette.volt)
                Text(phase == .email
                     ? "Sign in or create your account."
                     : "Enter the 6-digit code we emailed to \(email).")
                    .font(Tokens.Font.ui(15))
                    .foregroundStyle(Tokens.Palette.textSecondary)

                if phase == .email {
                    field("you@email.com", text: $email, keyboard: .emailAddress)
                    PrimaryButton(title: working ? "Sending…" : "Send code") {
                        Task { await send() }
                    }
                } else {
                    field("123456", text: $code, keyboard: .numberPad)
                    PrimaryButton(title: working ? "Verifying…" : "Verify & continue") {
                        Task { await verify() }
                    }
                    Button("Use a different email") {
                        phase = .email; code = ""; error = nil
                    }
                    .font(Tokens.Font.ui(13))
                    .foregroundStyle(Tokens.Palette.textTertiary)
                }

                if let error {
                    Text(error).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.danger)
                }

                Spacer()
                Text("We email you a one-time code — no passwords.")
                    .font(Tokens.Font.ui(12))
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(24)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(Tokens.Palette.textTertiary))
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(Tokens.Font.ui(16))
            .foregroundStyle(Tokens.Palette.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Tokens.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Tokens.Palette.elevated, lineWidth: 1)
            )
    }

    private func send() async {
        error = nil; working = true; defer { working = false }
        do {
            try await auth.sendCode(to: email.trimmingCharacters(in: .whitespacesAndNewlines))
            phase = .code
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func verify() async {
        error = nil; working = true; defer { working = false }
        do {
            try await auth.verify(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                code: code.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            self.error = "That code didn't work. Check it and try again."
        }
    }
}
