import SwiftUI

/// Offload's design tokens, taken directly from the build spec (section 5.2 / 5.3).
/// Colors are defined for both light and dark appearances; nothing is hardcoded at
/// call sites — views reference `Color.Offload.*` and `Font.Offload.*`.
enum OffloadTheme {}

/// The raw hex values behind `Color.Offload`, exposed so the contrast rules can be *tested*
/// rather than eyeballed. `Color` can't be read back apart on iOS, so the numbers live here and
/// the colours are built from them.
///
/// ### Why the semantic colours are light/dark pairs
///
/// They used to be single values, and light mode failed WCAG badly on every one that carries
/// meaning: teal 2.90:1, amber 2.18:1, green 2.28:1 against a white card — all below even the
/// 3:1 large-text floor. The hues are unchanged; the light-mode variants are simply dark enough
/// to read, and dark mode keeps the brighter values it always had.
///
/// Indigo needed splitting rather than darkening. As a **fill** under white text it wants to be
/// deep; as **text on a dark card** the same value is 1.72:1 and effectively invisible. One token
/// cannot be both, so there are two.
enum OffloadPalette {
    // Brand fill — carries white text. Lightened for dark mode so the shape itself separates from
    // a dark card (3.50:1) while white text on it still passes (4.86:1).
    static let indigoFillLight: UInt32 = 0x2E3B8C
    static let indigoFillDark: UInt32  = 0x5568D4
    // Indigo as text or an icon tint on a surface.
    static let indigoTextLight: UInt32 = 0x2E3B8C
    static let indigoTextDark: UInt32  = 0x8AA0FF

    static let tealLight: UInt32  = 0x107E7A
    static let tealDark: UInt32   = 0x16A9A3
    static let amberLight: UInt32 = 0x8A6A1F
    static let amberDark: UInt32  = 0xD4A959
    static let greenLight: UInt32 = 0x16823E
    static let greenDark: UInt32  = 0x22C55E
    static let redLight: UInt32   = 0xC0392B
    static let redDark: UInt32    = 0xF87171

    static let backgroundLight: UInt32 = 0xFAF6EE
    static let backgroundDark: UInt32  = 0x0E1020
    static let surfaceLight: UInt32    = 0xFFFFFF
    static let surfaceDark: UInt32     = 0x181B2E
    static let textLight: UInt32       = 0x17171B
    static let textDark: UInt32        = 0xECECEC
    static let mutedLight: UInt32      = 0x6E6A5F
    static let mutedDark: UInt32       = 0x9AA0AA
}

extension Color {
    enum Offload {
        // Brand + semantic colors (spec 5.2). Light/dark pairs — see `OffloadPalette`.
        /// Primary-action **fill**, under white text.
        static let indigo = Color(light: OffloadPalette.indigoFillLight, dark: OffloadPalette.indigoFillDark)
        /// Indigo used as **text or an icon** on a surface. Not interchangeable with `indigo`.
        static let indigoText = Color(light: OffloadPalette.indigoTextLight, dark: OffloadPalette.indigoTextDark)
        static let teal   = Color(light: OffloadPalette.tealLight, dark: OffloadPalette.tealDark)
        static let amber  = Color(light: OffloadPalette.amberLight, dark: OffloadPalette.amberDark)
        static let green  = Color(light: OffloadPalette.greenLight, dark: OffloadPalette.greenDark)
        static let red    = Color(light: OffloadPalette.redLight, dark: OffloadPalette.redDark)
        /// A solid teal fill carrying white text. Constant across modes: the bright dark-mode teal
        /// is only 2.90:1 under white, so a filled capsule must use the deep value in both.
        static let tealFill = Color(hex: OffloadPalette.tealLight)

        // Surfaces + text — adapt to light/dark.
        // Light mode is a warm cream (Design Language 2.0 "elite pass") — pure-white cards float
        // above a paper-like #FAF6EE ground; dark mode is the deep indigo-black from the design
        // language, never a flat neutral grey.
        static let background = Color(light: OffloadPalette.backgroundLight, dark: OffloadPalette.backgroundDark)
        static let surface    = Color(light: OffloadPalette.surfaceLight, dark: OffloadPalette.surfaceDark) // cards, inputs
        static let elevated   = Color(light: 0xFFFFFF, dark: 0x1F2340) // sheets, popovers
        static let text       = Color(light: OffloadPalette.textLight, dark: OffloadPalette.textDark) // primary text
        static let muted      = Color(light: OffloadPalette.mutedLight, dark: OffloadPalette.mutedDark) // secondary text
        static let divider    = Color(light: 0xEBE5D9, dark: 0x2C3050)

        /// Barely-there edge that separates layered surfaces in dark mode, where shadow alone
        /// can't. In light mode a warm near-black hairline (matching the cream ground) so cards
        /// read as pure depth, not outlines.
        static let hairline = Color(light: 0x17140A, dark: 0xFFFFFF).opacity(0.07)
    }
}

extension Font {
    enum Offload {
        /// The bundled Manrope static cut for a given weight (400/500/600/700/800). Falls back to
        /// the system font gracefully if a face fails to load, so nothing breaks either way.
        static func face(_ weight: Font.Weight) -> String {
            switch weight {
            case .black, .heavy: return "Manrope-ExtraBold"
            case .bold:          return "Manrope-Bold"
            case .semibold:      return "Manrope-SemiBold"
            case .medium:        return "Manrope-Medium"
            default:             return "Manrope-Regular"
            }
        }

        /// Manrope at a fixed point size, scaling with Dynamic Type relative to `style`. The
        /// primary way to type the redesign surfaces where an exact size matters.
        static func manrope(_ size: CGFloat, _ weight: Font.Weight = .regular,
                            relativeTo style: Font.TextStyle = .body) -> Font {
            .custom(face(weight), size: size, relativeTo: style)
        }

        /// Display — Manrope ExtraBold (800), for hero numerals and big section breaks.
        static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
            .custom("Manrope-ExtraBold", size: displaySize(style), relativeTo: style)
        }
        private static func displaySize(_ style: Font.TextStyle) -> CGFloat {
            switch style {
            case .largeTitle: return 32
            case .title:      return 28
            case .title2:     return 22
            default:          return 20
            }
        }
        /// Section header — Manrope Bold.
        static let section = Font.custom("Manrope-Bold", size: 20, relativeTo: .title3)
        /// Task title — Manrope SemiBold (600), scales with Dynamic Type.
        static let taskTitle = Font.custom("Manrope-SemiBold", size: 16, relativeTo: .body)
        /// Body — Manrope Regular.
        static let body = Font.custom("Manrope-Regular", size: 16, relativeTo: .body)
        /// Monospaced data (timestamps, effort) — SF Mono, per spec 5.3.
        static let data = Font.system(.caption, design: .monospaced)
    }
}

// MARK: - Hex helpers

extension Color {
    /// Create a color from a 0xRRGGBB integer.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// Create a dynamic color that resolves differently in light vs dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            let r = CGFloat((hex >> 16) & 0xFF) / 255
            let g = CGFloat((hex >> 8) & 0xFF) / 255
            let b = CGFloat(hex & 0xFF) / 255
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
    }
}
