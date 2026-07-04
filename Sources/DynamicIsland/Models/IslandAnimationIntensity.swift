import Foundation

enum IslandAnimationIntensity: String, CaseIterable {
    case low
    case medium
    case high

    static let defaultValue: Self = .medium

    static func resolve(rawValue: String, reduceMotion: Bool) -> Self {
        if reduceMotion {
            return .low
        }

        return Self(rawValue: rawValue) ?? defaultValue
    }

    var localizedTitle: String {
        switch self {
        case .low:
            return L10n.sensitivityLow
        case .medium:
            return L10n.sensitivityMedium
        case .high:
            return L10n.sensitivityHigh
        }
    }
}
