import SwiftUI

/// Appearance preference (spec §5.2). Defaults to following the system, but the user can pin
/// light or dark — a genuine preference for a app you open at 6am and 11pm.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    static let storageKey = "offload.appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Automatic"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "iphone"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.stars.fill"
        }
    }

    /// nil = follow the device, which is what `preferredColorScheme` wants.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Per-category colour. Categories are the app's main visual rhythm — a glance at a list
/// should tell you the *shape* of your day before you read a single word. Accents stay legible
/// on both appearances; tints are the soft card washes from the design reference.
extension Color.Offload {

    /// Saturated accent — text, icons, timeline nodes, progress.
    static func accent(for category: String?) -> Color {
        switch category ?? "Other" {
        case "Work":     return Color(light: 0x4C6FE7, dark: 0x7C97F5)   // blue
        case "Personal": return Color(light: 0xE8547C, dark: 0xF2799A)   // coral
        case "Health":   return Color(light: 0x18A97F, dark: 0x35C99B)   // mint
        case "Finance":  return Color(light: 0xD79A2B, dark: 0xE8B85A)   // amber
        case "Projects": return Color(light: 0x7A5AE0, dark: 0x9E86F0)   // violet
        case "Ideas":    return Color(light: 0x1AA0B8, dark: 0x45C2D8)   // teal
        case "Habits":   return Color(light: 0x2E8BC9, dark: 0x5FAEE5)   // sky
        case "Study":    return Color(light: 0x4F46E5, dark: 0x818CF8)   // indigo
        default:         return Color(light: 0x6B7280, dark: 0x9AA0AA)   // slate
        }
    }

    /// The soft wash a card sits on — pastel in light mode, a dim veil in dark.
    static func tint(for category: String?) -> Color {
        accent(for: category).opacity(0.12)
    }
}

/// Applies the user's appearance preference to a whole view tree.
struct ThemedRoot: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

    func body(content: Content) -> some View {
        content.preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
    }
}

extension View {
    /// Honour the user's light/dark choice.
    func themed() -> some View { modifier(ThemedRoot()) }
}
