import XCTest
@testable import XIsland

final class WorkBuddyIdentityTests: XCTestCase {
    func testWorkBuddyIdentityDoesNotAliasCodeBuddyCLI() {
        XCTAssertEqual(AgentType.from("WorkBuddy"), .workBuddy)
        XCTAssertEqual(AgentType.from("work-buddy"), .workBuddy)
        XCTAssertEqual(AgentType.fromBundleId("com.tencent.workbuddy.mac"), .workBuddy)
        XCTAssertEqual(AgentType.from("codebuddy"), .codeBuddy)
        XCTAssertEqual(TerminalApp.forAgent(.workBuddy), .workBuddy)
        XCTAssertEqual(TerminalApp.detect(from: "com.tencent.workbuddy.mac"), .workBuddy)
        XCTAssertFalse(AgentType.workBuddy.sendsSessionEnd)
    }

    func testManualPluginDoesNotClaimOrRepairInstalledConfiguration() {
        XCTAssertEqual(ZeroConfigManager.hookStatus(for: .workBuddy), .externalWorkBuddy)
        XCTAssertFalse(ZeroConfigManager.shouldRepairNativeHooks(for: .workBuddy, homeDirectory: "/unused"))
    }
}
