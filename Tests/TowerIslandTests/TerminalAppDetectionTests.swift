import XCTest
@testable import XIsland

final class TerminalAppDetectionTests: XCTestCase {
    func testDetectsTraeCnFromNameAndBundleId() {
        XCTAssertEqual(TerminalApp.detect(from: "Trae CN"), .traeCn)
        XCTAssertEqual(TerminalApp.detect(from: "cn.trae.app"), .traeCn)
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
    }

    func testCursorAgentPrefersCursorAppOverGenericTerminalHint() {
        let session = AgentSession(
            id: "cursor-1",
            agentType: .cursor,
            terminal: "Terminal",
            workingDirectory: "/tmp/project"
        )

        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(for: session), .cursor)
    }

    func testCursorAgentIgnoresTraeHintAndStillUsesCursor() {
        let session = AgentSession(
            id: "cursor-2",
            agentType: .cursor,
            terminal: "Trae CN",
            workingDirectory: "/tmp/project"
        )

        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(for: session), .cursor)
    }

    func testCursorAgentKeepsWindsurfHint() {
        let session = AgentSession(
            id: "cursor-3",
            agentType: .cursor,
            terminal: "Windsurf",
            workingDirectory: "/tmp/project"
        )

        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(for: session), .windsurf)
    }

    func testCursorCliInITermPrefersITermJumpTarget() {
        let session = AgentSession(
            id: "cursor-4",
            agentType: .cursor,
            terminal: "iTerm2",
            workingDirectory: "/tmp/project"
        )

        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(for: session), .iterm2)
    }

    func testCursorCliInAppleTerminalWithSessionIdPrefersTerminalJumpTarget() {
        let session = AgentSession(
            id: "cursor-5",
            agentType: .cursor,
            terminal: "Terminal",
            workingDirectory: "/tmp/project"
        )
        session.termSessionId = "tty:/dev/ttys001"

        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(for: session), .terminal)
    }

    func testOpenCodeAgentFallsBackToTerminalWhenHintIsGeneric() {
        let session = AgentSession(
            id: "opencode-1",
            agentType: .openCode,
            terminal: "Terminal",
            workingDirectory: "/tmp/project"
        )

        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(for: session), .terminal)
    }

    func testClaudeCodeAgentFallsBackToTerminalWhenHintIsGeneric() {
        let session = AgentSession(
            id: "claude-1",
            agentType: .claudeCode,
            terminal: "Terminal",
            workingDirectory: "/tmp/project"
        )

        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(for: session), .terminal)
    }

    func testCodexAgentFallsBackToCodexWhenTerminalHintIsGeneric() {
        let session = AgentSession(
            id: "codex-1",
            agentType: .codex,
            terminal: "Terminal",
            workingDirectory: "/tmp/project"
        )

        XCTAssertEqual(TerminalJumpManager.resolveTargetApp(for: session), .codex)
    }

    func testDoesNotMisdetectOpenCodeAsVSCode() {
        XCTAssertNil(TerminalApp.detect(from: "OpenCode"))
    }
}
