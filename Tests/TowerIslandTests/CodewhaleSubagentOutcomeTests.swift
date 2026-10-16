import DIShared
import AppKit
import SwiftUI
import XCTest
@testable import DIBridge
@testable import XIsland

@MainActor
final class CodewhaleSubagentOutcomeTests: XCTestCase {
    private func event(_ name: String, child: String = "worker", status: String? = nil) throws -> DIMessage {
        var payload: [String: Any] = ["event": name, "agent_id": child]
        if name == "subagent_spawn" {
            payload["prompt_preview"] = "Inspect /tmp/fixture"
            payload["prompt_truncated"] = false
        } else if name == "subagent_complete" {
            payload["result_preview"] = "Exact native result"
            payload["result_truncated"] = true
            payload["status"] = status
        }
        return try DeepSeekHookAdapter.normalize(hookType: name,
            stdinData: name == "session_start" ? nil : payload,
            environment: ["CODEWHALE_SESSION_ID": "subagent-result"])
    }

    func testNativeOutcomesKeepResultAndParentActivityWithoutSuccessForCancellationOrUnknown() throws {
        let symbols = ["completed": "checkmark", "failed": "xmark.circle", "cancelled": "minus.circle",
                       "interrupted": "minus.circle", "unknown": "questionmark.circle", "future-status": "questionmark.circle"]
        for (status, symbol) in symbols {
            let manager = SessionManager()
            manager.handleMessage(try event("session_start"))
            manager.handleMessage(try event("subagent_spawn"))
            manager.handleMessage(try event("subagent_spawn", child: "other"))
            let parent = try XCTUnwrap(manager.sessions.first)
            let eventID = parent.events[0].id
            manager.handleMessage(try event("subagent_complete", status: status))
            let finished = parent.events[0]
            XCTAssertEqual(finished.id, eventID, status)
            XCTAssertEqual(finished.result, "Exact native result\n[Codewhale preview truncated]", status)
            XCTAssertEqual(finished.nativeCompletionStatus, status)
            XCTAssertTrue(finished.summary.contains(status), status)
            XCTAssertTrue(finished.isComplete, status)
            XCTAssertFalse(finished.isRunning, status)
            XCTAssertEqual(AgentActivityView(event: finished).completionSymbol, symbol, status)
            XCTAssertTrue(parent.events[1].isRunning, status)
            XCTAssertEqual(parent.subagentIds, ["deepseek-subagent-result-subagent-other"], status)
            XCTAssertEqual(parent.status, .active, status)
            XCTAssertNil(parent.completedAt, status)

            // 同一终态重放不能覆盖已记录的结果或替别的子代理结束。
            manager.handleMessage(try event("subagent_complete", status: "completed"))
            XCTAssertEqual(parent.events[0].result, finished.result, status)
            XCTAssertEqual(AgentActivityView(event: parent.events[0]).completionSymbol, symbol, status)
        }
    }

