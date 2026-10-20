import XCTest
@testable import XIsland

@MainActor
final class PreferencesIntegrationStatusTests: XCTestCase {
    func testExternalRouteLabelsDoNotNeedConfigurationEvidence() {
        let expected: [AgentType: HookInstallStatus] = [
            .workBuddy: .externalWorkBuddy, .kiro: .externalKiro,
            .amazonQ: .externalAmazonQ, .cody: .externalCody, .continue: .externalObserver,
            .zed: .externalAgent, .jetbrainsAi: .externalAgent,
            .rooCode: .externalExtension, .pearai: .externalExtension, .glm: .modelSource,
        ]

        for (agent, status) in expected {
            XCTAssertEqual(ZeroConfigManager.externalHookStatus(for: agent), status, agent.rawValue)
        }
        for agent in AgentType.allCases where expected[agent] == nil {
            XCTAssertNil(ZeroConfigManager.externalHookStatus(for: agent), agent.rawValue)
        }
    }

    func testClineAndNativeClientsHaveNoStaticInstalledOrConnectedStatus() {
        for agent in [AgentType.cline, .claudeCode, .codex, .cursor] {
            XCTAssertNil(ZeroConfigManager.externalHookStatus(for: agent))
        }
    }

    func testMissingCachedEvidenceIsShownAsUnchecked() {
        XCTAssertEqual(PreferencesView.integrationStatusLabel(nil, language: "zh"), "尚未检查")
        XCTAssertEqual(PreferencesView.integrationStatusLabel(nil, language: "en"), "Not checked")
        XCTAssertNotEqual(PreferencesView.integrationStatusLabel(nil, language: "zh"),
                          PreferencesView.integrationStatusLabel(.notInstalled, language: "zh"))
    }

    func testPreparedAndUnauthorizedClientsAreDistinctFromConnectedClients() {
        XCTAssertEqual(PreferencesView.integrationStatusLabel(.waitingForActivity, language: "zh"), "配置待验证")
        XCTAssertEqual(PreferencesView.integrationStatusLabel(.needsAuthorization, language: "zh"), "待授权")
        XCTAssertEqual(PreferencesView.integrationStatusLabel(.connected, language: "zh"), "已接通")
        XCTAssertEqual(PreferencesView.integrationStatusLabel(.waitingForActivity, language: "en"), "Configuration unverified")
        XCTAssertEqual(PreferencesView.integrationStatusLabel(.needsAuthorization, language: "en"), "Needs authorization")
        XCTAssertEqual(PreferencesView.integrationStatusLabel(.connected, language: "en"), "Connected")
    }
}
