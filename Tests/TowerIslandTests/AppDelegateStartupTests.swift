import AppKit
import XCTest
@testable import XIsland

@MainActor
final class AppDelegateStartupTests: XCTestCase {
    func testAppDelegateSupportsDefaultInitializationForSwiftUIAppLifecycle() {
        let appDelegate = AppDelegate()

        XCTAssertNotNil(appDelegate)
    }

    func testApplicationDidFinishLaunchingSkipsProductionGlobalStartupSideEffectsInTestMode() {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        defer {
            NSApp.setActivationPolicy(previousPolicy)
        }

        let startupObserver = StartupObserver()
        let appDelegate = AppDelegate(
            testConfiguration: AppTestConfiguration(
                isEnabled: true,
                fixtureName: nil,
                fixturePath: nil,
                diagnosticsPath: nil,
                disableAnimations: false
            ),
            launchHooks: AppDelegate.LaunchHooks(
                performInitialStartup: { _ in
                    startupObserver.initialStartupRuns += 1
                },
                performProductionGlobalStartup: { _ in
                    startupObserver.productionStartupRuns += 1
                }
            )
        )

        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(startupObserver.initialStartupRuns, 1)
        XCTAssertEqual(startupObserver.productionStartupRuns, 0)
        XCTAssertTrue(AppDelegate.shared === appDelegate)
    }

    func testApplicationDidFinishLaunchingRunsProductionGlobalStartupSideEffectsOutsideTestMode() {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        defer {
            NSApp.setActivationPolicy(previousPolicy)
        }

        let startupObserver = StartupObserver()
        let appDelegate = AppDelegate(
            testConfiguration: AppTestConfiguration(
                isEnabled: false,
                fixtureName: nil,
                fixturePath: nil,
                diagnosticsPath: nil,
                disableAnimations: false
            ),
            launchHooks: AppDelegate.LaunchHooks(
                performInitialStartup: { _ in
                    startupObserver.initialStartupRuns += 1
                },
                performProductionGlobalStartup: { _ in
                    startupObserver.productionStartupRuns += 1
                }
            )
        )

        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(startupObserver.initialStartupRuns, 1)
        XCTAssertEqual(startupObserver.productionStartupRuns, 1)
        XCTAssertTrue(AppDelegate.shared === appDelegate)
    }

    func testApplicationDidFinishLaunchingWritesCollapsedDiagnosticsForNonInteractiveFixture() throws {
        let diagnosticsURL = makeDiagnosticsURL()

        let appDelegate = AppDelegate(
            testConfiguration: AppTestConfiguration(
                isEnabled: true,
                fixtureName: "session-list",
                fixturePath: nil,
                diagnosticsPath: diagnosticsURL.path,
                disableAnimations: false
            ),
            launchHooks: AppDelegate.LaunchHooks(
                performInitialStartup: { _ in },
                performProductionGlobalStartup: { _ in }
            )
        )

        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(try loadSnapshot(from: diagnosticsURL).islandState, "collapsed")
    }

    func testApplicationDidFinishLaunchingWritesPermissionDiagnosticsForPermissionFixture() throws {
        let diagnosticsURL = makeDiagnosticsURL()

        let appDelegate = AppDelegate(
            testConfiguration: AppTestConfiguration(
                isEnabled: true,
                fixtureName: "permission-smoke",
                fixturePath: nil,
                diagnosticsPath: diagnosticsURL.path,
                disableAnimations: false
            ),
            launchHooks: AppDelegate.LaunchHooks(
                performInitialStartup: { _ in },
                performProductionGlobalStartup: { _ in }
            )
        )

        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(try loadSnapshot(from: diagnosticsURL).islandState, "permission")
    }

    func testApplicationDidFinishLaunchingWritesQuestionDiagnosticsForQuestionFixture() throws {
        let diagnosticsURL = makeDiagnosticsURL()

        let appDelegate = AppDelegate(
            testConfiguration: AppTestConfiguration(
                isEnabled: true,
                fixtureName: "question-smoke",
                fixturePath: nil,
                diagnosticsPath: diagnosticsURL.path,
                disableAnimations: false
            ),
            launchHooks: AppDelegate.LaunchHooks(
                performInitialStartup: { _ in },
                performProductionGlobalStartup: { _ in }
            )
        )

        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(try loadSnapshot(from: diagnosticsURL).islandState, "question")
    }

    func testApplicationDidFinishLaunchingWritesPlanReviewDiagnosticsForPlanFixture() throws {
        let diagnosticsURL = makeDiagnosticsURL()

        let appDelegate = AppDelegate(
            testConfiguration: AppTestConfiguration(
                isEnabled: true,
                fixtureName: "plan-smoke",
                fixturePath: nil,
                diagnosticsPath: diagnosticsURL.path,
                disableAnimations: false
            ),
            launchHooks: AppDelegate.LaunchHooks(
                performInitialStartup: { _ in },
                performProductionGlobalStartup: { _ in }
            )
        )

        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(try loadSnapshot(from: diagnosticsURL).islandState, "planReview")
    }

    func testConfigureTestingThrowsWhenNamedFixtureIsMissing() {
        let appDelegate = AppDelegate(
            testConfiguration: AppTestConfiguration(
                isEnabled: true,
                fixtureName: "missing-fixture",
                fixturePath: nil,
                diagnosticsPath: nil,
                disableAnimations: false
            ),
            launchHooks: AppDelegate.LaunchHooks(
                performInitialStartup: { _ in },
                performProductionGlobalStartup: { _ in }
            )
        )

        XCTAssertThrowsError(try appDelegate.configureTesting())
    }

    func testConfigureTestingThrowsWhenFixtureIsMalformed() throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("malformed-fixture.json")
        try FileManager.default.createDirectory(at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: fixtureURL)

        let appDelegate = AppDelegate(
            testConfiguration: AppTestConfiguration(
                isEnabled: true,
                fixtureName: nil,
                fixturePath: fixtureURL.path,
                diagnosticsPath: nil,
                disableAnimations: false
            ),
            launchHooks: AppDelegate.LaunchHooks(
                performInitialStartup: { _ in },
                performProductionGlobalStartup: { _ in }
            )
        )

        XCTAssertThrowsError(try appDelegate.configureTesting())
    }
}

private final class StartupObserver {
    var initialStartupRuns = 0
    var productionStartupRuns = 0
}

private func makeDiagnosticsURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("diagnostics.json")
}

private func loadSnapshot(from url: URL) throws -> AppDiagnosticsSnapshot {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(AppDiagnosticsSnapshot.self, from: data)
}
