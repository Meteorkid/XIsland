import AppKit
import Darwin
import Foundation

enum UITestAccessibility {
    static let islandRoot = "island.root"
    static let collapsedPill = "island.collapsed-pill"
    static let sessionList = "island.session-list"
    static let permissionPanel = "island.permission-panel"
    static let permissionApproveButton = "island.permission-approve"
    static let questionPanel = "island.question-panel"
    static let customAnswerField = "island.question-custom-input"
    static let customAnswerSubmit = "island.question-custom-submit"
    static let multipleAnswerSubmit = "island.question-multiple-submit"
    static let planPanel = "island.plan-panel"
    static let planApproveButton = "island.plan-approve"
    static let planDetailsButton = "island.plan-details"
    static let planFeedbackField = "island.plan-feedback"
    static let preferencesRoot = "preferences.root"
    static let updateCheckButton = "preferences.update-check"
    static let updateInstallButton = "preferences.update-install"
    static let updateStatusLabel = "preferences.update-status"

    static func usesRequestScope(_ identifier: String) -> Bool {
        [permissionPanel, permissionApproveButton, questionPanel, planPanel,
         planApproveButton, planDetailsButton, planFeedbackField, customAnswerField, customAnswerSubmit, multipleAnswerSubmit].contains(identifier)
            || identifier.hasPrefix("island.question-option.")
    }

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

    func containsIdentifier(_ identifier: String) -> Bool {
        visibleAccessibilityIdentifiers.contains { actual in
            actual == identifier
                || (UITestAccessibility.usesRequestScope(identifier) && actual.hasPrefix(identifier + "."))
        }
    }

