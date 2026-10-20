import XCTest
@testable import XIsland

final class IntegrationSetupStateTests: XCTestCase {
    private let current = "current-hook-definition"
    private let previous = "previous-hook-definition"

    private func phase(_ agent: AgentType, _ evidence: IntegrationSetupEvidence) -> IntegrationSetupPhase {
        IntegrationSetupState.phase(descriptor: .descriptor(for: agent, language: "en"), evidence: evidence)
    }

    func testCatalogCoversAll31SupportedSourcesExactlyOnce() {
        let agents = IntegrationSetupDescriptor.all.map(\.agent)
        XCTAssertEqual(agents.count, 31)
        XCTAssertEqual(Set(agents).count, agents.count)
        XCTAssertEqual(Set(agents), Set(AgentType.allCases.filter(\.isSupported)))
        XCTAssertTrue(agents.contains(.workBuddy))
        XCTAssertFalse(agents.contains(.hermes))
    }

    func testManualRoutesMatchExistingInstallerBoundaries() {
        let manual: Set<AgentType> = [.workBuddy, .kiro, .rooCode, .pearai, .zed, .jetbrainsAi,
                                     .cody, .continue, .amazonQ, .glm]
        for descriptor in IntegrationSetupDescriptor.all {
            XCTAssertEqual(descriptor.canAutoConfigure, !manual.contains(descriptor.agent), descriptor.agent.rawValue)
            XCTAssertEqual(descriptor.requiresManualSetup,
                           manual.contains(descriptor.agent) || descriptor.agent == .aider,
                           descriptor.agent.rawValue)
        }
    }

    func testEachSourceProvidesEnglishAndChineseGuidanceWithoutRequestingCredentials() {
        for agent in AgentType.allCases where agent.isSupported {
            let english = IntegrationSetupDescriptor.descriptor(for: agent, language: "en")
            let chinese = IntegrationSetupDescriptor.descriptor(for: agent, language: "zh")
            XCTAssertNotEqual(english.authorizationGuidance, chinese.authorizationGuidance, agent.rawValue)
            XCTAssertTrue(english.authorizationGuidance.contains("No password or API key is needed"), agent.rawValue)
            XCTAssertTrue(chinese.authorizationGuidance.contains("无需输入密码或 API 密钥"), agent.rawValue)
            XCTAssertEqual(english.setupURL?.scheme, "https", agent.rawValue)
            XCTAssertEqual(english.setupURL?.host, "github.com", agent.rawValue)
        }
    }

    func testCodexGuidanceUsesTheNativeBatchReviewFlowForOnlyXIslandHooks() {
        for language in ["zh", "en"] {
            let guidance = IntegrationSetupDescriptor.descriptor(for: .codex, language: language).authorizationGuidance
            XCTAssertTrue(guidance.contains("Composer"))
            XCTAssertTrue(guidance.contains("Review hooks"))
            XCTAssertTrue(guidance.contains("Allow selected"))
            XCTAssertTrue(guidance.contains(language == "zh" ? "仅勾选 X Island 项" : "select only the X Island entries"))
            XCTAssertFalse(guidance.contains("设置 →"))
            XCTAssertFalse(guidance.contains("Settings →"))
        }
    }

    func testNotInstalledAndDisabledCannotBeOverriddenByAnOldEvent() {
        var evidence = IntegrationSetupEvidence(installed: false, configured: true,
                                               configurationFingerprint: current, observedFingerprint: current)
        XCTAssertEqual(phase(.claudeCode, evidence), .notInstalled)
        evidence.installed = true
        evidence.enabled = false
        XCTAssertEqual(phase(.claudeCode, evidence), .disabled)
    }

    func testAutomaticRouteNeedsConfigurationBeforeWaitingForActivity() {
        var evidence = IntegrationSetupEvidence(installed: true, configurationFingerprint: current)
        XCTAssertEqual(phase(.claudeCode, evidence), .needsConfiguration)
        evidence.configured = true
        XCTAssertEqual(phase(.claudeCode, evidence), .waitingForActivity)
    }

    func testUnknownAuthorizationDoesNotInventARequiredPermissionOrConnection() {
        let evidence = IntegrationSetupEvidence(installed: true, configured: true,
                                               configurationFingerprint: current, authorization: .unknown)
        XCTAssertEqual(phase(.cursor, evidence), .waitingForActivity)
        XCTAssertEqual(phase(.workBuddy, evidence), .needsSetup)
    }

