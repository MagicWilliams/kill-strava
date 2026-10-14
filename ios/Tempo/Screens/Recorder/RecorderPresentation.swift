import SwiftUI

extension View {
    /// Attach once, at the root of the main app. The one place the recorder's screens are
    /// presented (#126):
    ///
    /// - the pre-run sheet, whenever `TabRouter.startRun(_:)` is called;
    /// - one full-screen cover over everything while a run exists, its content chosen by
    ///   `PreRun.screen(for:)` from the recorder's phase. Countdown, live run (#127) and,
    ///   when it lands, post-run (#128) all hang off that one switch, so no screen decides
    ///   on its own that a run is over.
    ///
    /// Start is handed over in two steps on purpose. The sheet sets `router.pendingStart` and
    /// closes; `.start` is sent from the sheet's `onDismiss`, once it is gone. Sent while the
    /// sheet was still leaving, the cover would be presented on top of a dismissing sheet,
    /// which SwiftUI drops silently — a countdown that never appears over a session that is
    /// already preparing.
    func runRecorder(router: TabRouter, recorder: WorkoutRecorder) -> some View {
        // Read here, in the caller's `body`, where Observation tracks it — not inside the
        // binding's getter, which SwiftUI may call outside any tracking scope.
        let covered = PreRun.screen(for: recorder.state.phase) != .none
        return sheet(
            item: Binding(get: { router.preRun }, set: { router.preRun = $0 }),
            onDismiss: {
                guard let setup = router.pendingStart else { return }
                router.pendingStart = nil
                recorder.send(.start(setup, at: .now))
            }
        ) { request in
            PreRunSheet(request: request) { setup in
                router.pendingStart = setup
                router.preRun = nil
            }
            .environment(recorder)
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { covered },
                // Never dismissed from SwiftUI's side: only a reset or a cancelled countdown
                // takes the recorder back to idle, and that is what closes the cover.
                set: { _ in }
            ),
            onDismiss: {
                // Cancelled, or the workout session failed to prepare: back to the sheet,
                // which shows `lastFailure` if there was one.
                let failed = recorder.state.phase == .idle && recorder.lastFailure != nil
                guard router.reopenPreRun || failed, let last = router.lastPreRun else { return }
                router.reopenPreRun = false
                router.preRun = last
            }
        ) {
            RecorderScreen(router: router)
                .environment(recorder)
        }
    }
}

/// The cover's content: whichever recorder screen the phase calls for.
private struct RecorderScreen: View {
    let router: TabRouter
    @Environment(WorkoutRecorder.self) private var recorder

    var body: some View {
        switch (PreRun.screen(for: recorder.state.phase), recorder.state.phase) {
        case (.countdown, .countdown(let startedAt)):
            CountdownView(startedAt: startedAt) {
                router.reopenPreRun = true
                recorder.send(.discard(.liveScreen))
            }
        case (.live, _):
            LiveRunView()
        default:
            // Idle, for the instant the cover takes to leave.
            Tokens.Palette.canvas.ignoresSafeArea()
        }
    }
}
