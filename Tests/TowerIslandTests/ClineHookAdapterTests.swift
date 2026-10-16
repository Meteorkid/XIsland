import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class ClineHookAdapterTests: XCTestCase {
    @MainActor
    func testVSCodeSessionSurvivesAbsenceOfStandaloneClineProcess() {
        let manager = SessionManager()
        let cline = AgentSession(id: "cline-vscode-task", agentType: .cline)
        let cli = AgentSession(id: "qwen-process", agentType: .qwen)
        manager.sessions = [cline, cli]
        manager.checkProcessesAlive { _ in false }
        XCTAssertEqual(cline.status, .active)
        XCTAssertEqual(cli.status, .observationUnavailable)
        XCTAssertNil(cli.completedAt)
        XCTAssertFalse(AgentType.cline.sendsSessionEnd)
        XCTAssertFalse(AgentType.copilot.sendsSessionEnd)
    }

    func testInstallationUsesNativeExecutableEventFiles() throws {
        XCTAssertEqual(ClineHookConfiguration.relativeHooksDirectory, "Documents/Cline/Hooks")
        XCTAssertEqual(ClineHookConfiguration.workspaceHooksDirectory, ".clinerules/hooks")
        let plan = try ClineHookConfiguration.installationPlan(existingFiles: [:], bridgePath: "/bin/di-bridge")
        XCTAssertEqual(Set(plan.map(\.event)), Set(["TaskStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "TaskComplete", "TaskCancel"]))
        for file in plan {
            XCTAssertEqual(file.action, .create)
            XCTAssertEqual(file.permissions, 0o700)
            XCTAssertTrue(file.contents.hasPrefix("#!/bin/sh\n"))
            XCTAssertTrue(file.contents.contains("--agent cline --hook \(file.event)"))
            XCTAssertTrue(file.contents.hasSuffix("printf '%s\\n' '{\"cancel\":false}'\n"))
        }
    }

    func testInstallationIsIdempotentAndOnlyReplacesCanonicalOwnedFiles() throws {
        let first = try ClineHookConfiguration.installationPlan(existingFiles: [:], bridgePath: "/old/di-bridge")
        let existing = Dictionary(uniqueKeysWithValues: first.map {
            ($0.event, ClineHookConfiguration.ExistingFile.regularFile(contents: $0.contents, isExecutable: true))
        })
        XCTAssertTrue(ClineHookConfiguration.isConfigured(existingFiles: existing, bridgePath: "/old/di-bridge"))
        XCTAssertTrue(try ClineHookConfiguration.installationPlan(existingFiles: existing, bridgePath: "/old/di-bridge").allSatisfy { $0.action == .unchanged })
        let updated = try ClineHookConfiguration.installationPlan(existingFiles: existing, bridgePath: "/new/di-bridge")
        XCTAssertTrue(updated.allSatisfy { $0.action == .replaceOwned })
        XCTAssertFalse(ClineHookConfiguration.isConfigured(existingFiles: existing, bridgePath: "/new/di-bridge"))
    }

    func testUserFilesModifiedFilesSymlinksAndDirectoriesRemainConflicts() throws {
        let canonical = try ClineHookConfiguration.eventFileContents(event: "PostToolUse", bridgePath: "/bin/di-bridge")
        let existing: [String: ClineHookConfiguration.ExistingFile] = [
            "TaskStart": .regularFile(contents: "#!/bin/sh\naudit di-bridge\n", isExecutable: true),
            "PreToolUse": .symbolicLink,
            "PostToolUse": .regularFile(contents: canonical + "# User customization\n", isExecutable: true),
            "TaskComplete": .other,
            "TaskCancel": .regularFile(contents: "# XIsland:Cline:TaskCancel:v1\n", isExecutable: false),
        ]
        let plan = try ClineHookConfiguration.installationPlan(existingFiles: existing, bridgePath: "/bin/di-bridge")
        for file in plan {
            XCTAssertEqual(file.action, file.event == "UserPromptSubmit" ? .create : .conflict)
        }
        XCTAssertFalse(ClineHookConfiguration.isConfigured(existingFiles: existing, bridgePath: "/bin/di-bridge"))
    }

    func testNonExecutableOwnedFileIsNotReportedConfigured() throws {
        let script = try ClineHookConfiguration.eventFileContents(event: "PreToolUse", bridgePath: "/bin/di-bridge")
        let plan = try ClineHookConfiguration.installationPlan(existingFiles: ["PreToolUse": .regularFile(contents: script, isExecutable: false)], bridgePath: "/bin/di-bridge")
        XCTAssertEqual(plan.first { $0.event == "PreToolUse" }?.action, .replaceOwned)
    }

    func testInstallAndRemoveInTemporaryDirectoryPreserveOtherFiles() throws {
        try withTemporaryDirectory { root in
            let directory = root.appendingPathComponent("Hooks")
            try ClineHookConfiguration.install(in: directory, bridgePath: "/old/di-bridge")
            XCTAssertTrue(ClineHookConfiguration.isConfigured(in: directory, bridgePath: "/old/di-bridge"))
            for event in ClineHookConfiguration.events {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(event).path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            }
            try ClineHookConfiguration.install(in: directory, bridgePath: "/new/di-bridge")
            try ClineHookConfiguration.install(in: directory, bridgePath: "/new/di-bridge")
            XCTAssertTrue(ClineHookConfiguration.isConfigured(in: directory, bridgePath: "/new/di-bridge"))
            let readme = directory.appendingPathComponent("README.md")
            try "user notes".write(to: readme, atomically: true, encoding: .utf8)
            try ClineHookConfiguration.remove(from: directory)
            XCTAssertFalse(ClineHookConfiguration.isConfigured(in: directory, bridgePath: "/new/di-bridge"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["README.md"])
            XCTAssertEqual(try String(contentsOf: readme), "user notes")
        }
    }

    func testInstallPreflightRejectsConflictWithoutCreatingAnyEventFiles() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("TaskCancel")
            let userScript = "#!/bin/sh\nprintf '%s\\n' '{\"cancel\":true}'\n"
            try userScript.write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            XCTAssertThrowsError(try ClineHookConfiguration.install(in: directory, bridgePath: "/bin/di-bridge")) { error in
                XCTAssertEqual(error as? ClineHookConfiguration.ConfigurationError, .conflictingFiles(["TaskCancel"]))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["TaskCancel"])
            XCTAssertEqual(try String(contentsOf: target), userScript)
            try ClineHookConfiguration.remove(from: directory)
            XCTAssertEqual(try String(contentsOf: target), userScript)
        }
    }

    func testRepairRequiresExistingDirectoryAndConflictFreeIncompletePlan() throws {
        try withTemporaryDirectory { root in
            let directory = root.appendingPathComponent("Hooks")
            XCTAssertFalse(ClineHookConfiguration.shouldRepair(in: directory, bridgePath: "/bin/di-bridge"))
            try ClineHookConfiguration.install(in: directory, bridgePath: "/bin/di-bridge")
            XCTAssertFalse(ClineHookConfiguration.shouldRepair(in: directory, bridgePath: "/bin/di-bridge"))
            XCTAssertTrue(ClineHookConfiguration.shouldRepair(in: directory, bridgePath: "/new/di-bridge"))
            let target = directory.appendingPathComponent("PostToolUse")
            try FileManager.default.removeItem(at: target)
            XCTAssertTrue(ClineHookConfiguration.shouldRepair(in: directory, bridgePath: "/bin/di-bridge"))
            try "#!/bin/sh\nuser-audit\n".write(to: target, atomically: true, encoding: .utf8)
            XCTAssertFalse(ClineHookConfiguration.shouldRepair(in: directory, bridgePath: "/bin/di-bridge"))
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "/missing-target")
            XCTAssertFalse(ClineHookConfiguration.shouldRepair(in: directory, bridgePath: "/bin/di-bridge"))
            let alias = root.appendingPathComponent("HooksAlias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            XCTAssertFalse(ClineHookConfiguration.shouldRepair(in: alias, bridgePath: "/bin/di-bridge"))
        }
    }

    func testInstallAndRemoveDoNotFollowEventOrDirectorySymlinks() throws {
        try withTemporaryDirectory { root in
            let directory = root.appendingPathComponent("Hooks")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let external = root.appendingPathComponent("user-script")
            let script = try ClineHookConfiguration.eventFileContents(event: "PreToolUse", bridgePath: "/old/di-bridge")
            try script.write(to: external, atomically: true, encoding: .utf8)
            let hook = directory.appendingPathComponent("PreToolUse")
            try FileManager.default.createSymbolicLink(at: hook, withDestinationURL: external)
            XCTAssertThrowsError(try ClineHookConfiguration.install(in: directory, bridgePath: "/new/di-bridge"))
            try ClineHookConfiguration.remove(from: directory)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: hook.path), external.path)
            XCTAssertEqual(try String(contentsOf: external), script)
            let alias = root.appendingPathComponent("HooksAlias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            XCTAssertThrowsError(try ClineHookConfiguration.install(in: alias, bridgePath: "/new/di-bridge"))
            XCTAssertThrowsError(try ClineHookConfiguration.remove(from: alias))
            XCTAssertFalse(ClineHookConfiguration.isConfigured(in: alias, bridgePath: "/new/di-bridge"))
        }
    }

    func testRemovalKeepsModifiedOwnedScriptsAndNonUTF8UserFiles() throws {
        try withTemporaryDirectory { directory in
            try ClineHookConfiguration.install(in: directory, bridgePath: "/bin/di-bridge")
            let edited = directory.appendingPathComponent("PreToolUse")
            let script = try String(contentsOf: edited) + "# custom audit\n"
            try script.write(to: edited, atomically: true, encoding: .utf8)
            let binary = directory.appendingPathComponent("TaskCancel")
            let binaryContent = Data([0xff, 0xfe, 0x80])
            try binaryContent.write(to: binary)
            XCTAssertThrowsError(try ClineHookConfiguration.install(in: directory, bridgePath: "/new/di-bridge"))
            try ClineHookConfiguration.remove(from: directory)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["PreToolUse", "TaskCancel"])
            XCTAssertEqual(try String(contentsOf: edited), script)
            XCTAssertEqual(try Data(contentsOf: binary), binaryContent)
        }
    }

    func testOwnershipRequiresTheWholeScriptAndLiteralAbsolutePath() throws {
        let path = "/tmp/O'Brien $(touch unexpected) `echo bad`/di-bridge"
        let script = try ClineHookConfiguration.eventFileContents(event: "PreToolUse", bridgePath: path)
        XCTAssertTrue(script.contains("'/tmp/O'\\''Brien $(touch unexpected) `echo bad`/di-bridge'"))
        XCTAssertTrue(ClineHookConfiguration.isOwned(contents: script, event: "PreToolUse"))
        XCTAssertFalse(ClineHookConfiguration.isOwned(contents: script, event: "PostToolUse"))
        XCTAssertFalse(ClineHookConfiguration.isOwned(contents: script.replacingOccurrences(of: " --agent", with: " ; audit --agent"), event: "PreToolUse"))
        for path in ["~/bin/di-bridge", "relative", "/tmp/di\0bridge", "/tmp/di\nbridge"] {
            XCTAssertThrowsError(try ClineHookConfiguration.eventFileContents(event: "PreToolUse", bridgePath: path))
        }
        XCTAssertThrowsError(try ClineHookConfiguration.eventFileContents(event: "PermissionRequest", bridgePath: "/bin/di-bridge"))
    }

    func testScriptForwardsStdinButAlwaysReturnsOnlyTheObservationResponse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cline-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = directory.appendingPathComponent("O'Brien $(false) bridge")
        let captured = directory.appendingPathComponent("captured.json")
        let stub = "#!/bin/sh\n/bin/cat > \"$CLINE_TEST_CAPTURE\"\nprintf '%s\\n' '{\"cancel\":true}'\nexit 23\n"
        try stub.write(to: bridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        let hook = directory.appendingPathComponent("PreToolUse")
        try ClineHookConfiguration.eventFileContents(event: "PreToolUse", bridgePath: bridge.path).write(to: hook, atomically: true, encoding: .utf8)
        let input = Data("{\"taskId\":\"literal $(false)\"}".utf8)
        let result = try executeHook(hook, input: input, environment: ["CLINE_TEST_CAPTURE": captured.path])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "{\"cancel\":false}\n")
        XCTAssertEqual(try Data(contentsOf: captured), input)

        try ClineHookConfiguration.eventFileContents(event: "PreToolUse", bridgePath: directory.appendingPathComponent("missing").path).write(to: hook, atomically: true, encoding: .utf8)
        let missing = try executeHook(hook, input: Data(), environment: [:])
        XCTAssertEqual(missing.status, 0)
        XCTAssertEqual(missing.output, "{\"cancel\":false}\n")
    }

    func testTaskIdentityIsStableAcrossTurnsAndResume() throws {
        let start = try normalize("TaskStart", payload: ["taskMetadata": ["taskId": "task-1", "initialTask": "创建搜索"]])
        let next = try normalize("UserPromptSubmit", payload: ["prompt": "增加测试"])
        let resume = try normalize("TaskResume", payload: ["taskMetadata": ["taskId": "task-1"], "previousState": ["messageCount": "8"]])
        let other = try normalize("UserPromptSubmit", payload: ["prompt": "另一个任务"], fields: ["taskId": "task-2"])
        XCTAssertEqual(start.sessionId, "cline-task-1")
        XCTAssertEqual(start.sessionId, next.sessionId)
        XCTAssertEqual(start.sessionId, resume.sessionId)
        XCTAssertNotEqual(start.sessionId, other.sessionId)
        XCTAssertEqual(start.type, .sessionStart)
        XCTAssertEqual(start.prompt, "创建搜索")
        XCTAssertEqual(next.prompt, "增加测试")
        XCTAssertEqual(start.agentType, "cline")
    }

    func testTimestampUsesEpochMillisecondsString() throws {
        let message = try normalize("TaskStart", payload: [:], fields: ["timestamp": "1789000000123"])
        XCTAssertEqual(message.timestamp.timeIntervalSince1970, 1_789_000_000.123, accuracy: 0.0001)
        for value in ["2026-09-24T00:00:00Z", "NaN", "-1", "1e12", "253402300800000", 1789000000123] as [Any] {
            XCTAssertThrowsError(try normalize("TaskStart", payload: [:], fields: ["timestamp": value]))
        }
    }

    func testWorkspaceAndModelMetadataDoNotInventAMultiRootCwd() throws {
        let single = try normalize("TaskStart", payload: [:], fields: ["workspaceRoots": ["/tmp/project"], "model": ["provider": "vendor", "slug": "example-model"]])
        XCTAssertEqual(single.workingDir, "/tmp/project")
        XCTAssertEqual(single.model, "example-model")
        let multiple = try normalize("TaskStart", payload: [:], fields: ["workspaceRoots": ["/tmp/a", "/tmp/b"], "model": ["slug": "unknown"]])
        XCTAssertNil(multiple.workingDir)
        XCTAssertNil(multiple.model)
        XCTAssertNil(try normalize("TaskStart", payload: [:]).workingDir)
        XCTAssertThrowsError(try normalize("TaskStart", payload: [:], fields: ["workspaceRoots": "/tmp/project"]))
    }

    func testNestedToolFieldsPreserveStringParametersAndResult() throws {
        let parameters = ["path": "/tmp/project/a.swift", "content": "let value = 1", "requires_approval": "true"]
        let start = try normalize("PreToolUse", payload: ["toolName": "write_to_file", "parameters": parameters])
        let complete = try normalize("PostToolUse", payload: ["toolName": "write_to_file", "parameters": parameters, "result": "已写入", "success": true, "executionTimeMs": 125])
        XCTAssertEqual(start.type, .toolStart)
        XCTAssertEqual(complete.type, .toolComplete)
        XCTAssertEqual(start.tool, "write_to_file")
        XCTAssertEqual(start.filePath, "/tmp/project/a.swift")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(start.toolInput).utf8)) as? [String: String], parameters)
        XCTAssertEqual(complete.toolResult, "已写入")
        XCTAssertNil(complete.observedState)
        XCTAssertNil(start.toolCallId)
        XCTAssertNil(complete.totalTokens)
        XCTAssertNil(complete.costUSD)
    }

    func testProtoDefaultValuesAreRestoredAndFalseMeansToolFailure() throws {
        let defaulted = try normalize("PostToolUse", payload: ["toolName": "execute_command"])
        XCTAssertEqual(defaulted.toolInput, "{}")
        XCTAssertEqual(defaulted.toolResult, "")
        XCTAssertEqual(defaulted.observedState, "error")
        let failure = try normalize("PostToolUse", payload: ["toolName": "execute_command", "success": false, "result": "退出码 1"])
        XCTAssertEqual(failure.observedState, "error")
        XCTAssertEqual(failure.toolResult, "退出码 1")
        XCTAssertThrowsError(try normalize("PostToolUse", payload: ["toolName": "execute_command", "success": 1]))
        XCTAssertThrowsError(try normalize("PostToolUse", payload: ["toolName": "execute_command", "success": "false"]))
    }

    func testQuestionAndCompletionToolNamesNeverCreateNativeInteractions() throws {
        for tool in ["ask_followup_question", "AskUserQuestion", "attempt_completion", "execute_command"] {
            let message = try normalize("PreToolUse", payload: ["toolName": tool, "parameters": ["question": "继续？", "requires_approval": "true"]])
            XCTAssertEqual(message.type, .toolStart)
            XCTAssertNil(message.questionText)
            XCTAssertNil(message.permDescription)
            XCTAssertNil(message.nativeRequestId)
            XCTAssertNil(message.nativeRequestKind)
            XCTAssertNil(message.approved)
        }
    }

    func testCompletionAndCancellationEndRunWithoutClosingResumableTask() throws {
        let complete = try normalize("TaskComplete", payload: ["taskMetadata": ["taskId": "task-1", "result": "已完成"]])
        XCTAssertEqual(complete.type, .statusUpdate)
        XCTAssertEqual(complete.observedState, "idle")
        XCTAssertEqual(complete.status, "已完成")
        XCTAssertEqual(complete.statusIsAssistantReply, true)
        let cancelled = try normalize("TaskCancel", payload: ["taskMetadata": ["completionStatus": "cancelled"]])
        XCTAssertEqual(cancelled.type, .statusUpdate)
        XCTAssertEqual(cancelled.observedState, "idle")
        XCTAssertEqual(cancelled.statusIsAssistantReply, false)
    }

    func testInvalidPayloadIdentityAndFlatToolFieldsAreRejected() {
        XCTAssertThrowsError(try ClineHookAdapter.normalize(hookType: "TaskStart", stdinData: nil, environment: [:]))
        for field in ["hookName", "taskId", "timestamp"] {
            XCTAssertThrowsError(try normalize("TaskStart", payload: [:], fields: [field: " "]))
        }
        XCTAssertThrowsError(try normalize("TaskStart", payload: [:], fields: ["hookName": "TaskCancel"]))
        XCTAssertThrowsError(try normalize("TaskStart", payload: ["taskMetadata": ["taskId": "other-task"]]))
        XCTAssertThrowsError(try normalize("PreToolUse", payload: [:], fields: ["tool_name": "read_file", "tool_input": ["path": "/tmp/file"]]))
        XCTAssertThrowsError(try normalize("PreToolUse", payload: ["toolName": "read_file", "parameters": ["path": 1]]))
        XCTAssertThrowsError(try normalize("PostToolUse", payload: ["toolName": "read_file", "result": ["text": "bad"]]))
        XCTAssertThrowsError(try normalize("PreCompact", payload: [:]))
        XCTAssertThrowsError(try normalize("PermissionRequest", payload: [:]))
    }

    private func normalize(_ event: String, payload: [String: Any], fields: [String: Any] = [:]) throws -> DIMessage {
        let field = event.prefix(1).lowercased() + event.dropFirst()
        var data: [String: Any] = ["hookName": event, "taskId": "task-1", "timestamp": "1789000000000", field: payload]
        data.merge(fields) { _, replacement in replacement }
        return try ClineHookAdapter.normalize(hookType: event, stdinData: data, environment: [:])
    }

    private func executeHook(_ url: URL, input: Data, environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [url.path]
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cline-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
