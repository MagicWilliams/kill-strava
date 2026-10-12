import SwiftUI

/// Fitness / fatigue / form as one word and three numbers (#101). Shown on the just-running
/// Today in place of the readiness ring — readiness answers "can I do quality today?", which
/// is a question only a plan asks — and on Progress in place of a race projection.
///
/// Taps through to `ReadinessDetailView`, which is the same three numbers in depth.
struct FreshnessCard: View {
    let metrics: FitnessMetrics?
    var title = "Freshness"
    let action: () -> Void

    private var state: Freshness.State? { metrics.map(Freshness.state) }

    var body: some View {
        Button(action: action) {
            Card(well: well) {
                HStack {
                    SectionLabel(title, color: Tokens.Palette.accentText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
                Text(state?.label ?? "Warming up").display(24)
                Text(state?.caption ?? "Needs a few runs with pace before there's anything to read.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let m = metrics {
                    HStack(spacing: 18) {
                        number("FITNESS", String(format: "%.1f", m.ctl))
                        number("FATIGUE", String(format: "%.1f", m.atl))
                        number("FORM", String(format: "%+.1f", m.form))
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .motion(Motion.reveal, value: state)
    }

    /// Tint follows what the state costs, the same language Today's session cards use:
    /// fatigue is warm, freshness is good news, everything else is unremarkable.
    private var well: Tokens.Well {
        switch state {
        case .fresh:           return .success
        case .carryingFatigue: return .warm
        default:               return .neutral
        }
    }

    private func number(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(label)
            Text(value).font(Tokens.Font.mono(16)).foregroundStyle(Tokens.Palette.textPrimary)
        }
    }
}

/// The way back into training from the just-running state (#101). The action is passed in
/// rather than decided here; every caller passes `TabRouter.trainForSomething`, the one
/// function #102's intake replaces.
struct TrainForSomethingCard: View {
    let action: () -> Void

    var body: some View {
        Card(well: .accent) {
            SectionLabel("When you're ready", color: Tokens.Palette.accentText)
            Text("Aim at something").display(22)
            Text("A race, a distance, a time. The coach reads your history first and builds the block from what it supports.")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            PrimaryButton(title: "Train for something", action: action)
        }
    }
}

#Preview {
    VStack(spacing: 14) {
        FreshnessCard(metrics: nil) {}
        TrainForSomethingCard {}
    }
    .padding(20)
    .background(Tokens.Palette.canvas)
}
