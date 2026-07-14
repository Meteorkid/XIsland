import XCTest
@testable import XIsland

final class TerminalAppDetectionTests: XCTestCase {
    func testDetectsTraeCnFromNameAndBundleId() {
        XCTAssertEqual(TerminalApp.detect(from: "Trae CN"), .traeCn)
        XCTAssertEqual(TerminalApp.detect(from: "cn.trae.app"), .traeCn)
    }

    func testDetectsTraeWorkCnFromNameAndBundleId() {
        XCTAssertEqual(TerminalApp.detect(from: "TRAE SOLO CN"), .traeWorkCn)
        XCTAssertEqual(TerminalApp.detect(from: "Trae Work CN"), .traeWorkCn)
        XCTAssertEqual(TerminalApp.detect(from: "cn.trae.solo.app"), .traeWorkCn)
    }

    func testDetectsTraeFromNameAndBundleId() {
        XCTAssertEqual(TerminalApp.detect(from: "trae"), .trae)
        XCTAssertEqual(TerminalApp.detect(from: "com.trae.app"), .trae)
    }

    func testAgentTypeMapsCursorFamilyBundleIds() {
        XCTAssertEqual(AgentType.fromBundleId("com.todesktop.230313mzl4w4u92"), .cursor)
        XCTAssertEqual(AgentType.fromBundleId("com.codeium.windsurf"), .cursor)
        XCTAssertEqual(AgentType.fromBundleId("com.trae.app"), .trae)
        XCTAssertEqual(AgentType.fromBundleId("cn.trae.app"), .trae)
        XCTAssertEqual(AgentType.fromBundleId("cn.trae.solo.app"), .trae)
    }

    func testCursorAgentPrefersCursorAppOverGenericTerminalHint() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "cursor-1",
            agentType: .cursor,
            terminal: "Terminal",
            workingDirectory: "/tmp/project",
            termSessionId: nil,
            windowNumber: nil
        )
        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(snap: snap), .cursor)
    }

    func testCursorAgentIgnoresTraeHintAndStillUsesCursor() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "cursor-2",
            agentType: .cursor,
            terminal: "Trae CN",
            workingDirectory: "/tmp/project",
            termSessionId: nil,
            windowNumber: nil
        )
        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(snap: snap), .cursor)
    }

    func testTraeAgentKeepsWorkCnHint() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "trae-work-1",
            agentType: .trae,
            terminal: "TRAE SOLO CN",
            workingDirectory: "/tmp/project",
            termSessionId: nil,
            windowNumber: nil
        )
        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(snap: snap), .traeWorkCn)
    }

    func testCursorAgentKeepsWindsurfHint() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "cursor-3",
            agentType: .cursor,
            terminal: "Windsurf",
            workingDirectory: "/tmp/project",
            termSessionId: nil,
            windowNumber: nil
        )
        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(snap: snap), .windsurf)
    }

    func testCursorCliInITermPrefersITermJumpTarget() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "cursor-4",
            agentType: .cursor,
            terminal: "iTerm2",
            workingDirectory: "/tmp/project",
            termSessionId: nil,
            windowNumber: nil
        )
        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(snap: snap), .iterm2)
    }

    func testCursorCliInAppleTerminalWithSessionIdPrefersTerminalJumpTarget() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "cursor-5",
            agentType: .cursor,
            terminal: "Terminal",
            workingDirectory: "/tmp/project",
            termSessionId: "tty:/dev/ttys001",
            windowNumber: nil
        )
        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(snap: snap), .terminal)
    }

    func testOpenCodeAgentFallsBackToTerminalWhenHintIsGeneric() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "opencode-1",
            agentType: .openCode,
            terminal: "Terminal",
            workingDirectory: "/tmp/project",
            termSessionId: nil,
            windowNumber: nil
        )
        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(snap: snap), .terminal)
    }

    func testClaudeCodeAgentFallsBackToTerminalWhenHintIsGeneric() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "claude-1",
            agentType: .claudeCode,
            terminal: "Terminal",
            workingDirectory: "/tmp/project",
            termSessionId: nil,
            windowNumber: nil
        )
        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(snap: snap), .terminal)
    }

    func testCodexAgentFallsBackToCodexWhenTerminalHintIsGeneric() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "codex-1",
            agentType: .codex,
            terminal: "Terminal",
            workingDirectory: "/tmp/project",
            termSessionId: nil,
            windowNumber: nil
        )
        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(snap: snap), .codex)
    }

    func testDoesNotMisdetectOpenCodeAsVSCode() {
        XCTAssertNil(TerminalApp.detect(from: "OpenCode"))
    }
}
