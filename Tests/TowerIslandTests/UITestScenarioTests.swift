import XCTest
@testable import XIslandUITestDriver

final class UITestScenarioTests: XCTestCase {
    func testInlineInteractionResolvesOnlyTheSelectedSessionRequest() throws {
        let requestID = UUID().uuidString
        let expected = "island.plan-approve.session-a.\(requestID)"
        let snapshot = diagnostics(identifiers: [
            "island.plan-approve.session-b.\(UUID().uuidString)",
            expected,
        ])

        XCTAssertTrue(snapshot.containsIdentifier(UITestAccessibility.planApproveButton))
        XCTAssertEqual(
            try snapshot.resolvedIdentifier(UITestAccessibility.planApproveButton, requiringScopedInteraction: true),
            expected
        )
    }

    func testInlineActionRejectsMissingAmbiguousOrMalformedRequestIdentifiers() {
        let base = UITestAccessibility.planApproveButton
        for identifiers in [
            [base],
            ["\(base).session-b.\(UUID().uuidString)"],
            ["\(base).session-a.invalid-request"],
            ["\(base).session-a.\(UUID().uuidString)", "\(base).session-a.\(UUID().uuidString)"],
        ] {
            XCTAssertThrowsError(try diagnostics(identifiers: identifiers).resolvedIdentifier(
                base, requiringScopedInteraction: true
            ))
        }
    }

    func testRequiredIdentifiersAllowExactLegacyPresenceButActionsRequireInlineScope() throws {
        let base = UITestAccessibility.questionOption(index: 0)
        let snapshot = diagnostics(identifiers: [base])
        XCTAssertTrue(snapshot.containsIdentifier(base))
        XCTAssertEqual(try snapshot.resolvedIdentifier(base), base)
        XCTAssertThrowsError(try snapshot.resolvedIdentifier(base, requiringScopedInteraction: true))
    }

    func testStaticIdentifiersRequireAnExactMatch() throws {
        for identifier in [UITestAccessibility.updateCheckButton, UITestAccessibility.sessionCard(id: "session-a")] {
            let mismatched = diagnostics(identifiers: ["\(identifier).extra"])
            XCTAssertFalse(mismatched.containsIdentifier(identifier))
            XCTAssertThrowsError(try mismatched.resolvedIdentifier(identifier))
            XCTAssertEqual(try diagnostics(identifiers: [identifier]).resolvedIdentifier(identifier), identifier)
        }
    }

    func testInlineInteractionDoesNotGuessWhenNoSessionIsSelected() {
        let snapshot = diagnostics(
            selectedSessionID: nil,
            identifiers: ["island.plan-approve.session-a.\(UUID().uuidString)"]
        )
        XCTAssertThrowsError(try snapshot.resolvedIdentifier(
            UITestAccessibility.planApproveButton, requiringScopedInteraction: true
        ))
    }

    private func diagnostics(
        selectedSessionID: String? = "session-a",
        identifiers: [String]
    ) -> UITestDiagnosticsSnapshot {
        UITestDiagnosticsSnapshot(
            islandState: "planReview",
            selectedSessionId: selectedSessionID,
            pendingInteraction: "planReview",
            visibleSessions: [],
            visibleAccessibilityIdentifiers: identifiers,
            update: .init(state: "idle", version: nil, dmgURL: nil)
        )
    }

    func testLaunchRequestsUseSeparateRuntimeDirectoriesAndPreferenceDomains() throws {
        let runner = UITestScenarioRunner(appBundlePath: "/tmp/X Island.app", timeout: 15)
        let scenario = try UITestScenario.named("permission-smoke")
        let first = runner.makeLaunchRequest(
            for: scenario,
            diagnosticsURL: URL(fileURLWithPath: "/tmp/xi-ui-first/diagnostics.json")
        )
        let second = runner.makeLaunchRequest(
            for: scenario,
            diagnosticsURL: URL(fileURLWithPath: "/tmp/xi-ui-second/diagnostics.json")
        )

        XCTAssertEqual(first.environment["X_ISLAND_TEST_RUNTIME_DIR"], "/tmp/xi-ui-first")
        XCTAssertEqual(second.environment["X_ISLAND_TEST_RUNTIME_DIR"], "/tmp/xi-ui-second")
        XCTAssertNotNil(first.environment["X_ISLAND_TEST_DEFAULTS_SUITE"])
        XCTAssertNotEqual(
            first.environment["X_ISLAND_TEST_DEFAULTS_SUITE"],
            second.environment["X_ISLAND_TEST_DEFAULTS_SUITE"]
        )
    }

