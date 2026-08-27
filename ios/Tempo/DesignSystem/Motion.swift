import SwiftUI
import UIKit

/// The motion vocabulary. Six curves, named for what they mean rather than what they are.
///
/// Before this file the app had eight animations in ~3,500 lines of view code, and a tap
/// registered as a 0.12s opacity dim. The problem that created isn't ugliness, it's that a
/// data app which refreshes in silence gives you no way to tell "the numbers are the same"
/// from "the numbers never arrived". Motion here is mostly in service of that: things that
/// changed should be seen changing.
enum Motion {
    /// Finger-down feedback. Fast, slightly springy, never bouncy enough to feel loose.
    static let press = Animation.spring(response: 0.3, dampingFraction: 0.62)
    /// New data landing in an existing view — a counter rolling, a bar re-lengthening.
    static let settle = Animation.spring(response: 0.55, dampingFraction: 0.85)
    /// First paint of a gauge or chart. Slower on purpose; it only happens once.
    static let draw = Animation.easeOut(duration: 0.7)
    /// Something appearing or disappearing in place.
    static let reveal = Animation.spring(response: 0.4, dampingFraction: 0.85)
    /// Tab selection and other small discrete state flips.
    static let tab = Animation.spring(response: 0.3, dampingFraction: 0.7)
    /// Matched-geometry navigation — a card growing into a screen.
    static let nav = Animation.spring(response: 0.42, dampingFraction: 0.82)
}

// MARK: - Reduce Motion

/// SwiftUI does **not** honour Reduce Motion for you — `.animation` runs regardless. Every
/// animation in Tempo goes through one of the helpers below so the setting is respected in
/// one place instead of being forgotten in twelve.
extension View {
    /// `.animation(_:value:)` that collapses to an instant change under Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }

    /// Rolls digits instead of snapping when `value` changes.
    ///
    /// Apply to a `Text` showing a number. Under Reduce Motion the text just updates.
    func rolling(_ value: Double) -> some View {
        modifier(RollingNumber(value: value))
    }
}

private struct MotionAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct RollingNumber: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Double

    func body(content: Content) -> some View {
        content
            .contentTransition(.numericText(value: value))
            .animation(reduceMotion ? nil : Motion.settle, value: value)
    }
}

/// Animates a value in from zero on first appearance, then animates to each new target.
///
/// The wrapper exists because a ring or a bar wants two different curves — a slow `draw` the
/// first time you see it, a quicker `settle` when a refresh moves it — and hand-rolling that
/// pair of `onAppear`/`onChange` per gauge is how half of them end up not animating at all.
///
/// ```swift
/// Drawn(to: readiness) { shown in
///     Circle().trim(from: 0, to: shown)
/// }
/// ```
struct Drawn<Content: View>: View {
    private let target: Double
    private let content: (Double) -> Content

    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(to target: Double, @ViewBuilder content: @escaping (Double) -> Content) {
        self.target = target
        self.content = content
    }

    var body: some View {
        content(shown)
            .onAppear {
                guard !reduceMotion else { shown = target; return }
                withAnimation(Motion.draw) { shown = target }
            }
            .onChange(of: target) { _, new in
                guard !reduceMotion else { shown = new; return }
                withAnimation(Motion.settle) { shown = new }
            }
    }
}

// MARK: - Zoom navigation

private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// The namespace zoom pushes are matched in. Published by `RootTabView`, which owns both
    /// ends of every push: the card lives on a tab, the destination lives in
    /// `navigationDestination`, and a `@Namespace` declared in either one can't see the other.
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Marks this view as the visual origin of a zoom push — the card that grows into the
    /// screen. Silently a no-op before iOS 18, where the push just cross-fades as it always
    /// did; the deployment target is 17.0 and this isn't worth raising it over.
    @ViewBuilder
    func zoomSource(_ id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// The receiving end of `zoomSource`. Reduce Motion is handled by the system for
    /// navigation transitions, so there's no gate here.
    @ViewBuilder
    func zoomDestination(_ id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let namespace {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

// MARK: - Haptics

/// Deliberately *not* gated on Reduce Motion — haptics are how the app stays legible when
/// animation is turned off, not another thing to turn off with it.
///
/// Generators are held rather than allocated per call: `prepare()` is what buys the sub-frame
/// latency that makes a tick feel attached to your finger, and a generator created and thrown
/// away at the moment of impact never gets to warm up. That matters most for the training
/// wall scrub, which fires one of these per cell crossed.
@MainActor
enum Haptics {
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notice = UINotificationFeedbackGenerator()

    /// A tappable surface accepted the press.
    static func tap() {
        impactLight.impactOccurred()
        impactLight.prepare()
    }

    /// The selected thing changed — tab switch, scrubbing across the training wall.
    static func select() {
        selection.selectionChanged()
        selection.prepare()
    }

    /// A decision was committed — confirming a coach proposal, banking a check-in.
    static func commit() {
        notice.notificationOccurred(.success)
        notice.prepare()
    }

    /// Something needs attention, or an action was refused.
    static func warn() {
        notice.notificationOccurred(.warning)
        notice.prepare()
    }

    /// A heavier landing — a screen arriving, a run opening.
    static func land() {
        impactMedium.impactOccurred()
        impactMedium.prepare()
    }

    /// Call before a burst of haptics (e.g. on a scrub gesture starting) so the first tick
    /// isn't the slow one.
    static func warmUp() {
        selection.prepare()
        impactLight.prepare()
    }
}
