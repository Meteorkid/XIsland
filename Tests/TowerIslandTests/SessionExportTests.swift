import XCTest
import UniformTypeIdentifiers
@testable import XIsland

@MainActor
final class SessionExportTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession(
        prompt: String = "Fix the bug in login flow",
        agentType: AgentType = .claudeCode,
        events: [ToolEvent] = [],
        chatHistory: [ChatMessage] = [],
        toolEventCount: Int = 0
    ) -> AgentSession {
        let session = AgentSession(
            id: "export-test-\(UUID().uuidString)",
            agentType: agentType,
            terminal: "ttys001",
            workingDirectory: "/Users/test/my-project",
            prompt: prompt
        )
        session.status = .completed
        session.completedAt = Date()
        session.tokenUsage.totalTokens = 5000
        session.tokenUsage.estimatedCostUSD = 0.12

        for i in 0..<toolEventCount {
            var event = ToolEvent(tool: "Bash", input: "run tests \(i)")
            event.result = "Test passed"
            event.linesAdded = 10
            event.linesRemoved = 3
            event.isComplete = true
            session.events.append(event)
        }

        for event in events {
            session.events.append(event)
        }

        for msg in chatHistory {
            session.chatHistory.append(msg)
        }

        return session
    }

    // MARK: - JSON Export

    func testJSONExportIsValidJSON() {
        let session = makeSession(toolEventCount: 2)
        let data = ExportView.exportJSON(session: session)

        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed, "JSON export should produce valid JSON")
        XCTAssertNotNil(parsed?["sessionId"])
        XCTAssertNotNil(parsed?["agentType"])
        XCTAssertNotNil(parsed?["prompt"])
        XCTAssertNotNil(parsed?["chatHistory"])
        XCTAssertNotNil(parsed?["toolEvents"])
    }

    func testJSONExportContainsChatHistory() {
        let msg1 = ChatMessage(timestamp: Date(), role: .user, content: "Fix the bug")
        let msg2 = ChatMessage(timestamp: Date(), role: .assistant, content: "I found the issue")
        let session = makeSession(chatHistory: [msg1, msg2])
        let data = ExportView.exportJSON(session: session)

        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let history = parsed?["chatHistory"] as? [[String: Any]]
        XCTAssertEqual(history?.count, 2, "JSON should contain 2 chat messages")
        XCTAssertEqual(history?.first?["role"] as? String, "user")
        XCTAssertEqual(history?.last?["role"] as? String, "assistant")
    }

    // MARK: - Markdown Export

    func testMarkdownExportContainsHeaders() {
        let session = makeSession(toolEventCount: 1)
        let data = ExportView.exportMarkdown(session: session)
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(text.contains("# Session:"), "Markdown should have session header")
        XCTAssertTrue(text.contains("## Tool Events"), "Markdown should have tool events section")
    }

    // MARK: - CSV Export

    func testCSVExportHasHeaderRow() {
        let session = makeSession()
        let data = ExportView.exportCSV(session: session)
        let text = String(data: data, encoding: .utf8) ?? ""
        let firstLine = text.components(separatedBy: "\n").first ?? ""

        XCTAssertEqual(firstLine, "timestamp,tool,input,result_summary,lines_added,lines_removed,test_passed,test_failed")
    }

    func testCSVExportToolEvents() {
        let session = makeSession(toolEventCount: 3)
        let data = ExportView.exportCSV(session: session)
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        // 1 header + 3 data rows
        XCTAssertEqual(lines.count, 4, "CSV should have 1 header + 3 data rows")
    }

    // MARK: - Empty session

    func testExportEmptySession() {
        let session = makeSession()

        let jsonData = ExportView.exportJSON(session: session)
        XCTAssertFalse(jsonData.isEmpty, "JSON export of empty session should not be empty")

        let mdData = ExportView.exportMarkdown(session: session)
        XCTAssertFalse(mdData.isEmpty, "Markdown export of empty session should not be empty")

        let csvData = ExportView.exportCSV(session: session)
        let csvText = String(data: csvData, encoding: .utf8) ?? ""
        XCTAssertTrue(csvText.contains("timestamp"), "CSV of empty session should at least have header")
    }
}
