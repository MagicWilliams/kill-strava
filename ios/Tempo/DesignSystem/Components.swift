import SwiftUI

// MARK: - Well tint propagation

private struct WellKey: EnvironmentKey {
    static let defaultValue: Tokens.Well = .neutral
}

extension EnvironmentValues {
    /// The tint of the enclosing `Card`. Read by `InsetWell` so a nested panel recesses
    /// against its actual parent rather than against a guess.
    var well: Tokens.Well {
        get { self[WellKey.self] }
        set { self[WellKey.self] = newValue }
    }
}

// MARK: - Card

/// A tinted well. **No border, no shadow** — v2's `elevated` stroke and
/// `black.opacity(0.35)` drop shadow are both gone.
///
/// The shadow had to go before the light theme could work at all: a shadow tuned to separate
/// a `#161A20` card from a `#0B0D10` canvas does nothing on white but add grey haze, and the
/// usual fix — a second shadow value per theme — doubles the tuning surface of every card in
/// the app forever. A fill that differs from the canvas separates in both themes with one
/// value, and it can carry meaning while it's at it. See `Tokens.Well`.
struct Card<Content: View>: View {
    private let padding: CGFloat
    private let well: Tokens.Well
    private let content: Content

    init(padding: CGFloat = 18, well: Tokens.Well = .neutral, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.well = well
        self.content = content()
    }

    /// Source-compatible shim for `Card(glow:)`.
    ///
    /// v2's volt glow only ever meant "this is the card that matters right now", which is
    /// exactly `Well.accent`. Kept so the screens still queued for conversion keep compiling
    /// and keep looking deliberate in the meantime; delete it once they're all converted.
    init(padding: CGFloat = 18, glow: Bool, @ViewBuilder content: () -> Content) {
        self.init(padding: padding, well: glow ? .accent : .neutral, content: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.md) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(well.fill)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
            .environment(\.well, well)
    }
}

/// A recessed panel inside a `Card` — the coach's read, a warning strip, a sub-metric block.
/// Takes its fill from the enclosing card's tint, so a nested well inside a warm card stays
/// warm instead of punching a neutral grey hole in it.
struct InsetWell<Content: View>: View {
    @Environment(\.well) private var well
    private let padding: CGFloat
    private let radius: CGFloat
    private let content: Content

    init(padding: CGFloat = 12, radius: CGFloat = Tokens.Radius.md, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(well.insetFill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Type

/// Mono uppercase section label (tracking matches the Figma system).
///
/// The default is `textTertiary`; for an accent eyebrow pass `Tokens.Palette.accentText`,
/// never `.volt` — volt is a fill and vanishes on the light canvas.
struct SectionLabel: View {
    private let text: String
    private let color: Color

    init(_ text: String, color: Color = Tokens.Palette.textTertiary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Tokens.Font.mono(11))
            .tracking(1.5)
            .foregroundStyle(color)
    }
}

/// Small status pill. `bg` is a fill, so volt is legal here — with `onVolt` on top.
struct Tag: View {
    let text: String
    var fg: Color = Tokens.Palette.success
    var bg: Color = Tokens.Well.success.insetFill

    var body: some View {
        Text(text)
            .font(Tokens.Font.ui(11, .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(bg)
            .clipShape(Capsule())
    }
}

// MARK: - Interaction

/// Press feedback: spring scale, a light dim, and a haptic tick, so a tap lands in three
/// senses at once. Replaces v2's flat 0.12s ease-out, which was the app's only tactile signal
/// and read as lag rather than as feedback.
struct Pressable: ButtonStyle {
    var haptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        // ButtonStyle isn't a View, so @Environment can't live on the style itself — the
        // Reduce Motion read has to happen inside a real view. Not named `Body`: that
        // collides with ButtonStyle's own `Body` associatedtype and breaks conformance.
        PressBody(configuration: configuration, haptic: haptic)
    }

    private struct PressBody: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration
        let haptic: Bool

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.92 : 1)
                .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
                .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: configuration.isPressed) { _, pressed in
                    haptic && pressed
                }
        }
    }
}

/// Full-width volt CTA with built-in loading state.
struct PrimaryButton: View {
    let title: String
    var loading = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().controlSize(.small).tint(Tokens.Palette.onVolt)
                }
                Text(title)
                    .font(Tokens.Font.ui(16, .bold))
                    .foregroundStyle(Tokens.Palette.onVolt)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Tokens.Palette.volt.opacity(loading ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
            .motion(Motion.reveal, value: loading)
        }
        .buttonStyle(Pressable())
        .disabled(loading)
    }
}

/// Compact metric tile (value over label).
struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).display(22)
            SectionLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Tokens.Well.neutral.fill)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
    }
}

// MARK: - Screen

/// Standard scrollable screen with a large title header and the canvas background.
struct Screen<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).display(30)
                    if let subtitle {
                        Text(subtitle).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                    }
                }
                .padding(.top, 8)
                content
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tokens.Palette.canvas)
        .scrollIndicators(.hidden)
    }
}

// MARK: - Text helpers

extension Text {
    /// Mono metric text helper.
    func mono(_ size: CGFloat, _ color: Color = Tokens.Palette.textPrimary) -> some View {
        self.font(Tokens.Font.mono(size)).foregroundStyle(color)
    }

    /// Display type with the optical tracking a light canvas needs.
    ///
    /// Dark type on white looks heavier than light type on black at the same size — the
    /// glyphs read as thicker than they measure. Space Grotesk only ships Bold here, so
    /// weight isn't a lever; tightening tracking as size grows is, and it keeps big numbers
    /// from turning into slabs on the new ground.
    func display(_ size: CGFloat, _ color: Color = Tokens.Palette.textPrimary) -> some View {
        self.font(Tokens.Font.display(size))
            .tracking(size >= 28 ? -0.8 : size >= 20 ? -0.4 : 0)
            .foregroundStyle(color)
    }
}
