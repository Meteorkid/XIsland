import DIShared
import Foundation

protocol AppTestConfigurationProcessInfo {
    var arguments: [String] { get }
    var environment: [String: String] { get }
}

extension ProcessInfo: AppTestConfigurationProcessInfo {}

/// 所有应用偏好及 SwiftUI 的 defaultAppStorage 共用同一个存储，避免测试写入真实偏好。
enum AppPreferences {
    static let defaults: UserDefaults = {
        do {
            return try AppTestConfiguration.current().makeUserDefaults()
        } catch {
            preconditionFailure("Invalid test isolation configuration: \(error.localizedDescription)")
        }
    }()
}

struct AppTestConfiguration: Equatable {
    enum ConfigurationError: LocalizedError {
        case invalidDefaultsSuite
        case invalidAnimationProfile
        case diagnosticsOutsideRuntime

        var errorDescription: String? {
            switch self {
            case .invalidDefaultsSuite:
                return "Test defaults suite must use the dev.xisland.tests. prefix and a unique alphanumeric suffix."
            case .invalidAnimationProfile:
                return "Test animation profile must be deterministic or normal."
            case .diagnosticsOutsideRuntime:
                return "Test diagnostics must be stored inside the test runtime directory."
            }
        }
    }

    let isEnabled: Bool
    let fixtureName: String?
    let fixturePath: String?
    let diagnosticsPath: String?
    let disableAnimations: Bool
    let opensPreferencesOnLaunch: Bool
    let runtimeDirectory: String?
    let defaultsSuiteName: String?
    let animationProfile: String

    init(
        isEnabled: Bool,
        fixtureName: String?,
        fixturePath: String?,
        diagnosticsPath: String?,
        disableAnimations: Bool,
        opensPreferencesOnLaunch: Bool = false,
        runtimeDirectory: String? = nil,
        defaultsSuiteName: String? = nil,
        animationProfile: String = "deterministic"
    ) {
        self.isEnabled = isEnabled
        self.fixtureName = isEnabled ? fixtureName : nil
        self.fixturePath = isEnabled ? fixturePath : nil
        self.diagnosticsPath = isEnabled ? diagnosticsPath : nil
        self.disableAnimations = isEnabled && animationProfile != "normal" && disableAnimations
        self.opensPreferencesOnLaunch = isEnabled && opensPreferencesOnLaunch
        self.runtimeDirectory = isEnabled ? (runtimeDirectory ?? DISocketConfig.defaultTestRuntimeDirectory) : nil
        self.defaultsSuiteName = isEnabled
            ? (defaultsSuiteName ?? "dev.xisland.tests.\(ProcessInfo.processInfo.processIdentifier)")
            : nil
        self.animationProfile = isEnabled ? animationProfile : "normal"
    }

    var allowsMultipleInstances: Bool { isEnabled }
    var runsProductionGlobalStartupSideEffects: Bool { !isEnabled }
    var runtimeURL: URL? { runtimeDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var storageURL: URL? { runtimeURL?.appendingPathComponent("history.store") }

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
                || environment["X_ISLAND_TEST_OPEN_PREFERENCES"] == "1",
            runtimeDirectory: environment["X_ISLAND_TEST_RUNTIME_DIR"],
            defaultsSuiteName: environment["X_ISLAND_TEST_DEFAULTS_SUITE"],
            animationProfile: environment["X_ISLAND_TEST_ANIMATION_PROFILE"] ?? "deterministic"
        )
    }

    func validateIsolation() throws {
        guard isEnabled else { return }
        try DISocketConfig.validateTestRuntimeDirectory(runtimeDirectory ?? "")
        let prefix = "dev.xisland.tests."
        let suffix = defaultsSuiteName?.dropFirst(prefix.count) ?? ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard defaultsSuiteName?.hasPrefix(prefix) == true, !suffix.isEmpty,
              suffix.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ConfigurationError.invalidDefaultsSuite
        }
        guard ["deterministic", "normal"].contains(animationProfile) else {
            throw ConfigurationError.invalidAnimationProfile
        }
        if let diagnosticsPath, let runtimeURL {
            let runtime = runtimeURL.standardizedFileURL.resolvingSymlinksInPath().path
            let diagnostics = URL(fileURLWithPath: diagnosticsPath)
                .standardizedFileURL.resolvingSymlinksInPath().path
            guard diagnosticsPath.hasPrefix("/"), diagnostics.hasPrefix(runtime + "/") else {
                throw ConfigurationError.diagnosticsOutsideRuntime
            }
        }
    }

    func makeUserDefaults() throws -> UserDefaults {
        guard isEnabled else { return .standard }
        try validateIsolation()
        guard let defaultsSuiteName, let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw ConfigurationError.invalidDefaultsSuite
        }
        return defaults
    }

    func applyDefaults(_ defaults: UserDefaults = AppPreferences.defaults) {
        guard isEnabled else { return }

        defaults.set(animationProfile != "normal", forKey: "reduceMotion")
        defaults.set(disableAnimations, forKey: "disableAnimations")
        defaults.set(false, forKey: "smartSuppression")
        defaults.set(false, forKey: "autoHideWhenNoActiveSessions")
        defaults.set(0.15, forKey: "autoCollapseDelay")
    }

    private static func argumentValue(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }

        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex, !arguments[valueIndex].hasPrefix("--") else { return nil }

        return arguments[valueIndex]
    }
}
