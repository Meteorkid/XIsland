import Foundation

enum CollapsedTickerContentMode: String, CaseIterable {
    case activity
    case project
    case automatic

    static let defaultValue: Self = .activity
    static let rotationInterval: TimeInterval = 6

    static func resolve(rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? defaultValue
    }

    var localizedTitle: String {
        switch self {
        case .activity:
            return L10n.tickerContentActivity
        case .project:
            return L10n.tickerContentProject
        case .automatic:
            return L10n.tickerContentAutomatic
        }
    }
}
