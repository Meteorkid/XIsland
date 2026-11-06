import Darwin
import Foundation
import DIShared
@testable import DIBridge
import XCTest
@testable import XIsland

@MainActor
final class ApprovalGraphTests: XCTestCase {
    private let sessionID = "codex-graph-session"

    private func node(_ id: String, parent: String? = nil,
                      title: String = "Step", status: ApprovalGraphNodeStatus = .pending) -> ApprovalGraphNode {
        .init(id: id, parentID: parent, kind: parent == nil ? .task : .step,
              title: title, status: status)
    }

    private func writeRequest(_ nodes: [ApprovalGraphNode], revision: Int,
                              requestID: String = UUID().uuidString) -> ApprovalGraphRequest {
        .init(operation: .write, target: .init(sessionID: sessionID), baseRevision: revision,
              requestID: requestID, nodes: nodes)
    }

    func testWriteCreatesProposalsAndIsIdempotent() throws {
        let initial = ApprovalGraphDocument(sessionID: sessionID)
        let request = writeRequest([node("root", title: "Implement"), node("child", parent: "root")],
                                   revision: 0, requestID: "request-1")
        let written = try ApprovalGraphEngine.apply(request, to: initial)
        XCTAssertEqual(written.revision, 1)
        XCTAssertEqual(written.proposals.map(\.node.id), ["root", "child"])
        XCTAssertTrue(written.acceptedNodes.isEmpty)

        XCTAssertEqual(try ApprovalGraphEngine.apply(request, to: written), written)
        var conflicting = request
        conflicting.nodes = [node("different")]
        XCTAssertThrowsError(try ApprovalGraphEngine.apply(conflicting, to: written)) {
            XCTAssertEqual($0 as? ApprovalGraphEngineError, .requestConflict)
        }
    }

    func testStaleRevisionAndUnchangedWriteDoNotAdvanceRevision() throws {
        let request = writeRequest([node("root")], revision: 0, requestID: "first")
        let written = try ApprovalGraphEngine.apply(request, to: .init(sessionID: sessionID))
        let stale = writeRequest([node("other")], revision: 0, requestID: "stale")
        XCTAssertThrowsError(try ApprovalGraphEngine.apply(stale, to: written)) {
            XCTAssertEqual($0 as? ApprovalGraphEngineError, .staleRevision)
        }

        let unchanged = writeRequest([node("root")], revision: 1, requestID: "second")
        let same = try ApprovalGraphEngine.apply(unchanged, to: written)
        XCTAssertEqual(same.revision, 1)
        XCTAssertEqual(same.handledRequests["second"]?.revision, 1)
    }

    func testKeepRequiresAcceptedParentAndDiscardRemovesDescendants() throws {
        let nodes = [node("root"), node("child", parent: "root")]
        var document = try ApprovalGraphEngine.apply(
            writeRequest(nodes, revision: 0, requestID: "write"),
            to: .init(sessionID: sessionID)
        )
        let keepChild = ApprovalGraphRequest(operation: .resolve, baseRevision: document.revision,
                                             nodeID: "child", decision: .keep)
        XCTAssertThrowsError(try ApprovalGraphEngine.apply(keepChild, to: document)) {
            XCTAssertEqual($0 as? ApprovalGraphEngineError, .parentNotAccepted)
        }

        let discardRoot = ApprovalGraphRequest(operation: .resolve, baseRevision: document.revision,
                                               nodeID: "root", decision: .discard)
        document = try ApprovalGraphEngine.apply(discardRoot, to: document)
        XCTAssertTrue(document.proposals.isEmpty)
        XCTAssertTrue(document.acceptedNodes.isEmpty)
    }

    func testKeepMovesParentThenChildIntoAcceptedGraph() throws {
        var document = try ApprovalGraphEngine.apply(
            writeRequest([node("root"), node("child", parent: "root")],
                         revision: 0, requestID: "write"),
            to: .init(sessionID: sessionID)
        )
        document = try ApprovalGraphEngine.apply(
            .init(operation: .resolve, baseRevision: document.revision, nodeID: "root", decision: .keep),
            to: document
        )
        XCTAssertEqual(document.acceptedNodes.map(\.id), ["root"])
        document = try ApprovalGraphEngine.apply(
            .init(operation: .resolve, baseRevision: document.revision, nodeID: "child", decision: .keep),
            to: document
        )
        XCTAssertEqual(document.acceptedNodes.map(\.id), ["root", "child"])
        XCTAssertTrue(document.proposals.isEmpty)
    }

