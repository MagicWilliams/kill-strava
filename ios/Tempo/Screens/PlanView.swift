import SwiftUI

struct PlanView: View {
    var body: some View {
        Screen(title: "18-Week Marathon", subtitle: "Chicago · sub-3:15") {
            countdown
            phases
            ForEach(Array(Mock.planWeeks.enumerated()), id: \.offset) { _, wk in
                weekRow(wk)
            }
        }
    }

    private var countdown: some View {
        Card(glow: true) {
            HStack {
                SectionLabel("Chicago Marathon", color: Tokens.Palette.volt)
                Spacer()
                Text("Oct 12").font(Tokens.Font.ui(13, .semibold)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("113").font(Tokens.Font.display(46)).foregroundStyle(Tokens.Palette.textPrimary)
                Text("days to go").font(Tokens.Font.ui(14)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            Text("Week 3 of 18 · Base phase · 17% complete")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    private var phases: some View {
        HStack(spacing: 8) {
            ForEach(Array(["Base", "Build", "Peak", "Taper"].enumerated()), id: \.offset) { index, phase in
                let active = index == 0
                Text(phase)
                    .font(Tokens.Font.ui(13, active ? .semibold : .medium))
                    .foregroundStyle(active ? Tokens.Palette.onVolt : Tokens.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(active ? Tokens.Palette.volt : Tokens.Palette.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(active ? Color.clear : Tokens.Palette.elevated, lineWidth: 1))
            }
        }
    }

    private func weekRow(_ wk: (String, String, String)) -> some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(wk.0).font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                    Text(wk.1).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                }
                Spacer()
                Text(wk.2).font(Tokens.Font.mono(13)).foregroundStyle(Tokens.Palette.textSecondary)
                Image(systemName: "chevron.right").foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
    }
}

#Preview {
    PlanView().preferredColorScheme(.dark)
}
