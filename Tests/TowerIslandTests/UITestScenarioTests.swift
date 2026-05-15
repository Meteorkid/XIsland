import XCTest
@testable import XIslandUITestDriver

final class UITestScenarioTests: XCTestCase {
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
