import SwiftUI

/// **Placeholder for #127**, which replaces this file wholesale with the signed-off live run
/// screen (frames 4–5). It exists so the Start → countdown flow (#126) lands somewhere real,
/// and so a run started on the device can be ended and saved or discarded rather than left
/// running behind a screen with no way out.
///
/// The contract #127 keeps: `LiveRunView()` with no arguments, reading the recorder from the
/// environment (`@Environment(WorkoutRecorder.self)`). It is shown by `runRecorder(...)`
/// whenever `PreRun.screen(for:)` says `.live`, and it goes away when the recorder is reset.
struct LiveRunView: View {
    @Environment(WorkoutRecorder.self) private var recorder
    @Environment(\.units) private var units

    var body: some View {
        let snapshot = recorder.snapshot
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            VStack(spacing: Tokens.Space.xl) {
                SectionLabel(phaseLabel, color: Tokens.Palette.accentText)
                Text(Self.clock(snapshot.elapsedS))
                    .font(Tokens.Font.mono(72)).foregroundStyle(Tokens.Palette.textPrimary)
                Text(units.formatDistance(meters: snapshot.distanceM))
                    .font(Tokens.Font.mono(28)).foregroundStyle(Tokens.Palette.textSecondary)
                Spacer(minLength: 0)
                controls
            }
            .padding(Tokens.Space.xl)
            .padding(.top, Tokens.Space.xl4)
        }
    }

    @ViewBuilder private var controls: some View {
        switch recorder.state.phase {
        case .running:
            PrimaryButton(title: "Pause", icon: "pause.fill") { recorder.send(.pause(.manual(.liveScreen), at: .now)) }
        case .paused, .recovering:
            VStack(spacing: Tokens.Space.sm) {
                PrimaryButton(title: "Resume", icon: "play.fill") { recorder.send(.resume(.manual(.liveScreen), at: .now)) }
                SecondaryButton(title: "End run") { recorder.send(.endRequested(.liveScreen, at: .now)) }
            }
        case .ending(.review), .ending(.failed):
            VStack(spacing: Tokens.Space.sm) {
                if case .ending(.failed(let reason)) = recorder.state.phase {
                    Text(reason).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.warning)
                }
                PrimaryButton(title: "Save run") { recorder.confirmSave() }
                QuietButton(title: "Discard") { recorder.send(.discard(.liveScreen)) }
            }
        case .ending(.saving):
            PrimaryButton(title: "Saving", loading: true)
        case .saved, .discarded:
            PrimaryButton(title: "Done") { recorder.reset() }
        case .idle, .countdown:
            EmptyView()
        }
    }

    private var phaseLabel: String {
        switch recorder.state.phase {
        case .running: "Running"
        case .paused: "Paused"
        case .recovering: "Recovering"
        case .ending: "Run ended"
        case .saved: "Saved"
        case .discarded: "Discarded"
        case .idle, .countdown: ""
        }
    }

    private static func clock(_ s: Int) -> String {
        s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