    func testNoAuthorizationMechanismStillNeedsARealEvent() {
        var evidence = IntegrationSetupEvidence(installed: true, configured: true,
                                               configurationFingerprint: current, authorization: .notRequired)
        XCTAssertEqual(phase(.claudeCode, evidence), .waitingForActivity)
        evidence.observedFingerprint = current
        XCTAssertEqual(phase(.claudeCode, evidence), .connected)
    }

    func testCurrentRealEventCanConfirmAnExternallyConfiguredManualRoute() {
        let evidence = IntegrationSetupEvidence(installed: true, configured: false,
                                               configurationFingerprint: current, observedFingerprint: current)
        for agent in [AgentType.workBuddy, .rooCode, .zed, .cody, .continue, .amazonQ, .kiro] {
            XCTAssertEqual(phase(agent, evidence), .connected, agent.rawValue)
        }
    }

    func testExplicitRevocationAndFailureOverridePreviouslyAcceptedEvents() {
        var evidence = IntegrationSetupEvidence(installed: true, configured: true,
                                               configurationFingerprint: current, authorization: .granted,
                                               authorizationFingerprint: current, observedFingerprint: current)
        XCTAssertEqual(phase(.codex, evidence), .connected)
        evidence.authorization = .required
        XCTAssertEqual(phase(.codex, evidence), .needsAuthorization)
        evidence.authorization = .failed
        XCTAssertEqual(phase(.codex, evidence), .needsAuthorization)
    }

    func testGrantedAuthorizationOnlyAppliesToTheSameDefinition() {
        var evidence = IntegrationSetupEvidence(installed: true, configured: true,
                                               configurationFingerprint: current, authorization: .granted,
                                               authorizationFingerprint: current)
        XCTAssertEqual(phase(.codex, evidence), .waitingForActivity)
        evidence.authorizationFingerprint = previous
        XCTAssertEqual(phase(.codex, evidence), .needsAuthorization)
        evidence.authorizationFingerprint = nil
        XCTAssertEqual(phase(.codex, evidence), .needsAuthorization)
        evidence.configurationFingerprint = nil
        XCTAssertEqual(phase(.codex, evidence), .needsAuthorization)
    }

    func testChangedConfigurationInvalidatesOldEventAndGrant() {
        var evidence = IntegrationSetupEvidence(installed: true, configured: true,
                                               configurationFingerprint: current, authorization: .granted,
                                               authorizationFingerprint: previous, observedFingerprint: previous)
        XCTAssertEqual(phase(.codex, evidence), .needsAuthorization)
        evidence.observedFingerprint = current
        XCTAssertEqual(phase(.codex, evidence), .connected)
    }

    func testMissingAndEmptyFingerprintsCannotProveAConnection() {
        for fingerprint in [nil, "", "   "] as [String?] {
            let evidence = IntegrationSetupEvidence(installed: true, configured: true,
                                                   configurationFingerprint: fingerprint,
                                                   observedFingerprint: fingerprint)
            XCTAssertEqual(phase(.claudeCode, evidence), .waitingForActivity)
        }
    }

    func testStaleActivityDoesNotConfirmTheCurrentDefinition() {
        let evidence = IntegrationSetupEvidence(installed: true, configured: true,
                                               configurationFingerprint: current, observedFingerprint: previous)
        XCTAssertEqual(phase(.claudeCode, evidence), .waitingForActivity)
    }

    func testMissingAutomaticConfigurationOverridesAnOldAcceptedEvent() {
        let evidence = IntegrationSetupEvidence(installed: true, configured: false,
                                               configurationFingerprint: current, observedFingerprint: current)
        XCTAssertEqual(phase(.claudeCode, evidence), .needsConfiguration)
        XCTAssertEqual(phase(.aider, evidence), .needsConfiguration)
    }

    func testCheckFailureCannotBeHiddenByAPreviousEvent() {
        let evidence = IntegrationSetupEvidence(installed: true, configured: true,
                                               configurationFingerprint: current, observedFingerprint: current,
                                               checkFailed: true)
        XCTAssertEqual(phase(.claudeCode, evidence), .checkFailed)
    }

    func testAiderNeedsItsExplicitLauncherAfterAutomaticPreparation() {
        var evidence = IntegrationSetupEvidence(installed: true, configurationFingerprint: current)
        XCTAssertEqual(phase(.aider, evidence), .needsConfiguration)
        evidence.configured = true
        XCTAssertEqual(phase(.aider, evidence), .needsSetup)
        evidence.observedFingerprint = current
        XCTAssertEqual(phase(.aider, evidence), .connected)
    }

