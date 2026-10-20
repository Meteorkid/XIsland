import XCTest
import Foundation
import SwiftUI
import AppKit
import DIShared
@testable import XIsland
@testable import DIBridge

@MainActor
final class SecurityApprovalBoundaryTests: XCTestCase {
    private let command = "printf audit-fixture"
    private let explanation = "Read directory names"

    func testPermissionPreservesEveryInputAliasThroughPendingState() throws {
        let input: [String: Any] = ["command": command, "description": explanation, "extra": ["value": "<script>literal</script>"]]
        for alias in ["tool_input", "input", "parameters", "params", "args", "tool.input"] {
            for encoded in [false, true] {
                let value: Any = encoded ? String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self) : input
                var native: [String: Any] = ["tool_name": "Bash"]
                if alias == "tool.input" { native["tool"] = ["input": value] } else { native[alias] = value }
                let message = DIBridge.buildPermissionRequest(sessionId: "audit-permission", data: native)
                XCTAssertEqual(message.permDescription, command, alias)
                let manager = SessionManager()
                manager.handlePermissionRequest(message, respond: { _ in })
                let permission = try XCTUnwrap(manager.sessions.first?.pendingPermission)
                XCTAssertEqual(permission.operationText, command, alias)
                let bytes = try XCTUnwrap(permission.toolInput?.data(using: .utf8))
                XCTAssertEqual(try JSONSerialization.jsonObject(with: bytes) as? NSDictionary, input as NSDictionary, alias)
            }
        }
    }

    func testPlainTextCannotBeReplacedByALaterFriendlyAlias() throws {
        for alias in ["tool_input", "input", "parameters", "params", "args"] {
            var native: [String: Any] = ["tool_name": "Bash", "description": explanation, alias: command]
            if alias == "tool_input" { native["input"] = ["description": explanation] }
            let message = DIBridge.buildPermissionRequest(sessionId: "plain", data: native)
            XCTAssertEqual(message.permDescription, command)
            XCTAssertEqual(message.toolInput, command)
        }
    }

    func testTopLevelCommandSurvivesNestedDescription() throws {
        let inputs: [Any] = [["description": explanation], explanation, [explanation], "[\"Read directory names\"]"]
        for input in inputs {
            let message = DIBridge.buildPermissionRequest(sessionId: "top", data: [
                "tool_name": "Bash", "command": command, "tool_input": input
            ])
            let manager = SessionManager()
            manager.handlePermissionRequest(message, respond: { _ in })
            XCTAssertEqual(message.permDescription, command)
            XCTAssertEqual(manager.sessions.first?.pendingPermission?.operationText, command)
            XCTAssertTrue(message.toolInput?.contains(explanation) == true)
        }
    }

    func testUnknownToolRetainsAllArgumentsAndLegacyPermissionsStillRender() throws {
        let input: [String: Any] = ["description": explanation, "destination": "/tmp/audit", "remove": true]
        let message = DIBridge.buildPermissionRequest(sessionId: "unknown", data: ["tool_name": "Custom", "tool_input": input])
        let manager = SessionManager()
        manager.handlePermissionRequest(message, respond: { _ in })
        let permission = try XCTUnwrap(manager.sessions.first?.pendingPermission)
        XCTAssertTrue(permission.operationText.contains("destination"))
        XCTAssertTrue(permission.operationText.contains("remove"))
        let legacy = PendingPermission(requestingAgent: .claudeCode, tool: "Read", description: "/tmp/file", diff: nil, filePath: nil, respond: { _ in })
        XCTAssertEqual(legacy.operationText, "/tmp/file")
    }

    func testPermissionCommandWithoutDescriptionIsPreserved() {
        let message = DIBridge.buildPermissionRequest(sessionId: "audit-control", data: [
            "tool_name": "Bash", "tool_input": ["command": command]
        ])
        XCTAssertEqual(message.permDescription, command)
    }

    func testNewQuestionCannotReuseAnswerFromAnotherToolCall() {
        assertNewQuestionRequiresAnswer(firstID: "tool-one", secondID: "tool-two", secondText: "Continue? Also authorize changing the backup policy?")
    }

    func testIdenticalQuestionWithoutIdentityStillRequiresANewAnswer() {
        assertNewQuestionRequiresAnswer(firstID: nil, secondID: nil, secondText: "Continue?")
    }

    func testRepeatedToolIdentityDoesNotAutomaticallyGrantANewAnswer() {
        assertNewQuestionRequiresAnswer(firstID: "same-tool", secondID: "same-tool", secondText: "Continue?")
    }

    func testRenderApprovalCommandAndFullInput() throws {
        guard let directory = ProcessInfo.processInfo.environment["X_ISLAND_RENDER_APPROVAL_DIR"] else {
            throw XCTSkip("Enable explicitly for isolated approval snapshots")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manager = SessionManager(), theme = ThemeManager()
        let message = DIBridge.buildPermissionRequest(sessionId: "render-permission", data: [
            "tool_name": "Bash", "tool_input": ["description": "检查项目目录", "command": command, "cwd": "/tmp/审批测试", "timeout": 3000]
        ])
        manager.handlePermissionRequest(message, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)
        for expanded in [false, true] {
            session.pendingPermission?.state.isExpanded = expanded
            let content = PendingTaskCardView(session: session).environment(manager).environment(theme)
                .frame(width: 420).padding(16).background(Color.black)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 100)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 50)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(expanded ? "details.png" : "summary.png"))
        }
    }

    private func assertNewQuestionRequiresAnswer(firstID: String?, secondID: String?, secondText: String) {
        let manager = SessionManager()
        let replies = AuditReplies()
        var first = DIMessage(type: .question, sessionId: "audit-question")
        first.agentType = "claude_code"
        first.toolCallId = firstID
        first.questionText = "Continue?"
        first.options = ["Yes", "No"]
        manager.handleQuestionRequest(first, respond: { replies.append($0) })
        let session = manager.sessions[0]
        manager.answerQuestion(session: session, answer: "Yes")
        XCTAssertEqual(replies.values, ["Yes"])
        var second = first
        second.toolCallId = secondID
        second.questionText = secondText
        manager.handleQuestionRequest(second, respond: { replies.append($0) })
        XCTAssertEqual(replies.values, ["Yes"])
        XCTAssertEqual(session.pendingQuestion?.text, secondText)
        manager.answerQuestion(session: session, answer: "No")
        XCTAssertEqual(replies.values, ["Yes", "No"])
        XCTAssertNil(session.pendingQuestion)
    }
}

private final class AuditReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
