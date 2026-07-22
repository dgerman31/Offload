import SwiftUI

/// Offload's design tokens, taken directly from the build spec (section 5.2 / 5.3).
/// Colors are defined for both light and dark appearances; nothing is hardcoded at
/// call sites — views reference `Color.Offload.*` and `Font.Offload.*`.
enum OffloadTheme {}

extension Color {
    enum Offload {
        // Brand + semantic colors (spec 5.2)
        static let indigo   = Color(hex: 0x2E3B8C)   // primary actions, active states
        static let teal     = Color(hex: 0x16A9A3)   // completion, positive states
        static let amber    = Color(hex: 0xD4A959)   // deferred / friction / warnings
        static let green    = Color(hex: 0x22C55E)   // completed
        static let red      = Color(hex: 0xEF4444)   // overdue / blocked

        // Surfaces + text — adapt to light/dark.
        // Light mode is a warm cream (Design Language 2.0 "elite pass") — pure-white cards float
        // above a paper-like #FAF6EE ground; dark mode is the deep indigo-black from the design
        // language, never a flat neutral grey.
        static let background = Color(light: 0xFAF6EE, dark: 0x0E1020)
        static let surface    = Color(light: 0xFFFFFF, dark: 0x181B2E) // cards, inputs
        static let elevated   = Color(light: 0xFFFFFF, dark: 0x1F2340) // sheets, popovers
        static let text       = Color(light: 0x17171B, dark: 0xECECEC) // primary text
        static let muted      = Color(light: 0x7A756B, dark: 0x9AA0AA) // secondary text (warm grey)
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
