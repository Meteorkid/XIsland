import XCTest
import DIShared
@testable import XIsland

@MainActor
final class AmazonQSessionTests: XCTestCase {
    func testReceptionSwitchDoesNotInstallLegacyHooks() {
        let key = "autoConfigure.amazon_q", defaults = AppPreferences.defaults
        let old = defaults.object(forKey: key)
        defer {
            if let old { defaults.set(old, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        XCTAssertEqual(ZeroConfigManager.hookStatus(for: .amazonQ), .externalAmazonQ)
        XCTAssertFalse(ZeroConfigManager.shouldRepairNativeHooks(for: .amazonQ, homeDirectory: "/unused"))
        let manager = SessionManager()
        var message = DIMessage(type: .statusUpdate, sessionId: "amazonq-wrapper-fixture")
        message.agentType = "amazon_q"
        defaults.set(false, forKey: key)
        manager.handleMessage(message)
        XCTAssertTrue(manager.sessions.isEmpty)
        defaults.set(true, forKey: key)
        manager.handleMessage(message)
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testExitedWrapperRejectsLateHooksEvenAfterSessionRemoval() {
        let manager = SessionManager()
        var message = DIMessage(type: .statusUpdate, sessionId: "amazonq-wrapper-fixture")
        message.agentType = "amazon_q"
        message.nativeEvent = "amazonq_wrapper_start"
        manager.handleMessage(message)
        message.type = .sessionEnd
        message.nativeEvent = "amazonq_wrapper_end"
        manager.handleMessage(message)
        manager.sessions.removeAll()
        for event in ["amazonq_1_19_7_userPromptSubmit", "amazonq_1_19_7_agentSpawn", "amazonq_wrapper_start"] {
            message.type = .sessionStart
            message.nativeEvent = event
            manager.handleMessage(message)
        }
        XCTAssertTrue(manager.sessions.isEmpty)
        message.sessionId = "amazonq-wrapper-new-process"
        manager.handleMessage(message)
        XCTAssertEqual(manager.sessions.count, 1)
    }
}
