import AppKit
import Foundation

enum UITestAccessibility {
    static let islandRoot = "island.root"
    static let collapsedPill = "island.collapsed-pill"
    static let sessionList = "island.session-list"
    static let permissionPanel = "island.permission-panel"
    static let permissionApproveButton = "island.permission-approve"
    static let questionPanel = "island.question-panel"
    static let planPanel = "island.plan-panel"
    static let planApproveButton = "island.plan-approve"
    static let preferencesRoot = "preferences.root"
    static let updateCheckButton = "preferences.update-check"
    static let updateInstallButton = "preferences.update-install"
    static let updateStatusLabel = "preferences.update-status"

    static func sessionCard(id: String) -> String {
        "island.session-card.\(id)"
    }

    static func questionOption(index: Int) -> String {
        "island.question-option.\(index)"
    }
}

struct UITestDiagnosticsSnapshot: Decodable {
    struct SessionSnapshot: Decodable {
        let id: String
    }

    struct UpdateSnapshot: Decodable {
        let state: String
        let version: String?
        let dmgURL: String?
    }

    let islandState: String
    let selectedSessionId: String?
    let pendingInteraction: String?
    let visibleSessions: [SessionSnapshot]
    let visibleAccessibilityIdentifiers: [String]
    let update: UpdateSnapshot
}

struct UITestDriverConfiguration {
    let appBundlePath: String
    let scenarioArguments: [String]
    let timeout: TimeInterval

    static func make(arguments: [String]) throws -> Self {
        var appBundlePath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build")
            .appendingPathComponent("X Island.app")
            .path
        var scenarioArguments: [String] = []
        var timeout: TimeInterval = 15

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--app-path":
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    throw UITestDriverError.invalidArguments("Missing value after --app-path")
                }
                appBundlePath = arguments[nextIndex]
                index = nextIndex
            case "--timeout":
                let nextIndex = index + 1
                guard nextIndex < arguments.count, let parsed = TimeInterval(arguments[nextIndex]) else {
                    throw UITestDriverError.invalidArguments("Missing numeric value after --timeout")
                }
                timeout = parsed
                index = nextIndex
            default:
                scenarioArguments.append(argument)
            }

            index += 1
        }

        return Self(
            appBundlePath: appBundlePath,
            scenarioArguments: scenarioArguments.isEmpty ? ["smoke"] : scenarioArguments,
            timeout: timeout
        )
    }
}

struct UITestRunSelection {
    let scenarios: [UITestScenario]

    static func make(arguments: [String]) throws -> Self {
        let names: [String]

        if arguments == ["smoke"] {
            names = UITestScenario.smokeScenarioNames
        } else if arguments == ["full"] {
            names = UITestScenario.fullScenarioNames
        } else {
            names = arguments
        }

        return Self(scenarios: try names.map(UITestScenario.named(_:)))
    }
}

struct UITestScenario {
    let name: String
    let fixtureName: String
    let opensPreferencesOnLaunch: Bool
    let requiredIdentifiers: [String]
    let expectedInitialIslandState: String
    let run: (UITestScenarioContext) throws -> Void

    static let smokeScenarioNames = [
        "permission-smoke",
        "question-smoke",
        "plan-smoke",
        "preferences-update",
    ]

    static let fullScenarioNames = smokeScenarioNames + ["session-list"]

