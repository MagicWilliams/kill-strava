import SwiftUI

@main
struct TempoApp: App {
    @StateObject private var runs = RunStore()
    @StateObject private var router = TabRouter()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
                .environmentObject(runs)
                .environmentObject(router)
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
