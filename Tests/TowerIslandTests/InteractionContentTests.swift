import XCTest
@testable import XIsland

@MainActor
final class InteractionContentTests: XCTestCase {
    func testRegularListKeepsOrderAndExcludesEveryKindOfPendingInteraction() {
        let regular = AgentSession(id: "regular", agentType: .codex)
        let permission = AgentSession(id: "permission", agentType: .codex)
        permission.pendingPermission = PendingPermission(
            requestingAgent: .codex, tool: "Bash", description: "command", diff: nil, filePath: nil,
            respond: { _ in }
        )
        let question = AgentSession(id: "question", agentType: .codex)
        question.pendingQuestion = PendingQuestion(
            requestingAgent: .codex, text: "Continue?", options: ["Yes"], respond: { _ in }, cancel: nil
        )
        let plan = AgentSession(id: "plan", agentType: .codex)
        plan.pendingPlanReview = PendingPlanReview(requestingAgent: .codex, markdown: "Plan", respond: { _, _ in })
        let last = AgentSession(id: "last", agentType: .claudeCode)

        XCTAssertEqual(
            SessionListView.regularSessions(in: [regular, permission, question, plan, last]).map(\.id),
            ["regular", "last"]
        )
    }

    func testLongPlanKeepsLastLineAndRepeatedBlocks() {
        let lines = (0..<500).map { "第 \($0) 行 / line \($0)" }
        let view = MarkdownView(markdown: lines.joined(separator: "\n"))
        XCTAssertEqual(view.elements.count, 500)
        XCTAssertEqual(view.elements.last, .paragraph("第 499 行 / line 499"))

        let repeated = MarkdownView(markdown: "# 标题\n---\n# 标题\n---\n```\nsame\n```\n```\nsame\n```")
        XCTAssertEqual(repeated.elements, [
            .heading(level: 1, text: "标题"), .divider,
            .heading(level: 1, text: "标题"), .divider,
            .code("same"), .code("same"),
        ])
    }
}
