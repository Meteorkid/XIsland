import AppKit
import XCTest
@testable import XIsland

@MainActor
final class AppDiagnosticsRefreshTests: XCTestCase {
    func testAppTerminationRefreshesDiagnosticsAfterCompletingDesktopSession() throws {
        let context = try makeDiagnosticsContext()
        let session = AgentSession(id: "cursor-session", agentType: .cursor, workingDirectory: "/tmp/project")
        context.appDelegate.sessionManager.sessions = [session]
        context.appDelegate.sessionManager.selectedSessionId = session.id
        context.appDelegate.refreshDiagnostics(islandState: context.appDelegate.sessionManager.diagnosticsIslandState)

        context.appDelegate.sessionManager.handleAppTerminated(bundleId: "com.todesktop.230313mzl4w4u92")

        let snapshot = try loadSnapshot(from: context.diagnosticsURL)
        XCTAssertNil(snapshot.selectedSessionId)
        XCTAssertEqual(snapshot.visibleSessions.map(\.status), ["completed"])
    }

    func testStaleSessionCleanupRefreshesDiagnosticsAfterCompletion() throws {
        let context = try makeDiagnosticsContext()
        let session = AgentSession(id: "claude-session", agentType: .claudeCode, workingDirectory: "/tmp/project")
        session.lastActivityTime = Date(timeIntervalSinceNow: -(SessionManager.idleTimeout + 10))
        context.appDelegate.sessionManager.sessions = [session]
        context.appDelegate.sessionManager.selectedSessionId = session.id
        context.appDelegate.refreshDiagnostics(islandState: context.appDelegate.sessionManager.diagnosticsIslandState)

        context.appDelegate.sessionManager.cleanupStaleSessions()

        let snapshot = try loadSnapshot(from: context.diagnosticsURL)
        XCTAssertNil(snapshot.selectedSessionId)
        XCTAssertEqual(snapshot.visibleSessions.map(\.status), ["completed"])
    }

    func testLingerCleanupRefreshesDiagnosticsAfterRemovingExpiredSession() throws {
        let context = try makeDiagnosticsContext()
        let session = AgentSession(id: "completed-session", agentType: .claudeCode, workingDirectory: "/tmp/project")
        session.status = .completed
        session.completedAt = Date(timeIntervalSinceNow: -200)
        context.appDelegate.sessionManager.sessions = [session]
        context.appDelegate.refreshDiagnostics(islandState: context.appDelegate.sessionManager.diagnosticsIslandState)

        context.appDelegate.sessionManager.cleanupLingeredSessions()

        let snapshot = try loadSnapshot(from: context.diagnosticsURL)
        XCTAssertTrue(snapshot.visibleSessions.isEmpty)
    }

    func testProcessCheckRefreshesDiagnosticsAfterCompletingDeadCliSession() async throws {
        let context = try makeDiagnosticsContext()
        let session = AgentSession(id: "claude-session", agentType: .claudeCode, workingDirectory: "/tmp/project")
        context.appDelegate.sessionManager.sessions = [session]
        context.appDelegate.sessionManager.selectedSessionId = session.id
        context.appDelegate.refreshDiagnostics(islandState: context.appDelegate.sessionManager.diagnosticsIslandState)

        context.appDelegate.sessionManager.checkProcessesAlive(processStatus: { _ in false })

        let snapshot = try loadSnapshot(from: context.diagnosticsURL)
        XCTAssertNil(snapshot.selectedSessionId)
        XCTAssertEqual(snapshot.visibleSessions.map(\.status), ["completed"])
    }

