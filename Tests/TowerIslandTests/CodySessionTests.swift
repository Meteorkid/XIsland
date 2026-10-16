import XCTest
import DIShared
@testable import XIsland

@MainActor
final class CodySessionTests: XCTestCase {
    func testReceptionSwitchAndPreviewDoNotInventHistoryOrCompletion() {
        let defaults = AppPreferences.defaults, key = "autoConfigure.cody"
        let old = defaults.object(forKey: key)
        defer {
            if let old { defaults.set(old, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        XCTAssertEqual(ZeroConfigManager.hookStatus(for: .cody), .externalCody)
        XCTAssertFalse(ZeroConfigManager.shouldRepairNativeHooks(for: .cody, homeDirectory: "/unused"))
        let manager = SessionManager()
        var message = DIMessage(type: .statusUpdate, sessionId: "cody-fixture")
        message.agentType = "cody"
        message.statusIsAssistantReply = false
        message.observedState = "active"
        message.status = "回复预览"
        defaults.set(false, forKey: key)
        manager.handleMessage(message)
        XCTAssertTrue(manager.sessions.isEmpty)
        defaults.set(true, forKey: key)
        manager.handleMessage(message)
        XCTAssertEqual(manager.sessions[0].status, .active)
        XCTAssertTrue(manager.sessions[0].chatHistory.isEmpty)
        message.observedState = nil
        message.status = "观察已结束"
        manager.handleMessage(message)
        XCTAssertEqual(manager.sessions[0].statusText, "观察已结束")
        XCTAssertNotEqual(manager.sessions[0].status, .completed)
    }
}
