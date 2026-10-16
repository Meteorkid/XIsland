import XCTest
import DIShared
@testable import XIsland

@MainActor
final class ContinueSessionTests: XCTestCase {
    func testObservationSettingControlsReceptionWithoutClaimingInstalledHooks() {
        let key = "autoConfigure.continue"
        let defaults = AppPreferences.defaults
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        XCTAssertEqual(ZeroConfigManager.hookStatus(for: .`continue`), .externalObserver)
        XCTAssertFalse(ZeroConfigManager.shouldRepairNativeHooks(for: .`continue`, homeDirectory: "/tmp/continue-fixture"))
        let manager = SessionManager()
        defaults.set(false, forKey: key)
        manager.handleMessage(tool(.toolStart))
        XCTAssertTrue(manager.sessions.isEmpty)
        defaults.set(true, forKey: key)
        manager.handleMessage(tool(.toolStart))
        XCTAssertEqual(manager.sessions.count, 1)
    }

    private func tool(_ type: DIMessageType, input: String = "first") -> DIMessage {
        var message = DIMessage(type: type, sessionId: "continue-fixture")
        message.agentType = "continue"
        message.nativeEvent = "continue_snapshot"
        message.toolCallId = "native-tool"
        message.tool = "read_file"
        message.toolInput = input
        return message
    }

    func testSnapshotUpdatesSameToolMetadataAndResult() {
        let manager = SessionManager()
        manager.handleMessage(tool(.toolStart))
        manager.handleMessage(tool(.toolStart, input: "updated"))
        XCTAssertEqual(manager.sessions[0].events.count, 1)
        XCTAssertEqual(manager.sessions[0].events[0].input, "updated")
        var completed = tool(.toolComplete, input: "final")
        completed.toolResult = "result"
        manager.handleMessage(completed)
        let event = manager.sessions[0].events[0]
        XCTAssertTrue(event.isComplete)
        XCTAssertEqual(event.input, "final")
        XCTAssertEqual(event.result, "result")
    }

    func testHistoricalErrorDoesNotBecomeCurrentError() {
        let manager = SessionManager()
        manager.handleMessage(tool(.toolStart))
        var historical = tool(.toolComplete)
        historical.nativeMessageReplay = true
        historical.observedState = "error"
        historical.toolResult = "previous error"
        manager.handleMessage(historical)
        XCTAssertNotEqual(manager.sessions[0].status, .error)
        historical.nativeMessageReplay = false
        manager.handleMessage(historical)
        XCTAssertEqual(manager.sessions[0].status, .error)
    }
}
