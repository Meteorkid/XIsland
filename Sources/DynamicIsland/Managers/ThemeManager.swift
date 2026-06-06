import AppKit
import Observation
import SwiftUI

/// Supported appearance modes for the app.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark: return L10n.appearanceDark
        case .light: return L10n.appearanceLight
        case .system: return L10n.appearanceSystem
        }
    }
}

/// Manages the app's color scheme with dark/light/system modes.
@Observable @MainActor
final class ThemeManager {
    private static let storageKey = "appearanceMode"

    var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
            updateResolvedScheme()
            if mode == .system {
                startObservingSystemAppearance()
            } else {
                stopObservingSystemAppearance()
            }
        }
    }

    private(set) var resolvedScheme: ColorScheme

    /// KVO observer token for `NSApp.effectiveAppearance`.
    var effectiveAppearanceObservation: NSKeyValueObservation?

    init() {
        let initialMode: AppearanceMode = {
            if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
               let saved = AppearanceMode(rawValue: raw) {
                return saved
            }
            return .dark
        }()
        self.mode = initialMode
        self.resolvedScheme = initialMode == .dark ? .dark : .light
        updateResolvedScheme()
        if initialMode == .system {
            startObservingSystemAppearance()
        }
    }

    /// Cycle through dark -> light -> system -> dark.
    func toggleMode() {
        switch mode {
        case .dark: mode = .light
        case .light: mode = .system
        case .system: mode = .dark
        }
    }

    // MARK: - System Appearance Observation

    func startObservingSystemAppearance() {
        guard effectiveAppearanceObservation == nil else { return }
        effectiveAppearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateResolvedScheme()
            }
        }
    }

    func stopObservingSystemAppearance() {
        effectiveAppearanceObservation?.invalidate()
        effectiveAppearanceObservation = nil
    }

    private func updateResolvedScheme() {
        switch mode {
        case .dark:
            resolvedScheme = .dark
        case .light:
            resolvedScheme = .light
        case .system:
            let appearance = NSApp.effectiveAppearance
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            resolvedScheme = match == .darkAqua ? .dark : .light
        }
    }
}
