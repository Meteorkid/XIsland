import XCTest
import SwiftUI
import AppKit
@testable import XIsland

@MainActor
final class CustomQuestionRenderTests: XCTestCase {
    func testRenderCustomQuestionPanels() throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_RENDER_CUSTOM_QUESTION"] == "1" else {
            throw XCTSkip("Enable explicitly for isolated UI snapshots")
        }
        let manager = SessionManager(), theme = ThemeManager()
        let session = AgentSession(id: "render-fixture", agentType: .openCode)
        session.pendingQuestion = PendingQuestion(requestingAgent: .openCode, text: "请输入项目目录，或选择建议路径。",
            options: ["当前项目", "新建目录"], respond: { _ in }, cancel: nil, allowsCustomAnswer: true)
        session.pendingQuestion?.state.draftAnswer = "/tmp/我的项目"
        let output = URL(fileURLWithPath: "/tmp/xisland-custom-question-render")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try render(QuestionAnswerView(session: session, onComplete: {}).environment(manager).environment(theme),
                   to: output.appendingPathComponent("panel.png"))
        try render(PendingTaskCardView(session: session).environment(manager).environment(theme),
                   to: output.appendingPathComponent("card.png"))
        session.pendingQuestion?.allowsMultipleAnswers = true
        session.pendingQuestion?.state.selectedAnswers = ["当前项目", "新建目录"]
        try render(QuestionAnswerView(session: session, onComplete: {}).environment(manager).environment(theme),
                   to: output.appendingPathComponent("multiple-panel.png"))
        try render(PendingTaskCardView(session: session).environment(manager).environment(theme),
                   to: output.appendingPathComponent("multiple-card.png"))
    }

    private func render<V: View>(_ view: V, to url: URL) throws {
        let content = view.frame(width: 420).padding(16).background(Color.black)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 100)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 50)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
