import SwiftUI
import UIKit

/// Tempo design tokens — color, type, spacing, radius. Single source of truth.
///
/// **v3 is theme-resolving.** Every palette token is a dynamic `UIColor` that picks its value
/// from the trait environment, so `Tokens.Palette.canvas` is white in light mode and near-black
/// in dark without a single call site changing. That property is why the facelift could land
/// as a pilot: the screens that haven't been retuned yet still compile and still follow the
/// system appearance — they're un-*tuned*, not broken.
///
/// Two rules the palette encodes, both learned the hard way:
///
/// 1. **Volt is a fill, never text.** `#CDFB45` is ~1.2:1 on white — as body or label text on a
///    light ground it is not "low contrast", it is invisible. It stays for button fills, pills,
///    ring strokes and chart marks, always with `onVolt` on top. Anything that wants to *say*
///    accent in text reaches for `accentText`, which is volt-derived ink on light and volt
///    itself on dark.
/// 2. **Cards are tinted wells, not floating surfaces.** No borders, no shadows. A card is a
///    fill lifted off the canvas, and the fill carries meaning — see `Well`.
enum Tokens {

    // MARK: Color

    /// Resolves a light/dark pair against the trait environment.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    enum Palette {
        // Surfaces
        /// App background. Flat — the wells do the separating.
        static let canvas   = Tokens.dynamic(light: 0xFFFFFF, dark: 0x0B0D10)
        /// Default well fill. Equivalent to `Well.neutral`.
        static let surface  = Tokens.dynamic(light: 0xF4F5F3, dark: 0x161A20)
        /// A well *inside* a well — recessed one more step in both themes.
        static let inset    = Tokens.dynamic(light: 0xEAECE7, dark: 0x0E1014)
        /// Tracks, unfilled gauge strokes, inactive dots. Not a border colour any more.
        static let elevated = Tokens.dynamic(light: 0xE2E5E0, dark: 0x222831)
        static let divider  = Tokens.dynamic(light: 0xE6E9E4, dark: 0x2A313B)

        // Text — light values are contrast-checked against the *canvas*, which is the worst
        // case; every well is darker than white, so each only improves from here.
        static let textPrimary   = Tokens.dynamic(light: 0x14171A, dark: 0xF3F5F8) // 17.0:1
        static let textSecondary = Tokens.dynamic(light: 0x4A525C, dark: 0x9BA5B3) //  7.9:1
        // Both values clear 4.5:1 against every ground in `Tokens.Well` — the *inset* fills
        // included, which is what the first two attempts at the light value missed. A mid-grey
        // on a light ground gets worse as the ground darkens, so the recessed panels are the
        // binding constraint, not the canvas. The dark value was already under on `surface`
        // before this change: `SectionLabel` is 11pt mono and lives on cards, so the canvas
        // was never its real background either. Pinned by `DesignTokenTests`.
        static let textTertiary  = Tokens.dynamic(light: 0x5B6470, dark: 0x7E8794) //  6.0:1 / 5.4:1

        // Brand
        /// The one accent. **Fill only** — see the type-level note.
        static let volt   = Tokens.dynamic(light: 0xCDFB45, dark: 0xCDFB45)
        /// Text and icons on a volt fill. Near-black in both themes, because volt is.
        static let onVolt = Tokens.dynamic(light: 0x0B0D10, dark: 0x0B0D10)
        /// Volt's legal text form: darkened to ink on light (9.5:1), volt itself on dark.
        /// This is what `SectionLabel(color:)` eyebrows and accent links should use.
        static let accentText = Tokens.dynamic(light: 0x3F4A16, dark: 0xCDFB45)
        /// Volt for *marks* — gauge arcs, day dots, progress bars, chart washes. Anything
        /// that has to be seen against the ground rather than sit underneath dark text.
        ///
        /// "Fill only" isn't the whole rule. A 10pt lime dot on white is ~1.2:1, so a filled
        /// dot and an empty one look identical — and on the week strip those two states are
        /// the entire message. A button keeps plain `volt` because `onVolt` sits on top of it
        /// and carries the contrast; a bare mark has nothing on top, so it carries its own.
        ///
        /// The light value is deep enough to clear 3:1 against `elevated`, which is the colour
        /// of the *unfilled* dot — the comparison that actually decides whether the week strip
        /// is readable. That pushes it to olive rather than lime, which is the same place
        /// `accentText` lands: on a light ground, volt survives only where dark text sits on
        /// top of it.
        static let voltMark = Tokens.dynamic(light: 0x6E8712, dark: 0xCDFB45)

