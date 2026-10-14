import SwiftUI

/// "We kept your run" (#115): what launch found when iOS had killed Tempo mid-run.
///
/// A placeholder for #128's prompt (Figma frame 10), so a recovered run is never left
/// waiting on disk with nothing on screen to say so. It reads `WorkoutRecorder.recovered` and
/// the run's own phase, and offers only what the reducer allows from there:
///
/// - the session survived: the run is going again — keep going, or end and save it;
/// - it did not: "Save what we have" or "Discard", the only two ways out of `.recovering`;
/// - it died on the save screen: Save or Discard, as the save screen would.
///
/// No journal is collected here; the post-run screen (#129) owns that. Discard asks twice,
/// as everywhere else (#128).
struct RecoveredRunSheet: View {
    let recorder: WorkoutRecorder
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.lg) {
            Text(title).display(28)
                .foregroundStyle(Tokens.Palette.textPrimary)
            Text(message)
                .font(Tokens.Font.ui(15))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Tokens.Space.sm) {
                StatTile(value: snapshot.units.formatDistance(meters: snapshot.distanceM), label: "Distance")
                StatTile(value: Self.duration(elapsedS), label: "Time")
            }

            if case .ending(.failed(let reason)) = state.phase {
                Text(reason)
                    .font(Tokens.Font.ui(13))
                    .foregroundStyle(Tokens.Palette.danger)
            }

            Spacer(minLength: 0)
            actions
        }
        .padding(Tokens.Space.xl2)
        .presentationDetents([.medium, .large])
        // A run waiting on a decision is not swiped away; Save or Discard are the ways out.
        .interactiveDismissDisabled(needsDecision)
        .confirmationDialog("Discard this run?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard run", role: .destructive) { recorder.send(.discard(.liveScreen)) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It won't be saved to Apple Health or Tempo.")
        }
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        switch state.phase {
        case .running, .paused:
            PrimaryButton(title: "Keep going") { recorder.acknowledgeRecovery() }
            secondary("End and save") { endAndSave() }
        case .recovering:
            PrimaryButton(title: "Save what we have") { endAndSave() }
            secondary("Discard") { confirmingDiscard = true }
        case .ending(.saving):
            PrimaryButton(title: "Saving", loading: true)
        case .ending:
            PrimaryButton(title: "Save") { recorder.confirmSave() }
            secondary("Discard") { confirmingDiscard = true }
        case .saved, .discarded, .idle, .countdown:
            PrimaryButton(title: "Done") {
                recorder.reset()
                recorder.acknowledgeRecovery()
            }
        }
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Font.ui(15, .semibold))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Space.md)
        }
        .buttonStyle(Pressable())
    }

    /// From the live screen's point of view: the athlete ended the run. Out of
    /// `.recovering` the reducer ends it at the last instant it was known to be recording.
    /// A race saves itself; anything else goes straight through Save, since the save
    /// screen (#129) is not here to stop on.
    private func endAndSave() {
        recorder.send(.endRequested(.liveScreen, at: Date()))
        if recorder.state.phase == .ending(.review) { recorder.confirmSave() }
    }

    // MARK: - Copy

    private var state: RecorderState { recorder.state }
    private var snapshot: RecorderSnapshot { recorder.snapshot }

    private var needsDecision: Bool {
        switch state.phase {
        case .recovering, .ending: true
        default: false
        }
    }

    private var title: String {
        switch state.phase {
        case .saved: "Saved to Apple Health"
        case .discarded: "Run discarded"
        case .ending: "Your run is ready to save"
        default: "We kept your run"
        }
    }

    private var message: String {
        switch (recorder.recovered, state.phase) {
        case (_, .saved): return "It's in Apple Health and on its way into Tempo."
        case (_, .discarded): return "Nothing was saved."
        case (.expired, .recovering):
            return "Tempo closed during a run that started \(Self.when(state.startedAt)), and the workout stopped with it. Everything up to the moment it closed is still on this phone."
        case (_, .recovering):
            return "Tempo closed mid-run, and the workout stopped with it. Everything up to the moment it closed is still on this phone."
        case (_, .ending):
            return "Tempo closed before your run was saved. Nothing was lost."
        default:
            return "Tempo closed mid-run. The workout kept recording, and your clock kept counting."
        }
    }

    /// Wall time through the last instant the run is known to have been recording: the end
    /// if it has one, the kill if it is being rescued, now if it is going again.
    private var elapsedS: Double {
        if case .recovering(let since) = state.phase { return state.elapsed(at: since) }
        return state.elapsed(at: Date())
    }

    private static func duration(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds.rounded())).formatted(.time(pattern: .hourMinuteSecond))
    }

    private static func when(_ date: Date?) -> String {
        guard let date else { return "earlier" }
        return date.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}
