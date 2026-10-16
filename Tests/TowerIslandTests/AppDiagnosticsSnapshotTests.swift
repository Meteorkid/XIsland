import XCTest
@testable import XIsland

@MainActor
final class AppDiagnosticsSnapshotTests: XCTestCase {
    func testWaitingStatusWithoutPendingObjectsDoesNotReportInteraction() {
        let manager = SessionManager(), update = UpdateManager()
        let session = AgentSession(id: "observed-waiting", agentType: .kimi)
        manager.sessions = [session]
        manager.selectedSessionId = session.id
        for status in [SessionStatus.waitingPermission, .waitingAnswer, .waitingPlanReview] {
            session.status = status
            let snapshot = AppDiagnosticsSnapshot.make(sessionManager: manager, updateManager: update, islandState: "collapsed")
            XCTAssertNil(snapshot.pendingInteraction)
            XCTAssertNil(snapshot.visibleSessions.first?.pendingInteraction)
            XCTAssertEqual(snapshot.visibleSessions.first?.status, status.rawValue)
        }
    }

    func testRealPendingObjectsDetermineDiagnosticsInteractionKind() {
        let manager = SessionManager(), update = UpdateManager()
        let session = AgentSession(id: "real-pending", agentType: .claudeCode)
        manager.sessions = [session]
        manager.selectedSessionId = session.id
        session.pendingPermission = PendingPermission(requestingAgent: .claudeCode, tool: "Bash", description: "Run", diff: nil,
            filePath: nil, respond: { _ in })
        XCTAssertEqual(AppDiagnosticsSnapshot.make(sessionManager: manager, updateManager: update, islandState: "expanded").pendingInteraction, "permission")
        session.pendingPermission = nil
        session.pendingQuestion = PendingQuestion(requestingAgent: .claudeCode, text: "Continue?", options: ["Yes"], respond: { _ in }, cancel: nil)
        XCTAssertEqual(AppDiagnosticsSnapshot.make(sessionManager: manager, updateManager: update, islandState: "expanded").pendingInteraction, "question")
        session.pendingQuestion = nil
        session.pendingPlanReview = PendingPlanReview(requestingAgent: .claudeCode, markdown: "Plan", respond: { _, _ in })
        XCTAssertEqual(AppDiagnosticsSnapshot.make(sessionManager: manager, updateManager: update, islandState: "expanded").pendingInteraction, "planReview")
    }

    func testCustomInputIdentifiersAreExplicitAndRequestScoped() {
        let manager = SessionManager(), update = UpdateManager()
        let session = AgentSession(id: "custom-fixture", agentType: .openCode)
        session.status = .waitingAnswer
        session.pendingQuestion = PendingQuestion(requestingAgent: .openCode, text: "Path?", options: [],
            respond: { _ in }, cancel: nil, allowsCustomAnswer: true)
        manager.sessions = [session]
        manager.selectedSessionId = session.id
        let question = session.pendingQuestion!
        let snapshot = AppDiagnosticsSnapshot.make(sessionManager: manager, updateManager: update, islandState: "question")
        for base in [TestAccessibility.customAnswerField, TestAccessibility.customAnswerSubmit] {
            XCTAssertTrue(snapshot.visibleAccessibilityIdentifiers.contains(TestAccessibility.interactionControl(base, sessionID: session.id, requestID: question.id)))
        }
        session.pendingQuestion?.allowsCustomAnswer = false
        let disabled = AppDiagnosticsSnapshot.make(sessionManager: manager, updateManager: update, islandState: "question")
        XCTAssertFalse(disabled.visibleAccessibilityIdentifiers.contains { $0.contains("question-custom") })
    }

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
            TestAccessibility.sessionList,
            TestAccessibility.interactionControl(TestAccessibility.questionPanel, sessionID: session.id, requestID: session.pendingQuestion!.id),
            TestAccessibility.interactionControl(TestAccessibility.questionOption(index: 0), sessionID: session.id, requestID: session.pendingQuestion!.id),
            TestAccessibility.interactionControl(TestAccessibility.questionOption(index: 1), sessionID: session.id, requestID: session.pendingQuestion!.id),
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
