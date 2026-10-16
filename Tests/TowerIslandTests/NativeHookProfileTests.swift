import XCTest
@testable import XIsland

final class NativeHookProfileTests: XCTestCase {
    func testOnlyDocumentedNativeProfilesAreAvailable() throws {
        let expected: [AgentType: String] = [
            .claudeCode: ".claude/settings.json",
            .codex: ".codex/hooks.json",
            .qwen: ".qwen/settings.json",
            .qoder: ".qoder/settings.json",
            .droid: ".factory/hooks.json",
            .geminiCli: ".gemini/settings.json",
            .tabnine: ".tabnine/agent/settings.json",
        ]
        for agent in AgentType.allCases {
            if let path = expected[agent] {
                let profile = try XCTUnwrap(NativeHookProfile.profile(for: agent))
                XCTAssertEqual(profile.relativeConfigPath, path)
                XCTAssertEqual(profile.hooksAreAtRoot, agent == .droid)
                XCTAssertEqual(profile.timeoutUnit, [.geminiCli, .tabnine].contains(agent) ? .milliseconds : .seconds)
            } else {
                XCTAssertNil(NativeHookProfile.profile(for: agent), "Unexpected template for \(agent)")
            }
        }
    }

    func testGeminiUsesNativeNamesMillisecondsAndObservationOnly() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .geminiCli))
        let events = Dictionary(uniqueKeysWithValues: profile.bindings.map { ($0.event, $0) })
        XCTAssertEqual(events["BeforeTool"]?.bridgeHook, "toolstart")
        XCTAssertEqual(events["BeforeTool"]?.timeout, 5_000)
        XCTAssertEqual(events["BeforeAgent"]?.bridgeHook, "UserPromptSubmit")
        XCTAssertEqual(events["Notification"]?.bridgeHook, "Notification")
        XCTAssertEqual(events["AfterAgent"]?.bridgeHook, "notification")
        XCTAssertEqual(events["SessionEnd"]?.timeout, 1_000)
        for invalidEvent in ["PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "PreCompact"] {
            XCTAssertNil(events[invalidEvent])
        }
    }

    func testFactoryUsesUnwrappedEventMapAndOnlyDocumentedEvents() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .droid))
        let merged = try profile.merging(into: [:], bridgePath: "/bin/di-bridge")
        XCTAssertNil(merged["hooks"])
        XCTAssertNotNil(merged["PreToolUse"])
        XCTAssertNil(merged["PermissionRequest"])
        XCTAssertNil(merged["SubagentStart"])
        XCTAssertNil(merged["PostToolUseFailure"])
        XCTAssertEqual(profile.bindings.first { $0.event == "PreToolUse" }?.bridgeHook, "toolstart")
    }

    func testPromptSubmissionRemainsSeparateFromSessionStart() throws {
        for agent in [AgentType.claudeCode, .codex, .qwen, .qoder, .droid] {
            let profile = try XCTUnwrap(NativeHookProfile.profile(for: agent))
            XCTAssertEqual(profile.bindings.first { $0.event == "SessionStart" }?.bridgeHook, "session_start")
            XCTAssertEqual(profile.bindings.first { $0.event == "UserPromptSubmit" }?.bridgeHook, "UserPromptSubmit")
            XCTAssertNotEqual(profile.bindings.first { $0.event == "Stop" }?.bridgeHook, "session_end")
        }
    }

    func testCodexBindingsMatchItsSupportedLifecycle() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .codex))
        XCTAssertEqual(Set(profile.bindings.map(\.event)), [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd",
            "SubagentStart", "SubagentStop",
            "Interrupt", "PreCompact", "PostCompact",
        ])
        XCTAssertEqual(profile.bindings.first { $0.event == "Stop" }?.bridgeHook, "Stop")
        XCTAssertEqual(profile.bindings.first { $0.event == "SessionEnd" }?.timeout, 1)
        for event in ["Interrupt", "PreCompact", "PostCompact"] {
            XCTAssertEqual(profile.bindings.first { $0.event == event }?.bridgeHook, event)
            XCTAssertEqual(profile.bindings.first { $0.event == event }?.timeout, event == "Interrupt" ? 1 : 5)
        }
    }

    func testOnlyClaudeKeepsLongRunningPreToolQuestionInteraction() throws {
        let claude = try XCTUnwrap(NativeHookProfile.profile(for: .claudeCode))
        let claudePreTool = try XCTUnwrap(claude.bindings.first { $0.event == "PreToolUse" })
        XCTAssertEqual(claudePreTool.bridgeHook, "PreToolUse")
        XCTAssertEqual(claudePreTool.timeout, 300)
        for agent in [AgentType.qwen, .qoder, .droid] {
            let profile = try XCTUnwrap(NativeHookProfile.profile(for: agent))
            let preTool = try XCTUnwrap(profile.bindings.first { $0.event == "PreToolUse" })
            XCTAssertEqual(preTool.bridgeHook, "toolstart")
            XCTAssertEqual(preTool.timeout, 5)
        }
    }

    func testPermissionCommandsPreserveDecisionWhileReportsRemainNonBlocking() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .qoder))
        let merged = try profile.merging(into: [:], bridgePath: "/bin/di-bridge")
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        let permission = try generatedCommand(in: hooks, event: "PermissionRequest")
        XCTAssertEqual(permission["command"] as? String, "'/bin/di-bridge' --agent qoder --hook PermissionRequest")
        XCTAssertEqual(permission["timeout"] as? Int, 300)
        let report = try generatedCommand(in: hooks, event: "Notification")
        XCTAssertEqual(report["command"] as? String, "'/bin/di-bridge' --agent qoder --hook Notification || true")
    }

    func testMergePreservesThirdPartyHooksInMixedMatcherGroupAndRemovesStaleOwnedEvent() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .qwen))
        let thirdParty: [String: Any] = ["type": "command", "command": "audit-tool --strict", "timeout": 9]
        let original: [String: Any] = [
            "model": "existing-model",
            "hooks": [
                "PreToolUse": [[
                    "matcher": "read_file",
                    "sequential": true,
                    "hooks": [
                        ["type": "command", "command": "/old/di-bridge --agent qwen --hook PreToolUse || true"],
                        thirdParty,
                    ],
                ]],
                "ToolUse": [["hooks": [["type": "command", "command": "/old/di-bridge --agent qwen --hook ToolUse"]]]],
            ],
        ]
        let merged = try profile.merging(into: original, bridgePath: "/new/di-bridge")
        XCTAssertEqual(merged["model"] as? String, "existing-model")
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        XCTAssertNil(hooks["ToolUse"])
        let groups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0]["matcher"] as? String, "read_file")
        XCTAssertEqual(groups[0]["sequential"] as? Bool, true)
        let preserved = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(preserved.count, 1)
        XCTAssertTrue(NSDictionary(dictionary: preserved[0]).isEqual(to: thirdParty))
    }

    func testMergeDoesNotClaimCommandsThatOnlyMentionBridgeOrAnotherAgent() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .codex))
        let preserved: [[String: Any]] = [
            ["type": "command", "command": "echo /bin/di-bridge --agent codex --hook Stop"],
            ["type": "command", "command": "/bin/di-bridge-helper --agent codex --hook Stop"],
            ["type": "command", "command": "/bin/di-bridge --agent qwen --hook Stop"],
            ["type": "command", "command": "/bin/di-bridge --agent codex --hook Stop && custom-cleanup"],
            ["type": "prompt", "prompt": "Inspect the result", "command": "/bin/di-bridge --agent codex --hook Stop"],
        ]
        let merged = try profile.merging(into: ["hooks": ["Stop": [["hooks": preserved]]]], bridgePath: "/new/di-bridge")
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let commands = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(commands.count, preserved.count)
        for (actual, expected) in zip(commands, preserved) {
            XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected))
        }
    }

    func testShellSensitiveBridgePathIsQuotedAndRepeatedMergeIsIdempotent() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .claudeCode))
        let bridgePath = "/Users/O'Brien/$(touch sentinel) `echo unsafe`/di-bridge"
        let once = try profile.merging(into: ["keep": true], bridgePath: bridgePath)
        let twice = try profile.merging(into: once, bridgePath: bridgePath)
        XCTAssertTrue(NSDictionary(dictionary: once).isEqual(to: twice))
        let hooks = try XCTUnwrap(once["hooks"] as? [String: Any])
        let command = try generatedCommand(in: hooks, event: "SessionStart")
        XCTAssertEqual(command["command"] as? String,
                       "'/Users/O'\\''Brien/$(touch sentinel) `echo unsafe`/di-bridge' --agent claude_code --hook session_start || true")
    }

    func testMalformedConfigurationRejectsTheWholeMerge() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .qwen))
        let cases: [([String: Any], NativeHookProfile.MergeError)] = [
            (["hooks": "custom-format"], .invalidHooksContainer),
            (["hooks": ["SessionStart": "unsupported"]], .invalidEvent("SessionStart")),
            (["hooks": ["Stop": [42]]], .invalidGroup(event: "Stop", index: 0)),
            (["hooks": ["Stop": [["hooks": "wrong"]]]], .invalidGroup(event: "Stop", index: 0)),
            (["hooks": ["Stop": [["matcher": 42, "hooks": []]]]], .invalidGroup(event: "Stop", index: 0)),
            (["hooks": ["Stop": [["hooks": [42]]]]], .invalidHook(event: "Stop", group: 0, index: 0)),
            (["hooks": ["Stop": [["hooks": [["type": "command"]]]]]], .invalidHook(event: "Stop", group: 0, index: 0)),
            (["hooks": ["Stop": [["hooks": [["type": "prompt"]]]]]], .invalidHook(event: "Stop", group: 0, index: 0)),
        ]
        for (configuration, expectedError) in cases {
            XCTAssertThrowsError(try profile.merging(into: configuration, bridgePath: "/bin/di-bridge")) { error in
                XCTAssertEqual(error as? NativeHookProfile.MergeError, expectedError)
            }
        }
    }

    func testUnknownValidHookTypesAndEventsArePreserved() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .qwen))
        let futureGroup: [String: Any] = ["hooks": [["type": "future-handler", "options": ["keep": true]]]]
        let merged = try profile.merging(into: ["hooks": ["FutureEvent": [futureGroup]]], bridgePath: "/bin/di-bridge")
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["FutureEvent"] as? [[String: Any]])
        XCTAssertTrue(NSDictionary(dictionary: groups[0]).isEqual(to: futureGroup))
    }

    func testEveryProfileProducesIdempotentJSON() throws {
        for agent in AgentType.allCases {
            guard let profile = NativeHookProfile.profile(for: agent) else { continue }
            let first = try profile.merging(into: [:], bridgePath: "/path with spaces/di-bridge")
            let second = try profile.merging(into: first, bridgePath: "/path with spaces/di-bridge")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(first))
            XCTAssertTrue(NSDictionary(dictionary: first).isEqual(to: second), "Non-idempotent profile: \(agent)")
        }
    }

    func testRemovingPreservesMixedHandlersAndDeletesOwnedLegacyEvents() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .codex))
        let otherHandler: [String: Any] = ["type": "command", "command": "audit-tool --strict"]
        let otherAgentHandler: [String: Any] = ["type": "command", "command": "/bin/di-bridge --agent qwen --hook Stop"]
        let source: [String: Any] = [
            "keep": "value",
            "hooks": [
                "Stop": [["matcher": "*", "hooks": [
                    ["type": "command", "command": "/old/di-bridge --agent codex --hook notification || true"],
                    otherHandler,
                    otherAgentHandler,
                ]]],
                "PatchApply": [["hooks": [["type": "command", "command": "/old/di-bridge --agent codex --hook PatchApply"]]]],
                "FutureEvent": [["hooks": [["type": "http", "url": "https://example.invalid/hooks"]]]],
            ],
        ]
        let removed = try profile.removing(from: source)
        XCTAssertEqual(removed["keep"] as? String, "value")
        let hooks = try XCTUnwrap(removed["hooks"] as? [String: Any])
        XCTAssertNil(hooks["PatchApply"])
        XCTAssertNotNil(hooks["FutureEvent"])
        let group = try XCTUnwrap((hooks["Stop"] as? [[String: Any]])?.first)
        XCTAssertEqual(group["matcher"] as? String, "*")
        let commands = try XCTUnwrap(group["hooks"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(NSDictionary(dictionary: commands[0]).isEqual(to: otherHandler))
        XCTAssertTrue(NSDictionary(dictionary: commands[1]).isEqual(to: otherAgentHandler))
        XCTAssertTrue(NSDictionary(dictionary: try profile.removing(from: removed)).isEqual(to: removed))
    }

    func testRemovingDoesNotCreateHooksContainerAndWorksForFactoryRootMap() throws {
        let codex = try XCTUnwrap(NativeHookProfile.profile(for: .codex))
        let empty: [String: Any] = ["keep": true]
        XCTAssertTrue(NSDictionary(dictionary: try codex.removing(from: empty)).isEqual(to: empty))
        let factory = try XCTUnwrap(NativeHookProfile.profile(for: .droid))
        let installed = try factory.merging(into: [:], bridgePath: "/bin/di-bridge")
        XCTAssertTrue(try factory.removing(from: installed).isEmpty)
    }

    func testRemovingRejectsMalformedStructureBeforeReturningChanges() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .qwen))
        let installed = try profile.merging(into: [:], bridgePath: "/bin/di-bridge")
        var broken = installed
        var hooks = try XCTUnwrap(broken["hooks"] as? [String: Any])
        hooks["FutureEvent"] = [["hooks": ["invalid-handler"]]]
        broken["hooks"] = hooks
        XCTAssertThrowsError(try profile.removing(from: broken)) { error in
            XCTAssertEqual(error as? NativeHookProfile.MergeError, .invalidHook(event: "FutureEvent", group: 0, index: 0))
        }
        XCTAssertFalse(profile.isConfigured(in: broken, bridgePath: "/bin/di-bridge"))
    }

    func testConfigurationRequiresEveryBindingAndCurrentPath() throws {
        for agent in AgentType.allCases {
            guard let profile = NativeHookProfile.profile(for: agent) else { continue }
            let installed = try profile.merging(into: [:], bridgePath: "/current/di-bridge")
            XCTAssertTrue(profile.isConfigured(in: installed, bridgePath: "/current/di-bridge"))
            XCTAssertFalse(profile.isConfigured(in: installed, bridgePath: "/new/di-bridge"))
            XCTAssertFalse(profile.isConfigured(in: [:], bridgePath: "/current/di-bridge"))
            var missing = installed
            if profile.hooksAreAtRoot {
                missing.removeValue(forKey: "SessionStart")
            } else {
                var hooks = try XCTUnwrap(missing["hooks"] as? [String: Any])
                hooks.removeValue(forKey: "SessionStart")
                missing["hooks"] = hooks
            }
            XCTAssertFalse(profile.isConfigured(in: missing, bridgePath: "/current/di-bridge"))
        }
    }

    func testConfigurationRejectsIncorrectTimeoutMappingAndMatcher() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .geminiCli))
        let installed = try profile.merging(into: [:], bridgePath: "/bin/di-bridge")
        for mutation in 0..<3 {
            var configuration = installed
            var hooks = try XCTUnwrap(configuration["hooks"] as? [String: Any])
            var groups = try XCTUnwrap(hooks["BeforeTool"] as? [[String: Any]])
            var commands = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
            switch mutation {
            case 0: commands[0]["timeout"] = 5
            case 1: commands[0]["command"] = "'/bin/di-bridge' --agent gemini_cli --hook PermissionRequest"
            default: groups[0]["matcher"] = "read_file"
            }
            groups[0]["hooks"] = commands
            hooks["BeforeTool"] = groups
            configuration["hooks"] = hooks
            XCTAssertFalse(profile.isConfigured(in: configuration, bridgePath: "/bin/di-bridge"))
        }
    }

    func testConfigurationRejectsOwnedDuplicatesAndWrongEventsButKeepsThirdPartyHooks() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .codex))
        var installed = try profile.merging(into: [:], bridgePath: "/bin/di-bridge")
        var hooks = try XCTUnwrap(installed["hooks"] as? [String: Any])
        hooks["CustomEvent"] = [["hooks": [["type": "command", "command": "audit-custom-event"]]]]
        installed["hooks"] = hooks
        XCTAssertTrue(profile.isConfigured(in: installed, bridgePath: "/bin/di-bridge"))
        let stopGroups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        hooks["ToolUse"] = stopGroups
        installed["hooks"] = hooks
        XCTAssertFalse(profile.isConfigured(in: installed, bridgePath: "/bin/di-bridge"))
        hooks.removeValue(forKey: "ToolUse")
        hooks["Stop"] = stopGroups + stopGroups
        installed["hooks"] = hooks
        XCTAssertFalse(profile.isConfigured(in: installed, bridgePath: "/bin/di-bridge"))
        let repaired = try profile.merging(into: installed, bridgePath: "/bin/di-bridge")
        XCTAssertTrue(profile.isConfigured(in: repaired, bridgePath: "/bin/di-bridge"))
    }

    private func generatedCommand(in hooks: [String: Any], event: String) throws -> [String: Any] {
        let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
        let commands = try XCTUnwrap(groups.last?["hooks"] as? [[String: Any]])
        return try XCTUnwrap(commands.last)
    }
}