    func testCommentIsBoundedAndReadableByGet() throws {
        var document = try ApprovalGraphEngine.apply(
            writeRequest([node("root")], revision: 0, requestID: "write"),
            to: .init(sessionID: sessionID)
        )
        document = try ApprovalGraphEngine.apply(
            .init(operation: .resolve, baseRevision: document.revision, nodeID: "root", decision: .keep),
            to: document
        )
        document = try ApprovalGraphEngine.apply(
            .init(operation: .comment, baseRevision: document.revision, nodeID: "root",
                  commentKind: .command, commentText: "  Add keyboard navigation  "),
            to: document
        )
        XCTAssertEqual(document.comments.last?.text, "Add keyboard navigation")
        let read = try ApprovalGraphEngine.apply(
            .init(operation: .get, target: .init(sessionID: sessionID)), to: document
        )
        XCTAssertEqual(read.comments.last?.kind, .command)
        XCTAssertThrowsError(try ApprovalGraphEngine.apply(
            .init(operation: .comment, baseRevision: document.revision - 1, nodeID: "root",
                  commentKind: .question, commentText: "stale"),
            to: document
        )) {
            XCTAssertEqual($0 as? ApprovalGraphEngineError, .staleRevision)
        }
    }

    func testValidationRejectsDuplicateCycleAndControlCharacters() {
        XCTAssertThrowsError(try ApprovalGraphValidator.validate([node("same"), node("same")]))
        let a = node("a", parent: "b")
        let b = node("b", parent: "a")
        XCTAssertThrowsError(try ApprovalGraphValidator.validate([a, b]))
        XCTAssertThrowsError(try ApprovalGraphValidator.validate([node("bad", title: "line\nbreak")]))
    }

    func testWriteEnforcesTotalNodeLimitAndAcceptedParentDepth() throws {
        let accepted = (0..<ApprovalGraphValidator.maxNodes).map { node("a\($0)") }
        let full = ApprovalGraphDocument(sessionID: sessionID, acceptedNodes: accepted)
        XCTAssertThrowsError(try ApprovalGraphEngine.apply(
            writeRequest([node("new")], revision: 0, requestID: "full"), to: full
        )) {
            XCTAssertEqual($0 as? ApprovalGraphEngineError, .invalidGraph(.tooManyNodes))
        }

        let chain = [
            node("d1"), node("d2", parent: "d1"), node("d3", parent: "d2"),
            node("d4", parent: "d3")
        ]
        let deep = ApprovalGraphDocument(sessionID: sessionID, acceptedNodes: chain)
        XCTAssertThrowsError(try ApprovalGraphEngine.apply(
            writeRequest([node("d5", parent: "d4")], revision: 0, requestID: "deep"), to: deep
        )) {
            XCTAssertEqual($0 as? ApprovalGraphEngineError, .invalidGraph(.tooDeep))
        }
    }

    func testAcceptedNodeUpdateStaysPendingAndOldKeepIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-graph-update-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager()
        manager.approvalGraphStore = ApprovalGraphStore(directory: directory)
        manager.sessions = [AgentSession(id: sessionID, agentType: .codex)]

        let first = manager.handleApprovalGraphRequest(
            writeRequest([node("goal", title: "Goal", status: .active)], revision: 0, requestID: "create")
        )
        let firstProposal = try XCTUnwrap(first.document?.proposals.first)
        XCTAssertTrue(manager.keepApprovalGraphNode(
            sessionID: sessionID, nodeID: "goal",
            expectedRevision: first.document!.revision, expectedNode: firstProposal.node
        ))

        let update = manager.handleApprovalGraphRequest(
            writeRequest([node("goal", title: "Goal", status: .done)], revision: 2, requestID: "update")
        )
        XCTAssertTrue(update.ok)
        let document = try XCTUnwrap(update.document)
        let currentProposal = try XCTUnwrap(document.proposals.first)
        let rendered = ApprovalContextMapView.orderedGraphNodes(document)
        XCTAssertEqual(rendered.count, 1)
        XCTAssertEqual(rendered.first?.node.status, .done)

