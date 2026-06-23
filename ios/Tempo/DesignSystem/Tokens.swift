import SwiftUI

/// Tempo design tokens — generated from the Figma design system (v2, dark-first).
/// Single source of truth for color, type, spacing, and radius in the app.
enum Tokens {

    // MARK: Color
    enum Palette {
        // Surfaces
        static let canvas    = Color(hex: 0x0B0D10)  // app background
        static let surface   = Color(hex: 0x161A20)  // cards
        static let elevated  = Color(hex: 0x222831)  // raised surfaces / borders
        static let inset     = Color(hex: 0x0E1014)  // wells, tab bar
        static let divider   = Color(hex: 0x2A313B)

        // Text
        static let textPrimary   = Color(hex: 0xF3F5F8)
        static let textSecondary = Color(hex: 0x9BA5B3)
        static let textTertiary  = Color(hex: 0x646E7C)

        // Brand + status
        static let volt    = Color(hex: 0xCDFB45)  // the one accent
        static let onVolt  = Color(hex: 0x0B0D10)  // text/icon on volt
        static let success = Color(hex: 0x34D399)
        static let warning = Color(hex: 0xFBBF24)
        static let danger  = Color(hex: 0xF87171)
        static let info    = Color(hex: 0x3BD7F5)
    }

    /// Pace / HR zone ramp (Z1 easy → Z5 max).
    enum Zone {
        static let z1 = Color(hex: 0x4F8DF7)
        static let z2 = Color(hex: 0x34D399)
        static let z3 = Color(hex: 0xCDFB45)
        static let z4 = Color(hex: 0xFB923C)
        static let z5 = Color(hex: 0xF43F5E)
        static let all = [z1, z2, z3, z4, z5]
    }

    // MARK: Typography
    // Display/titles: Space Grotesk · UI/body: Inter · Metrics: Roboto Mono
    enum Font {
        static func display(_ size: CGFloat) -> SwiftUI.Font { .custom("SpaceGrotesk-Bold", size: size) }
        static func ui(_ size: CGFloat, _ weight: Weight = .regular) -> SwiftUI.Font {
            .custom("Inter-\(weight.rawValue)", size: size)
        }
        static func mono(_ size: CGFloat) -> SwiftUI.Font { .custom("RobotoMono-Medium", size: size) }

        enum Weight: String { case regular = "Regular", medium = "Medium", semibold = "SemiBold", bold = "Bold", extrabold = "ExtraBold" }
    }

    // MARK: Spacing & radius scales (match Figma)
    enum Space { static let xs2: CGFloat = 2, xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 20, xl2: CGFloat = 24, xl3: CGFloat = 32, xl4: CGFloat = 40 }
    enum Radius { static let sm: CGFloat = 6, md: CGFloat = 10, lg: CGFloat = 14, xl: CGFloat = 20, xl2: CGFloat = 28, full: CGFloat = 999 }
}

extension Color {
    /// Hex int initializer, e.g. `Color(hex: 0xCDFB45)`.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
