import SwiftUI

/// Visual chrome aligned with the physical notch / camera housing strip.
/// Text colors use SwiftUI semantic colors (.primary/.secondary) which
/// automatically adapt when NSApp.appearance is set by ThemeManager.
/// Background/decoration colors are custom per-scheme.
enum IslandStyle {

    // MARK: - Text colors (auto-adapt via NSApp.appearance)

    /// Primary text — full contrast heading / label.
    /// Resolves to white in dark mode, black in light mode.
    static var primaryText: Color { .primary }

    /// Secondary text — body / description.
    /// Resolves to gray-white in dark mode, gray-black in light mode.
    static var secondaryText: Color { .secondary }

    /// Tertiary text — timestamps, meta, hints.
    /// Needs explicit scheme because SwiftUI has no tertiary semantic color.
    static func tertiaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.35) : .black.opacity(0.40)
    }

    // MARK: - Background / decoration (per-scheme)

    /// Capsule + expanded panel background.
    static func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : Color(white: 0.965)
    }

    /// Session cards — subtle lift on background.
    static func cardRest(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.06) : Color(white: 0.91)
    }

    static func cardHover(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.10) : Color(white: 0.87)
    }

    /// Card stroke — full-opacity dedicated color per scheme.
    static func cardStrokeColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(white: 0.75)
    }

    static func cardStrokeRest(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.08 : 1.0
    }

    static func cardStrokeHover(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.14 : 1.0
    }

    /// Nested rows (permission copy, question options, jump chip).
    static func insetFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.06) : Color(white: 0.89)
    }

    /// Code / diff / markdown wells.
    static func codeWell(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.05) : Color(white: 0.88)
    }

    /// Divider / separator.
    static func divider(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(white: 0.78)
    }

    static func dividerOpacity(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.08 : 1.0
    }

    /// Capsule stroke color and opacity.
    static func strokeColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(white: 0.75)
    }

    static func strokeOpacity(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.14 : 1.0
    }

    /// Shadow.
    static func shadowColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : .black
    }

    static func shadowOpacity(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.04 : 0.08
    }

    /// Accent color.
    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .cyan : .blue
    }

    // MARK: - Backward-compatible static properties (dark defaults)

    static var surface: Color { surface(for: .dark) }
    static var cardRest: Color { cardRest(for: .dark) }
    static var cardHover: Color { cardHover(for: .dark) }
    static var insetFill: Color { insetFill(for: .dark) }
    static var codeWell: Color { codeWell(for: .dark) }
}
