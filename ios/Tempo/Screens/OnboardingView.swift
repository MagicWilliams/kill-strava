import SwiftUI

/// Hard-gated setup flow (spec: progress.md "Onboarding"):
/// Welcome (brand) → Connect (HealthKit moment, run count) → coach interview.
/// The coach's `complete_onboarding` tool flips `needsOnboarding`, and RootTabView
/// swaps to the main app reactively — no callbacks needed here.
struct OnboardingView: View {
    @EnvironmentObject private var store: RunStore

    private enum Step { case welcome, connect, interview }
    @State private var step: Step = .welcome
    @State private var connecting = false
    @State private var connected = false

    var body: some View {
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            switch step {
            case .welcome: welcome
            case .connect: connect
            case .interview: CoachView(onboarding: true)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    // MARK: - Welcome (brand moment)

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("Tempo")
                .font(Tokens.Font.display(56))
                .foregroundStyle(Tokens.Palette.textPrimary)
            Rectangle()
                .fill(Tokens.Palette.voltMark)
                .frame(width: 56, height: 5)
                .padding(.top, 10)
            Text("Marathon coaching, honestly.")
                .font(Tokens.Font.ui(17, .medium))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .padding(.top, 18)
            Text("Your plan is built from your real running — not a template. Your coach reads every run, listens when you push back, and never paywalls the truth.")
                .font(Tokens.Font.ui(14))
                .foregroundStyle(Tokens.Palette.textTertiary)
                .lineSpacing(3)
                .padding(.top, 10)
            Spacer()
            PrimaryButton(title: "Get started") {
                step = .connect
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
    }

    // MARK: - Connect (the HealthKit moment)

    private var connect: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            SectionLabel("Step 1 of 2", color: Tokens.Palette.accentText)
            Text("Connect your runs")
                .font(Tokens.Font.display(34))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .padding(.top, 8)
            Text("Tempo reads finished runs from Apple Health — Apple Watch, and Garmin or Coros by way of their Health sync. No in-app recording needed; keep racing your watch.")
                .font(Tokens.Font.ui(14))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .lineSpacing(3)
                .padding(.top, 12)

            if connected {
                connectedCard.padding(.top, 24)
            }

            Spacer()

            if connected {
                PrimaryButton(title: "Meet your coach") {
                    step = .interview
                }
            } else {
                PrimaryButton(title: connecting ? "Reading Apple Health…" : "Connect Apple Health") {
                    guard !connecting else { return }
                    connecting = true
                    Task {
                        await store.refresh()
                        connecting = false
                        connected = true
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
    }

    private var connectedCard: some View {
        Card {
            if store.runs.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(Tokens.Palette.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No runs found yet")
                            .font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                        Text("Using Garmin? Check Garmin Connect → Settings → Apple Health → share workouts. You can continue — the coach will ask about your recent running instead.")
                            .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tokens.Palette.success)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(store.runs.count) runs found")
                            .font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                        Text(String(format: "%.0f miles of history — your coach starts from what you actually do.",
                                    store.runs.reduce(0) { $0 + $1.miles }))
                            .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                    }
                }
            }
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(RunStore())
        .environmentObject(TabRouter())
        .preferredColorScheme(.dark)
}
