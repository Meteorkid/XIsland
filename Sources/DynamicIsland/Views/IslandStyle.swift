import SwiftUI

/// Visual chrome aligned with the physical notch / camera housing strip.
/// Provides both parameterized (dynamic) and backward-compatible (static) accessors.
enum IslandStyle {

    // MARK: - Dynamic accessors (preferred)

    /// Capsule + expanded panel background.
    static func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }

    static func strokeOpacity(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.14 : 0.12
    }

    /// Session cards — subtle lift on background.
    static func cardRest(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.05)
    }

    static func cardHover(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.10) : .black.opacity(0.08)
    }

    static func cardStrokeRest(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.08 : 0.10
    }

    static func cardStrokeHover(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.14 : 0.15
    }

    /// Nested rows (permission copy, question options, jump chip).
    static func insetFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.04)
    }

    /// Code / diff / markdown wells.
    static func codeWell(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.05) : .black.opacity(0.03)
    }

    /// Primary text color.
    static func primaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.9) : .black.opacity(0.85)
    }

    /// Secondary text color.
    static func secondaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.6) : .black.opacity(0.55)
    }

    /// Accent color.
    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .cyan : .blue
    }

    // MARK: - Backward-compatible static properties (dark defaults)

    /// Capsule + expanded panel — matches the notch area (OLED black).
    static var surface: Color { surface(for: .dark) }
    static var strokeOpacity: CGFloat { strokeOpacity(for: .dark) }

    /// Session cards — subtle lift on black.
    static var cardRest: Color { cardRest(for: .dark) }
    static var cardHover: Color { cardHover(for: .dark) }
    static var cardStrokeRest: CGFloat { cardStrokeRest(for: .dark) }
    static var cardStrokeHover: CGFloat { cardStrokeHover(for: .dark) }

    /// Nested rows.
    static var insetFill: Color { insetFill(for: .dark) }

    /// Code wells.
    static var codeWell: Color { codeWell(for: .dark) }
}
