import SwiftUI
import UIKit

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
    case raceRecap(RunSummary)
    case changes
    case overlapReview
    case blockReview(GoalInfo)
    /// One coach conversation (#87). The id and not the row: a thread's title and recap are
    /// written while it is open, and a pushed copy of the row would go stale behind it.
    case coachThread(UUID)
}

@MainActor
final class TabRouter: ObservableObject {
    @Published var selection: Tab = .today
    @Published var path: [Route] = []
    /// A coach message to scroll to when the Coach tab next shows — set by "See in chat"
    /// on a What changed entry, consumed (cleared) by `CoachView`.
    @Published var coachFocus: UUID?
    /// Text to drop into the Coach input when the tab next shows — set by "Train for
    /// something", consumed (cleared) by `CoachView`. Prefilled, never sent: the athlete
    /// gets to read it, change it, or back out.
    @Published var coachDraft: String?
    /// The training intake (#102), presented over the whole app by `.trainingIntake(...)`.
    @Published var trainingIntakeShown = false
    /// The pre-run sheet (#126), presented over the whole app by `.runRecorder(...)`.
    @Published var preRun: PreRun.Request?
    /// The sheet's answers, waiting for it to finish leaving before `.start` is sent.
    var pendingStart: RecorderState.Setup?
    /// The last sheet opened, to come back to when a countdown is cancelled.
    var lastPreRun: PreRun.Request?
    /// Set by the countdown's Cancel: re-open `lastPreRun` once the cover is gone.
    var reopenPreRun = false

    func openRun(_ run: RunSummary) { path.append(.run(run)) }
    func openReadiness() { path.append(.readiness) }
    func openHistory() { path.append(.history) }
    func openProjection() { path.append(.projection) }
    func openRaceRecap(_ run: RunSummary) { path.append(.raceRecap(run)) }
    func openChanges() { path.append(.changes) }
    func openCoachThread(_ id: UUID) { path.append(.coachThread(id)) }
    func openOverlapReview() { path.append(.overlapReview) }
    func openBlockReview(_ goal: GoalInfo) { path.append(.blockReview(goal)) }

    /// Land on the Coach tab scrolled to one message.
    ///
    /// Since #87 the tab opens on the list of conversations, so this sets the focus and
    /// `CoachHomeView` pushes the live thread; the transcript scrolls to the message if it
    /// is in the page it loaded. The ledger does not know which thread holds a message —
    /// routing to the exact one is follow-up work.
    func showCoachMessage(_ id: UUID) {
        coachFocus = id
        showCoach()
    }

    /// The "Train for something" CTA on the just-running Today and Plan (#101), and the one
    /// way into the training intake (#102) from anywhere in the app. The form hands its
    /// answers to the coach itself: see `View.trainingIntake(router:store:)`.
    func trainForSomething() {
        trainingIntakeShown = true
    }

    /// The Start button on Today (#126): open the pre-run sheet. The one way into a recorded
    /// run; the countdown and the live screen follow the recorder from there.
    func startRun(_ request: PreRun.Request) {
        lastPreRun = request
        reopenPreRun = false
        preRun = request
    }

    /// Where the app goes once a recorded run is saved (`RaceFinish.destination`): a race
    /// lands on its recap (#117, Figma frame 9b), on Today's stack so Back goes home.
    func land(after destination: RaceFinish.Destination) {
        guard case .raceRecap(let run) = destination else { return }
        selection = .today
        path = [.raceRecap(run)]
    }

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
    @Environment(WorkoutRecorder.self) private var recorder

    /// Owned here because a zoom push needs both ends in one namespace, and the two ends live
    /// in different places: the card is on a tab, the destination is in `navigationDestination`.
    /// Published down the tree as `\.zoomNamespace`.
    @Namespace private var zoom

    /// Whether the software keyboard is on screen. The tab bar steps aside while it is (#186).
    @State private var keyboardUp = false

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
                        // A bottom inset respects the keyboard, so a bar left here while typing
                        // rode up on top of the keyboard and put five tab buttons between the
                        // Coach composer and the keys (David, 2026-10-15). Gone while the keyboard
                        // is up, the chat-app layout: the composer sits on the keys, and the bar
                        // is back at the bottom as the keyboard leaves.
                        if !keyboardUp {
                            TempoTabBar(selection: $router.selection)
                        }
                    }
            }
            .trackingKeyboard($keyboardUp)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .run(let run): RunDetailView(run: run).zoomDestination(run.id, in: zoom)
                case .readiness: ReadinessDetailView()
                case .history: HistoryView()
                case .projection: ProjectionDetailView()
                case .raceRecap(let run): RaceRecapView(run: run)
                case .changes: ChangesView()
                case .overlapReview: OverlapReviewView()
                case .blockReview(let goal): BlockReviewView(goal: goal)
                case .coachThread(let id): CoachView(threadID: id)
                }
            }
        }
        .environment(\.zoomNamespace, zoom)
        .trainingIntake(router: router, store: store)
        .runRecorder(router: router, recorder: recorder)
        // The moment a save lands, while the recorder's cover is still up: the recap is
        // pushed underneath it, so the cover closes onto the race and not onto a frame of
        // Today. Here rather than on the save screen (#129), so the landing is the same
        // whichever screen ended the run (the live one, or "We kept your run").
        .onChange(of: recorder.lastSaved) { _, saved in
            guard let saved else { return }
            router.land(after: RaceFinish.destination(saved, runs: store.runs))
        }
    }

    @ViewBuilder private var content: some View {
        switch router.selection {
        case .today:    TodayView()
        case .plan:     PlanView()
        case .progress: ProgressScreen()
        case .coach:    CoachHomeView()
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

/// Keeps `isUp` in step with the software keyboard, on the keyboard's own clock.
///
/// Notifications rather than focus, because "the keyboard is up" is what the tab bar has to
/// get out of the way of, whichever field raised it. The animation takes the keyboard's
/// duration instead of going through `motion(_:value:)`: it is not decoration, it keeps the
/// composer moving with the keys, and the keys move under Reduce Motion too.
private struct KeyboardTracking: ViewModifier {
    @Binding var isUp: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) {
                set(true, $0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) {
                set(false, $0)
            }
    }

    private func set(_ up: Bool, _ note: Notification) {
        guard up != isUp else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        withAnimation(.easeOut(duration: duration)) { isUp = up }
    }
}

private extension View {
    func trackingKeyboard(_ isUp: Binding<Bool>) -> some View {
        modifier(KeyboardTracking(isUp: isUp))
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
    let store = RunStore()
    RootTabView()
        .environmentObject(TabRouter())
        .environmentObject(store)
        .environment(WorkoutRecorder(store: store))
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    let store = RunStore()
    RootTabView()
        .environmentObject(TabRouter())
        .environmentObject(store)
        .environment(WorkoutRecorder(store: store))
        .preferredColorScheme(.dark)
}
