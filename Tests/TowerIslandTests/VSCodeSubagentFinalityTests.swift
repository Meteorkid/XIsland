import XCTest
import SwiftData
import SwiftUI
import AppKit
import DIShared
@testable import XIsland
@testable import DIBridge

@MainActor
final class VSCodeSubagentFinalityTests: XCTestCase {
    func testLocalStopKeepsChildIdentityAndDoesNotClaimCompletion() throws {
        let manager = SessionManager()
        let parent = AgentSession(id: "copilot-local-parent", agentType: .copilot)
        manager.sessions = [parent]
        let start = try message("SubagentStart", id: "child")
        manager.handleMessage(start)
        let eventID = parent.events.first?.id

        manager.handleMessage(try message("SubagentStop", id: "child"))

        XCTAssertEqual(parent.events.count, 1)
        XCTAssertEqual(parent.events.first?.id, eventID)
        XCTAssertEqual(parent.events.first?.toolCallId, start.subagentId)
        XCTAssertEqual(parent.subagentIds, [try XCTUnwrap(start.subagentId)])
        XCTAssertFalse(try XCTUnwrap(parent.events.first).isComplete)
        XCTAssertTrue(try XCTUnwrap(parent.events.first).completionUnconfirmed)
        XCTAssertNotEqual(parent.events.first?.result, "Completed")
        XCTAssertFalse(parent.lastActivity.contains("Running"))
    }

