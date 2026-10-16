import XCTest
import SwiftUI
import AppKit
@testable import XIsland
@testable import DIBridge
import DIShared

@MainActor
final class GLMMultiClientTests: XCTestCase {
    func testModelRecognitionDoesNotGuessFromClientOrProviderAliases() {
        for value in ["glm", "GLM-5.3", "glm-4.7-flash", "z-ai/glm-5", "openrouter/z-ai/glm-5.2", "glm-5.2[1m]", "glm4.7"] {
            XCTAssertTrue(GLMIntegration.isGLMModel(value), value)
        }
        for value in ["", "sonnet", "zai/sonnet", "my-glm-agent", "glm client", "glm-5\nextra", "glm-", "glm" + String(repeating: "x", count: 300)] {
            XCTAssertFalse(GLMIntegration.isGLMModel(value), value)
        }
        XCTAssertEqual(ZeroConfigManager.hookStatus(for: .glm), .modelSource)
        XCTAssertNil(NativeHookProfile.profile(for: .glm))
    }

    func testFourClientPayloadsKeepIdentityAndModelThroughHistoryAndFiltering() throws {
        let model = "glm-5.3"
        var claude = try DIBridge.makeMessage(agentType: "claude_code", hookType: "SessionStart", sessionId: "claude_code-shared",
            stdinData: ["hook_event_name": "SessionStart", "session_id": "shared", "cwd": "/tmp/project", "model": model])
        claude.agentType = "claude_code"
        let openCode = try OpenCodeHookAdapter.normalize(hookType: "prompt.submitted", stdinData: [
            "native_event": "prompt.submitted", "session_id": "shared", "cwd": "/tmp/project", "prompt": "OpenCode task", "model": model])
        let cline = try ClineHookAdapter.normalize(hookType: "TaskStart", stdinData: [
            "hookName": "TaskStart", "taskId": "shared", "timestamp": "1789550000000", "taskStart": [:],
            "workspaceRoots": ["/tmp/project"], "model": ["provider": "zai", "slug": model]], environment: [:])
        let pi = try PiHookAdapter.normalize(hookType: "session_start", stdinData: [
            "native_event": "session_start", "hook_event_name": "SessionStart", "session_id": "shared", "cwd": "/tmp/project", "model": model])
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        for message in [claude, openCode, cline, pi] {
            manager.handleMessage(message)
            let session = try XCTUnwrap(manager.sessions.first { $0.id == message.sessionId })
            XCTAssertEqual(session.agentType.rawValue, message.agentType)
            XCTAssertNotEqual(session.agentType, .glm)
            XCTAssertEqual(session.tokenUsage.model, model)
            XCTAssertTrue(session.usesGLMModel)
            persistence.save(session: session)
            let restored = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
            XCTAssertEqual(restored.agentType, session.agentType)
            XCTAssertEqual(restored.tokenUsage.model, model)
        }
        XCTAssertEqual(manager.sessions.count, 4)
        manager.activeFilter = .agentType(.glm)
        XCTAssertEqual(manager.filteredSessions.count, 4)
        manager.activeFilter = .agentType(.openCode)
        XCTAssertEqual(manager.filteredSessions.map(\.agentType), [.openCode])
        manager.activeFilter = .all
        manager.searchText = "GLM-5.3"
        XCTAssertEqual(manager.filteredSessions.count, 4)
        manager.searchText = ""
        manager.activeFilter = .text("GLM-5.3")
        XCTAssertEqual(manager.filteredSessions.count, 4)
    }

    func testSwitchingModelUpdatesGLMFilterWithoutCreatingAnotherSession() {
        let manager = SessionManager()
        var message = DIMessage(type: .sessionStart, sessionId: "opencode-model-switch")
        message.agentType = "opencode"
        message.model = "glm-5.3"
        manager.handleMessage(message)
        manager.activeFilter = .agentType(.glm)
        XCTAssertEqual(manager.filteredSessions.count, 1)
        message.model = "other-model"
        manager.handleMessage(message)
        XCTAssertTrue(manager.filteredSessions.isEmpty)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions.first?.agentType, .openCode)
        XCTAssertEqual(manager.sessions.first?.tokenUsage.model, "other-model")
    }

    func testRenderClientAndModelLabels() throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_RENDER_SESSION_FINALITY"] == "1" else {
            throw XCTSkip("显式启用模型标签渲染")
        }
        XCTAssertTrue(AppPreferences.isIsolated)
        let defaults = AppPreferences.defaults
        let keys = ["appLanguage", "appearanceMode", "disableAnimations"]
        let oldValues = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, oldValues) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("zh", forKey: "appLanguage")
        defaults.set("dark", forKey: "appearanceMode")
        defaults.set(true, forKey: "disableAnimations")
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let manager = SessionManager()
        let theme = ThemeManager()
        manager.sessions = GLMIntegration.clients.map { client in
            let session = AgentSession(id: "glm-render-\(client.rawValue)", agentType: client,
                workingDirectory: "/tmp/model-display", prompt: "同一模型，保留各自客户端身份")
            session.tokenUsage.model = "z-ai/glm-5.3-flash"
            session.status = .idle
            return session
        }
        let view = VStack(spacing: 12) {
            ForEach(manager.sessions) { session in
                SessionCardView(session: session)
            }
        }
        .environment(manager)
        .environment(theme)
        .defaultAppStorage(defaults)
        .frame(width: 500)
        .padding(16)
        .background(Color.black)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 400)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 200)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/xisland-v2-glm-model-render.png"))
    }
}
