import XCTest
@testable import XIsland

final class IntegrationSetupPresentationTests: XCTestCase {
    func testPendingSourcesPrecedeReadyAndInactiveSourcesInActionOrder() {
        let rows = [row(.claudeCode, .connected), row(.zed, .needsSetup), row(.codex, .needsAuthorization),
                    row(.cursor, .needsConfiguration, canConfigure: true), row(.kimi, .waitingForActivity),
                    row(.qwen, .disabled, canConfigure: true), row(.geminiCli, .checkFailed), row(.amp, .notInstalled)]

        XCTAssertEqual(IntegrationSetupPresentation.pendingRows(rows).map(\.agent), [.cursor, .codex, .zed, .geminiCli])
        XCTAssertEqual(IntegrationSetupPresentation.readyRows(rows).map(\.agent), [.claudeCode, .kimi])
        XCTAssertEqual(IntegrationSetupPresentation.otherRows(rows).map(\.agent), [.qwen, .amp])
    }

    func testBatchPreparationHasPriorityOnlyForConfigurablePendingSources() {
        let rows = [row(.codex, .needsAuthorization), row(.cursor, .needsConfiguration, canConfigure: true)]

        XCTAssertEqual(primary(rows), .prepareAll)
        XCTAssertEqual(IntegrationSetupPresentation.primaryAction(rows, canPrepareAll: false, canPrepareFiles: true), .configure(.cursor))
    }

    func testAuthorizationOpensOneClientWithoutCallingBatchPreparation() {
        let rows = [row(.workBuddy, .needsSetup), row(.codex, .needsAuthorization), row(.claudeCode, .needsAuthorization)]

        XCTAssertEqual(primary(rows), .openClient(.codex))
        XCTAssertEqual(primary(Array(rows.dropFirst(2))), .openClient(.claudeCode))
    }

    func testManualFileRoutesUsePreparedFilesAndOtherRoutesUseTheirGuide() {
        XCTAssertEqual(primary([row(.workBuddy, .needsSetup)]), .prepareFiles(.workBuddy))
        XCTAssertEqual(primary([row(.kiro, .needsSetup)]), .prepareFiles(.kiro))
        XCTAssertEqual(primary([row(.zed, .needsSetup)]), .openGuide(.zed))
        XCTAssertEqual(primary([row(.aider, .needsSetup, canConfigure: true)]), .openGuide(.aider),
                       "等待手动启动的已准备入口不需要重写配置")
        XCTAssertEqual(IntegrationSetupPresentation.primaryAction([row(.workBuddy, .needsSetup)],
            canPrepareAll: true, canPrepareFiles: false), .openGuide(.workBuddy))
    }

    func testWaitingForActivityIsReadyAndNeverAnAuthorizationOrBatchAction() {
        let rows = [row(.codex, .waitingForActivity, canConfigure: true)]

        XCTAssertTrue(IntegrationSetupPresentation.pendingRows(rows).isEmpty)
        XCTAssertEqual(IntegrationSetupPresentation.readyRows(rows).map(\.agent), [.codex])
        XCTAssertNil(primary(rows))
        XCTAssertEqual(IntegrationSetupPresentation.rowAction(rows[0], canPrepareFiles: true), .refresh)
    }

    func testDisabledMissingAndModelSourcesNeverEnterThePrimaryWorkflow() {
        let rows = [row(.codex, .disabled, canConfigure: true), row(.cursor, .notInstalled, canConfigure: true),
                    row(.glm, .needsSetup), row(.hermes, .needsSetup)]

        XCTAssertNil(primary(rows))
        XCTAssertTrue(IntegrationSetupPresentation.pendingRows(rows).isEmpty)
        XCTAssertEqual(IntegrationSetupPresentation.otherRows(rows).count, rows.count)
        XCTAssertNil(IntegrationSetupPresentation.rowAction(rows[0], canPrepareFiles: true),
                     "已关闭来源只能到设置重新开启，不能提供无效的配置按钮")
    }

    func testConnectedAndEmptyScreensHaveNoPendingPrimaryAction() {
        let connected = row(.claudeCode, .connected, canConfigure: true)

        XCTAssertNil(primary([]))
        XCTAssertNil(primary([connected]))
        XCTAssertNil(IntegrationSetupPresentation.rowAction(connected, canPrepareFiles: true))
    }

    func testFailedChecksRefreshWithoutRewritingConfigurationsOrGrantingTrust() {
        XCTAssertEqual(primary([row(.codex, .checkFailed, canConfigure: true)]), .refresh)
        XCTAssertEqual(primary([row(.zed, .needsConfiguration)]), .openGuide(.zed))
    }

    func testFocusedRequestWaitsForDiscoveryAndUsesCurrentPhase() {
        let request = IntegrationSetupFocusRequest(agent: .codex)
        XCTAssertNil(IntegrationSetupPresentation.focusTarget(request, rows: [], handledID: nil))
        for phase in IntegrationSetupPhase.allCases {
            let target = IntegrationSetupPresentation.focusTarget(request, rows: [row(.codex, phase)], handledID: nil)
            XCTAssertEqual(target?.request, request)
            XCTAssertEqual(target?.phase, phase)
        }
    }

    func testPeriodicRefreshDoesNotRepeatFocusButAnotherClickCan() {
        let first = IntegrationSetupFocusRequest(agent: .codex)
        XCTAssertNil(IntegrationSetupPresentation.focusTarget(first, rows: [row(.codex, .connected)], handledID: first.id))
        let repeated = IntegrationSetupFocusRequest(agent: .codex)
        XCTAssertNotNil(IntegrationSetupPresentation.focusTarget(repeated, rows: [row(.codex, .connected)], handledID: first.id))
        XCTAssertNil(IntegrationSetupPresentation.focusTarget(nil, rows: [row(.codex, .needsAuthorization)], handledID: nil))
    }

    private func primary(_ rows: [IntegrationSetupRow]) -> IntegrationSetupAction? {
        IntegrationSetupPresentation.primaryAction(rows, canPrepareAll: true, canPrepareFiles: true)
    }

    private func row(_ agent: AgentType, _ phase: IntegrationSetupPhase, canConfigure: Bool = false) -> IntegrationSetupRow {
        IntegrationSetupRow(agent: agent, phase: phase, detail: "Fixture", canConfigure: canConfigure, lastSeen: nil)
    }
}