    func testProvisionalStopWireSignalIsExplicitAndStartRemainsUnchanged() throws {
        let stop = try message("SubagentStop", id: "child")
        let decoded = try DIProtocol.decode(DIProtocol.encode(stop))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: DIProtocol.encode(decoded)) as? [String: Any])
        XCTAssertEqual(wire["subagentEndIsProvisional"] as? Bool, true)
        XCTAssertEqual(decoded.subagentId, stop.subagentId)

        let startWire = try XCTUnwrap(JSONSerialization.jsonObject(with: DIProtocol.encode(message("SubagentStart", id: "child"))) as? [String: Any])
        XCTAssertNil(startWire["subagentEndIsProvisional"])
    }

    func testOrdinaryToolCompletionDoesNotResumeAnUnconfirmedSubagent() throws {
        let manager = SessionManager()
        let parent = AgentSession(id: "copilot-local-parent", agentType: .copilot)
        manager.sessions = [parent]
        manager.handleMessage(try message("SubagentStart", id: "child"))
        var tool = DIMessage(type: .toolStart, sessionId: parent.id)
        tool.agentType = "copilot"
        tool.tool = "Read"
        tool.toolCallId = "read-1"
        manager.handleMessage(tool)
        manager.handleMessage(try message("SubagentStop", id: "child"))
        tool.type = .toolComplete
        manager.handleMessage(tool)

        XCTAssertNil(parent.currentTool)
        XCTAssertFalse(parent.events[0].isComplete)
        XCTAssertTrue(parent.events[1].isComplete)
    }

    func testProvisionalStopsAreIdempotentAndFinalEndStillCompletesOnlyItsChild() throws {
        let manager = SessionManager()
        let parent = AgentSession(id: "copilot-local-parent", agentType: .copilot)
        manager.sessions = [parent]
        let first = try message("SubagentStart", id: "first")
        let second = try message("SubagentStart", id: "second")
        manager.handleMessage(first)
        manager.handleMessage(second)
        parent.status = .waitingPermission
        parent.currentTool = "Read"
        var stop = try message("SubagentStop", id: "first")
        stop.tokensIn = 9
        manager.handleMessage(stop)
        let activity = parent.lastActivityTime
        manager.handleMessage(stop)
        manager.handleMessage(first)

        XCTAssertEqual(parent.events.count, 2)
        XCTAssertEqual(parent.events.map(\.completionUnconfirmed), [true, false])
        XCTAssertEqual(parent.subagentIds, [first.subagentId!, second.subagentId!])
        XCTAssertEqual(parent.status, .waitingPermission)
        XCTAssertEqual(parent.currentTool, "Read")
        XCTAssertEqual(parent.tokenUsage.inputTokens, 0)
        XCTAssertEqual(parent.lastActivityTime, activity)

        stop.subagentEndIsProvisional = nil
        manager.handleMessage(stop)
        manager.handleMessage(stop)
        manager.handleMessage(try message("SubagentStop", id: "first"))

        XCTAssertEqual(parent.events.map(\.isComplete), [true, false])
        XCTAssertEqual(parent.events.map(\.completionUnconfirmed), [false, false])
        XCTAssertEqual(parent.events[0].result, "Completed")
        XCTAssertEqual(parent.subagentIds, [second.subagentId!])
        XCTAssertEqual(parent.tokenUsage.inputTokens, 9)
        XCTAssertEqual(parent.currentTool, "Read")
        XCTAssertEqual(parent.status, .waitingPermission)
    }

    func testUnknownOrMissingProvisionalChildDoesNotUseLegacyFallback() throws {
        let manager = SessionManager()
        let parent = AgentSession(id: "copilot-local-parent", agentType: .copilot)
        manager.sessions = [parent]
        manager.handleMessage(try message("SubagentStart", id: "known"))
        var unknown = try message("SubagentStop", id: "unknown")
        manager.handleMessage(unknown)
        unknown.subagentId = nil
        manager.handleMessage(unknown)

        XCTAssertEqual(parent.events.count, 1)
        XCTAssertFalse(parent.events[0].completionUnconfirmed)
        XCTAssertTrue(parent.events[0].isRunning)
    }

    func testFinalEndClearsRunningSubagentSelectedAfterAnotherToolFinishes() throws {
        let manager = SessionManager()
        let parent = AgentSession(id: "copilot-local-parent", agentType: .copilot)
        manager.sessions = [parent]
        manager.handleMessage(try message("SubagentStart", id: "child"))
        var tool = DIMessage(type: .toolStart, sessionId: parent.id)
        tool.agentType = "copilot"
        tool.tool = "Read"
        tool.toolCallId = "read-1"
        manager.handleMessage(tool)
        tool.type = .toolComplete
        manager.handleMessage(tool)
        XCTAssertEqual(parent.currentTool, "Subagent")

        var end = try message("SubagentStop", id: "child")
        end.subagentEndIsProvisional = false
        manager.handleMessage(end)
        XCTAssertTrue(parent.events[0].isComplete)
        XCTAssertNil(parent.currentTool)
    }

    func testUnconfirmedActivityAndExportDoNotReadAsRunningOrDone() throws {
        let event = ToolEvent(tool: "Subagent", input: "/project/plan", toolCallId: "child", completionUnconfirmed: true)
        let parent = AgentSession(id: "copilot-local-parent", agentType: .copilot)
        parent.events = [event]

        XCTAssertFalse(event.isComplete)
        XCTAssertFalse(event.isRunning)
        XCTAssertEqual(event.summary, L10n.completionUnconfirmed)
        XCTAssertTrue(parent.lastActivity.contains(L10n.completionUnconfirmed))
        XCTAssertTrue(NotchContentView.activityTickerText(for: parent).contains(L10n.completionUnconfirmed))
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: ExportView.exportJSON(session: parent)) as? [String: Any])
        let row = try XCTUnwrap((exported["toolEvents"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["isComplete"] as? Bool, false)
        XCTAssertEqual(row["completionUnconfirmed"] as? Bool, true)
        XCTAssertEqual(row["toolCallId"] as? String, "child")
    }

    func testUnconfirmedStateAndNativeIdentitySurviveSaveReopenAndFinalUpdate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-subagent-finality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("history.store")
        let parent = AgentSession(id: "copilot-local-parent", agentType: .copilot)
        let event = ToolEvent(tool: "Subagent", input: "Plan", toolCallId: "child", completionUnconfirmed: true)
        parent.events = [event]

        autoreleasepool {
            let persistence = SessionPersistenceManager()
            XCTAssertTrue(persistence.setupContainer(storeURL: storeURL))
            XCTAssertTrue(persistence.save(session: parent))
            XCTAssertTrue(persistence.save(session: parent))
        }
        try autoreleasepool {
            let persistence = SessionPersistenceManager()
            XCTAssertTrue(persistence.setupContainer(storeURL: storeURL))
            let stored = try XCTUnwrap(persistence.fetchHistory().first)
            XCTAssertEqual(stored.toolEvents.count, 1)
            let saved = try XCTUnwrap(stored.toolEvents.first)
            XCTAssertTrue(saved.completionUnconfirmed)
            XCTAssertFalse(saved.isComplete)
            XCTAssertEqual(saved.toolCallId, "child")
            XCTAssertEqual(saved.eventId, event.id)
            XCTAssertEqual(saved.timestamp, event.timestamp)

            parent.events[0].completionUnconfirmed = false
            parent.events[0].isComplete = true
            parent.events[0].result = "Completed"
            XCTAssertTrue(persistence.save(session: parent))
        }
        try autoreleasepool {
            let persistence = SessionPersistenceManager()
            XCTAssertTrue(persistence.setupContainer(storeURL: storeURL))
            let stored = try XCTUnwrap(persistence.fetchHistory().first?.toolEvents.first)
            XCTAssertFalse(stored.completionUnconfirmed)
            XCTAssertTrue(stored.isComplete)
            XCTAssertEqual(stored.toolCallId, "child")
            XCTAssertEqual(stored.eventId, event.id)
        }
    }

    private func message(_ event: String, id: String) throws -> DIMessage {
        try VSCodeHookAdapter.normalize(hookType: event, stdinData: [
            "hook_event_name": event, "session_id": "parent", "timestamp": "2026-10-10T00:00:00Z",
            "agent_id": id, "agent_type": "Plan",
        ])
    }

    func testRenderRunningUnconfirmedAndCompletedActivities() throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_RENDER_SUBAGENT_FINALITY"] == "1" else {
            throw XCTSkip("显式启用隔离的状态视图快照")
        }
        let defaults = AppPreferences.defaults
        let language = defaults.string(forKey: "appLanguage")
        defaults.set("zh", forKey: "appLanguage")
        defer {
            if let language { defaults.set(language, forKey: "appLanguage") }
            else { defaults.removeObject(forKey: "appLanguage") }
        }
        _ = NSApplication.shared
        let parent = AgentSession(id: "render-finality", agentType: .copilot)
        parent.events = [ToolEvent(tool: "Subagent", input: "reviewer", toolCallId: "child", completionUnconfirmed: true),
                         ToolEvent(tool: "Read", input: "/tmp/project.swift", isComplete: true),
                         ToolEvent(tool: "Write", input: "/tmp/output.swift")]
        let view = VStack(spacing: 8) {
            ForEach(parent.events) { AgentActivityView(event: $0) }
        }.environment(ThemeManager())
            .frame(width: 420).padding(16).background(Color.black)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = URL(fileURLWithPath: "/tmp/xisland-subagent-finality-render.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
        XCTAssertGreaterThan(bitmap.pixelsWide, 100)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 50)
    }
}
