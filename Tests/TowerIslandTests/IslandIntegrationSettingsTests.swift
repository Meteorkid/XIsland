import AppKit
import XCTest
@testable import XIsland

final class IslandIntegrationSettingsTests: XCTestCase {
    private let keys = [
        IslandIntegrationSettings.Key.swipeSwitchEnabled,
        IslandIntegrationSettings.Key.swipeSensitivity,
        IslandIntegrationSettings.Key.startupDisplayMode,
        IslandIntegrationSettings.Key.lastShownIsland,
    ]
    private var savedValues: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        let defaults = IslandIntegrationSettings.sharedDefaults
        savedValues = Dictionary(
            uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) }
        )
    }

    override func tearDown() {
        let defaults = IslandIntegrationSettings.sharedDefaults
        for key in keys {
            if let value = savedValues[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        savedValues.removeAll()
        super.tearDown()
    }

    func testPreferredStartupIslandFallsBackToXNookWhenPeerInstalled() {
        IslandIntegrationSettings.sharedDefaults.set(
            IslandStartupDisplayMode.lastUsed.rawValue,
            forKey: IslandIntegrationSettings.Key.startupDisplayMode
        )
        IslandIntegrationSettings.sharedDefaults.removeObject(forKey: IslandIntegrationSettings.Key.lastShownIsland)

        XCTAssertEqual(
            IslandIntegrationSettings.preferredStartupIsland(
                currentApp: .xisland,
                otherAppInstalled: true
            ),
            .xnook
        )
    }

    func testPreferredStartupIslandUsesLastShownIsland() {
        IslandIntegrationSettings.sharedDefaults.set(
            IslandStartupDisplayMode.lastUsed.rawValue,
            forKey: IslandIntegrationSettings.Key.startupDisplayMode
        )
        IslandIntegrationSettings.sharedDefaults.set(
            IslandApp.xisland.rawValue,
            forKey: IslandIntegrationSettings.Key.lastShownIsland
        )

        XCTAssertEqual(
            IslandIntegrationSettings.preferredStartupIsland(
                currentApp: .xnook,
                otherAppInstalled: true
            ),
            .xisland
        )
    }

    func testShouldShowOnLaunchFallsBackWhenPreferredAppIsNotVisible() {
        XCTAssertTrue(
            IslandIntegrationSettings.shouldShowOnLaunch(
                currentApp: .xisland,
                preferredApp: .xnook,
                preferredAppVisible: false
            )
        )
        XCTAssertFalse(
            IslandIntegrationSettings.shouldShowOnLaunch(
                currentApp: .xisland,
                preferredApp: .xnook,
                preferredAppVisible: true
            )
        )
    }

    func testSwipeSensitivityChangesReleaseThreshold() {
        let defaults = IslandIntegrationSettings.sharedDefaults
        let now = Date()
        for (sensitivity, expected) in [
            (IslandSwitchSensitivity.high, SwipeResult.triggered(.right)),
            (IslandSwitchSensitivity.low, SwipeResult.cancelled),
        ] {
            defaults.set(sensitivity.rawValue, forKey: IslandIntegrationSettings.Key.swipeSensitivity)
            let recognizer = SwipeGestureRecognizer()
            let tracking = recognizer.handleScroll(
                deltaX: 35, deltaY: 0, isPrecise: true,
                phase: .began, momentumPhase: [], now: now
            )
            XCTAssertEqual(tracking, .progress(35), "达到阈值后仍应跟手，不能提前提交")
            let released = recognizer.handleScroll(
                deltaX: 0, deltaY: 0, isPrecise: true,
                phase: .ended, momentumPhase: [], now: now.addingTimeInterval(0.1)
            )
            XCTAssertEqual(released, expected, "灵敏度决定松手时的提交阈值")
        }
    }
}