    func resolvedIdentifier(_ identifier: String, requiringScopedInteraction: Bool = false) throws -> String {
        if UITestAccessibility.usesRequestScope(identifier), let selectedSessionId {
            let prefix = identifier + "." + selectedSessionId + "."
            let matches = visibleAccessibilityIdentifiers.filter {
                $0.hasPrefix(prefix) && UUID(uuidString: String($0.dropFirst(prefix.count))) != nil
            }
            guard matches.count <= 1 else {
                throw UITestDriverError.actionFailed("Ambiguous inline accessibility identifier: \(identifier)")
            }
            if let match = matches.first { return match }
        }
        // 旧标识只可用于存在性检查，实际操作必须指向当前会话的唯一请求。
        if (!requiringScopedInteraction || !UITestAccessibility.usesRequestScope(identifier)),
           visibleAccessibilityIdentifiers.contains(identifier) {
            return identifier
        }
        throw UITestDriverError.missingElement(identifier)
    }

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
        case "question-custom-socket", "question-multiple-socket":
            return Self(name: name, fixtureName: "empty-interaction", opensPreferencesOnLaunch: false,
                        requiredIdentifiers: [], expectedInitialIslandState: "collapsed") { context in
                try context.verifyCustomQuestionSocketRoundTrip(multiple: name == "question-multiple-socket")
            }
        case "question-focus":
            return Self(name: name, fixtureName: name, opensPreferencesOnLaunch: false,
                        requiredIdentifiers: [UITestAccessibility.customAnswerField], expectedInitialIslandState: "question") { context in
                let secondPrefix = UITestAccessibility.customAnswerField + ".fixture-question-b."
                let initial = try context.waitForSnapshot(description: "Waiting for two question cards") {
                    $0.selectedSessionId == "fixture-question-a" && $0.visibleAccessibilityIdentifiers.contains { $0.hasPrefix(secondPrefix) }
                }
                guard let secondField = initial.visibleAccessibilityIdentifiers.first(where: { $0.hasPrefix(secondPrefix) }) else {
                    throw UITestDriverError.missingElement(secondPrefix)
                }
                try context.setText("B custom answer", in: secondField)
                _ = try context.waitForSnapshot(description: "Editing B did not focus its request") { $0.selectedSessionId == "fixture-question-b" }
                try context.pressElement(UITestAccessibility.customAnswerSubmit)
                _ = try context.waitForSnapshot(description: "B submit changed the wrong request") {
                    $0.selectedSessionId == "fixture-question-a" && $0.pendingInteraction == "question"
                        && !$0.visibleAccessibilityIdentifiers.contains { $0.hasPrefix(secondPrefix) }
                }
            }
        case "question-custom":
            return Self(name: name, fixtureName: name, opensPreferencesOnLaunch: false,
                        requiredIdentifiers: [UITestAccessibility.customAnswerField, UITestAccessibility.customAnswerSubmit],
                        expectedInitialIslandState: "question") { context in
                _ = try context.waitForPrimaryWindow(minWidth: 300, description: "Waiting for custom question window")
                _ = try context.waitForSnapshot(description: "Waiting for custom question") {
                    $0.pendingInteraction == "question" && $0.selectedSessionId == "fixture-custom-question"
                }
                try context.setText("/tmp/自定义项目", in: UITestAccessibility.customAnswerField)
                try context.pressElement(UITestAccessibility.customAnswerSubmit)
                _ = try context.waitForSnapshot(description: "Custom answer did not clear request") {
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
                    UITestAccessibility.planDetailsButton,
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
                try context.pressElement(UITestAccessibility.planDetailsButton)
                try context.setText(
                    "请保留现有配置。\n完成后运行测试并报告结果。",
                    in: UITestAccessibility.planFeedbackField
                )
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

    func verifyCustomQuestionSocketRoundTrip(multiple: Bool = false) throws {
        guard let appExecutable = process.executableURL else { throw UITestDriverError.launchFailed("No application executable") }
        let bridge = Process()
        bridge.executableURL = appExecutable.deletingLastPathComponent().appendingPathComponent("di-bridge")
        bridge.arguments = ["--agent", "opencode", "--adapter", "opencode_plugin", "--hook", "question.asked"]
        var environment = process.environment ?? [:]
        environment["DI_SOCKET_PATH"] = diagnosticsURL.deletingLastPathComponent().appendingPathComponent("di.sock").path
        bridge.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        bridge.standardInput = input; bridge.standardOutput = output; bridge.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        bridge.terminationHandler = { _ in exited.signal() }
        try bridge.run()
        defer {
            if bridge.isRunning {
                bridge.terminate()
                if exited.wait(timeout: .now() + 1) != .success { kill(bridge.processIdentifier, SIGKILL) }
            }
        }
        let payload: [String: Any] = ["native_event": "question.asked", "session_id": "ui-socket",
            "native_request_id": "question-1", "native_request_kind": "question", "question": "请输入目录",
            "options": multiple ? ["A,逗号", "B换行\n第二行"] : [], "allow_custom_answer": true, "allow_multiple_answers": multiple]
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        _ = try waitForSnapshot(description: "Socket question did not reach UI") {
            $0.pendingInteraction == "question" && $0.selectedSessionId == "opencode-ui-socket"
        }
        let answer = "/tmp/中文项目"
        if multiple {
            try pressElement(UITestAccessibility.questionOption(index: 1))
            try pressElement(UITestAccessibility.questionOption(index: 0))
        }
        try setText(answer, in: UITestAccessibility.customAnswerField)
        try pressElement(multiple ? UITestAccessibility.multipleAnswerSubmit : UITestAccessibility.customAnswerSubmit)
        guard exited.wait(timeout: .now() + timeout) == .success, bridge.terminationStatus == 0,
              let data = try output.fileHandleForReading.readToEnd(),
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              multiple ? (response["answers"] as? [String] == ["A,逗号", "B换行\n第二行", answer] && response["answer"] == nil)
                : (response["answer"] as? String == answer && response["answers"] == nil) else {
            throw UITestDriverError.actionFailed("Custom answer did not return unchanged through bridge")
        }
        _ = try waitForSnapshot(description: "Delivered socket question did not clear") { $0.pendingInteraction == nil }
    }

    func activate() throws {
        guard let runningApplication = NSRunningApplication(processIdentifier: process.processIdentifier) else {
            throw UITestDriverError.launchFailed("Unable to resolve running X Island application")
        }
        _ = runningApplication.activate()
    }

    func waitForElement(_ identifier: String) throws -> AXUIElement {
        try waitForResolvedElement(identifier).element
    }

    private func waitForResolvedElement(
        _ identifier: String,
        requiringScopedInteraction: Bool = false
    ) throws -> (element: AXUIElement, identifier: String) {
        let snapshot = try waitForSnapshot(
            description: "Timed out waiting for diagnostics to expose accessibility identifier \(identifier)"
        ) {
            $0.containsIdentifier(identifier)
        }
        let actualIdentifier = try snapshot.resolvedIdentifier(
            identifier, requiringScopedInteraction: requiringScopedInteraction
        )
        let element = try AXUIHelpers.waitForElement(
            in: application, identifier: actualIdentifier, timeout: timeout
        )
        return (element, actualIdentifier)
    }

    private func actionElement(_ identifier: String) throws -> (element: AXUIElement, identifier: String) {
        try activate()
        let resolved = try waitForResolvedElement(identifier, requiringScopedInteraction: true)
        let latestIdentifier = try currentSnapshot().resolvedIdentifier(identifier, requiringScopedInteraction: true)
        guard latestIdentifier == resolved.identifier else {
            throw UITestDriverError.actionFailed("Interaction changed before activating \(identifier)")
        }
        return resolved
    }

    func pressElement(_ identifier: String) throws {
        let resolved = try actionElement(identifier)
        try AXUIHelpers.press(resolved.element, identifier: resolved.identifier)
    }

    func setText(_ text: String, in identifier: String) throws {
        let resolved = try actionElement(identifier)
        try AXUIHelpers.setText(text, in: resolved.element, identifier: resolved.identifier)
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
        // 短路径避免超过 Darwin Unix socket 的路径长度上限。
        let runtimeURL = URL(fileURLWithPath: "/tmp/xi-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: runtimeURL)
        }
        let request = makeLaunchRequest(
            for: scenario,
            diagnosticsURL: runtimeURL.appendingPathComponent("diagnostics.json")
        )
        defer {
            if let suite = request.environment["X_ISLAND_TEST_DEFAULTS_SUITE"] {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
        }
        let context = try launch(request: request)
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

    private func launch(request: UITestLaunchRequest) throws -> UITestScenarioContext {
        guard let executableURL = Bundle(url: request.bundleURL)?.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path),
              let diagnosticsPath = request.environment["X_ISLAND_TEST_DIAGNOSTICS_PATH"] else {
            throw UITestDriverError.launchFailed("X Island executable not found in \(request.bundleURL.path)")
        }

        // 直接管理自己创建的应用进程，不根据 bundle ID 猜测或终止其他实例。
        let process = Process()
        process.executableURL = executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = URL(fileURLWithPath: diagnosticsPath).deletingLastPathComponent()
        try process.run()

        return UITestScenarioContext(
            process: process,
            application: AXUIHelpers.applicationElement(pid: process.processIdentifier),
            diagnosticsURL: URL(fileURLWithPath: diagnosticsPath),
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
        if ["question-custom-socket", "question-multiple-socket"].contains(scenario.name) { arguments.append("--ui-test-socket") }
        if scenario.opensPreferencesOnLaunch {
            arguments.append("--open-preferences")
        }
        return arguments
    }

    private func launchEnvironment(diagnosticsURL: URL, scenario: UITestScenario) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["X_ISLAND_TEST_MODE"] = "1"
        environment["X_ISLAND_TEST_FIXTURE"] = scenario.fixtureName
        environment.removeValue(forKey: "X_ISLAND_TEST_FIXTURE_PATH")
        environment["X_ISLAND_TEST_DIAGNOSTICS_PATH"] = diagnosticsURL.path
        environment["X_ISLAND_TEST_RUNTIME_DIR"] = diagnosticsURL.deletingLastPathComponent().path
        environment["X_ISLAND_TEST_DEFAULTS_SUITE"] = "dev.xisland.tests.\(UUID().uuidString)"
        let animationProfile = environment["X_ISLAND_TEST_ANIMATION_PROFILE"] ?? "deterministic"
        environment["X_ISLAND_TEST_ANIMATION_PROFILE"] = animationProfile
        environment["X_ISLAND_DISABLE_ANIMATIONS"] = animationProfile == "normal" ? "0" : "1"
        if scenario.opensPreferencesOnLaunch {
            environment["X_ISLAND_TEST_OPEN_PREFERENCES"] = "1"
        } else {
            environment.removeValue(forKey: "X_ISLAND_TEST_OPEN_PREFERENCES")
        }
        return environment
    }

    private func terminate(process: Process) {
        guard process.isRunning else { return }
        _ = NSRunningApplication(processIdentifier: process.processIdentifier)?.terminate()
        let gracefulDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < gracefulDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
            let forcedDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < forcedDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}
