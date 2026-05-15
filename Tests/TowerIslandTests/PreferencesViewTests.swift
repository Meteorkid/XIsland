import XCTest
@testable import XIsland

final class PreferencesViewTests: XCTestCase {
    func testAccessibilityIdentifiersRemainStable() {
        XCTAssertEqual(TestAccessibility.islandRoot, "island.root")
        XCTAssertEqual(TestAccessibility.collapsedPill, "island.collapsed-pill")
        XCTAssertEqual(TestAccessibility.sessionList, "island.session-list")
        XCTAssertEqual(TestAccessibility.permissionPanel, "island.permission-panel")
        XCTAssertEqual(TestAccessibility.permissionApproveButton, "island.permission-approve")
        XCTAssertEqual(TestAccessibility.permissionDenyButton, "island.permission-deny")
        XCTAssertEqual(TestAccessibility.questionPanel, "island.question-panel")
        XCTAssertEqual(TestAccessibility.planPanel, "island.plan-panel")
        XCTAssertEqual(TestAccessibility.planApproveButton, "island.plan-approve")
        XCTAssertEqual(TestAccessibility.planRejectButton, "island.plan-reject")
        XCTAssertEqual(TestAccessibility.planFeedbackField, "island.plan-feedback")
        XCTAssertEqual(TestAccessibility.preferencesRoot, "preferences.root")
        XCTAssertEqual(TestAccessibility.updateCheckButton, "preferences.update-check")
        XCTAssertEqual(TestAccessibility.updateInstallButton, "preferences.update-install")
        XCTAssertEqual(TestAccessibility.updateStatusLabel, "preferences.update-status")
    }

    func testAccessibilityIdentifierBuildersRemainStable() {
        XCTAssertEqual(TestAccessibility.sessionCard(id: "session-123"), "island.session-card.session-123")
        XCTAssertEqual(TestAccessibility.questionOption(index: 2), "island.question-option.2")
    }

    func testInstallButtonHiddenWhenReleaseIsNotNewer() {
        XCTAssertFalse(
            PreferencesView.shouldShowInstallButton(
                state: .upToDate,
                latestRelease: release(version: "1.2.3")
            )
        )
    }

    func testInstallButtonShownWhenNewerReleaseIsAvailable() {
        XCTAssertTrue(
            PreferencesView.shouldShowInstallButton(
                state: .updateAvailable(version: "1.2.4"),
                latestRelease: release(version: "1.2.4")
            )
        )
    }

    private func release(version: String) -> UpdateManager.ReleaseInfo {
        UpdateManager.ReleaseInfo(
            tagName: "v\(version)",
            htmlURL: URL(string: "https://example.com/release")!,
            publishedAt: ISO8601DateFormatter().date(from: "2026-04-15T00:00:00Z")!,
            assets: [
                .init(
                    name: "XIsland-\(version).dmg",
                    browserDownloadURL: URL(string: "https://example.com/XIsland-\(version).dmg")!
                )
            ]
        )
    }
}
