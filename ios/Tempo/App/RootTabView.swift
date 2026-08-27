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
    case history
    case projection
}

@MainActor
final class TabRouter: ObservableObject {
    @Published var selection: Tab = .today
    @Published var path: [Route] = []

    func openRun(_ run: RunSummary) { path.append(.run(run)) }
    func openReadiness() { path.append(.readiness) }
    func openHistory() { path.append(.history) }
    func openProjection() { path.append(.projection) }

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

    /// Owned here because a zoom push needs both ends in one namespace, and the two ends live
    /// in different places: the card is on a tab, the destination is in `navigationDestination`.
    /// Published down the tree as `\.zoomNamespace`.
    @Namespace private var zoom

    var body: some View {
        switch store.launch {
        case .loading:
            // Profile still loading — brand splash, no flash of the wrong screen.
            splash
        case .unreachable(let reason):
            // The splash used to cover this case too, which is how a paused backend
            // became a frozen app. A dead end is now a screen you can act on.
            LaunchErrorView(reason: reason) { await store.retryLaunch() }
        case .onboarding:
            OnboardingView()
        case .ready:
            mainApp
        }
    }

    private var splash: some View {
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            Text("Tempo")
                .font(Tokens.Font.display(40))
                .foregroundStyle(Tokens.Palette.textPrimary)
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
                case .run(let run): RunDetailView(run: run).zoomDestination(run.id, in: zoom)
                case .readiness: ReadinessDetailView()
                case .history: HistoryView()
                case .projection: ProjectionDetailView()
                }
            }
        }
        .environment(\.zoomNamespace, zoom)
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
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                let active = tab == selection
                Button {
                    guard tab != selection else { return }
                    Haptics.select()
                    selection = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: active ? .semibold : .regular))
                            .modifier(BounceOnSelect(active: active))
                        Text(tab.title)
                            .font(Tokens.Font.ui(10, active ? .semibold : .medium))
                    }
                    .foregroundStyle(active ? Tokens.Palette.accentText : Tokens.Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        // One capsule, matched across tabs, so selection *travels* instead of
                        // blinking out here and in over there.
                        if active {
                            Capsule()
                                .fill(Tokens.Well.accent.fill)
                                .matchedGeometryEffect(id: "tab", in: indicator)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .motion(Motion.tab, value: selection)
        .padding(.top, 8)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .background(Tokens.Palette.inset)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.Palette.divider).frame(height: 0.5)
        }
    }
}

/// Bounces a tab's glyph when it *becomes* selected.
///
/// `.symbolEffect(.bounce, value: active)` looks like the obvious spelling and is wrong: it
/// fires on every change of `active`, so switching tabs bounces the one you left as well as
/// the one you chose. Counting activations gives one bounce, on the tab you actually picked.
private struct BounceOnSelect: ViewModifier {
    let active: Bool

    @State private var activations = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce, options: .nonRepeating, value: activations)
            .onChange(of: active) { _, isActive in
                guard isActive, !reduceMotion else { return }
                activations += 1
            }
    }
}

/// Shown when the launch sequence can't reach Supabase.
///
/// Deliberately says *connection*, not *error*: the failure mode this was written for is a
/// paused free-tier project, where every byte of the athlete's training history is intact
/// and the only broken thing is the round-trip. A screen that implied data loss would be
/// both wrong and alarming.
struct LaunchErrorView: View {
    let reason: String
    let retry: () async -> Void

    @State private var retrying = false

    var body: some View {
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            VStack(spacing: Tokens.Space.lg) {
                Text("Tempo")
                    .font(Tokens.Font.display(40))
                    .foregroundStyle(Tokens.Palette.textPrimary)

                VStack(spacing: Tokens.Space.sm) {
                    Text(reason)
                        .font(Tokens.Font.ui(16, .semibold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                    Text(LaunchGate.Copy.hint)
                        .font(Tokens.Font.ui(14))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Space.xl2)

                PrimaryButton(title: retrying ? "Trying\u{2026}" : "Try again", loading: retrying) {
                    Task {
                        retrying = true
                        await retry()
                        retrying = false
                    }
                }
                .padding(.horizontal, Tokens.Space.xl3)
                .padding(.top, Tokens.Space.sm)
            }
        }
    }
}

#Preview("Light") {
    RootTabView()
        .environmentObject(TabRouter())
        .environmentObject(RunStore())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    RootTabView()
        .environmentObject(TabRouter())
        .environmentObject(RunStore())
        .preferredColorScheme(.dark)
}
