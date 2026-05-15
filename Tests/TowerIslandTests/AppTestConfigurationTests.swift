import XCTest
@testable import XIsland

final class AppTestConfigurationTests: XCTestCase {
    func testParsesUITestModeAndFixtureName() {
        let config = AppTestConfiguration.make(
            arguments: ["XIsland", "--ui-test-mode", "--fixture", "permission-smoke"],
            environment: ["X_ISLAND_DISABLE_ANIMATIONS": "1"]
        )

        let expected = AppTestConfiguration(
            isEnabled: true,
            fixtureName: "permission-smoke",
            fixturePath: nil,
            diagnosticsPath: nil,
            disableAnimations: true,
            opensPreferencesOnLaunch: false
        )

        XCTAssertEqual(config, expected)
        XCTAssertTrue(config.allowsMultipleInstances)
    }

    func testMakeEnablesTestModeFromArgumentsAndEnvironment() {
        let configuration = AppTestConfiguration.make(
            arguments: [
                "XIsland",
                "--ui-test-mode",
                "--fixture", "sample-fixture",
                "--fixture-path", "/tmp/sample.json"
            ],
            environment: [
                "X_ISLAND_TEST_FIXTURE": "env-fixture",
                "X_ISLAND_TEST_FIXTURE_PATH": "/tmp/env.json",
                "X_ISLAND_TEST_DIAGNOSTICS_PATH": "/tmp/diagnostics.log",
                "X_ISLAND_DISABLE_ANIMATIONS": "1"
            ]
        )

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.fixtureName, "sample-fixture")
        XCTAssertEqual(configuration.fixturePath, "/tmp/sample.json")
        XCTAssertEqual(configuration.diagnosticsPath, "/tmp/diagnostics.log")
        XCTAssertTrue(configuration.disableAnimations)
        XCTAssertTrue(configuration.allowsMultipleInstances)
        XCTAssertFalse(configuration.runsProductionGlobalStartupSideEffects)
    }

    func testMakeEnablesTestModeFromEnvironmentOnly() {
        let configuration = AppTestConfiguration.make(
            arguments: ["XIsland"],
            environment: [
                "X_ISLAND_TEST_MODE": "1",
                "X_ISLAND_TEST_FIXTURE": "env-fixture",
                "X_ISLAND_TEST_FIXTURE_PATH": "/tmp/env.json"
            ]
        )

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.fixtureName, "env-fixture")
        XCTAssertEqual(configuration.fixturePath, "/tmp/env.json")
        XCTAssertNil(configuration.diagnosticsPath)
        XCTAssertFalse(configuration.disableAnimations)
        XCTAssertTrue(configuration.allowsMultipleInstances)
        XCTAssertFalse(configuration.runsProductionGlobalStartupSideEffects)
    }

    func testProductionModeKeepsProductionGlobalStartupSideEffectsEnabled() {
        let configuration = AppTestConfiguration.make(
            arguments: ["XIsland"],
            environment: [:]
        )

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertFalse(configuration.allowsMultipleInstances)
        XCTAssertTrue(configuration.runsProductionGlobalStartupSideEffects)
    }

    func testCurrentBuildsConfigurationFromProcessInfo() {
        let processInfo = ProcessInfoStub(
            arguments: [
                "XIsland",
                "--ui-test-mode",
                "--fixture", "current-fixture",
                "--open-preferences"
            ],
            environment: [
                "X_ISLAND_TEST_FIXTURE_PATH": "/tmp/current.json",
                "X_ISLAND_TEST_DIAGNOSTICS_PATH": "/tmp/current.log",
                "X_ISLAND_DISABLE_ANIMATIONS": "1"
            ]
        )

        let configuration = AppTestConfiguration.current(processInfo: processInfo)

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.fixtureName, "current-fixture")
        XCTAssertEqual(configuration.fixturePath, "/tmp/current.json")
        XCTAssertEqual(configuration.diagnosticsPath, "/tmp/current.log")
        XCTAssertTrue(configuration.disableAnimations)
        XCTAssertTrue(configuration.opensPreferencesOnLaunch)
    }

    func testMakeParsesOpenPreferencesFromArgumentsOrEnvironment() {
        let fromArguments = AppTestConfiguration.make(
            arguments: ["XIsland", "--ui-test-mode", "--open-preferences"],
            environment: [:]
        )
        let fromEnvironment = AppTestConfiguration.make(
            arguments: ["XIsland", "--ui-test-mode"],
            environment: ["X_ISLAND_TEST_OPEN_PREFERENCES": "1"]
        )

        XCTAssertTrue(fromArguments.opensPreferencesOnLaunch)
        XCTAssertTrue(fromEnvironment.opensPreferencesOnLaunch)
    }

    func testApplyDefaultsOverridesAppBehaviorInTestMode() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        defaults.set(false, forKey: "reduceMotion")
        defaults.set(true, forKey: "smartSuppression")
        defaults.set(true, forKey: "autoHideWhenNoActiveSessions")
        defaults.set(3.0, forKey: "autoCollapseDelay")

        AppTestConfiguration(
            isEnabled: true,
            fixtureName: nil,
            fixturePath: nil,
            diagnosticsPath: nil,
            disableAnimations: false,
            opensPreferencesOnLaunch: false
        ).applyDefaults(defaults)

        XCTAssertTrue(defaults.bool(forKey: "reduceMotion"))
        XCTAssertFalse(defaults.bool(forKey: "smartSuppression"))
        XCTAssertFalse(defaults.bool(forKey: "autoHideWhenNoActiveSessions"))
        XCTAssertFalse(defaults.bool(forKey: "disableAnimations"))
        XCTAssertEqual(defaults.double(forKey: "autoCollapseDelay"), 0.15, accuracy: 0.0001)
    }

    func testApplyDefaultsPropagatesDisableAnimationsFlagInTestMode() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        AppTestConfiguration(
            isEnabled: true,
            fixtureName: nil,
            fixturePath: nil,
            diagnosticsPath: nil,
            disableAnimations: true,
            opensPreferencesOnLaunch: false
        ).applyDefaults(defaults)

        XCTAssertTrue(defaults.bool(forKey: "disableAnimations"))
    }

    func testApplyDefaultsDoesNothingWhenTestModeDisabled() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        defaults.set(false, forKey: "reduceMotion")
        defaults.set(true, forKey: "smartSuppression")
        defaults.set(true, forKey: "autoHideWhenNoActiveSessions")
        defaults.set(3.0, forKey: "autoCollapseDelay")

        AppTestConfiguration(
            isEnabled: false,
            fixtureName: nil,
            fixturePath: nil,
            diagnosticsPath: nil,
            disableAnimations: false,
            opensPreferencesOnLaunch: false
        ).applyDefaults(defaults)

        XCTAssertFalse(defaults.bool(forKey: "reduceMotion"))
        XCTAssertTrue(defaults.bool(forKey: "smartSuppression"))
        XCTAssertTrue(defaults.bool(forKey: "autoHideWhenNoActiveSessions"))
        XCTAssertFalse(defaults.bool(forKey: "disableAnimations"))
        XCTAssertEqual(defaults.double(forKey: "autoCollapseDelay"), 3.0, accuracy: 0.0001)
    }
}

private struct ProcessInfoStub: AppTestConfigurationProcessInfo {
    let arguments: [String]
    let environment: [String: String]
}
