import SwiftUI

/// Required onboarding gate: grant Apple Health, pull run history, mark the profile
/// connected. Only after this does the user reach Home.
struct ConnectView: View {
    @EnvironmentObject private var health: HealthService
    var onConnected: () -> Void

    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Spacer().frame(height: 8)
                Text("Connect your runs")
                    .font(Tokens.Font.display(28)).foregroundStyle(Tokens.Palette.textPrimary)
                Text("Tempo builds your plan around the runs you already track. Connect a source to import your history and sync automatically.")
                    .font(Tokens.Font.ui(15)).foregroundStyle(Tokens.Palette.textSecondary)

                source(letter: "♥", tint: Color(hex: 0xF4516C), name: "Apple Health",
                       detail: "Runs, heart rate & distance", enabled: true)
                source(letter: "G", tint: Color(hex: 0x3BD7F5), name: "Garmin Connect",
                       detail: "Coming soon", enabled: false)
                source(letter: "S", tint: Color(hex: 0xFB923C), name: "Strava",
                       detail: "Coming soon", enabled: false)

                if let error {
                    Text(error).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.danger)
                }

                Spacer()
                PrimaryButton(title: working ? "Connecting…" : "Connect Apple Health") {
                    Task { await connect() }
                }
                Text("Apple Health is required to continue. Your data stays yours.")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(24)
        }
    }

    private func source(letter: String, tint: Color, name: String, detail: String, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tint)
                .frame(width: 40, height: 40)
                .overlay(Text(letter).font(Tokens.Font.display(16)).foregroundStyle(Tokens.Palette.onVolt))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                Text(detail).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            Spacer()
            if !enabled {
                Text("Soon").font(Tokens.Font.ui(12, .medium)).foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
        .padding(14)
        .background(Tokens.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(Tokens.Palette.elevated, lineWidth: 1)
        )
        .opacity(enabled ? 1 : 0.55)
    }

    private func connect() async {
        error = nil; working = true; defer { working = false }
        do {
            try await health.requestAuthorization()
            _ = try? await health.sync()                 // best-effort first import
            if let uid = Supa.userID?.uuidString {
                try await Supa.client
                    .from("profiles")
                    .update(["health_connected": true])
                    .eq("id", value: uid)
                    .execute()
            }
            onConnected()
        } catch {
            self.error = "Couldn't connect Apple Health. \(error.localizedDescription)"
        }
    }
}
