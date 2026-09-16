import DIShared
import XCTest
@testable import XIsland

final class AppTestConfigurationTests: XCTestCase {
    func testProductionModeIgnoresAllTestEnvironmentOverrides() {
        let configuration = AppTestConfiguration.make(
            arguments: ["XIsland", "--fixture", "test-fixture", "--open-preferences"],
            environment: [
                "X_ISLAND_TEST_FIXTURE_PATH": "/tmp/fixture.json",
                "X_ISLAND_TEST_DIAGNOSTICS_PATH": "/tmp/diagnostics.json",
                "X_ISLAND_DISABLE_ANIMATIONS": "1",
            ]
        )

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertNil(configuration.fixtureName)
        XCTAssertNil(configuration.fixturePath)
        XCTAssertNil(configuration.diagnosticsPath)
        XCTAssertFalse(configuration.disableAnimations)
        XCTAssertFalse(configuration.opensPreferencesOnLaunch)
    }

    func testNormalAnimationProfileDoesNotReduceOrDisableAnimations() {
        let suiteName = "dev.xisland.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = AppTestConfiguration.make(
            arguments: ["XIsland", "--ui-test-mode"],
            environment: [
                "X_ISLAND_TEST_ANIMATION_PROFILE": "normal",
                "X_ISLAND_DISABLE_ANIMATIONS": "1",
            ]
        )

        configuration.applyDefaults(defaults)

        XCTAssertFalse(defaults.bool(forKey: "reduceMotion"))
        XCTAssertFalse(defaults.bool(forKey: "disableAnimations"))
    }

    func testTestStorageUsesExplicitRuntimeDirectory() throws {
        let configuration = isolatedConfiguration()
        try configuration.validateIsolation()

        XCTAssertEqual(configuration.runtimeURL?.path, "/tmp/xi-tests-config")
        XCTAssertEqual(configuration.storageURL?.path, "/tmp/xi-tests-config/history.store")
    }

    func testInvalidTestPathsAndProductionPreferenceDomainsAreRejected() {
        for directory in ["relative/path", "/", "/tmp", "/Users/example/.xisland", "/tmp/" + String(repeating: "x", count: 100)] {
            let configuration = isolatedConfiguration(runtimeDirectory: directory)
            XCTAssertThrowsError(try configuration.validateIsolation(), directory)
        }
        for suite in ["", "dev.xisland.app", "dev.xisland.tests.", "dev.xisland.tests.bad/path"] {
            let configuration = isolatedConfiguration(defaultsSuiteName: suite)
            XCTAssertThrowsError(try configuration.makeUserDefaults(), suite)
        }
    }

    func testDiagnosticsCannotEscapeRuntimeDirectory() {
        let configuration = AppTestConfiguration.make(
            arguments: ["XIsland", "--ui-test-mode"],
            environment: [
                "X_ISLAND_TEST_RUNTIME_DIR": "/tmp/xi-tests-config",
                "X_ISLAND_TEST_DIAGNOSTICS_PATH": "/tmp/xi-tests-config/../outside.json",
            ]
        )
        XCTAssertThrowsError(try configuration.validateIsolation())
    }

    func testIndependentDefaultsDoNotWriteStandardDomain() throws {
        let suite = "dev.xisland.tests.\(UUID().uuidString)"
        let configuration = isolatedConfiguration(defaultsSuiteName: suite)
        let defaults = try configuration.makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "test-isolation-\(UUID().uuidString)"

        defaults.set("isolated", forKey: key)
        configuration.applyDefaults(defaults)

        XCTAssertEqual(defaults.string(forKey: key), "isolated")
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?[key] as? String, "isolated")
    }

    func testSocketConfigurationKeepsProductionDefaultAndSupportsIndependentTestPath() throws {
        let environment = ["X_ISLAND_TEST_RUNTIME_DIR": "/tmp/xi-tests-config"]
        XCTAssertEqual(
            try DISocketConfig.resolvedSocketDirectory(arguments: [], environment: environment, homeDirectory: "/Users/example"),
            "/Users/example/.xisland"
        )
        XCTAssertEqual(
            try DISocketConfig.resolvedSocketDirectory(arguments: ["--ui-test-mode"], environment: environment),
            "/tmp/xi-tests-config"
        )
        XCTAssertThrowsError(try DISocketConfig.resolvedSocketDirectory(
            arguments: ["--ui-test-mode"], environment: ["X_ISLAND_TEST_RUNTIME_DIR": "/Users/example/.xisland"]
        ))
    }

    func testDisabledModeIgnoresInvalidIsolationConfiguration() throws {
        let configuration = AppTestConfiguration.make(
            arguments: ["XIsland"],
            environment: [
                "X_ISLAND_TEST_RUNTIME_DIR": "invalid",
                "X_ISLAND_TEST_DEFAULTS_SUITE": "dev.xisland.app",
                "X_ISLAND_TEST_ANIMATION_PROFILE": "invalid",
            ]
        )
        try configuration.validateIsolation()
        XCTAssertNil(configuration.runtimeURL)
        XCTAssertNil(configuration.storageURL)
        XCTAssertNil(configuration.defaultsSuiteName)
        XCTAssertTrue(try configuration.makeUserDefaults() === UserDefaults.standard)
    }

    private func isolatedConfiguration(
        runtimeDirectory: String = "/tmp/xi-tests-config",
        defaultsSuiteName: String = "dev.xisland.tests.config"
    ) -> AppTestConfiguration {
        AppTestConfiguration.make(
            arguments: ["XIsland", "--ui-test-mode"],
            environment: [
                "X_ISLAND_TEST_RUNTIME_DIR": runtimeDirectory,
                "X_ISLAND_TEST_DEFAULTS_SUITE": defaultsSuiteName,
            ]
        )
    }

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