    func testOutcomePersistsBeforeParentStopsAndSurvivesDiskReopenAndExports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-codewhale-outcome-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("history.store")
        var eventID: UUID?
        try autoreleasepool {
            let persistence = SessionPersistenceManager()
            XCTAssertTrue(persistence.setupContainer(storeURL: store))
            let manager = SessionManager()
            manager.persistenceManager = persistence
            manager.handleMessage(try event("session_start"))
            manager.handleMessage(try event("subagent_spawn"))
            manager.handleMessage(try event("subagent_complete", status: "failed"))
            let saved = try XCTUnwrap(persistence.restoreSession(sessionId: "deepseek-subagent-result"))
            XCTAssertEqual(saved.status, .active)
            eventID = try XCTUnwrap(saved.events.first?.id)
        }

        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(storeURL: store))
        let restored = try XCTUnwrap(persistence.restoreSession(sessionId: "deepseek-subagent-result"))
        let finished = try XCTUnwrap(restored.events.first)
        XCTAssertEqual(finished.id, eventID)
        XCTAssertEqual(finished.result, "Exact native result\n[Codewhale preview truncated]")
        XCTAssertEqual(finished.nativeCompletionStatus, "failed")
        XCTAssertEqual(AgentActivityView(event: finished).completionSymbol, "xmark.circle")
        XCTAssertEqual(restored.status, .active)
        XCTAssertNil(restored.completedAt)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ExportView.exportJSON(session: restored)) as? [String: Any])
        let row = try XCTUnwrap((json["toolEvents"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["nativeCompletionStatus"] as? String, "failed")
        XCTAssertEqual(row["result"] as? String, finished.result)
        XCTAssertEqual(row["toolCallId"] as? String, "deepseek-subagent-result-subagent-worker")
        for data in [ExportView.exportMarkdown(session: restored), ExportView.exportCSV(session: restored)] {
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(text.contains("failed"))
            XCTAssertTrue(text.contains("Exact native result"))
        }
        restored.events[0].nativeCompletionStatus = "cancelled"
        XCTAssertTrue(persistence.save(session: restored))
        let updated = try XCTUnwrap(persistence.restoreSession(sessionId: restored.id))
        XCTAssertEqual(updated.events[0].id, eventID)
        XCTAssertEqual(updated.events[0].nativeCompletionStatus, "cancelled")
        XCTAssertEqual(AgentActivityView(event: updated.events[0]).completionSymbol, "minus.circle")
    }

    func testUnrelatedSubagentStatusDoesNotAcquireCodewhaleOutcomeSemantics() throws {
        let manager = SessionManager()
        let parent = AgentSession(id: "fixture-parent", agentType: .copilotCli)
        manager.sessions = [parent]
        var start = DIMessage(type: .subagentStart, sessionId: parent.id)
        start.agentType = parent.agentType.rawValue
        start.subagentId = "child"
        manager.handleMessage(start)
        var end = start
        end.type = .subagentEnd
        end.status = "failed"
        end.toolResult = "Not a verified Codewhale result"
        manager.handleMessage(end)
        XCTAssertEqual(parent.events[0].result, "Completed")
        XCTAssertEqual(AgentActivityView(event: parent.events[0]).completionSymbol, "checkmark")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ExportView.exportJSON(session: parent)) as? [String: Any])
        let row = try XCTUnwrap((json["toolEvents"] as? [[String: Any]])?.first)
        XCTAssertNil(row["nativeCompletionStatus"])
    }

    func testRenderNativeOutcomeActivitiesAndSessionCard() throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_RENDER_SUBAGENT_FINALITY"] == "1" else {
            throw XCTSkip("显式启用隔离的子代理状态快照")
        }
        XCTAssertTrue(AppPreferences.isIsolated)
        let defaults = AppPreferences.defaults
        let keys = ["appLanguage", "appearanceMode", "disableAnimations"]
        let values = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, values) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("zh", forKey: "appLanguage")
        defaults.set("dark", forKey: "appearanceMode")
        defaults.set(true, forKey: "disableAnimations")
        _ = NSApplication.shared
        let parent = AgentSession(id: "codewhale-outcome-render", agentType: .deepseek,
            workingDirectory: "/tmp/fixture", prompt: "子代理的成功、失败、取消和未知状态")
        parent.events = ["completed", "failed", "cancelled", "interrupted", "unknown"].map { status in
            ToolEvent(tool: "Subagent", result: "原生结果预览", isComplete: true, nativeCompletionStatus: status)
        }
        let manager = SessionManager()
        manager.sessions = [parent]
        let view = VStack(spacing: 16) {
            ForEach(parent.events) { AgentActivityView(event: $0) }
            SessionCardView(session: parent)
        }.environment(manager)
            .environment(ThemeManager())
            .defaultAppStorage(defaults)
            .frame(width: 500).padding(16).background(Color.black)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/xisland-codewhale-outcome-render.png"))
    }
}