    static func named(_ name: String) throws -> Self {
        switch name {
        case "permission-smoke":
            return Self(
                name: name,
                fixtureName: "permission-smoke",
                opensPreferencesOnLaunch: false,
                requiredIdentifiers: [
                    UITestAccessibility.permissionApproveButton,
                ],
                expectedInitialIslandState: "permission"
            ) { context in
                _ = try context.waitForPrimaryWindow(minWidth: 300, description: "Timed out waiting for permission window")
                _ = try context.waitForSnapshot(
                    description: "Timed out waiting for permission diagnostics"
                ) {
                    $0.pendingInteraction == "permission"
                        && $0.selectedSessionId == "fixture-permission"
                }
                try context.pressElement(UITestAccessibility.permissionApproveButton)
                _ = try context.waitForSnapshot(
                    description: "Timed out waiting for permission approval to clear diagnostics"
                ) {
                    $0.pendingInteraction == nil && $0.islandState == "collapsed"
                }
            }
        case "question-smoke":
            return Self(
                name: name,
                fixtureName: "question-smoke",
                opensPreferencesOnLaunch: false,
                requiredIdentifiers: [
                    UITestAccessibility.questionPanel,
                    UITestAccessibility.questionOption(index: 0),
                ],
                expectedInitialIslandState: "question"
            ) { context in
                _ = try context.waitForPrimaryWindow(minWidth: 300, description: "Timed out waiting for question window")
                _ = try context.waitForSnapshot(
                    description: "Timed out waiting for question diagnostics"
                ) {
                    $0.pendingInteraction == "question"
                        && $0.selectedSessionId == "fixture-question"
                }
                try context.pressElement(UITestAccessibility.questionOption(index: 0))
                _ = try context.waitForSnapshot(
                    description: "Timed out waiting for question answer to clear diagnostics"
                ) {
                    $0.pendingInteraction == nil && $0.islandState == "collapsed"
                }
            }
        case "plan-smoke":
            return Self(
                name: name,
                fixtureName: "plan-smoke",
                opensPreferencesOnLaunch: false,
                requiredIdentifiers: [
                    UITestAccessibility.planPanel,
                    UITestAccessibility.planApproveButton,
                ],
                expectedInitialIslandState: "planReview"
            ) { context in
                _ = try context.waitForPrimaryWindow(minWidth: 300, description: "Timed out waiting for plan window")
                _ = try context.waitForSnapshot(
                    description: "Timed out waiting for plan diagnostics"
                ) {
                    $0.pendingInteraction == "planReview"
                        && $0.selectedSessionId == "fixture-plan"
                }
                try context.pressElement(UITestAccessibility.planApproveButton)
                _ = try context.waitForSnapshot(
                    description: "Timed out waiting for plan approval to clear diagnostics"
                ) {
                    $0.pendingInteraction == nil && $0.islandState == "collapsed"
                }
            }
        case "preferences-update":
            return Self(
                name: name,
                fixtureName: "update-available",
                opensPreferencesOnLaunch: true,
                requiredIdentifiers: [
                    UITestAccessibility.preferencesRoot,
                    UITestAccessibility.updateStatusLabel,
                    UITestAccessibility.updateCheckButton,
                    UITestAccessibility.updateInstallButton,
                ],
                expectedInitialIslandState: "collapsed"
            ) { context in
                _ = try context.waitForPrimaryWindow(
                    minWidth: 600,
                    description: "Timed out waiting for preferences window"
                )
                let snapshot = try context.waitForSnapshot(
                    description: "Timed out waiting for update diagnostics"
                ) {
                    $0.update.state == "updateAvailable" && $0.update.version == "1.2.9"
                }
                guard snapshot.update.dmgURL == "https://example.com/XIsland-1.2.9.dmg" else {
                    throw UITestDriverError.actionFailed("Unexpected update diagnostics DMG URL")
                }
            }
        case "session-list":
            return Self(
                name: name,
                fixtureName: "session-list",
                opensPreferencesOnLaunch: false,
                requiredIdentifiers: [],
                expectedInitialIslandState: "collapsed"
            ) { context in
                _ = try context.waitForPrimaryWindow(
                    minWidth: 120,
                    maxWidth: 220,
                    description: "Timed out waiting for collapsed island window"
                )
                _ = try context.waitForSnapshot(
                    description: "Timed out waiting for session list fixture diagnostics"
                ) {
                    $0.visibleSessions.count == 3
                        && $0.selectedSessionId == "fixture-session-1"
                        && $0.islandState == "collapsed"
                }
            }
        default:
            throw UITestDriverError.invalidArguments("Unknown UI test scenario: \(name)")
        }
    }
}

struct UITestScenarioContext {
    let process: Process
    let application: AXUIElement
    let diagnosticsURL: URL
    let timeout: TimeInterval

    func activate() throws {
        guard let runningApplication = NSRunningApplication(processIdentifier: process.processIdentifier) else {
            throw UITestDriverError.launchFailed("Unable to resolve running X Island application")
        }
        _ = runningApplication.activate()
    }

    func waitForElement(_ identifier: String) throws -> AXUIElement {
        _ = try waitForSnapshot(
            description: "Timed out waiting for diagnostics to expose accessibility identifier \(identifier)"
        ) {
            $0.visibleAccessibilityIdentifiers.contains(identifier)
        }

        return try AXUIHelpers.waitForElement(in: application, identifier: identifier, timeout: timeout)
    }

    func pressElement(_ identifier: String) throws {
        try activate()
        let element = try waitForElement(identifier)
        try AXUIHelpers.press(element, identifier: identifier)
    }

    func waitForPrimaryWindow(
        minWidth: CGFloat,
        maxWidth: CGFloat? = nil,
        description: String
    ) throws -> WindowInfo {
        try AXUIHelpers.waitForWindow(
            ownedBy: process.processIdentifier,
            timeout: timeout,
            where: { window in
                guard window.layer >= 26 else { return false }
                guard window.bounds.width >= minWidth else { return false }
                if let maxWidth, window.bounds.width > maxWidth {
                    return false
                }
                return window.bounds.height >= 32
            },
            description: description
        )
    }

