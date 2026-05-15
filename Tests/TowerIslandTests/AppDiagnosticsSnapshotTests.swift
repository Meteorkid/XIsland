import XCTest
@testable import XIsland

@MainActor
final class AppDiagnosticsSnapshotTests: XCTestCase {
    func testSnapshotIncludesSelectedSessionAndInteractionType() {
        let sessionManager = SessionManager()
        let updateManager = UpdateManager()
        let session = AgentSession(
            id: "fixture-session",
            agentType: .claudeCode,
            workingDirectory: "/tmp/demo",
            prompt: "Ship it"
        )
        session.status = .waitingAnswer
        session.pendingQuestion = PendingQuestion(
            requestingAgent: .claudeCode,
            text: "Continue?",
            options: ["yes", "no"],
            respond: { _ in },
            cancel: nil
        )
        sessionManager.sessions = [session]
        sessionManager.selectedSessionId = session.id

        let snapshot = AppDiagnosticsSnapshot.make(
            sessionManager: sessionManager,
            updateManager: updateManager,
            islandState: "question"
        )

        XCTAssertEqual(snapshot.islandState, "question")
        XCTAssertEqual(snapshot.selectedSessionId, "fixture-session")
        XCTAssertEqual(snapshot.pendingInteraction, "question")
        XCTAssertEqual(snapshot.visibleSessions.first?.id, "fixture-session")
        XCTAssertEqual(snapshot.visibleSessions.first?.status, "waitingAnswer")
        XCTAssertEqual(snapshot.visibleSessions.first?.workingDirectory, "/tmp/demo")
        XCTAssertEqual(snapshot.visibleAccessibilityIdentifiers, [
            TestAccessibility.islandRoot,
            TestAccessibility.questionPanel,
            TestAccessibility.questionOption(index: 0),
            TestAccessibility.questionOption(index: 1),
        ])
    }

    func testSnapshotIncludesUpdateDiagnostics() {
        let sessionManager = SessionManager()
        let updateManager = UpdateManager()
        let release = UpdateManager.ReleaseInfo(
            tagName: "v1.2.9",
            htmlURL: URL(string: "https://example.com/release")!,
            publishedAt: ISO8601DateFormatter().date(from: "2026-04-15T08:00:00Z")!,
            assets: [
                .init(
                    name: "XIsland-1.2.9.dmg",
                    browserDownloadURL: URL(string: "https://example.com/XIsland-1.2.9.dmg")!
                )
            ]
        )
        updateManager.latestRelease = release
        updateManager.state = .updateAvailable(version: "1.2.9")

        let snapshot = AppDiagnosticsSnapshot.make(
            sessionManager: sessionManager,
            updateManager: updateManager,
            islandState: "collapsed"
        )

        XCTAssertEqual(snapshot.update.state, "updateAvailable")
        XCTAssertEqual(snapshot.update.version, "1.2.9")
        XCTAssertEqual(snapshot.update.dmgURL, "https://example.com/XIsland-1.2.9.dmg")
        XCTAssertEqual(snapshot.visibleAccessibilityIdentifiers, [
            TestAccessibility.collapsedPill,
        ])
    }

    func testSnapshotIncludesPreferencesAccessibilityIdentifiersWhenPreferencesVisible() {
        let sessionManager = SessionManager()
        let updateManager = UpdateManager()
        let release = UpdateManager.ReleaseInfo(
            tagName: "v1.2.9",
            htmlURL: URL(string: "https://example.com/release")!,
            publishedAt: ISO8601DateFormatter().date(from: "2026-04-15T08:00:00Z")!,
            assets: [
                .init(
                    name: "XIsland-1.2.9.dmg",
                    browserDownloadURL: URL(string: "https://example.com/XIsland-1.2.9.dmg")!
                )
            ]
        )
        updateManager.latestRelease = release
        updateManager.state = .updateAvailable(version: "1.2.9")

        let snapshot = AppDiagnosticsSnapshot.make(
            sessionManager: sessionManager,
            updateManager: updateManager,
            islandState: "collapsed",
            preferencesVisible: true
        )

        XCTAssertEqual(snapshot.visibleAccessibilityIdentifiers, [
            TestAccessibility.collapsedPill,
            TestAccessibility.preferencesRoot,
            TestAccessibility.updateStatusLabel,
            TestAccessibility.updateCheckButton,
            TestAccessibility.updateInstallButton,
        ])
    }
}