        // Status — the dark values are the originals; the light ones are deepened, because
        // a colour tuned to glow on near-black washes out completely on white. Each is checked
        // against *every* well, both depths: an `info` note sits in whatever card the session
        // it annotates happens to be, so "readable on its own tint" isn't the bar.
        static let success = Tokens.dynamic(light: 0x0C6A47, dark: 0x34D399)
        static let warning = Tokens.dynamic(light: 0x8A5A00, dark: 0xFBBF24)
        static let danger  = Tokens.dynamic(light: 0xB3261E, dark: 0xF87171)
        static let info    = Tokens.dynamic(light: 0x0A6E85, dark: 0x3BD7F5)
    }

    /// Card fills. The tint *is* the label: scanning the Plan list, you read the shape of a
    /// week before you read a word of it.
    ///
    /// Kept deliberately quiet. These sit a few points off the canvas, not a few dozen — the
    /// failure mode for a tinted-well system on white is a page that looks like a highlighter
    /// accident, and the fix is restraint in the token, not restraint in how often it's used.
    enum Well: CaseIterable {
        /// Everything with no particular character. The default.
        case neutral
        /// Rest and recovery. Cool, a step back.
        case calm
        /// Quality work — intervals, tempo, anything that costs something.
        case warm
        /// Long runs. Cool but substantial, distinct from rest.
        case cool
        /// The card that wants your attention right now. Replaces v2's volt glow.
        case accent
        case success, warning, danger

        var fill: Color {
            switch self {
            case .neutral: return Tokens.dynamic(light: 0xF4F5F3, dark: 0x161A20)
            case .calm:    return Tokens.dynamic(light: 0xEFF2F6, dark: 0x141A22)
            case .warm:    return Tokens.dynamic(light: 0xFAF5E9, dark: 0x1F1B12)
            case .cool:    return Tokens.dynamic(light: 0xEBF3F5, dark: 0x121D21)
            case .accent:  return Tokens.dynamic(light: 0xF3F8E2, dark: 0x1A1F10)
            case .success: return Tokens.dynamic(light: 0xECF6F1, dark: 0x11201A)
            case .warning: return Tokens.dynamic(light: 0xFCF4E3, dark: 0x211B0F)
            case .danger:  return Tokens.dynamic(light: 0xFBEFEE, dark: 0x231313)
            }
        }

        /// The recessed fill for a well nested inside this one.
        var insetFill: Color {
            switch self {
            case .neutral: return Tokens.Palette.inset
            case .calm:    return Tokens.dynamic(light: 0xE4EAF0, dark: 0x0F141B)
            case .warm:    return Tokens.dynamic(light: 0xF3EBD8, dark: 0x17140D)
            case .cool:    return Tokens.dynamic(light: 0xDFEBEE, dark: 0x0D1518)
            case .accent:  return Tokens.dynamic(light: 0xE9F2CE, dark: 0x13170B)
            case .success: return Tokens.dynamic(light: 0xDFEFE7, dark: 0x0C1813)
            case .warning: return Tokens.dynamic(light: 0xF7EBD0, dark: 0x18140A)
            case .danger:  return Tokens.dynamic(light: 0xF6E2E0, dark: 0x1A0E0E)
            }
        }
    }

    /// Training-wall intensity ramp, level 0 (no run) → 4 (biggest day).
    ///
    /// Each step is its own light/dark pair rather than `volt.opacity(…)`. Translucent lime
    /// over white barely separates from the paper at the low end, which flattens exactly the
    /// thing the wall exists to show — the shape of a season, the injury gap, the taper. On
    /// light the ramp runs pale-lime → deep olive; on dark it runs dim → full volt.
    enum Wall {
        static let ramp: [Color] = [
            Tokens.dynamic(light: 0xEEF0EC, dark: 0x0E1014),
            Tokens.dynamic(light: 0xD3E39B, dark: 0x3A4718),
            Tokens.dynamic(light: 0xC3DC6B, dark: 0x6F8B25),
            Tokens.dynamic(light: 0xA8CE1F, dark: 0x9DC533),
            Tokens.dynamic(light: 0x6E8712, dark: 0xCDFB45),
        ]
    }

    /// Pace / HR zone ramp (Z1 easy → Z5 max). Used as fills — bars, wall cells, chart marks —
    /// so the light values are deepened enough to hold their own against white.
    enum Zone {
        static let z1 = Tokens.dynamic(light: 0x2F6FE0, dark: 0x4F8DF7)
        static let z2 = Tokens.dynamic(light: 0x0F9D6E, dark: 0x34D399)
        static let z3 = Tokens.dynamic(light: 0xA8CE1F, dark: 0xCDFB45)
        static let z4 = Tokens.dynamic(light: 0xE07A16, dark: 0xFB923C)
        static let z5 = Tokens.dynamic(light: 0xDE2A47, dark: 0xF43F5E)
        static let all = [z1, z2, z3, z4, z5]
    }

    // MARK: Typography
    // Display/titles: Space Grotesk · UI/body: Inter · Metrics: Roboto Mono
    //
    // Retuned for a light ground. Ink on white carries more optical weight than paper on ink,
    // so display sizes that looked right at 28/24/22 on near-black read chunky on the new
    // canvas. The scale below is the retune: sizes stay, but callers reach for `display` less
    // and `ui(_, .bold)` more for mid-level headings. Sizes and families are unchanged so no
    // font files move and `project.yml` doesn't change.
    enum Font {
        static func display(_ size: CGFloat) -> SwiftUI.Font { .custom("SpaceGrotesk-Bold", size: size) }
        static func ui(_ size: CGFloat, _ weight: Weight = .regular) -> SwiftUI.Font {
            .custom("Inter-\(weight.rawValue)", size: size)
        }
        static func mono(_ size: CGFloat) -> SwiftUI.Font { .custom("RobotoMono-Medium", size: size) }

        enum Weight: String { case regular = "Regular", medium = "Medium", semibold = "SemiBold", bold = "Bold", extrabold = "ExtraBold" }
    }

    // MARK: Spacing & radius scales
    enum Space { static let xs2: CGFloat = 2, xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 20, xl2: CGFloat = 24, xl3: CGFloat = 32, xl4: CGFloat = 40 }
    enum Radius { static let sm: CGFloat = 6, md: CGFloat = 10, lg: CGFloat = 14, xl: CGFloat = 20, xl2: CGFloat = 28, full: CGFloat = 999 }
}

extension UIColor {
    /// Hex int initializer, e.g. `UIColor(hex: 0xCDFB45)`.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue:  CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// Hex int initializer, e.g. `Color(hex: 0xCDFB45)`.
    ///
    /// Static — it does *not* follow the appearance. Prefer a `Tokens.Palette` member; this
    /// stays for one-off literals that genuinely mean the same thing in both themes.
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
