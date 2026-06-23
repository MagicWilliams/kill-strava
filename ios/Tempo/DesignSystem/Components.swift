import SwiftUI

/// Surface card with the v2 depth treatment (border + soft shadow, optional volt glow).
struct Card<Content: View>: View {
    private let padding: CGFloat
    private let glow: Bool
    private let content: Content

    init(padding: CGFloat = 18, glow: Bool = false, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.glow = glow
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.md) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Tokens.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous)
                    .strokeBorder(Tokens.Palette.elevated, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
            .shadow(color: glow ? Tokens.Palette.volt.opacity(0.16) : .clear, radius: 24, x: 0, y: 2)
    }
}

/// Mono uppercase section label (tracking matches the Figma system).
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

/// Small status pill.
struct Tag: View {
    let text: String
    var fg: Color = Tokens.Palette.success
    var bg: Color = Color(hex: 0x13241D)

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

/// Full-width volt CTA.
struct PrimaryButton: View {
    let title: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Font.ui(16, .bold))
                .foregroundStyle(Tokens.Palette.onVolt)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Tokens.Palette.volt)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Compact metric tile (value over label).
struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(Tokens.Font.display(22)).foregroundStyle(Tokens.Palette.textPrimary)
            SectionLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Tokens.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(Tokens.Palette.elevated, lineWidth: 1)
        )
    }
}

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
                    Text(title).font(Tokens.Font.display(28)).foregroundStyle(Tokens.Palette.textPrimary)
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

extension Text {
    /// Mono metric text helper.
    func mono(_ size: CGFloat, _ color: Color = Tokens.Palette.textPrimary) -> some View {
        self.font(Tokens.Font.mono(size)).foregroundStyle(color)
    }
}