    func waitForSnapshot(
        description: String,
        predicate: (UITestDiagnosticsSnapshot) -> Bool
    ) throws -> UITestDiagnosticsSnapshot {
        try AXUIHelpers.waitUntil(timeout: timeout, description: description) {
            guard let snapshot = try? currentSnapshot(), predicate(snapshot) else {
                return nil
            }
            return snapshot
        }
    }

    func currentSnapshot() throws -> UITestDiagnosticsSnapshot {
        let data = try Data(contentsOf: diagnosticsURL)
        return try JSONDecoder().decode(UITestDiagnosticsSnapshot.self, from: data)
    }
}

struct UITestLaunchRequest {
    let bundleURL: URL
    let arguments: [String]
    let environment: [String: String]
}

struct UITestScenarioRunner {
    let appBundlePath: String
    let timeout: TimeInterval

    func run(_ scenario: UITestScenario) throws {
        let context = try launch(scenario: scenario)

        defer {
            terminate(process: context.process)
        }

        _ = try context.waitForSnapshot(
            description: "Timed out waiting for initial diagnostics for \(scenario.name)"
        ) {
            $0.islandState == scenario.expectedInitialIslandState
        }

        for identifier in scenario.requiredIdentifiers {
            _ = try context.waitForElement(identifier)
        }

        try scenario.run(context)
    }

    private func launch(scenario: UITestScenario) throws -> UITestScenarioContext {
        let diagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-ui-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("diagnostics.json")
        try FileManager.default.createDirectory(
            at: diagnosticsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let request = makeLaunchRequest(for: scenario, diagnosticsURL: diagnosticsURL)
        guard Bundle(url: request.bundleURL) != nil else {
            throw UITestDriverError.launchFailed("X Island app bundle not found at \(request.bundleURL.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = openArguments(for: request)
        process.environment = request.environment

        try process.run()

        let applicationPID = try waitForApplicationPID(
            bundleURL: request.bundleURL,
            diagnosticsURL: diagnosticsURL,
            scenario: scenario
        )

        let application = AXUIHelpers.applicationElement(pid: applicationPID)
        return UITestScenarioContext(
            process: process,
            application: application,
            diagnosticsURL: diagnosticsURL,
            timeout: timeout
        )
    }

    func makeLaunchRequest(for scenario: UITestScenario, diagnosticsURL: URL) -> UITestLaunchRequest {
        UITestLaunchRequest(
            bundleURL: URL(fileURLWithPath: appBundlePath),
            arguments: launchArguments(for: scenario),
            environment: launchEnvironment(diagnosticsURL: diagnosticsURL, scenario: scenario)
        )
    }

    private func launchArguments(for scenario: UITestScenario) -> [String] {
        var arguments = ["--ui-test-mode", "--fixture", scenario.fixtureName]
        if scenario.opensPreferencesOnLaunch {
            arguments.append("--open-preferences")
        }
        return arguments
    }

    private func launchEnvironment(diagnosticsURL: URL, scenario: UITestScenario) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["X_ISLAND_TEST_MODE"] = "1"
        environment["X_ISLAND_TEST_FIXTURE"] = scenario.fixtureName
        environment["X_ISLAND_TEST_DIAGNOSTICS_PATH"] = diagnosticsURL.path
        environment["X_ISLAND_DISABLE_ANIMATIONS"] = "1"
        if scenario.opensPreferencesOnLaunch {
            environment["X_ISLAND_TEST_OPEN_PREFERENCES"] = "1"
        } else {
            environment.removeValue(forKey: "X_ISLAND_TEST_OPEN_PREFERENCES")
        }
        return environment
    }

    private func openArguments(for request: UITestLaunchRequest) -> [String] {
        ["-n", request.bundleURL.path, "--args"] + request.arguments
    }

    private func waitForApplicationPID(
        bundleURL: URL,
        diagnosticsURL: URL,
        scenario: UITestScenario
    ) throws -> pid_t {
        let bundleIdentifier = try bundleIdentifier(for: bundleURL)

        return try AXUIHelpers.waitUntil(
            timeout: timeout,
            description: "Timed out waiting for X Island to launch for \(scenario.name)"
        ) {
            guard FileManager.default.fileExists(atPath: diagnosticsURL.path) else {
                return nil
            }

            let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            if let match = candidates.sorted(by: { $0.launchDate ?? .distantPast > $1.launchDate ?? .distantPast }).first {
                return match.processIdentifier
            }

            return nil
        }
    }

    private func bundleIdentifier(for bundleURL: URL) throws -> String {
        guard let bundle = Bundle(url: bundleURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            throw UITestDriverError.launchFailed("X Island bundle identifier not found at \(bundleURL.path)")
        }
        return bundleIdentifier
    }

    private func terminate(process: Process) {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}
