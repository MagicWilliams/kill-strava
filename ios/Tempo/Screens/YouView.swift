import SwiftUI

struct YouView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        Screen(title: "David", subtitle: "Chicago Marathon · 16 weeks out") {
            goal
            HStack(spacing: 10) {
                StatTile(value: "412", label: "Miles")
                StatTile(value: "78", label: "Runs")
                StatTile(value: "64h", label: "Time")
            }
            prefs
            Button {
                Task { await auth.signOut() }
            } label: {
                Text("Sign out")
                    .font(Tokens.Font.ui(15, .semibold))
                    .foregroundStyle(Tokens.Palette.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
        }
    }

    private var goal: some View {
        Card(glow: true) {
            HStack {
                SectionLabel("Your goal", color: Tokens.Palette.volt)
                Spacer()
                Tag(text: "on track")
            }
            Text("Sub-3:15 Marathon").font(Tokens.Font.display(23)).foregroundStyle(Tokens.Palette.textPrimary)
            HStack(spacing: 18) {
                metric("TARGET", PaceModel.format(Mock.paces.marathon) + " /mi")
                metric("RACE", "Oct 12")
                metric("WEEKS", "16")
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(label)
            Text(value).font(Tokens.Font.ui(16, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
        }
    }

    private var prefs: some View {
        Card {
            SectionLabel("Preferences")
            row("Units", "Miles")
            Divider().overlay(Tokens.Palette.divider)
            row("Coach voice", "Calm expert")
            Divider().overlay(Tokens.Palette.divider)
            row("Notifications", "On")
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(Tokens.Font.ui(15, .medium)).foregroundStyle(Tokens.Palette.textPrimary)
            Spacer()
            Text(value).font(Tokens.Font.ui(14)).foregroundStyle(Tokens.Palette.textSecondary)
            Image(systemName: "chevron.right").foregroundStyle(Tokens.Palette.textTertiary)
        }
    }
}

#Preview {
    YouView()
        .environmentObject(AuthService())
        .preferredColorScheme(.dark)
}
