import Testing
import Foundation
@testable import Offload

/// The palette has to stay readable, and "readable" is arithmetic rather than taste.
///
/// This exists because the light palette shipped for months failing WCAG on every colour that
/// carries meaning — teal at 2.90:1, amber at 2.18:1, green at 2.28:1 against a white card, all
/// below even the 3:1 large-text floor. Nobody noticed, because nothing measured it. Now something
/// does, and a future palette tweak that breaks contrast fails CI instead of shipping.
struct PaletteContrastTests {

    /// WCAG relative luminance.
    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let c = Double(raw) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel((hex >> 16) & 0xFF)
        let g = channel((hex >> 8) & 0xFF)
        let b = channel(hex & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// WCAG AA for body text.
    private let normalText = 4.5
    /// WCAG AA for large text and for meaningful non-text elements.
    private let largeText = 3.0

    @Test("The contrast maths itself is right")
    func sanity() {
        #expect(abs(contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(contrast(0xFFFFFF, 0xFFFFFF) - 1) < 0.01)
    }

    // MARK: Light mode

    @Test("Every semantic colour is readable on a light card")
    func lightOnSurface() {
        let surface = OffloadPalette.surfaceLight
        for (name, hex) in [("teal", OffloadPalette.tealLight),
                            ("amber", OffloadPalette.amberLight),
                            ("green", OffloadPalette.greenLight),
                            ("red", OffloadPalette.redLight),
                            ("indigo text", OffloadPalette.indigoTextLight),
                            ("muted", OffloadPalette.mutedLight),
                            ("text", OffloadPalette.textLight)] {
            let ratio = contrast(hex, surface)
            #expect(ratio >= normalText, "\(name) on a light card is \(ratio):1, needs \(normalText)")
        }
    }

    @Test("…and on the cream page background, which is the harder of the two")
    func lightOnBackground() {
        // Cream is darker than the white cards, so a dark foreground has *less* contrast against
        // it. Anything that passes here passes on a card too.
        let background = OffloadPalette.backgroundLight
        for (name, hex) in [("teal", OffloadPalette.tealLight),
                            ("amber", OffloadPalette.amberLight),
                            ("green", OffloadPalette.greenLight),
                            ("red", OffloadPalette.redLight),
                            ("muted", OffloadPalette.mutedLight)] {
            let ratio = contrast(hex, background)
            #expect(ratio >= normalText, "\(name) on the cream background is \(ratio):1")
        }
    }

    // MARK: Dark mode

    @Test("Every semantic colour is readable on a dark card")
    func darkOnSurface() {
        let surface = OffloadPalette.surfaceDark
        for (name, hex) in [("teal", OffloadPalette.tealDark),
                            ("amber", OffloadPalette.amberDark),
                            ("green", OffloadPalette.greenDark),
                            ("red", OffloadPalette.redDark),
                            ("indigo text", OffloadPalette.indigoTextDark),
                            ("muted", OffloadPalette.mutedDark),
                            ("text", OffloadPalette.textDark)] {
            let ratio = contrast(hex, surface)
            #expect(ratio >= normalText, "\(name) on a dark card is \(ratio):1, needs \(normalText)")
        }
    }

    @Test("The indigo used as text is not the indigo used as a fill")
    func indigoIsTwoTokens() {
        // The bug this encodes: the fill value on a dark card is 1.72:1 — the primary action
        // colour, effectively invisible. One token cannot be both a fill and a foreground.
        #expect(contrast(OffloadPalette.indigoFillDark, OffloadPalette.surfaceDark) < normalText)
        #expect(contrast(OffloadPalette.indigoTextDark, OffloadPalette.surfaceDark) >= normalText)
    }

    // MARK: Fills

    @Test("White text on a brand fill is readable in both modes")
    func whiteOnFills() {
        let white: UInt32 = 0xFFFFFF
        #expect(contrast(white, OffloadPalette.indigoFillLight) >= normalText)
        #expect(contrast(white, OffloadPalette.indigoFillDark) >= normalText)
        // The solid teal capsule uses the deep value in both modes for exactly this reason — the
        // bright dark-mode teal is only 2.90:1 under white.
        #expect(contrast(white, OffloadPalette.tealLight) >= normalText)
    }

    @Test("A brand fill is visible against the card it sits on")
    func fillSeparatesFromSurface() {
        // Non-text UI needs 3:1. A dark-mode indigo capsule that matches the card is a button
        // nobody can find.
        #expect(contrast(OffloadPalette.indigoFillDark, OffloadPalette.surfaceDark) >= largeText)
    }
}
