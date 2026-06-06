import AppKit
import Foundation

/// Opens macOS System Settings / System Preferences panes for first-run permission setup.
/// URLs vary slightly by OS version; we prefer Ventura+ style and fall back where sensible.
enum SystemPrivacySettings {
    static func openPrivacySecurity() {
        if #available(macOS 13.0, *) {
            open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
        } else {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy")
        }
    }

    /// Assistive / control apps — needed only for some automation or UI-test tooling.
    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Apple Events / “Automation” — required for AppleScript-based terminal tab jumping (`NSAppleEventsUsageDescription`).
    static func openAutomation() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    /// Login Items & Extensions (background items) — pairs with “Launch at Login”.
    static func openLoginItems() {
        if #available(macOS 13.0, *) {
            open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        } else {
            open("x-apple.systempreferences:com.apple.preferences.users")
        }
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
