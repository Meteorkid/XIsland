import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class AiderWrapperTests: XCTestCase {
    func testNewLauncherDoesNotRepurposeExistingNotificationHelper() throws {
        try withDirectory { directory in
            let old = directory.appendingPathComponent(".xisland/bin/aider-bridge")
            try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = "#!/bin/sh\n# existing manually configured notification helper\nexit 0\n"
            try source.write(to: old, atomically: true, encoding: .utf8)
            let launcher = directory.appendingPathComponent(AiderWrapperConfiguration.relativePath)
            XCTAssertNotEqual(old, launcher)
            try AiderWrapperConfiguration.install(at: launcher, bridgePath: "/bin/di-bridge")
            try AiderWrapperConfiguration.remove(at: launcher)
            XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), source)
        }
    }

    func testInstallationUpgradeAndRemovalTouchOnlyOwnedWrapper() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("aider-bridge")
            try AiderWrapperConfiguration.install(at: path, bridgePath: "/old/di-bridge")
            XCTAssertTrue(AiderWrapperConfiguration.isConfigured(at: path, bridgePath: "/old/di-bridge"))
            XCTAssertTrue(AiderWrapperConfiguration.shouldRepair(at: path, bridgePath: "/new/di-bridge"))
            try AiderWrapperConfiguration.install(at: path, bridgePath: "/new/di-bridge")
            XCTAssertFalse(AiderWrapperConfiguration.shouldRepair(at: path, bridgePath: "/new/di-bridge"))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            let current = try Data(contentsOf: path)
            try AiderWrapperConfiguration.install(at: path, bridgePath: "/new/di-bridge")
            XCTAssertEqual(current, try Data(contentsOf: path))
            try AiderWrapperConfiguration.remove(at: path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        }
    }

    func testUserScriptEmptyFileAndSymlinkArePreserved() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("aider-bridge")
            for text in ["", "#!/bin/sh\nmy-custom-aider \"$@\"\n", try AiderWrapperConfiguration.source(bridgePath: "/bin/di-bridge") + "# edited\n"] {
                try text.write(to: path, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try AiderWrapperConfiguration.install(at: path, bridgePath: "/bin/di-bridge"))
                try AiderWrapperConfiguration.remove(at: path)
                XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), text)
                XCTAssertFalse(AiderWrapperConfiguration.shouldRepair(at: path, bridgePath: "/bin/di-bridge"))
            }
            let link = directory.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
            XCTAssertThrowsError(try AiderWrapperConfiguration.install(at: link, bridgePath: "/bin/di-bridge"))
            XCTAssertThrowsError(try AiderWrapperConfiguration.remove(at: link))
            XCTAssertFalse(AiderWrapperConfiguration.isConfigured(at: link, bridgePath: "/bin/di-bridge"))
        }
    }

    func testGeneratedShellUsesArgvWithoutReinterpretingUserText() throws {
        try withDirectory { directory in
            let bridge = directory.appendingPathComponent("O'Brien $(touch forbidden) bridge")
            try "#!/bin/sh\nprintf '%s\\0' \"$@\"\n".write(to: bridge, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
            let wrapper = directory.appendingPathComponent("aider-bridge")
            try AiderWrapperConfiguration.install(at: wrapper, bridgePath: bridge.path)
            let arguments = ["--message", "中文\n'quoted' $(touch forbidden)", "--", "file name"]
            let process = Process()
            process.executableURL = wrapper
            process.arguments = arguments
            process.currentDirectoryURL = directory
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }, ["aider"] + arguments)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden").path))
        }
    }

    func testExecutableLookupRequiresExecutableRegularFileAndResolvesLinks() throws {
        try withDirectory { directory in
            let binary = directory.appendingPathComponent("aider")
            try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
            XCTAssertNil(AiderLauncher.executablePath("aider", environment: ["PATH": directory.path]))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            XCTAssertEqual(AiderLauncher.executablePath("aider", environment: ["PATH": directory.path]), binary.resolvingSymlinksInPath().path)
            XCTAssertNil(AiderLauncher.executablePath(directory.path, environment: [:]))
            XCTAssertNil(AiderLauncher.executablePath("bad\0name", environment: [:]))
            let link = directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
            XCTAssertEqual(AiderLauncher.executablePath(link.path, environment: [:]), binary.resolvingSymlinksInPath().path)
        }
    }

    @MainActor
    func testProcessLifecycleAndNotificationsDoNotInventAssistantHistory() {
        let manager = SessionManager()
        var start = DIMessage(type: .sessionStart, sessionId: "aider-wrapper-fixture")
        start.agentType = "aider"
        start.status = "Aider 进程已连接；轮次状态不可用"
        start.statusIsAssistantReply = false
        manager.handleMessage(start)
        let session = manager.sessions[0]
        XCTAssertEqual(session.statusText, start.status)
        manager.checkProcessesAlive { _ in false }
        XCTAssertEqual(session.status, .active)
        var notice = DIMessage(type: .statusUpdate, sessionId: start.sessionId)
        notice.agentType = "aider"
        notice.status = "收到 Aider 通知，请查看终端"
        notice.statusIsAssistantReply = false
        manager.handleMessage(notice)
        XCTAssertNil(session.pendingQuestion)
        XCTAssertNil(session.pendingPermission)
        XCTAssertTrue(session.chatHistory.isEmpty)
        XCTAssertEqual(session.status, .active)
        var end = DIMessage(type: .sessionEnd, sessionId: start.sessionId)
        end.agentType = "aider"
        end.observedState = "completed"
        end.status = "Aider 进程已退出（退出码 7）"
        end.statusIsAssistantReply = false
        manager.handleMessage(end)
        XCTAssertEqual(session.status, .completed)
        XCTAssertTrue(session.chatHistory.isEmpty)
        XCTAssertEqual(session.agentResponse, "")
        XCTAssertEqual(session.statusText, end.status)
    }

    @MainActor
    func testOperationalSessionEndPreservesExistingAssistantReply() {
        let manager = SessionManager()
        let session = AgentSession(id: "fixture", agentType: .aider)
        session.agentResponse = "Actual reply"
        session.chatHistory = [ChatMessage(timestamp: Date(), role: .assistant, content: "Actual reply")]
        let oldID = session.chatHistory[0].id
        manager.sessions = [session]
        var message = DIMessage(type: .sessionEnd, sessionId: "fixture")
        message.agentType = "aider"
        message.statusIsAssistantReply = false
        message.status = "Process exited"
        message.observedState = "completed"
        manager.handleMessage(message)
        XCTAssertEqual(session.agentResponse, "Actual reply")
        XCTAssertEqual(session.chatHistory.count, 1)
        XCTAssertEqual(session.chatHistory[0].id, oldID)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xi-aider-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
