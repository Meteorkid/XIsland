import XCTest
import SwiftUI
import AppKit
@testable import XIsland

/// 审批上下文地图的隔离渲染快照，默认跳过；
/// 需要视觉核对时设置 `X_ISLAND_RENDER_APPROVAL_MAP_DIR` 后单独运行。
@MainActor
final class ApprovalContextMapRenderTests: XCTestCase {
    func testRenderApprovalContextMapStates() throws {
        guard let directory = ProcessInfo.processInfo.environment["X_ISLAND_RENDER_APPROVAL_MAP_DIR"] else {
            throw XCTSkip("Enable explicitly for isolated approval map snapshots")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let session = AgentSession(id: "render-map", agentType: .claudeCode, prompt: "为审批面板加入上下文地图")
        session.appendEvent(ToolEvent(tool: "Write", input: #"{"file_path":"/tmp/xisland/NewView.swift"}"#, isComplete: true))
        session.appendEvent(ToolEvent(tool: "Edit", input: #"{"file_path":"/tmp/xisland/SessionManager.swift"}"#, isComplete: true))
        session.appendEvent(ToolEvent(tool: "Delete", input: #"{"file_path":"/tmp/xisland/OldView.swift"}"#, isComplete: true))
        session.agentResponse = "# 实现计划\n## 数据模型\n## 视图接入\n### 测试"
        session.pendingPermission = PendingPermission(
            requestingAgent: .claudeCode,
            tool: "Bash",
            description: "swift test --filter ApprovalContextMap",
            diff: "+ let map = ApprovalContextMapBuilder.build(session: session)",
            filePath: "/tmp/xisland/Tests/ApprovalContextMapTests.swift",
            respond: { _ in }
        )

        let theme = ThemeManager()
        let manager = SessionManager()
        let historyStore = ApprovalContextMapSnapshotStore(
            url: output.appendingPathComponent("approval-map-history.json")
        )
        let previousMap = ApprovalContextMap(
            task: .init(title: "上一轮任务"),
            plan: [.init(title: "数据模型", depth: 1), .init(title: "旧流程", depth: 2)],
            changes: [
                .init(path: "/tmp/xisland/SessionManager.swift", kind: .modified),
                .init(path: "/tmp/xisland/RemovedView.swift", kind: .created),
            ],
            pending: nil,
            reason: nil
        )
        historyStore.append(ApprovalContextMapSnapshot(map: previousMap), sessionID: session.id)
        for expanded in [false, true] {
            let content = ApprovalContextMapView(
                session: session,
                pendingKind: .permission,
                initiallyExpanded: expanded,
                snapshotStore: historyStore
            )
                .environment(manager)
                .environment(theme)
                .frame(width: 380)
                .padding(16)
                .background(Color.black)
            try render(content, to: output.appendingPathComponent(expanded ? "map-expanded.png" : "map-collapsed.png"))
        }

        // 差异明细展开态：刻意点开才显示逐条变化。
        let deltaContent = ApprovalContextMapView(
            session: session,
            pendingKind: .permission,
            initiallyExpanded: true,
            initiallyDeltaExpanded: true,
            snapshotStore: historyStore
        )
            .environment(manager)
            .environment(theme)
            .frame(width: 380)
            .padding(16)
            .background(Color.black)
        try render(deltaContent, to: output.appendingPathComponent("map-delta-expanded.png"))

        // 集成形态：审批卡片内的地图与批准/拒绝按钮共存。
        let card = PendingTaskCardView(session: session)
            .environment(manager)
            .environment(theme)
            .frame(width: 420)
            .padding(16)
            .background(Color.black)
        try render(card, to: output.appendingPathComponent("permission-card.png"))

        // 计划审阅卡片：地图待审批节点为计划类型。
        let planSession = AgentSession(id: "render-map-plan", agentType: .claudeCode, prompt: "审阅实现计划")
        planSession.appendEvent(ToolEvent(tool: "Write", input: #"{"file_path":"/tmp/xisland/PlanModel.swift"}"#, isComplete: true))
        planSession.appendEvent(ToolEvent(tool: "Edit", input: #"{"file_path":"/tmp/xisland/PlanView.swift"}"#, isComplete: true))
        planSession.agentResponse = "# 实现计划\n## 数据模型\n## 视图接入"
        planSession.pendingPlanReview = PendingPlanReview(
            requestingAgent: .claudeCode,
            markdown: "# 实现计划\n## 数据模型\n## 视图接入\n### 测试",
            respond: { _, _ in }
        )
        let planCard = PendingTaskCardView(session: planSession)
            .environment(manager)
            .environment(theme)
            .frame(width: 420)
            .padding(16)
            .background(Color.black)
        try render(planCard, to: output.appendingPathComponent("plan-card.png"))
    }

    private func render<V: View>(_ view: V, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 100)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 50)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
