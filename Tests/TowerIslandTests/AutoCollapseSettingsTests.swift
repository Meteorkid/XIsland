import XCTest
@testable import XIsland

final class AutoCollapseSettingsTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults, String) -> Void) throws {
        let suite = "dev.xisland.tests.collapse-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, suite)
    }

    func testNewInstallDefaultsToEnabledAndThreeSeconds() throws {
        try withDefaults { defaults, suite in
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            XCTAssertTrue(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
            XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 3)
        }
    }

    func testReportedZeroPrimaryAndFiveSecondExitBecomesImmediate() throws {
        try withDefaults { defaults, suite in
            defaults.set(0.0, forKey: "autoCollapseDelay")
            defaults.set(5.0, forKey: "expandedInactivityAutoHideDelay")
            defaults.set(0.15, forKey: "hoverExitCollapseDelay")
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            XCTAssertTrue(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
            XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 0)
            XCTAssertEqual(defaults.double(forKey: "expandedInactivityAutoHideDelay"), 5)
            XCTAssertEqual(defaults.double(forKey: "hoverExitCollapseDelay"), 0.15)
        }
    }

    func testExplicitLegacyExitDisableStaysOffDespiteOtherActiveDelays() throws {
        try withDefaults { defaults, suite in
            defaults.set(0.0, forKey: "expandedInactivityAutoHideDelay")
            defaults.set(2.0, forKey: "autoCollapseDelay")
            defaults.set(0.5, forKey: "hoverExitCollapseDelay")
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            XCTAssertFalse(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
            XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 2)
        }
    }

    func testAllLegacyZeroRemainsOffButZeroIsAvailableWhenEnabledLater() throws {
        try withDefaults { defaults, suite in
            for key in ["autoCollapseDelay", "expandedInactivityAutoHideDelay", "hoverExitCollapseDelay"] {
                defaults.set(0.0, forKey: key)
            }
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            XCTAssertFalse(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
            XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 0)
            defaults.set(true, forKey: AutoCollapseSettings.enabledKey)
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            XCTAssertTrue(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
        }
    }

    func testExistingNewSettingsAreNeverOverwrittenByLegacyValues() throws {
        try withDefaults { defaults, suite in
            defaults.set(0.0, forKey: "autoCollapseDelay")
            defaults.set(0.0, forKey: "expandedInactivityAutoHideDelay")
            defaults.set(true, forKey: AutoCollapseSettings.enabledKey)
            defaults.set(7.25, forKey: AutoCollapseSettings.delayKey)
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            XCTAssertTrue(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
            XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 7.25)
        }
    }

    func testMissingPrimaryFallsBackToSavedNormalExitDelay() throws {
        try withDefaults { defaults, suite in
            defaults.set(5.0, forKey: "expandedInactivityAutoHideDelay")
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            XCTAssertTrue(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
            XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 5)
        }
    }

    func testRegisteredDefaultsAreNotMistakenForSavedUserChoices() throws {
        try withDefaults { defaults, suite in
            let registration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
            defer { defaults.setVolatileDomain(registration, forName: UserDefaults.registrationDomain) }
            defaults.register(defaults: [AutoCollapseSettings.enabledKey: true,
                                        AutoCollapseSettings.delayKey: 3.0])
            defaults.set(0.0, forKey: "autoCollapseDelay")
            defaults.set(0.0, forKey: "expandedInactivityAutoHideDelay")
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            XCTAssertFalse(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
            XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 0)
        }
    }

    @MainActor
    func testObservedWaitingProtectsPanelWithoutInventingLocalApproval() {
        let manager = SessionManager()
        let session = AgentSession(id: "observed-waiting-collapse", agentType: .kimi)
        manager.sessions = [session]
        for status in [SessionStatus.waitingPermission, .waitingAnswer, .waitingPlanReview] {
            session.status = status
            XCTAssertFalse(manager.hasInteraction)
            XCTAssertTrue(manager.protectsInteraction)
            XCTAssertNil(ExpandedAutoCollapsePolicy.delay(state: .expanded,
                protectsInteraction: manager.protectsInteraction, isEnabled: true, configuredDelay: 0))
        }
        for status in [SessionStatus.active, .idle, .completed, .observationUnavailable] {
            session.status = status
            XCTAssertFalse(manager.protectsInteraction)
        }
    }

    func testPartialNewConfigurationPreservesSavedToggleOrDelay() throws {
        try withDefaults { defaults, suite in
            defaults.set(false, forKey: AutoCollapseSettings.enabledKey)
            defaults.set(0.0, forKey: "autoCollapseDelay")
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            XCTAssertFalse(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
            XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 0)
        }
        try withDefaults { defaults, suite in
            defaults.set(0.0, forKey: AutoCollapseSettings.delayKey)
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            XCTAssertTrue(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
            XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 0)
        }
    }

    func testInvalidDelaysCannotBecomeImmediateByCoercionAndOversizeIsClamped() throws {
        for invalid: Any in [true, "0", Double.nan, Double.infinity, -1.0] {
            try withDefaults { defaults, suite in
                defaults.set(invalid, forKey: "autoCollapseDelay")
                defaults.set(invalid, forKey: AutoCollapseSettings.delayKey)
                AutoCollapseSettings.migrate(defaults, domainName: suite)
                XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 3)
            }
        }
        try withDefaults { defaults, suite in
            defaults.set(10_000.0, forKey: AutoCollapseSettings.delayKey)
            AutoCollapseSettings.migrate(defaults, domainName: suite)
            XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 600)
        }
    }
}
