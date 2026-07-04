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

    func testShouldShowOnLaunchFallsBackWhenPreferredAppIsNotRunning() {
        XCTAssertTrue(
            IslandIntegrationSettings.shouldShowOnLaunch(
                currentApp: .xisland,
                preferredApp: .xnook,
                preferredAppRunning: false
            )
        )
        XCTAssertFalse(
            IslandIntegrationSettings.shouldShowOnLaunch(
                currentApp: .xisland,
                preferredApp: .xnook,
                preferredAppRunning: true
            )
        )
    }

    func testSwipeSensitivityChangesTriggerThreshold() {
        let defaults = IslandIntegrationSettings.sharedDefaults
        defaults.set(
            IslandSwitchSensitivity.high.rawValue,
            forKey: IslandIntegrationSettings.Key.swipeSensitivity
        )
        let highSensitivityRecognizer = SwipeGestureRecognizer()
        let highResult = highSensitivityRecognizer.handleScroll(
            deltaX: 35,
            deltaY: 0,
            isPrecise: true,
            phase: .changed,
            momentumPhase: [],
            now: Date()
        )

        defaults.set(
            IslandSwitchSensitivity.low.rawValue,
            forKey: IslandIntegrationSettings.Key.swipeSensitivity
        )
        let lowSensitivityRecognizer = SwipeGestureRecognizer()
        let lowResult = lowSensitivityRecognizer.handleScroll(
            deltaX: 35,
            deltaY: 0,
            isPrecise: true,
            phase: .changed,
            momentumPhase: [],
            now: Date()
        )

        guard case .triggered = highResult else {
            return XCTFail("高灵敏度应在较小位移下触发切换")
        }
        guard case .inProgress = lowResult else {
            return XCTFail("低灵敏度不应在相同位移下提前触发")
        }
    }
}