    func testDiagnosticsRefreshUsesPrioritizedWaitingInteractionState() throws {
        let context = try makeDiagnosticsContext()

        let active = AgentSession(id: "selected-active", agentType: .claudeCode, workingDirectory: "/tmp/project")
        active.status = .active

        let waiting = AgentSession(id: "waiting-question", agentType: .codex, workingDirectory: "/tmp/project")
        waiting.status = .waitingAnswer
        waiting.pendingQuestion = PendingQuestion(
            requestingAgent: .codex,
            text: "Continue?",
            options: ["yes", "no"],
            respond: { _ in },
            cancel: nil
        )

        context.appDelegate.sessionManager.sessions = [active, waiting]
        context.appDelegate.sessionManager.selectedSessionId = active.id

        context.appDelegate.refreshDiagnostics(islandState: context.appDelegate.sessionManager.diagnosticsIslandState)

        let snapshot = try loadSnapshot(from: context.diagnosticsURL)
        XCTAssertEqual(snapshot.islandState, "question")
        XCTAssertEqual(snapshot.pendingInteraction, "question")
    }

    func testDiagnosticsRefreshKeepsCollapsedStateForVisibleNonInteractiveSession() throws {
        let context = try makeDiagnosticsContext()

        let session = AgentSession(id: "active-session", agentType: .claudeCode, workingDirectory: "/tmp/project")
        session.status = .active

        context.appDelegate.sessionManager.sessions = [session]
        context.appDelegate.sessionManager.selectedSessionId = session.id

        context.appDelegate.refreshDiagnostics(islandState: context.appDelegate.sessionManager.diagnosticsIslandState)

        let snapshot = try loadSnapshot(from: context.diagnosticsURL)
        XCTAssertEqual(snapshot.islandState, "collapsed")
    }

    func testIslandStateTransitionRefreshesDiagnosticsForManualExpandCollapse() throws {
        let context = try makeDiagnosticsContext()

        let session = AgentSession(id: "active-session", agentType: .claudeCode, workingDirectory: "/tmp/project")
        session.status = .active

        context.appDelegate.sessionManager.sessions = [session]
        context.appDelegate.sessionManager.selectedSessionId = session.id

        NotchContentView.handleIslandStateChange(.expanded, manager: context.appDelegate.sessionManager)

        var snapshot = try loadSnapshot(from: context.diagnosticsURL)
        XCTAssertEqual(snapshot.islandState, "expanded")

        NotchContentView.handleIslandStateChange(.collapsed, manager: context.appDelegate.sessionManager)

        snapshot = try loadSnapshot(from: context.diagnosticsURL)
        XCTAssertEqual(snapshot.islandState, "collapsed")
    }

    func testIslandStateTransitionRefreshesDiagnosticsForInteractionState() throws {
        let context = try makeDiagnosticsContext()

        let waiting = AgentSession(id: "waiting-question", agentType: .codex, workingDirectory: "/tmp/project")
        waiting.status = .waitingAnswer
        waiting.pendingQuestion = PendingQuestion(
            requestingAgent: .codex,
            text: "Continue?",
            options: ["yes", "no"],
            respond: { _ in },
            cancel: nil
        )

        context.appDelegate.sessionManager.sessions = [waiting]
        context.appDelegate.sessionManager.selectedSessionId = waiting.id

        NotchContentView.handleIslandStateChange(.question(waiting.id), manager: context.appDelegate.sessionManager)

        let snapshot = try loadSnapshot(from: context.diagnosticsURL)
        XCTAssertEqual(snapshot.islandState, "question")
        XCTAssertEqual(snapshot.pendingInteraction, "question")
    }

    private func makeDiagnosticsContext(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (appDelegate: AppDelegate, diagnosticsURL: URL) {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        addTeardownBlock {
            NSApp.setActivationPolicy(previousPolicy)
        }

        let diagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("diagnostics.json")

        let appDelegate = AppDelegate(
            testConfiguration: AppTestConfiguration(
                isEnabled: true,
                fixtureName: nil,
                fixturePath: nil,
                diagnosticsPath: diagnosticsURL.path,
                disableAnimations: false
            ),
            launchHooks: AppDelegate.LaunchHooks(
                performInitialStartup: { _ in },
                performProductionGlobalStartup: { _ in }
            )
        )
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertTrue(AppDelegate.shared === appDelegate, file: file, line: line)
        return (appDelegate, diagnosticsURL)
    }

    private func loadSnapshot(from url: URL) throws -> AppDiagnosticsSnapshot {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppDiagnosticsSnapshot.self, from: data)
    }
}
