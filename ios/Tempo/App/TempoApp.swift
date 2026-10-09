import SwiftUI

@main
struct TempoApp: App {
    @StateObject private var runs = RunStore()
    @StateObject private var router = TabRouter()

    var body: some Scene {
        WindowGroup {
            // No `.preferredColorScheme` here: the app follows system appearance (design
            // system v3, decision 1). A dark pin left over from the first shell sat on this
            // line through build 10 and kept the light theme from ever appearing (#80).
            RootTabView()
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
