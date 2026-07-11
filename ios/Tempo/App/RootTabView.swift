import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case today, plan, progress, coach, you
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .plan: return "Plan"
        case .progress: return "Progress"
        case .coach: return "Coach"
        case .you: return "You"
        }
    }

    var symbol: String {
        switch self {
        case .today: return "square.grid.2x2"
        case .plan: return "calendar"
        case .progress: return "chart.bar.fill"
        case .coach: return "bubble.left.fill"
        case .you: return "person.fill"
        }
    }
}

/// App-wide navigation: tab selection + the push stack.
/// Lives above the tab bar so any screen (or the coach) can route.
enum Route: Hashable {
    case run(RunSummary)
    case readiness
}

@MainActor
final class TabRouter: ObservableObject {
    @Published var selection: Tab = .today
    @Published var path: [Route] = []

    func openRun(_ run: RunSummary) { path.append(.run(run)) }
    func openReadiness() { path.append(.readiness) }

    /// Pop everything and land on a tab (e.g. "Discuss with Coach").
    func showCoach() {
        path.removeAll()
        selection = .coach
    }

    func show(_ tab: Tab) {
        path.removeAll()
        selection = tab
    }
}

struct RootTabView: View {
    @EnvironmentObject private var router: TabRouter
    @EnvironmentObject private var store: RunStore

    var body: some View {
        switch store.needsOnboarding {
        case nil:
            // Profile still loading — brand splash, no flash of the wrong screen.
            ZStack {
                Tokens.Palette.canvas.ignoresSafeArea()
                Text("Tempo")
                    .font(Tokens.Font.display(40))
                    .foregroundStyle(Tokens.Palette.textPrimary)
            }
        case .some(true):
            OnboardingView()
        case .some(false):
            mainApp
        }
    }

    private var mainApp: some View {
        NavigationStack(path: $router.path) {
            ZStack {
                Tokens.Palette.canvas.ignoresSafeArea()
                content
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        TempoTabBar(selection: $router.selection)
                    }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .run(let run): RunDetailView(run: run)
                case .readiness: ReadinessDetailView()
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch router.selection {
        case .today:    TodayView()
        case .plan:     PlanView()
        case .progress: ProgressScreen()
        case .coach:    CoachView()
        case .you:      YouView()
        }
    }
}

struct TempoTabBar: View {
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                let active = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: active ? .semibold : .regular))
                        Text(tab.title)
                            .font(Tokens.Font.ui(10, active ? .semibold : .medium))
                    }
                    .foregroundStyle(active ? Tokens.Palette.volt : Tokens.Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .background(Tokens.Palette.inset)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.Palette.elevated).frame(height: 1)
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(TabRouter())
        .environmentObject(RunStore())
        .preferredColorScheme(.dark)
}
