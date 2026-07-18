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
        static let background = Color(light: 0xFAFAF8, dark: 0x121212) // warm off-white / near-black
        static let surface    = Color(light: 0xFFFFFF, dark: 0x1E1E1E) // cards, inputs
        static let text       = Color(light: 0x1F2937, dark: 0xECECEC) // primary text
        static let muted      = Color(light: 0x6B7280, dark: 0x9AA0AA) // secondary text
        static let divider    = Color(light: 0xE5E7EB, dark: 0x2C2C2E)
    }
}

extension Font {
    enum Offload {
        /// Display — SF Pro Rounded, heavy, section breaks only. Respects Dynamic Type.
        static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
            .system(style, design: .rounded).weight(.heavy)
        }
        /// Section header.
        static let section = Font.system(.title3, design: .rounded).weight(.bold)
        /// Task title — weight 600, scales with Dynamic Type.
        static let taskTitle = Font.system(.body).weight(.semibold)
        /// Body.
        static let body = Font.system(.body)
        /// Monospaced data (timestamps, effort) — used sparingly, spec 5.3.
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