    func testGLMAndUnsupportedHermesNeverBecomeIndependentConnections() {
        let evidence = IntegrationSetupEvidence(installed: true, configured: true,
                                               configurationFingerprint: current, authorization: .granted,
                                               authorizationFingerprint: current, observedFingerprint: current)
        XCTAssertEqual(phase(.glm, evidence), .needsSetup)
        XCTAssertEqual(phase(.hermes, evidence), .needsSetup)
    }

    func testReminderStaysQuietForUnavailableDisabledConnectedAndWaitingSources() {
        for state in [IntegrationSetupPhase.notInstalled, .disabled, .connected, .waitingForActivity] {
            XCTAssertFalse(IntegrationSetupReminderPolicy.shouldPrompt(agent: .codex, phase: state,
                                                                      fingerprint: current, lastPrompted: [:]))
        }
        for agent in [AgentType.glm, .hermes] {
            XCTAssertFalse(IntegrationSetupReminderPolicy.shouldPrompt(agent: agent, phase: .needsSetup,
                                                                      fingerprint: current, lastPrompted: [:]))
        }
    }

    func testReminderOccursOncePerDefinitionAndReturnsWhenDefinitionChanges() {
        for state in [IntegrationSetupPhase.needsConfiguration, .needsAuthorization, .needsSetup, .checkFailed] {
            XCTAssertTrue(IntegrationSetupReminderPolicy.shouldPrompt(agent: .codex, phase: state,
                                                                     fingerprint: current, lastPrompted: [:]))
            XCTAssertFalse(IntegrationSetupReminderPolicy.shouldPrompt(agent: .codex, phase: state,
                                                                      fingerprint: current,
                                                                      lastPrompted: [AgentType.codex.rawValue: "\(state.rawValue):\(current)"]))
            XCTAssertTrue(IntegrationSetupReminderPolicy.shouldPrompt(agent: .codex, phase: state,
                                                                     fingerprint: current,
                                                                     lastPrompted: [AgentType.codex.rawValue: "\(state.rawValue):\(previous)"]))
        }
    }

    func testMissingFingerprintUsesStablePhaseTokenAcrossLaunches() {
        let token = IntegrationSetupReminderPolicy.reminderToken(phase: .checkFailed, fingerprint: nil)
        XCTAssertEqual(token, "checkFailed:unconfigured")
        XCTAssertTrue(IntegrationSetupReminderPolicy.shouldPrompt(agent: .codex, phase: .checkFailed,
                                                                 fingerprint: nil, lastPrompted: [:]))
        XCTAssertFalse(IntegrationSetupReminderPolicy.shouldPrompt(agent: .codex, phase: .checkFailed,
                                                                  fingerprint: nil,
                                                                  lastPrompted: [AgentType.codex.rawValue: token]))
        XCTAssertEqual(IntegrationSetupReminderPolicy.reminderToken(phase: .checkFailed, fingerprint: "  "), token)
    }

    func testOneAgentReminderDoesNotSuppressAnotherAgent() {
        XCTAssertTrue(IntegrationSetupReminderPolicy.shouldPrompt(agent: .workBuddy, phase: .needsSetup,
                                                                 fingerprint: current,
                                                                 lastPrompted: [AgentType.codex.rawValue: current]))
    }

    func testFirstConfigurationReminderDoesNotNeedAnExistingFingerprint() {
        let state = IntegrationSetupPhase.needsConfiguration
        XCTAssertTrue(IntegrationSetupReminderPolicy.shouldPrompt(agent: .claudeCode, phase: state,
                                                                 fingerprint: nil, lastPrompted: [:]))
        let dismissed = IntegrationSetupReminderPolicy.reminderToken(phase: state, fingerprint: nil)
        XCTAssertFalse(IntegrationSetupReminderPolicy.shouldPrompt(agent: .claudeCode, phase: state,
                                                                  fingerprint: nil,
                                                                  lastPrompted: [AgentType.claudeCode.rawValue: dismissed]))
    }

    func testNewAuthorizationStepCanPromptAfterConfigurationWasDismissed() {
        let dismissed = IntegrationSetupReminderPolicy.reminderToken(phase: .needsConfiguration, fingerprint: current)
        XCTAssertTrue(IntegrationSetupReminderPolicy.shouldPrompt(agent: .codex, phase: .needsAuthorization,
                                                                 fingerprint: current,
                                                                 lastPrompted: [AgentType.codex.rawValue: dismissed]))
    }
}
