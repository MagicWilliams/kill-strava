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
        }
    }
}
