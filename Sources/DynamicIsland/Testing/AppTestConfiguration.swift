import Foundation

protocol AppTestConfigurationProcessInfo {
    var arguments: [String] { get }
    var environment: [String: String] { get }
}

extension ProcessInfo: AppTestConfigurationProcessInfo {}

struct AppTestConfiguration: Equatable {
    let isEnabled: Bool
    let fixtureName: String?
    let fixturePath: String?
    let diagnosticsPath: String?
    let disableAnimations: Bool
    let opensPreferencesOnLaunch: Bool

    init(
        isEnabled: Bool,
        fixtureName: String?,
        fixturePath: String?,
        diagnosticsPath: String?,
        disableAnimations: Bool,
        opensPreferencesOnLaunch: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.fixtureName = fixtureName
        self.fixturePath = fixturePath
        self.diagnosticsPath = diagnosticsPath
        self.disableAnimations = disableAnimations
        self.opensPreferencesOnLaunch = opensPreferencesOnLaunch
    }

    var allowsMultipleInstances: Bool {
        isEnabled
    }

    var runsProductionGlobalStartupSideEffects: Bool {
        !isEnabled
    }

    static func current(processInfo: any AppTestConfigurationProcessInfo = ProcessInfo.processInfo) -> Self {
        make(arguments: processInfo.arguments, environment: processInfo.environment)
    }

    static func make(arguments: [String], environment: [String: String]) -> Self {
        let isEnabled = arguments.contains("--ui-test-mode") || environment["X_ISLAND_TEST_MODE"] == "1"

        return Self(
            isEnabled: isEnabled,
            fixtureName: argumentValue(for: "--fixture", in: arguments) ?? environment["X_ISLAND_TEST_FIXTURE"],
            fixturePath: argumentValue(for: "--fixture-path", in: arguments) ?? environment["X_ISLAND_TEST_FIXTURE_PATH"],
            diagnosticsPath: environment["X_ISLAND_TEST_DIAGNOSTICS_PATH"],
            disableAnimations: environment["X_ISLAND_DISABLE_ANIMATIONS"] == "1",
            opensPreferencesOnLaunch: arguments.contains("--open-preferences")
                || environment["X_ISLAND_TEST_OPEN_PREFERENCES"] == "1"
        )
    }

    func applyDefaults(_ defaults: UserDefaults = .standard) {
        guard isEnabled else { return }

        defaults.set(true, forKey: "reduceMotion")
        defaults.set(disableAnimations, forKey: "disableAnimations")
        defaults.set(false, forKey: "smartSuppression")
        defaults.set(false, forKey: "autoHideWhenNoActiveSessions")
        defaults.set(0.15, forKey: "autoCollapseDelay")
    }

    private static func argumentValue(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }

        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }

        return arguments[valueIndex]
    }
}
