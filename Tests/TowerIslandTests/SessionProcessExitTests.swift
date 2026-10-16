import XCTest
import DIShared
@testable import XIsland

@MainActor
final class SessionProcessExitTests: XCTestCase {
    func testMissingCliProcessEndsObservationWithoutCompletingActiveOrIdleSession() throws {
        for status in [SessionStatus.active, .idle] {
            let endedAt = Date(timeIntervalSince1970: 1_000)
            let manager = SessionManager(observationWallClock: { endedAt })
            let session = AgentSession(id: "claude-process-\(status.rawValue)", agentType: .claudeCode,
                                       startTime: endedAt.addingTimeInterval(-60))
            session.status = status
            session.currentTool = status == .active ? "Bash" : nil
            manager.sessions = [session]
            manager.selectedSessionId = session.id

            manager.checkProcessesAlive(processStatus: { _ in false })

            XCTAssertEqual(session.status, .observationUnavailable)
            XCTAssertNil(session.completedAt)
            XCTAssertEqual(session.observationEndedAt, endedAt)
            XCTAssertEqual(session.statusText, L10n.observationInterrupted)
            XCTAssertNil(session.currentTool)
            XCTAssertTrue(manager.activeSessions.isEmpty)
            XCTAssertNil(manager.selectedSessionId)
            let project = try XCTUnwrap(AgentFlowAggregator.group(sessions: manager.sessions).first)
            XCTAssertEqual(project.completedCount, 0)
            XCTAssertEqual(project.unavailableCount, 1)
        }
    }

    func testDesktopExitEndsObservationAndLeavesOtherAgentsRunning() throws {
        let endedAt = Date(timeIntervalSince1970: 1_000)
        let manager = SessionManager(observationWallClock: { endedAt })
        let desktop = AgentSession(id: "cursor-process", agentType: .cursor)
        let cli = AgentSession(id: "claude-running", agentType: .claudeCode)
        manager.sessions = [desktop, cli]
        manager.selectedSessionId = desktop.id

        manager.handleAppTerminated(bundleId: "com.todesktop.230313mzl4w4u92")

        XCTAssertEqual(desktop.status, .observationUnavailable)
        XCTAssertNil(desktop.completedAt)
        XCTAssertEqual(desktop.observationEndedAt, endedAt)
        XCTAssertEqual(cli.status, .active)
        XCTAssertNil(cli.observationEndedAt)
        XCTAssertEqual(manager.selectedSessionId, cli.id)
    }

    func testProcessOrDesktopExitPreservesConfirmedCompletion() throws {
        for agent in [AgentType.claudeCode, .cursor] {
            let manager = SessionManager()
            let session = AgentSession(id: "\(agent.rawValue)-confirmed", agentType: agent)
            manager.sessions = [session]
            var end = DIMessage(type: .sessionEnd, sessionId: session.id)
            end.agentType = agent.rawValue
            end.observedState = "completed"
            manager.handleMessage(end)
            let completedAt = try XCTUnwrap(session.completedAt)

            if agent.isDesktopApp {
                manager.handleAppTerminated(bundleId: try XCTUnwrap(agent.bundleId))
            } else {
                manager.checkProcessesAlive(processStatus: { _ in false })
            }

            XCTAssertEqual(session.status, .completed)
            XCTAssertEqual(session.completedAt, completedAt)
            XCTAssertNil(session.observationEndedAt)
        }
    }

    func testLiveOrFailedProcessCheckPreservesCurrentState() throws {
        let processStates: [Bool?] = [true, nil]
        for processStatus in processStates {
            let manager = SessionManager()
            let session = AgentSession(id: "claude-running", agentType: .claudeCode)
            session.currentTool = "Bash"
            manager.sessions = [session]
            manager.selectedSessionId = session.id

            manager.checkProcessesAlive(processStatus: { _ in processStatus })

            XCTAssertEqual(session.status, .active)
            XCTAssertEqual(session.currentTool, "Bash")
            XCTAssertEqual(manager.selectedSessionId, session.id)
            XCTAssertNil(session.completedAt)
            XCTAssertNil(session.observationEndedAt)
        }
    }

