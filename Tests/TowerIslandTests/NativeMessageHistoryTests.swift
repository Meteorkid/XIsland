import XCTest
import DIShared
@testable import XIsland

@MainActor
final class NativeMessageHistoryTests: XCTestCase {
    func testCompanionReceptionSwitchUsesIsolatedPreferences() {
        XCTAssertFalse(AppPreferences.defaults === UserDefaults.standard)
        let key = "autoConfigure.roo_code"
        let previous = AppPreferences.defaults.object(forKey: key)
        defer {
            if let previous { AppPreferences.defaults.set(previous, forKey: key) }
            else { AppPreferences.defaults.removeObject(forKey: key) }
        }
        var message = reply("1", "fixture")
        message.agentType = "roo_code"
        let manager = SessionManager()
        AppPreferences.defaults.set(false, forKey: key)
        manager.handleMessage(message)
        XCTAssertTrue(manager.sessions.isEmpty)
        AppPreferences.defaults.set(true, forKey: key)
        manager.handleMessage(message)
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testPartialAndFinalUpdateTheSameNativeMessageWithoutMergingOtherReplies() {
        let manager = SessionManager()
        manager.handleMessage(reply("1", "partial", partial: true))
        manager.handleMessage(reply("1", "final"))
        manager.handleMessage(reply("2", "second reply"))
        let session = manager.sessions[0]
        XCTAssertEqual(session.chatHistory.map(\.content), ["final", "second reply"])
        XCTAssertNotEqual(session.chatHistory[0].id, session.chatHistory[1].id)
        XCTAssertEqual(session.agentResponse, "second reply")
        manager.handleMessage(reply("1", "late correction"))
        XCTAssertEqual(session.chatHistory.map(\.content), ["late correction", "second reply"])
        XCTAssertEqual(session.agentResponse, "second reply")
        XCTAssertEqual(session.statusText, "second reply")
    }

    func testUserFeedbackDeduplicatesAndKeepsExistingReplyOnReplay() {
        let manager = SessionManager()
        var prompt = DIMessage(type: .sessionStart, sessionId: "fixture")
        prompt.agentType = "codex"
        prompt.nativeMessageId = "user-1"
        prompt.prompt = "继续"
        manager.handleMessage(prompt)
        manager.handleMessage(reply("1", "answer"))
        manager.handleMessage(prompt)
        XCTAssertEqual(manager.sessions[0].chatHistory.count, 2)
        XCTAssertEqual(manager.sessions[0].agentResponse, "answer")
    }

    func testNativeIDsAreStableAcrossManagerReconstructionAndScopedToRoleAndSession() {
        let first = SessionManager(), restored = SessionManager()
        first.handleMessage(reply("1", "before"))
        let session = first.sessions[0]
        let oldID = session.chatHistory[0].id
        restored.sessions = [session]
        restored.handleMessage(reply("1", "after"))
        XCTAssertEqual(session.chatHistory.count, 1)
        XCTAssertEqual(session.chatHistory[0].id, oldID)
        var other = reply("1", "different session")
        other.sessionId = "other"
        restored.handleMessage(other)
        XCTAssertNotEqual(restored.sessions.first { $0.id == "other" }?.chatHistory[0].id, oldID)
    }

    func testOptionalNativeFieldsRoundTripAndLegacyMessagesStillMerge() throws {
        let message = reply("native", "文字", partial: true)
        let decoded = try DIProtocol.decode(DIProtocol.encode(message))
        XCTAssertEqual(decoded.nativeMessageId, "native")
        XCTAssertEqual(decoded.nativeMessagePartial, true)
        let manager = SessionManager()
        var legacy = message
        legacy.nativeMessageId = nil
        legacy.nativeMessagePartial = nil
        manager.handleMessage(legacy)
        legacy.status = "legacy update"
        manager.handleMessage(legacy)
        XCTAssertEqual(manager.sessions[0].chatHistory.map(\.content), ["legacy update"])
    }

    func testCompanionConfigurationDoesNotClaimFabricatedHookFiles() {
        for agent in [AgentType.rooCode, .pearai] {
            XCTAssertTrue(ZeroConfigManager.usesCompanionExtension(agent))
            XCTAssertEqual(ZeroConfigManager.hookStatus(for: agent), .externalExtension)
            XCTAssertFalse(agent.sendsSessionEnd)
        }
        XCTAssertFalse(ZeroConfigManager.usesCompanionExtension(.codex))
    }

    func testExplicitClientRoutesCannotReportLegacyFilesAsConfigured() {
        for (agent, status) in [(AgentType.kiro, HookInstallStatus.externalKiro), (.glm, .modelSource)] {
            XCTAssertEqual(ZeroConfigManager.hookStatus(for: agent), status)
            XCTAssertNotEqual(ZeroConfigManager.hookStatus(for: agent), .active)
            XCTAssertFalse(ZeroConfigManager.shouldRepairNativeHooks(for: agent, homeDirectory: "/unused-fixture"))
        }
        XCTAssertFalse(ZeroConfigManager.hasUnverifiedIntegration(.codex))
        XCTAssertFalse(ZeroConfigManager.hasUnverifiedIntegration(.rooCode))
        for agent in [AgentType.zed, .jetbrainsAi] {
            XCTAssertTrue(ZeroConfigManager.usesACPBridge(agent))
            XCTAssertEqual(ZeroConfigManager.hookStatus(for: agent), .externalAgent)
        }
    }

    func testAcceptedNativeUserMessagesDoNotRestartForegroundWork() {
        let manager = SessionManager()
        let session = AgentSession(id: "fixture", agentType: .codex)
        session.status = .waitingPermission
        session.agentResponse = "Current answer"
        session.statusText = "Waiting for original permission"
        manager.sessions = [session]
        var update = DIMessage(type: .statusUpdate, sessionId: "fixture")
        update.agentType = "codex"; update.statusIsAssistantReply = false
        update.nativeMessageId = "accepted"; update.prompt = "Queued user message"
        manager.handleMessage(update)
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertEqual(session.agentResponse, "Current answer")
        XCTAssertEqual(session.statusText, "Waiting for original permission")
        XCTAssertEqual(session.chatHistory.last?.role, .user)
        update.prompt = ""
        manager.handleMessage(update)
        XCTAssertTrue(session.chatHistory.isEmpty)
        XCTAssertEqual(session.prompt, "")
    }

    func testNativeEmptyReplacementClearsOnlyTheAddressedMessage() {
        let manager = SessionManager()
        manager.handleMessage(reply("first", "One"))
        manager.handleMessage(reply("second", "Two"))
        manager.handleMessage(reply("first", ""))
        XCTAssertEqual(manager.sessions[0].chatHistory.map(\.content), ["Two"])
        XCTAssertEqual(manager.sessions[0].agentResponse, "Two")
        manager.handleMessage(reply("second", ""))
        XCTAssertTrue(manager.sessions[0].chatHistory.isEmpty)
        XCTAssertEqual(manager.sessions[0].agentResponse, "")
    }

    func testReplayFlagIsOptionalAndSurvivesProtocolEncoding() throws {
        var message = reply("historical", "History")
        message.nativeMessageReplay = true
        XCTAssertEqual(try DIProtocol.decode(DIProtocol.encode(message)).nativeMessageReplay, true)
        message.nativeMessageReplay = nil
        XCTAssertNil(try DIProtocol.decode(DIProtocol.encode(message)).nativeMessageReplay)
    }

    func testACPToolSnapshotUpdatesAndClearsMetadataWithoutAddingDuplicateEvents() {
        let manager = SessionManager()
        var tool = DIMessage(type: .toolStart, sessionId: "fixture")
        tool.agentType = "codex"; tool.nativeEvent = "acp"; tool.toolCallId = "native-call"
        tool.tool = "Pending title"; tool.toolInput = "partial input"
        manager.handleMessage(tool)
        tool.tool = "Actual title"; tool.toolInput = ""
        manager.handleMessage(tool)
        XCTAssertEqual(manager.sessions[0].events.count, 1)
        XCTAssertEqual(manager.sessions[0].events[0].tool, "Actual title")
        XCTAssertEqual(manager.sessions[0].events[0].input, "")
        tool.type = .toolComplete; tool.toolResult = "first result"
        manager.handleMessage(tool)
        tool.toolResult = "updated result"
        manager.handleMessage(tool)
        XCTAssertEqual(manager.sessions[0].events.count, 1)
        XCTAssertEqual(manager.sessions[0].events[0].result, "updated result")
    }

    func testActualCompiledObserverFramesDecodeWithSwiftProtocol() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let observer = root.appendingPathComponent("Sources/XIslandVSCode/out/task-observer.js")
        guard FileManager.default.fileExists(atPath: observer.path) else {
            throw XCTSkip("先编译 Sources/XIslandVSCode，以验证真实 TypeScript 生成消息")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        process.arguments = ["-e", """
        const {EventEmitter}=require('node:events');
        const {observeTasks}=require(process.argv[1]);
        const api=new EventEmitter();
        const sub=observeTasks(api,'roo_code','a'.repeat(24),m=>process.stdout.write(JSON.stringify(m)+'\\n'));
        api.emit('taskStarted','native-task');
        api.emit('message',{taskId:'native-task',action:'created',message:{ts:123,type:'say',say:'text',text:'中文'+String.fromCharCode(0xd800),partial:true}});
        api.emit('taskCompleted','native-task',{totalTokensIn:2,totalTokensOut:3,totalCost:0.1},{});
        sub.dispose();
        """, observer.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { XCTFail("编译观察器未成功生成消息"); return }
        let messages = try bytes.split(separator: 10).map { try DIProtocol.decode(Data($0)) }
        guard messages.count == 4 else { XCTFail("应有3条业务事件及1条观察结束通知"); return }
        XCTAssertEqual(messages.map(\.type), [.sessionStart, .statusUpdate, .statusUpdate, .observationEnded])
        XCTAssertEqual(messages[1].nativeMessageId, "123")
        XCTAssertEqual(messages[1].status, "中文�")
        XCTAssertEqual(messages[2].observedState, "idle")
        XCTAssertEqual(messages[2].usageIsCumulative, true)
        XCTAssertEqual(messages[0].nativeTaskId, "native-task")
        XCTAssertNil(messages[3].nativeTaskId)
        var ledger = ObservationLeaseLedger()
        for message in messages {
            XCTAssertNotEqual(ledger.accept(message, now: 0, wallTime: Date()), .rejected)
        }
    }

    private func reply(_ id: String, _ text: String, partial: Bool = false) -> DIMessage {
        var message = DIMessage(type: .statusUpdate, sessionId: "fixture")
        message.agentType = "codex"
        message.statusIsAssistantReply = true
        message.nativeMessageId = id
        message.nativeMessagePartial = partial
        message.status = text
        return message
    }
}