    func testSmokeSelectionUsesApprovedSmokeScenarios() throws {
        let selection = try UITestRunSelection.make(arguments: ["smoke"])

        XCTAssertEqual(selection.scenarios.map(\ .name), [
            "permission-smoke",
            "question-smoke",
            "plan-smoke",
            "preferences-update"
        ])
    }

    func testFullSelectionIncludesSessionList() throws {
        let selection = try UITestRunSelection.make(arguments: ["full"])

        XCTAssertEqual(selection.scenarios.map(\ .name), [
            "permission-smoke",
            "question-smoke",
            "plan-smoke",
            "preferences-update",
            "session-list"
        ])
    }

    func testPreferencesUpdateScenarioUsesUpdateFixtureAndPreferencesWindow() throws {
        let scenario = try UITestScenario.named("preferences-update")

        XCTAssertEqual(scenario.fixtureName, "update-available")
        XCTAssertTrue(scenario.opensPreferencesOnLaunch)
        XCTAssertEqual(scenario.requiredIdentifiers, [
            UITestAccessibility.preferencesRoot,
            UITestAccessibility.updateStatusLabel,
            UITestAccessibility.updateCheckButton,
            UITestAccessibility.updateInstallButton,
        ])
    }

    func testInteractionSmokeScenariosRequireVisiblePanelsAndControls() throws {
        let permission = try UITestScenario.named("permission-smoke")
        XCTAssertEqual(permission.requiredIdentifiers, [
            UITestAccessibility.permissionApproveButton,
        ])

        let question = try UITestScenario.named("question-smoke")
        XCTAssertEqual(question.requiredIdentifiers, [
            UITestAccessibility.questionPanel,
            UITestAccessibility.questionOption(index: 0),
        ])

        let plan = try UITestScenario.named("plan-smoke")
        XCTAssertEqual(plan.requiredIdentifiers, [
            UITestAccessibility.planPanel,
            UITestAccessibility.planDetailsButton,
            UITestAccessibility.planApproveButton,
        ])
    }

    func testPreferencesUpdateScenarioRequiresVisibleUpdateControls() throws {
        let scenario = try UITestScenario.named("preferences-update")

        XCTAssertEqual(scenario.requiredIdentifiers, [
            UITestAccessibility.preferencesRoot,
            UITestAccessibility.updateStatusLabel,
            UITestAccessibility.updateCheckButton,
            UITestAccessibility.updateInstallButton,
        ])
    }

    func testLaunchRequestUsesAppBundlePathAndScenarioEnvironment() throws {
        let runner = UITestScenarioRunner(
            appBundlePath: "/tmp/X Island.app",
            timeout: 15
        )
        let scenario = try UITestScenario.named("preferences-update")
        let diagnosticsURL = URL(fileURLWithPath: "/tmp/tower-island-diagnostics.json")

        let request = runner.makeLaunchRequest(for: scenario, diagnosticsURL: diagnosticsURL)

        XCTAssertEqual(request.bundleURL.path, "/tmp/X Island.app")
        XCTAssertEqual(request.arguments, [
            "--ui-test-mode",
            "--fixture", "update-available",
            "--open-preferences",
        ])
        XCTAssertEqual(request.environment["X_ISLAND_TEST_MODE"], "1")
        XCTAssertEqual(request.environment["X_ISLAND_TEST_FIXTURE"], "update-available")
        XCTAssertEqual(request.environment["X_ISLAND_TEST_DIAGNOSTICS_PATH"], diagnosticsURL.path)
        XCTAssertEqual(request.environment["X_ISLAND_DISABLE_ANIMATIONS"], "1")
        XCTAssertEqual(request.environment["X_ISLAND_TEST_OPEN_PREFERENCES"], "1")
    }
}
