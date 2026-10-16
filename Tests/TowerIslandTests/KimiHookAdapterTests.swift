import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class KimiHookAdapterTests: XCTestCase {
    func testConfigurationUsesTOMLNativeEventsAndObservationCommands() throws {
        XCTAssertEqual(KimiHookConfiguration.relativeConfigPath, ".kimi/config.toml")
        let config = try KimiHookConfiguration.merging(into: "", bridgePath: "/bin/di-bridge")
        XCTAssertEqual(config.components(separatedBy: "[[hooks]]").count - 1, 13)
        XCTAssertEqual(config.components(separatedBy: "timeout = 5").count - 1, 13)
        XCTAssertEqual(config.components(separatedBy: " || true").count - 1, 13)
        XCTAssertFalse(config.contains("PermissionRequest"))
        XCTAssertFalse(config.contains("matcher"))
        XCTAssertTrue(KimiHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))
        XCTAssertEqual(try KimiHookConfiguration.removing(from: config), "")
    }

    func testMergeAndRemovalPreserveThirdPartyTOMLByteForByte() throws {
        let original = """
        # User configuration; keep formatting, order and comments.
        default_model = 'my-model'
        tags = [
          'hooks = []', # not a hooks definition
          'other',
        ]
        [[hooks]] # a third-party observer
        event = 'Stop'
        command = 'audit di-bridge --agent kimi'
        timeout = 19
        [models.'my-model']
        provider = "custom"
        hooks = ["a model field"]
        """
        for source in [original, original + "\n", original.replacingOccurrences(of: "\n", with: "\r\n")] {
            let merged = try KimiHookConfiguration.merging(into: source, bridgePath: "/bin/di-bridge")
            XCTAssertTrue(merged.hasPrefix(source))
            XCTAssertEqual(try KimiHookConfiguration.removing(from: merged), source)
            XCTAssertEqual(try KimiHookConfiguration.removing(from: source), source)
        }
    }

    func testMultilineStringsDoNotCreateHooksOrOwnershipMarkers() throws {
        let source = "description = \"\"\"\n# BEGIN XIsland:Kimi:hooks v1\n[[hooks]]\nhooks = []\n# END XIsland:Kimi:hooks v1\n\"\"\"\nliteral = '''\n[hooks]\n'''\n"
        let merged = try KimiHookConfiguration.merging(into: source, bridgePath: "/bin/di-bridge")
        XCTAssertEqual(try KimiHookConfiguration.removing(from: merged), source)
    }

    func testMergeIsIdempotentAndChangesOnlyOwnedBridgePath() throws {
        let original = "[[hooks]]\nevent = 'Stop'\ncommand = '/old/di-bridge --agent kimi --hook Stop'\n"
        let first = try KimiHookConfiguration.merging(into: original, bridgePath: "/old/di-bridge")
        let second = try KimiHookConfiguration.merging(into: first, bridgePath: "/new/di-bridge")
        XCTAssertEqual(try KimiHookConfiguration.merging(into: second, bridgePath: "/new/di-bridge"), second)
        XCTAssertEqual(try KimiHookConfiguration.removing(from: second), original)
        XCTAssertTrue(second.contains("command = '/old/di-bridge --agent kimi --hook Stop'"))
        XCTAssertFalse(KimiHookConfiguration.isConfigured(in: second, bridgePath: "/old/di-bridge"))
    }

    func testPathsWithShellAndTOMLSyntaxRemainLiteral() throws {
        let bridge = "/tmp/O'Brien $(touch unexpected) `echo bad` \\ \"quoted\"/di-bridge"
        let config = try KimiHookConfiguration.merging(into: "", bridgePath: bridge)
        XCTAssertTrue(KimiHookConfiguration.isConfigured(in: config, bridgePath: bridge))
        XCTAssertEqual(try KimiHookConfiguration.removing(from: config), "")
        let line = try XCTUnwrap(config.components(separatedBy: "\n").first(where: { $0.hasPrefix("command = ") }))
        let encoded = Data(line.dropFirst("command = ".count).utf8)
        let command = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed]) as? String)
        // 使用 shell 自身检验参数还原；printf 不会执行被引用的路径内容。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\n' " + command.replacingOccurrences(of: " || true", with: "")]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "\(bridge)\n--agent\nkimi\n--hook\nSessionStart\n")
    }

    func testUnsupportedHooksDefinitionsAndMalformedLexicalBoundariesAreRejected() {
        let invalid = [
            "hooks = []\n", "hooks=[{ event='Stop', command='audit' }]\n",
            "'hooks' = []", "\"hooks\" = []", "hooks.Stop.command = 'audit'",
            "[hooks]\nStop = []", "[hooks.Stop]\ncommand = 'audit'",
            "[[hooks.child]]\nevent = 'Stop'", "[\"hooks\"]\n",
            "\"\\u0068ooks\" = []", "[[\"\\u0068ooks\"]]\nevent='Stop'",
            "text = \"unterminated", "text = '''unterminated", "tags = [1, 2",
            "tags = { x = 1 ]", "[unfinished", "name='a'\rname='b'", "name='\0'",
        ]
        for source in invalid {
            XCTAssertThrowsError(try KimiHookConfiguration.merging(into: source, bridgePath: "/bin/di-bridge"), source)
            XCTAssertThrowsError(try KimiHookConfiguration.removing(from: source), source)
            XCTAssertFalse(KimiHookConfiguration.isConfigured(in: source, bridgePath: "/bin/di-bridge"), source)
        }
        for path in ["~/bin/di-bridge", "relative", "/bin/di\0bridge", "/bin/di\nbridge", "/bin/di\tbridge"] {
            XCTAssertThrowsError(try KimiHookConfiguration.merging(into: "", bridgePath: path))
        }
    }

    func testConflictingOwnershipBlocksAreNeverDeletedOrOverwritten() throws {
        let owned = try KimiHookConfiguration.merging(into: "model = 'keep'\n", bridgePath: "/bin/di-bridge")
        let conflicting = [
            owned.replacingOccurrences(of: "timeout = 5", with: "timeout = 6"),
            owned.replacingOccurrences(of: "# END XIsland:Kimi:hooks v1", with: "# missing end"),
            owned.replacingOccurrences(of: "command = ", with: "custom = true\ncommand = "),
            owned + "[thirdparty]\nkeep = true\n",
            owned + "\n# BEGIN XIsland:Kimi:hooks v1\n",
            owned + (try KimiHookConfiguration.merging(into: "", bridgePath: "/other/di-bridge")),
            "# BEGIN XIsland:Kimi:hooks v2\n# END XIsland:Kimi:hooks v2\n",
        ]
        for source in conflicting {
            XCTAssertThrowsError(try KimiHookConfiguration.removing(from: source))
            XCTAssertThrowsError(try KimiHookConfiguration.merging(into: source, bridgePath: "/new/di-bridge"))
            XCTAssertFalse(KimiHookConfiguration.isConfigured(in: source, bridgePath: "/bin/di-bridge"))
        }
    }

    func testLegacyTemplateIncludingUnsupportedPermissionRequestIsMigrated() throws {
        let original = "default_model = 'keep'\n# X Island hooks\n"
        let legacy = legacyHookTemplates.map { legacyTable($0) }.joined()
        let removed = try KimiHookConfiguration.removing(from: original + legacy)
        XCTAssertEqual(removed, original)
        let migrated = try KimiHookConfiguration.merging(into: original + legacy, bridgePath: "/new/di-bridge")
        XCTAssertEqual(migrated, try KimiHookConfiguration.merging(into: original, bridgePath: "/new/di-bridge"))
        XCTAssertFalse(migrated.contains("PermissionRequest"))
        XCTAssertFalse(migrated.contains("matcher = \"*\""))
        XCTAssertEqual(migrated.components(separatedBy: "[[hooks]]").count - 1, 13)
        XCTAssertTrue(KimiHookConfiguration.isConfigured(in: migrated, bridgePath: "/new/di-bridge"))
    }

    func testMarkerlessDuplicateLegacyTablesAreRemovedAndInvalidateConfiguredStatus() throws {
        let legacy = legacyHookTemplates.map { legacyTable($0) }.joined()
        let source = legacy + legacy + legacyTable(("PermissionRequest", "PermissionRequest", 300))
        XCTAssertEqual(try KimiHookConfiguration.removing(from: source), "")
        let modern = try KimiHookConfiguration.merging(into: "", bridgePath: "/new/di-bridge")
        XCTAssertFalse(KimiHookConfiguration.isConfigured(in: source + modern, bridgePath: "/new/di-bridge"))
        XCTAssertEqual(try KimiHookConfiguration.merging(into: source + modern, bridgePath: "/new/di-bridge"), modern)
    }

    func testUserModifiedAndThirdPartyTablesArePreservedDuringLegacyMigration() throws {
        let legacy = legacyTable(("Stop", "notification", 5))
        let modified = [
            legacy + "custom = 'keep'\n",
            legacy.replacingOccurrences(of: "matcher = \"*\"", with: "matcher = \"Shell\""),
            legacy.replacingOccurrences(of: "timeout = 5", with: "timeout = 15"),
            legacy.replacingOccurrences(of: " --hook notification", with: " --hook Stop"),
            legacy.replacingOccurrences(of: "/old/di-bridge", with: "echo /old/di-bridge"),
            legacy.replacingOccurrences(of: "/old/di-bridge", with: "/old/custom-bridge"),
            legacy.replacingOccurrences(of: "/old/di-bridge", with: "/old/di-bridge && /new/di-bridge"),
            legacy.replacingOccurrences(of: "event =", with: "# user's annotation\nevent ="),
            legacy.replacingOccurrences(of: "[[hooks]]", with: "[[hooks]] # user's annotation"),
        ]
        for source in modified {
            XCTAssertEqual(try KimiHookConfiguration.removing(from: source), source)
            let migrated = try KimiHookConfiguration.merging(into: source + legacy, bridgePath: "/new/di-bridge")
            XCTAssertEqual(try KimiHookConfiguration.removing(from: migrated), source)
        }
    }

    func testModifiedUnsupportedLegacyEventIsRejectedWithoutProducingReplacement() throws {
        let permission = legacyTable(("PermissionRequest", "PermissionRequest", 300))
        for source in [permission + "custom = 'keep'\n", permission.replacingOccurrences(of: "timeout = 300", with: "timeout = 5"), permission.replacingOccurrences(of: "[[hooks]]", with: "[[\thooks\t]]")] {
            XCTAssertThrowsError(try KimiHookConfiguration.removing(from: source))
            XCTAssertThrowsError(try KimiHookConfiguration.merging(into: source, bridgePath: "/new/di-bridge"))
            XCTAssertFalse(KimiHookConfiguration.isConfigured(in: source, bridgePath: "/new/di-bridge"))
        }
    }

    func testLegacyTemplatesAndMarkersInsideMultilineStringsRemainUntouched() throws {
        let legacy = legacyHookTemplates.map { legacyTable($0) }.joined()
        let source = "notes = '''\n# X Island hooks\n" + legacy + "'''\n"
        XCTAssertEqual(try KimiHookConfiguration.removing(from: source), source)
        let migrated = try KimiHookConfiguration.merging(into: source + legacy, bridgePath: "/new/di-bridge")
        XCTAssertEqual(try KimiHookConfiguration.removing(from: migrated), source)
        XCTAssertTrue(migrated.hasPrefix(source))
    }

    func testSessionIdentitySurvivesMultipleTurnsAndCWDChanges() throws {
        let first = try normalize("UserPromptSubmit", fields: ["prompt": "实现搜索"])
        let next = try normalize("UserPromptSubmit", fields: ["prompt": "加测试", "cwd": "/other"])
        let other = try normalize("UserPromptSubmit", fields: ["prompt": "其他会话", "session_id": "native-2"])
        XCTAssertEqual(first.sessionId, "kimi-native-1")
        XCTAssertEqual(first.sessionId, next.sessionId)
        XCTAssertNotEqual(first.sessionId, other.sessionId)
        XCTAssertEqual(first.prompt, "实现搜索")
        XCTAssertEqual(first.workingDir, "/tmp/project with spaces")
        XCTAssertEqual(first.agentType, "kimi")
        XCTAssertEqual(first.terminal, "iTerm.app")
        XCTAssertEqual(first.termSessionId, "term-1")
    }

    func testPreToolNeverCreatesPermissionQuestionOrPlanRequest() throws {
        for tool in ["Shell", "AskUserQuestion", "ExitPlanMode"] {
            let message = try normalize("PreToolUse", fields: [
                "tool_name": tool, "tool_input": ["command": "pwd"], "tool_call_id": "tc-1",
            ])
            XCTAssertEqual(message.type, .toolStart)
            XCTAssertEqual(message.toolCallId, "tc-1")
            XCTAssertNil(message.permDescription)
            XCTAssertNil(message.questionText)
            XCTAssertNil(message.planMarkdown)
            XCTAssertNil(message.approved)
        }
    }

    func testToolOutputUsesNativeFieldAndPreservesJSONOrPlainText() throws {
        for output: Any in ["plain result", ["exit_code": 0, "stdout": "hello"], ["one", "two"], NSNull()] {
            let message = try normalize("PostToolUse", fields: [
                "tool_name": "Shell", "tool_input": ["command": "echo hello"],
                "tool_output": output, "tool_response": "wrong field", "tool_call_id": "tc-1",
            ])
            XCTAssertEqual(message.type, .toolComplete)
            XCTAssertEqual(message.toolResult, try text(output))
            XCTAssertEqual(message.toolCallId, "tc-1")
            XCTAssertNil(message.observedState)
        }
        let failed = try normalize("PostToolUseFailure", fields: [
            "tool_name": "Shell", "tool_input": [:], "error": "cancelled",
        ])
        XCTAssertEqual(failed.type, .toolComplete)
        XCTAssertEqual(failed.toolResult, "cancelled")
        XCTAssertEqual(failed.observedState, "error")
    }

    func testStopEndsTurnWithoutClaimingAnswerOrClosingSession() throws {
        let stop = try normalize("Stop", fields: ["stop_hook_active": false])
        XCTAssertEqual(stop.type, .statusUpdate)
        XCTAssertEqual(stop.observedState, "completionUnconfirmed")
        XCTAssertNil(stop.status)
        XCTAssertEqual(stop.statusIsAssistantReply, false)
        let end = try normalize("SessionEnd", fields: ["reason": "exit"])
        XCTAssertEqual(end.type, .sessionEnd)
        XCTAssertEqual(end.observedState, "completed")
        let failed = try normalize("StopFailure", fields: ["error_type": "TransportError", "error_message": "offline"])
        XCTAssertEqual(failed.observedState, "error")
        XCTAssertEqual(failed.status, "TransportError: offline")
    }

    func testCompactionDoesNotInventSummaryOrTokenUsage() throws {
        let start = try normalize("PreCompact", fields: ["trigger": "auto", "token_count": 123])
        let end = try normalize("PostCompact", fields: ["trigger": "auto", "estimated_token_count": 42])
        XCTAssertEqual(start.type, .contextCompact)
        XCTAssertEqual(end.type, .statusUpdate)
        XCTAssertEqual(end.observedState, "active")
        XCTAssertNil(end.recapText)
        XCTAssertNil(start.totalTokens)
        XCTAssertNil(end.totalTokens)
    }

    func testNotificationShowsReadableTextAndRemainsObservation() throws {
        let fields = ["sink": "terminal", "notification_type": "permission_prompt", "title": "Kimi", "body": "Needs approval", "severity": "warning"]
        let message = try normalize("Notification", fields: fields)
        XCTAssertEqual(message.type, .statusUpdate)
        XCTAssertEqual(message.status, "Kimi\nNeeds approval")
        XCTAssertEqual(message.statusIsAssistantReply, false)
        XCTAssertNil(message.observedState)
        XCTAssertNil(message.permDescription)
        XCTAssertNil(message.approved)
        for field in ["sink", "notification_type", "severity"] {
            var invalid: [String: Any] = fields
            invalid[field] = 12
            XCTAssertThrowsError(try normalize("Notification", fields: invalid))
        }
        XCTAssertEqual(try normalize("Notification", fields: fields.merging(["title": ""]) { _, value in value }).status, "Needs approval")
    }

    func testSubagentsWithoutUniqueIDRemainUnpairedObservations() throws {
        for event in ["SubagentStart", "SubagentStop"] {
            let field = event == "SubagentStart" ? "prompt" : "response"
            let message = try normalize(event, fields: ["agent_name": "researcher", field: "details"])
            XCTAssertEqual(message.type, .statusUpdate)
            XCTAssertEqual(message.statusIsAssistantReply, false)
            XCTAssertEqual(message.status, "researcher\ndetails")
            XCTAssertNil(message.subagentId)
            XCTAssertNil(message.parentSessionId)
        }
    }

    func testMissingIdentityMismatchedEventAndMalformedFieldsAreRejected() {
        XCTAssertThrowsError(try KimiHookAdapter.normalize(hookType: "Stop", stdinData: nil, environment: [:]))
        XCTAssertThrowsError(try normalize("Stop", fields: ["session_id": " "]))
        XCTAssertThrowsError(try normalize("Stop", fields: ["session_id": "native\0session"]))
        XCTAssertThrowsError(try normalize("Stop", fields: ["hook_event_name": "SessionEnd"]))
        XCTAssertThrowsError(try normalize("Stop", fields: ["cwd": 3]))
        XCTAssertThrowsError(try normalize("UserPromptSubmit", fields: [:]))
        XCTAssertThrowsError(try normalize("PreToolUse", fields: ["tool_name": "Shell", "tool_input": "pwd"]))
        XCTAssertThrowsError(try normalize("PreToolUse", fields: ["tool_name": "", "tool_input": [:]]))
        XCTAssertThrowsError(try normalize("PreToolUse", fields: ["tool_name": "Shell", "tool_input": [:], "tool_call_id": 3]))
        XCTAssertThrowsError(try normalize("PostToolUse", fields: ["tool_name": "Shell", "tool_input": [:], "tool_response": "wrong field"]))
        XCTAssertThrowsError(try normalize("PostToolUseFailure", fields: ["tool_name": "Shell", "tool_input": [:]]))
        XCTAssertThrowsError(try normalize("StopFailure", fields: [:]))
        XCTAssertThrowsError(try normalize("Notification", fields: ["message": "wrong field"]))
        XCTAssertThrowsError(try normalize("SubagentStart", fields: ["agent_name": "researcher"]))
        XCTAssertThrowsError(try normalize("PermissionRequest", fields: [:]))
        XCTAssertThrowsError(try normalize("InventedHook", fields: [:]))
    }

    private func normalize(_ event: String, fields: [String: Any]) throws -> DIMessage {
        var payload: [String: Any] = [
            "hook_event_name": event, "session_id": "native-1", "cwd": "/tmp/project with spaces",
        ]
        payload.merge(fields) { _, new in new }
        return try KimiHookAdapter.normalize(
            hookType: event, stdinData: payload,
            environment: ["TERM_PROGRAM": "iTerm.app", "TERM_SESSION_ID": "term-1"]
        )
    }

    private func text(_ value: Any) throws -> String {
        if let string = value as? String { return string }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }

    private let legacyHookTemplates: [(String, String, Int)] = [
        ("PreToolUse", "PreToolUse", 5), ("PostToolUse", "PostToolUse", 5),
        ("UserPromptSubmit", "session_start", 5), ("SessionStart", "session_start", 5),
        ("SessionEnd", "session_end", 5), ("Stop", "notification", 5),
        ("SubagentStart", "subagent_start", 5), ("SubagentStop", "subagent_end", 5),
        ("PreCompact", "compact", 5), ("Notification", "Notification", 5),
        ("PermissionRequest", "PermissionRequest", 300),
    ]

    private func legacyTable(_ hook: (String, String, Int)) -> String {
        let suffix = hook.2 == 300 ? "" : " || true"
        return "[[hooks]]\nevent = \"\(hook.0)\"\ncommand = \"/old/di-bridge --agent kimi --hook \(hook.1)\(suffix)\"\nmatcher = \"*\"\ntimeout = \(hook.2)\n"
    }
}
