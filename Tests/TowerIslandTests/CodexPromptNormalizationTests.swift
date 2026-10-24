import XCTest
import SwiftData
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class CodexPromptNormalizationTests: XCTestCase {
    private func reply(_ answers: [String]) throws -> String {
        let items = answers.map { ["questionItemId": "internal-id", "question": "内部问题", "answer": $0] }
        let json = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        return "<send_user_message_question_reply>\n\(String(decoding: json, as: UTF8.self))\n</send_user_message_question_reply>"
    }

    private func hook(_ prompt: String, agent: String = "codex") throws -> DIMessage {
        try DIBridge.makeMessage(agentType: agent, hookType: "UserPromptSubmit", sessionId: "codex-title-test",
            stdinData: ["hook_event_name": "UserPromptSubmit", "session_id": "title-test", "prompt": prompt])
    }

    private func rawMessage(_ prompt: String) -> DIMessage {
        var message = DIMessage(type: .sessionStart, sessionId: "codex-title-test")
        message.agentType = "codex"
        message.nativeEvent = "UserPromptSubmit"
        message.prompt = prompt
        message.workingDir = "/tmp/title-project"
        return message
    }

    func testBridgeExtractsAnswersWithoutInternalMetadata() throws {
        let raw = try reply(["  设置已打开，可以继续  ", "先检查图例\n再检查任务"])
        XCTAssertEqual(try hook(raw).prompt, "设置已打开，可以继续\n先检查图例\n再检查任务")
    }

    func testBridgeNormalizesReplyAfterExistingSystemPrefixExtraction() throws {
        XCTAssertEqual(try hook("System: context\n\nUser: " + reply(["继续检查"])).prompt, "继续检查")
    }

    func testValidReplyRetainsFollowingUserText() throws {
        XCTAssertEqual(try hook(reply(["同意"]) + "\n接着检查窗口").prompt, "同意\n接着检查窗口")
    }

    func testMalformedAndEmptyRepliesDoNotExposeEnvelopeOrJSON() throws {
        for raw in [
            "<send_user_message_question_reply>",
            "<send_user_message_question_reply>[]</send_user_message_question_reply>",
            "<send_user_message_question_reply>{\"answer\":\"not-an-array\"}</send_user_message_question_reply>",
            "<send_user_message_question_reply>[{\"answer\":false}]</send_user_message_question_reply>",
            "<send_user_message_question_reply>[{\"question\":\"metadata-only\"}]</send_user_message_question_reply>",
            "<send_user_message_question_reply>not-json</send_user_message_question_reply>",
            try reply([" \n "])
        ] {
            XCTAssertEqual(try hook(raw).prompt, "", raw)
        }
    }

    func testOrdinaryTextXMLCodeAndSimilarTagsArePreserved() throws {
        for raw in ["继续修复标题", "<request>显示这个标签</request>",
                    "解释 <send_user_message_question_reply> 的用途",
                    "```xml\n<send_user_message_question_reply>\n```",
                    "<send_user_message_question_reply_example>示例</send_user_message_question_reply_example>"] {
            XCTAssertEqual(try hook(raw).prompt, raw)
        }
    }

    func testOtherAgentsDoNotInterpretCodexReplyEnvelope() throws {
        let raw = try reply(["保留原文"])
        XCTAssertEqual(DIBridge.buildSessionStart(sessionId: "claude-test", agentType: "claude_code",
                                                data: ["prompt": raw]).prompt, raw)
        let session = AgentSession(id: "claude-test", agentType: .claudeCode, prompt: raw)
        XCTAssertEqual(session.displayTitle, "<send_user_message_question_reply>")
    }

    func testNestedRepliesNormalizeConsistentlyAcrossBridgeAndApp() throws {
        let nested = try reply([reply(["保留可读答案"])])
        let message = try hook(nested)
        XCTAssertEqual(message.prompt, "保留可读答案")
        let manager = SessionManager()
        manager.handleMessage(message)
        XCTAssertEqual(manager.sessions.first?.prompt, "保留可读答案")
        XCTAssertEqual(try hook(reply(["<send_user_message_question_reply>"])).prompt, "")
    }

    func testNormalizationIsBoundedAndIdempotent() throws {
        var nested = "有效答案"
        for _ in 0..<8 { nested = try reply([nested]) }
        XCTAssertEqual(CodexPromptText.normalized(nested), "有效答案")
        XCTAssertEqual(CodexPromptText.normalized(try reply([nested])), "")
        for raw in [nested, try reply(["<send_user_message_question_reply>"]),
                    try reply(["```xml\n<send_user_message_question_reply>\n```"]),
                    try reply(["包含 </send_user_message_question_reply> 的普通答案"])] {
            let normalized = CodexPromptText.normalized(raw)
            XCTAssertEqual(CodexPromptText.normalized(normalized), normalized)
        }
    }

    func testParsedLegacyTitleKeepsExistingLengthLimit() throws {
        let session = AgentSession(id: "legacy-long", agentType: .codex, prompt: try reply([String(repeating: "字", count: 50)]))
        XCTAssertEqual(session.displayTitle, String(repeating: "字", count: 38) + "...")
        XCTAssertEqual(StoredSession(from: session).displayTitle, session.displayTitle)
    }

    func testAppIngressNormalizesOlderBridgeMessagesBeforeSaving() throws {
        let manager = SessionManager()
        manager.handleMessage(rawMessage(try reply(["打开设置后继续检查"])))
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.prompt, "打开设置后继续检查")
        XCTAssertEqual(session.displayTitle, "打开设置后继续检查")
        XCTAssertEqual(session.chatHistory.last?.content, "打开设置后继续检查")
        XCTAssertEqual(SessionSaveSnapshot(session: session).prompt, "打开设置后继续检查")
    }

    func testInvalidReplyKeepsPreviousTitleAndAddsNoMetadataChatEntry() throws {
        let manager = SessionManager()
        manager.handleMessage(rawMessage("修复标题解析"))
        manager.handleMessage(rawMessage("<send_user_message_question_reply>broken"))
        XCTAssertEqual(manager.sessions.first?.prompt, "修复标题解析")
        XCTAssertEqual(manager.sessions.first?.chatHistory.count, 1)
    }

    func testFirstInvalidReplyUsesWorkspaceFallback() throws {
        let manager = SessionManager()
        manager.handleMessage(rawMessage("<send_user_message_question_reply>broken"))
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.prompt, "")
        XCTAssertEqual(session.displayTitle, "title-project")
        XCTAssertFalse(session.hasPromptTitle)
    }

    func testLegacyHistoryTitlesAreReadableWithoutRewritingStoredContent() throws {
        let raw = try reply(["设置已打开，可以继续"])
        let session = AgentSession(id: "legacy-codex", agentType: .codex, workingDirectory: "/tmp/project", prompt: raw)
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let persistence = SessionPersistenceManager()
        persistence.modelContainer = container
        persistence.save(session: session)
        let stored = try XCTUnwrap(persistence.fetchHistory().first)
        XCTAssertEqual(stored.prompt, raw)
        XCTAssertEqual(stored.displayTitle, "设置已打开，可以继续")
        XCTAssertEqual(HistorySessionRow(stored).displayTitle, "设置已打开，可以继续")
        let restored = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.prompt, raw)
        XCTAssertEqual(restored.displayTitle, "设置已打开，可以继续")
        XCTAssertTrue(restored.hasPromptTitle)
    }

    func testLegacyMalformedTitleFallsBackWithoutShowingInternalTag() {
        let session = AgentSession(id: "legacy-codex", agentType: .codex,
            workingDirectory: "/tmp/project", prompt: "<send_user_message_question_reply>broken")
        XCTAssertEqual(session.displayTitle, "project")
        XCTAssertFalse(session.hasPromptTitle)
        XCTAssertEqual(StoredSession(from: session).displayTitle, "project")
    }
}
