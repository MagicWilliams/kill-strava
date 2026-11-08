import SwiftUI

/// Hard-gated setup flow (spec: progress.md "Onboarding"):
/// Welcome (brand) → Connect (HealthKit moment, run count) → permission to send data to
/// Anthropic → "Where are you right now?" (the training intake, #102) → coach interview.
/// The permission comes ahead of the intake because every answer on that form exists to be
/// handed to the coach. Saying no skips both and opens the app: runs, history and the recorder
/// don't need the coach, and it can be turned on later from the You tab.
/// The intake answers the structured questions by tap; the interview reflects them back,
/// proposes the plan, and asks only what the form didn't.
/// The coach's `complete_onboarding` tool flips `needsOnboarding`, and RootTabView
/// swaps to the main app reactively — no callbacks needed here.
///
/// The interview is never the only way out (#167). A coach that forgets to call
/// `complete_onboarding` once shut a just-running athlete out of the app behind a chat with
/// nothing left to say, so "Finish setup later" takes the same exit by hand.
struct OnboardingView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.units) private var units

    private enum Step { case welcome, connect, consent, intake, interview }
    @State private var step: Step = .welcome
    @State private var connecting = false
    @State private var connected = false
    @State private var finishing = false
    @ObservedObject private var consent = CoachConsentStore.shared

    var body: some View {
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            switch step {
            case .welcome: welcome
            case .connect: connect
            case .consent:
                CoachConsentView(eyebrow: "Step 2 of 4") { decision in
                    if decision == .declined {
                        finishSetup()
                    } else {
                        step = .intake
                    }
                }
            case .intake:
                TrainingIntakeView(
                    entry: .onboarding,
                    seed: IntakeAnswers(daysPerWeek: store.daysPerWeek, longRunDay: store.longRunDay, risk: store.riskTolerance)
                ) { answers in
                    // Onboarding has no close button, so this is always a send.
                    if let answers { store.beginIntake(answers) }
                    step = .interview
                }
            case .interview:
                VStack(spacing: 0) {
                    exitBar
                    CoachView(onboarding: true)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    // MARK: - Interview exit

    /// Secondary while the plan question is open, since the interview is still the way in. Once
    /// there is a plan or goal it is the primary thing on screen: see `OnboardingFacts.Exit`.
    private var exitBar: some View {
        let exit = OnboardingFacts.Exit(hasPlan: store.plan != nil, hasGoal: store.goal != nil)
        return HStack {
            Spacer()
            Button {
                guard !finishing else { return }
                if exit == .openPlan { router.show(.plan) }
                finishSetup()
            } label: {
                Text(finishing ? "Opening Tempo…" : exit.title)
                    .font(Tokens.Font.ui(13, exit.isPrimary ? .bold : .medium))
                    .foregroundStyle(exit.isPrimary ? Tokens.Palette.onVolt : Tokens.Palette.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(exit.isPrimary ? Tokens.Palette.volt : Tokens.Palette.surface)
                    .clipShape(Capsule())
            }
            .buttonStyle(Pressable())
            .disabled(finishing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func finishSetup() {
        guard !finishing else { return }
        finishing = true
        Task {
            await store.markOnboarded()
            // Normally this view is gone by now; if it isn't, the tap must work again.
            finishing = false
        }
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
            Text("Marathon coaching from your own runs.")
                .font(Tokens.Font.ui(17, .medium))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .padding(.top, 18)
            Text("Your plan is built from your own running. Your coach reads every run and adjusts when you push back.")
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
            SectionLabel("Step 1 of 4", color: Tokens.Palette.accentText)
            Text("Connect your runs")
                .font(Tokens.Font.display(34))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .padding(.top, 8)
            Text("Tempo reads finished runs from Apple Health: Apple Watch, plus Garmin or Coros through their Health sync. No in-app recording needed; keep racing your watch.")
                .font(Tokens.Font.ui(14))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .lineSpacing(3)
                .padding(.top, 12)

            if connected {
                connectedCard.padding(.top, 24)
            }

            Spacer()

            if connected {
                PrimaryButton(title: "Continue") {
                    // A relaunch restarts onboarding at Welcome. Someone who already agreed
                    // isn't asked twice.
                    step = consent.maySend ? .intake : .consent
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
                        Text("Using Garmin? Check Garmin Connect → Settings → Apple Health → share workouts. You can continue, and the coach will ask about your recent running instead.")
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
                        Text("\(units.number(miles: store.runs.reduce(0) { $0 + $1.miles }, decimals: 0)) \(units.name(plural: true)) of history. Your coach starts from what you actually do.")
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
