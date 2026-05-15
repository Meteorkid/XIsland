import AppKit
import XCTest
@testable import XIsland

@MainActor
final class AppDelegateUITestLaunchTests: XCTestCase {
    func testApplicationDidFinishLaunchingOpensPreferencesWhenRequested() {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()

        defer {
            NSApp.windows
                .filter { $0.title == "X Island Settings" }
                .forEach { $0.close() }
            NSApp.setActivationPolicy(previousPolicy)
        }

        let appDelegate = AppDelegate(
            testConfiguration: AppTestConfiguration(
                isEnabled: true,
                fixtureName: "update-available",
                fixturePath: nil,
                diagnosticsPath: nil,
                disableAnimations: false,
                opensPreferencesOnLaunch: true
            ),
            launchHooks: AppDelegate.LaunchHooks(
                performInitialStartup: { _ in },
                performProductionGlobalStartup: { _ in }
            )
        )

        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertTrue(NSApp.windows.contains(where: { $0.title == "X Island Settings" }))
    }
}
