import SwiftUI

@main
struct TempoApp: App {
    @StateObject private var runs: RunStore
    @StateObject private var router = TabRouter()
    /// The one recorder (#114), for the life of the app: a run outlives every screen, tab
    /// switch and sheet. Built on the same store the save path writes into.
    @State private var recorder: WorkoutRecorder

    init() {
        let runs = RunStore()
        _runs = StateObject(wrappedValue: runs)
        _recorder = State(initialValue: WorkoutRecorder(store: runs))
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
