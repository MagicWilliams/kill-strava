import SwiftUI

@main
struct TempoApp: App {
    @StateObject private var runs: RunStore
    @StateObject private var router = TabRouter()
    /// The one run recorder (#114), app-wide: a run outlives any screen it was started from.
    @State private var recorder: WorkoutRecorder

    init() {
        let runs = RunStore()
        let recorder = WorkoutRecorder(store: runs)
        _runs = StateObject(wrappedValue: runs)
        _recorder = State(initialValue: recorder)
        // Kill recovery (#115) starts with the process, not with a view: when iOS relaunches
        // Tempo for a workout session it killed, there may be no scene on screen to run a
        // `.task`, and the session is waiting to be picked back up either way.
        Task { @MainActor in await recorder.recoverAtLaunch() }
    }

    var body: some Scene {
        WindowGroup {
            // No `.preferredColorScheme` here: the app follows system appearance (design
            // system v3, decision 1). A dark pin left over from the first shell sat on this
            // line through build 10 and kept the light theme from ever appearing (#80).
            RootTabView()
                .environmentObject(runs)
                .environmentObject(router)
                .environment(recorder)
                // Every distance and pace below reads this (#109). Flipping it on the You tab
                // re-renders the whole tree in the new unit.
                .environment(\.units, runs.units)
                .task { await runs.start() }
                // "We kept your run" (#115) — a placeholder until #128's prompt lands.
                .sheet(isPresented: Binding(
                    get: { recorder.recovered != nil },
                    set: { if !$0 { recorder.acknowledgeRecovery() } }
                )) {
                    RecoveredRunSheet(recorder: recorder)
                        .environment(\.units, runs.units)
                }
                // Widget taps (#76): Week opens Today, Coach opens the Coach tab.
                .onOpenURL { url in
                    switch WidgetLink(url: url) {
                    case .today: router.show(.today)
                    case .coach: router.show(.coach)
                    case nil: break
                    }
                }
        }
    }
}