    func testExitCancelsPendingInteractionsWithoutDecidingAndPersistsInterruption() throws {
        for agent in [AgentType.claudeCode, .cursor] {
            let store = try temporaryStore()
            let endedAt = Date(timeIntervalSince1970: 1_000)
            try autoreleasepool {
                let persistence = SessionPersistenceManager()
                XCTAssertTrue(persistence.setupContainer(storeURL: store))
                let manager = SessionManager(observationWallClock: { endedAt })
                manager.persistenceManager = persistence
                let cancellations = ProcessExitCancellationRecorder()
                var request = DIMessage(type: .permissionRequest, sessionId: "\(agent.rawValue)-waiting")
                request.agentType = agent.rawValue
                request.tool = "Bash"
                manager.handlePermissionRequest(request, cancel: { cancellations.record() }) { _ in
                    XCTFail("退出不能替用户决定审批")
                }
                request.questionText = "Continue?"
                request.options = ["Yes", "No"]
                manager.handleQuestionRequest(request, respond: { _ in
                    XCTFail("退出不能替用户回答问题")
                }, cancel: { cancellations.record() })
                request.planMarkdown = "Review changes"
                manager.handlePlanReview(request, cancel: { cancellations.record() }) { _, _ in
                    XCTFail("退出不能替用户审阅计划")
                }
                let session = try XCTUnwrap(manager.sessions.first)
                XCTAssertTrue(manager.hasInteraction)

                if agent.isDesktopApp {
                    manager.handleAppTerminated(bundleId: try XCTUnwrap(agent.bundleId))
                } else {
                    manager.checkProcessesAlive(processStatus: { _ in false })
                }

                XCTAssertEqual(cancellations.count, 3)
                XCTAssertFalse(manager.hasInteraction)
                XCTAssertNil(manager.focusedInteraction)
                XCTAssertFalse(session.hasPendingInteraction)
                XCTAssertEqual(session.status, .observationUnavailable)
                XCTAssertNil(session.completedAt)
            }
            let reopened = SessionPersistenceManager()
            XCTAssertTrue(reopened.setupContainer(storeURL: store))
            let saved = try XCTUnwrap(reopened.fetchHistory().first)
            XCTAssertEqual(saved.status, .observationUnavailable)
            XCTAssertNil(saved.completedAt)
            XCTAssertEqual(saved.observationEndedAt, endedAt)
        }
    }

    func testFreshToolAfterProcessExitClearsObservedEndAndRefreshesHistory() throws {
        let store = try temporaryStore()
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(storeURL: store))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        var start = DIMessage(type: .sessionStart, sessionId: "claude-resume-process")
        start.agentType = AgentType.claudeCode.rawValue
        manager.handleMessage(start)
        manager.checkProcessesAlive(processStatus: { _ in false })
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.status, .observationUnavailable)
        XCTAssertNotNil(session.observationEndedAt)

        var tool = start
        tool.type = .toolStart
        tool.tool = "Read"
        tool.toolCallId = "new-work"
        manager.handleMessage(tool)

        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(session.currentTool, "Read")
        XCTAssertNil(session.completedAt)
        XCTAssertNil(session.observationEndedAt)
        let reopened = SessionPersistenceManager()
        XCTAssertTrue(reopened.setupContainer(storeURL: store))
        let saved = try XCTUnwrap(reopened.fetchHistory().first)
        XCTAssertEqual(saved.status, .active)
        XCTAssertNil(saved.completedAt)
        XCTAssertNil(saved.observationEndedAt)
    }

    private func temporaryStore() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-process-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("history.store")
    }
}

private final class ProcessExitCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return recordedCount }
    func record() {
        lock.lock(); defer { lock.unlock() }
        recordedCount += 1
    }
}
