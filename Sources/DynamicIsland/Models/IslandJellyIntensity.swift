import Foundation

enum IslandJellyIntensity: String, CaseIterable {
    case low = "weak"
    case medium
    case high = "strong"

    static let defaultValue: Self = .medium

    static func resolve(rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? defaultValue
    }

    var localizedTitle: String {
        switch self {
        case .low:
            return L10n.jellyWeak
        case .medium:
            return L10n.jellyMedium
        case .high:
            return L10n.jellyStrong
        }
    }
}