        XCTAssertFalse(manager.keepApprovalGraphNode(
            sessionID: sessionID, nodeID: "goal",
            expectedRevision: first.document!.revision, expectedNode: firstProposal.node
        ))
        XCTAssertTrue(manager.keepApprovalGraphNode(
            sessionID: sessionID, nodeID: "goal",
            expectedRevision: document.revision, expectedNode: currentProposal.node
        ))
        XCTAssertEqual(manager.approvalGraph(for: sessionID)?.acceptedNodes.first?.status, .done)
        XCTAssertEqual(try ApprovalGraphStore(directory: directory).load(sessionID: sessionID)?.acceptedNodes.first?.status, .done)
    }

    func testAcceptedNodeCannotMoveToAnotherParent() throws {
        let manager = SessionManager()
        manager.approvalGraphStore = nil
        manager.sessions = [AgentSession(id: sessionID, agentType: .codex)]
        let initial = manager.handleApprovalGraphRequest(
            writeRequest([node("a"), node("b"), node("child", parent: "a")],
                         revision: 0, requestID: "create")
        )
        for id in ["a", "b", "child"] {
            let proposal = try XCTUnwrap(initial.document?.proposals.first(where: { $0.node.id == id }))
            let current = try XCTUnwrap(manager.approvalGraph(for: sessionID))
            XCTAssertTrue(manager.keepApprovalGraphNode(
                sessionID: sessionID, nodeID: id,
                expectedRevision: current.revision, expectedNode: proposal.node
            ))
        }
        let current = try XCTUnwrap(manager.approvalGraph(for: sessionID))
        let moved = manager.handleApprovalGraphRequest(
            writeRequest([node("child", parent: "b")], revision: current.revision, requestID: "move")
        )
        XCTAssertFalse(moved.ok)
        XCTAssertEqual(moved.error, .invalidGraph)
    }

    func testStorePersistsPrivateRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-graph-store-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ApprovalGraphStore(directory: directory)
        var document = ApprovalGraphDocument(sessionID: sessionID)
        document.acceptedNodes = [node("root", title: "Persisted", status: .done)]
        document.revision = 2
        try store.save(document)
        XCTAssertEqual(try store.load(sessionID: sessionID), document)

        let dirMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(dirMode, 0o700)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: directory.path).first
        )
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(fileMode, 0o600)
    }

    func testStoreRejectsSymlinkInsteadOfFollowingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-graph-symlink-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ApprovalGraphStore(directory: directory)
        try store.save(.init(sessionID: sessionID))
        let file = directory.appendingPathComponent(
            try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory.path).first)
        )
        let target = directory.appendingPathComponent("target.json")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try store.load(sessionID: sessionID)) {
            XCTAssertEqual($0 as? ApprovalGraphStoreError, .unsafePath)
        }
    }

    func testStoreRejectsSymlinkedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-graph-dir-link-\(UUID())", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ApprovalGraphStore(directory: link).save(.init(sessionID: sessionID))) {
            XCTAssertEqual($0 as? ApprovalGraphStoreError, .unsafePath)
        }
    }

    func testOrderedGraphNodesKeepParentBeforeChild() throws {
        let document = ApprovalGraphDocument(
            sessionID: sessionID,
            revision: 1,
            acceptedNodes: [node("root", title: "Root")],
            proposals: [
                .init(node: node("child", parent: "root", title: "Child")),
                .init(node: node("grandchild", parent: "child", title: "Grandchild")),
            ]
        )
        let ordered = ApprovalContextMapView.orderedGraphNodes(document)
        XCTAssertEqual(ordered.map(\.node.id), ["root", "child", "grandchild"])
        XCTAssertEqual(ordered.map(\.depth), [1, 2, 3])
    }

    func testProtocolRoundTripsGraphRequestAndResponse() throws {
        var message = DIMessage(type: .approvalGraphRequest, sessionId: sessionID)
        message.approvalGraphRequest = writeRequest(
            [node("root", title: "实现显式任务图")], revision: 0, requestID: "roundtrip"
        )
        let decoded = try DIProtocol.decode(DIProtocol.encode(message))
        XCTAssertEqual(decoded.type, .approvalGraphRequest)
        XCTAssertEqual(decoded.approvalGraphRequest, message.approvalGraphRequest)
        XCTAssertEqual(decoded.approvalGraphRequest?.nodes?.first?.title, "实现显式任务图")

        var response = DIMessage(type: .approvalGraphResponse, sessionId: sessionID)
        response.approvalGraphResponse = .success(.init(sessionID: sessionID))
        let decodedResponse = try DIProtocol.decode(DIProtocol.encode(response))
        XCTAssertTrue(decodedResponse.approvalGraphResponse?.ok == true)
    }

    func testMCPHandshakeRoundTripsAsDistinctConnectionEvidence() throws {
        var message = DIMessage(type: .mcpHandshake, sessionId: "mcp-handshake:codex")
        message.agentType = "codex"
        message.nativeEvent = "initialize"
        message.integrationFingerprint = ApprovalGraphMCPIdentity.fingerprint(
            command: "/Users/me/.xisland/bin/di-bridge", agent: "codex"
        )

        let decoded = try DIProtocol.decode(DIProtocol.encode(message))
        XCTAssertEqual(decoded.type, .mcpHandshake)
        XCTAssertEqual(decoded.agentType, "codex")
        XCTAssertEqual(decoded.integrationFingerprint, message.integrationFingerprint)
        XCTAssertNotEqual(decoded.type, .sessionStart)
        XCTAssertNotEqual(decoded.type, .approvalGraphRequest)
    }

    func testMCPWriteParserPreservesChineseTitles() throws {
        let arguments: [String: Any] = [
            "base_revision": 0,
            "request_id": "unicode-write",
            "nodes": [[
                "id": "goal", "kind": "task", "title": "实现显式任务图",
                "status": "active"
            ]]
        ]
        let request = try MCPApprovalGraphServer.writeRequest(
            arguments: arguments,
            baseTarget: .init(sessionID: sessionID, agentType: "codex")
        )
        XCTAssertEqual(request.nodes?.first?.title, "实现显式任务图")
    }

    func testSessionManagerPersistsWriteKeepAndCommentWithoutCreatingSessions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-graph-manager-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager()
        manager.approvalGraphStore = ApprovalGraphStore(directory: directory)
        manager.sessions = [AgentSession(id: sessionID, agentType: .codex,
                                         workingDirectory: "/tmp/graph-project")]

        let missing = manager.handleApprovalGraphRequest(
            .init(operation: .get, target: .init(sessionID: "missing"))
        )
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.error, .sessionNotFound)
        XCTAssertEqual(manager.sessions.count, 1)

        let written = manager.handleApprovalGraphRequest(
            writeRequest([node("root", title: "Agent plan")], revision: 0, requestID: "manager-write")
        )
        XCTAssertTrue(written.ok)
        XCTAssertEqual(written.document?.proposals.count, 1)
        let proposal = try XCTUnwrap(written.document?.proposals.first)
        XCTAssertTrue(manager.keepApprovalGraphNode(
            sessionID: sessionID, nodeID: "root",
            expectedRevision: written.document!.revision, expectedNode: proposal.node
        ))
        XCTAssertTrue(manager.addApprovalGraphComment(
            sessionID: sessionID, nodeID: "root", kind: .question, text: "Why this step?"
        ))
        XCTAssertEqual(manager.approvalGraph(for: sessionID)?.comments.last?.text, "Why this step?")

        let reloaded = SessionManager()
        reloaded.approvalGraphStore = ApprovalGraphStore(directory: directory)
        reloaded.sessions = [AgentSession(id: sessionID, agentType: .codex,
                                          workingDirectory: "/tmp/graph-project")]
        let read = reloaded.handleApprovalGraphRequest(
            .init(operation: .get, target: .init(sessionID: sessionID))
        )
        XCTAssertEqual(read.document?.acceptedNodes.map(\.id), ["root"])
        try reloaded.removeApprovalGraph(sessionID: sessionID)
        XCTAssertNil(try ApprovalGraphStore(directory: directory).load(sessionID: sessionID))
    }

    func testManagerBindsByAgentAndWorkingDirectoryAndRejectsAmbiguity() {
        let manager = SessionManager()
        manager.approvalGraphStore = nil
        let first = AgentSession(id: "codex-a", agentType: .codex, workingDirectory: "/tmp/shared-graph")
        first.termSessionId = "tty:/dev/ttys001"
        let second = AgentSession(id: "codex-b", agentType: .codex, workingDirectory: "/tmp/shared-graph")
        second.termSessionId = "tty:/dev/ttys002"
        manager.sessions = [first]

        let matched = manager.handleApprovalGraphRequest(.init(
            operation: .get,
            target: .init(agentType: "codex", workingDirectory: "/tmp/shared-graph")
        ))
        XCTAssertTrue(matched.ok)
        XCTAssertEqual(matched.document?.sessionID, first.id)

        manager.sessions = [first, second]
        let ambiguous = manager.handleApprovalGraphRequest(.init(
            operation: .get,
            target: .init(agentType: "codex", workingDirectory: "/tmp/shared-graph")
        ))
        XCTAssertFalse(ambiguous.ok)
        XCTAssertEqual(ambiguous.error, .sessionAmbiguous)

        let terminal = manager.handleApprovalGraphRequest(.init(
            operation: .get,
            target: .init(agentType: "codex", terminalSessionID: "tty:/dev/ttys001")
        ))
        XCTAssertTrue(terminal.ok)
        XCTAssertEqual(terminal.document?.sessionID, first.id)

        let wrongTerminal = manager.handleApprovalGraphRequest(.init(
            operation: .get,
            target: .init(agentType: "codex", terminalSessionID: "tty:/dev/ttys999")
        ))
        XCTAssertFalse(wrongTerminal.ok)
        XCTAssertEqual(wrongTerminal.error, .sessionNotFound)

        let unknownAgent = manager.handleApprovalGraphRequest(.init(
            operation: .get,
            target: .init(agentType: "not-a-real-agent", workingDirectory: "/tmp/shared-graph")
        ))
        XCTAssertFalse(unknownAgent.ok)
        XCTAssertEqual(unknownAgent.error, .invalidRequest)
    }

    func testCompletionSnapshotContainsOnlyAcceptedGraphNodes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-graph-snapshot-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager()
        manager.approvalGraphStore = ApprovalGraphStore(directory: directory.appendingPathComponent("graphs"))
        let snapshotStore = ApprovalContextMapSnapshotStore(
            url: directory.appendingPathComponent("snapshots.json")
        )
        manager.approvalMapSnapshotStore = snapshotStore

        var start = DIMessage(type: .sessionStart, sessionId: sessionID)
        start.agentType = "codex"
        start.prompt = "Snapshot the explicit graph"
        manager.handleMessage(start)
        let written = manager.handleApprovalGraphRequest(
            writeRequest([node("accepted"), node("pending")], revision: 0, requestID: "snapshot-write")
        )
        XCTAssertTrue(written.ok)
        let acceptedProposal = try XCTUnwrap(
            written.document?.proposals.first(where: { $0.node.id == "accepted" })
        )
        XCTAssertTrue(manager.keepApprovalGraphNode(
            sessionID: sessionID, nodeID: "accepted",
            expectedRevision: written.document!.revision, expectedNode: acceptedProposal.node
        ))

        var end = DIMessage(type: .sessionEnd, sessionId: sessionID)
        end.agentType = "codex"
        end.observedState = "completed"
        manager.handleMessage(end)
        let snapshot = try XCTUnwrap(snapshotStore.latest(sessionID: sessionID))
        XCTAssertEqual(snapshot.graphNodes?.map(\.id), ["accepted"])
    }

    func testGraphPeerPolicyRejectsShellMissingPathAndWritableBridge() {
        let id = geteuid()
        let bridge = "/tmp/bridge"
        let attrs: [FileAttributeKey: Any] = [.ownerAccountID: NSNumber(value: id), .posixPermissions: NSNumber(value: 0o700)]
        XCTAssertTrue(SocketServer.isApprovalGraphPeerTrusted(
            .init(pid: 1, effectiveUID: id, executablePath: bridge), ownUID: id, bridgePath: bridge,
            fileAttributes: { _ in attrs }
        ))
        XCTAssertFalse(SocketServer.isApprovalGraphPeerTrusted(
            .init(pid: 1, effectiveUID: id, executablePath: "/bin/sh"), ownUID: id, bridgePath: bridge,
            fileAttributes: { _ in attrs }
        ))
        XCTAssertFalse(SocketServer.isApprovalGraphPeerTrusted(
            .init(pid: nil, effectiveUID: id, executablePath: nil), ownUID: id, bridgePath: bridge,
            fileAttributes: { _ in attrs }
        ))
        XCTAssertFalse(SocketServer.isApprovalGraphPeerTrusted(
            .init(pid: 1, effectiveUID: id, executablePath: bridge), ownUID: id, bridgePath: bridge,
            fileAttributes: { _ in [.ownerAccountID: NSNumber(value: id), .posixPermissions: NSNumber(value: 0o722)] }
        ))
    }
}
