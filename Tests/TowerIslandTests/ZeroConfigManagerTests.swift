import XCTest
@testable import XIsland

final class ZeroConfigManagerTests: XCTestCase {
    func testSanitizeCursorHooksRemovesLegacyClaudeAndOldBridgeEntries() throws {
        let config: [String: Any] = [
            "dynamic_island": "/Users/test/.dynamic-island/bin/di-bridge --agent cursor",
            "hooks": [
                "beforeSubmitPrompt": [
                    ["command": "python3 ~/.claude/hooks/codeisland-state.py --agent cursor --hook UserPromptSubmit"],
                    ["command": "/Users/test/.tower-island/bin/di-bridge --agent cursor --hook session_start"]
                ],
                "preToolUse": [
                    ["command": "/Users/test/.dynamic-island/bin/di-bridge --agent cursor --hook PreToolUse"],
                    ["command": "python3 ~/.claude/hooks/codeisland-state.py --agent cursor --hook PreToolUse"]
                ]
            ],
            "version": 1
        ]

        let sanitized = ZeroConfigManager.sanitizeCursorConfig(
            config,
            bridgePath: "/Users/test/.tower-island/bin/di-bridge"
        )
        let hooks = try XCTUnwrap(sanitized["hooks"] as? [String: Any])
        let beforeSubmit = try XCTUnwrap(hooks["beforeSubmitPrompt"] as? [[String: Any]])
        let preToolUse = try XCTUnwrap(hooks["preToolUse"] as? [[String: Any]])

        XCTAssertFalse(
            beforeSubmit.contains { ($0["command"] as? String)?.contains("codeisland-state.py") == true }
        )
        XCTAssertEqual(
            beforeSubmit.filter { ($0["command"] as? String)?.contains("di-bridge") == true }.count,
            1
        )
        XCTAssertTrue(preToolUse.isEmpty)
        XCTAssertNil(sanitized["dynamic_island"])
    }

    func testSanitizeTraeIDEClaudeHooksAddsBridgeCommands() throws {
        let hooks: [String: Any] = [
            "PreToolUse": [
                [
                    "matcher": "*",
                    "hooks": [
                        [
                            "type": "command",
                            "command": "/Users/test/.old/di-bridge --agent cursor --hook PreToolUse"
                        ]
                    ]
                ]
            ]
        ]

        let sanitized = ZeroConfigManager.sanitizeClaudeCodeHooksForIDE(
            hooks,
            bridgePath: "/Users/test/.tower-island/bin/di-bridge",
            agent: "trae"
        )

        let preToolUse = try XCTUnwrap(sanitized["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 1)

        let first = try XCTUnwrap(preToolUse.first)
        XCTAssertEqual(first["matcher"] as? String, "*")
        let hookCommands = try XCTUnwrap(first["hooks"] as? [[String: Any]])
        let command = try XCTUnwrap(hookCommands.first?["command"] as? String)
        XCTAssertEqual(command, "/Users/test/.tower-island/bin/di-bridge --agent trae --hook PreToolUse || true")

        XCTAssertNotNil(sanitized["PermissionRequest"])
        XCTAssertNotNil(sanitized["SessionStart"])
        XCTAssertNotNil(sanitized["Stop"])
    }

    func testSanitizeTraeCursorFamilyHooksUseTraeAgent() throws {
        let sanitized = ZeroConfigManager.sanitizeCursorConfig(
            [:],
            bridgePath: "/Users/test/.tower-island/bin/di-bridge",
            agent: "trae"
        )

        let hooks = try XCTUnwrap(sanitized["hooks"] as? [String: Any])
        let beforeSubmit = try XCTUnwrap(hooks["beforeSubmitPrompt"] as? [[String: Any]])
        let command = try XCTUnwrap(beforeSubmit.first?["command"] as? String)

        XCTAssertEqual(command, "/Users/test/.tower-island/bin/di-bridge --agent trae --hook session_start")
        XCTAssertFalse(command.contains("--agent cursor"))
    }

    // MARK: - hook 命令生成

    /// 审批必须靠退出码回传用户的选择，一旦被 || true 吞掉，工具会当成"已放行"
    func testBridgeHookCommandKeepsExitCodeForPermissionRequest() {
        XCTAssertEqual(
            ZeroConfigManager.bridgeHookCommand(
                bridgePath: "/bin/di-bridge", agent: .qwen, hookArg: "PermissionRequest"
            ),
            "/bin/di-bridge --agent qwen --hook PermissionRequest"
        )
    }

    /// 其余事件只上报状态，桥接不可用时不该阻塞工具运行
    func testBridgeHookCommandSwallowsFailureForReportingHooks() {
        XCTAssertEqual(
            ZeroConfigManager.bridgeHookCommand(
                bridgePath: "/bin/di-bridge", agent: .droid, hookArg: "session_start"
            ),
            "/bin/di-bridge --agent droid --hook session_start || true"
        )
    }
}
