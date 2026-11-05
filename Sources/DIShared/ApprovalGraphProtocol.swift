import Foundation

/// 智能体通过本地 MCP 写入的显式任务图。
///
/// 该协议只承载任务图数据，不能批准权限、回答问题或回写文件。
public enum ApprovalGraphOperation: String, Codable, Sendable {
    case get
    case write
    case resolve
    case comment
}

public enum ApprovalGraphNodeKind: String, Codable, CaseIterable, Sendable {
    case task
    case step
}

public enum ApprovalGraphNodeStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case active
    case done
    case blocked
    case cancelled
}

public enum ApprovalGraphDecision: String, Codable, Sendable {
    case keep
    case discard
}

public enum ApprovalGraphCommentKind: String, Codable, Sendable {
    case question
    case command
}

public struct ApprovalGraphTarget: Codable, Equatable, Sendable {
    public var sessionID: String?
    public var agentType: String?
    public var workingDirectory: String?
    public var terminalSessionID: String?

    public init(sessionID: String? = nil, agentType: String? = nil,
                workingDirectory: String? = nil, terminalSessionID: String? = nil) {
        self.sessionID = sessionID
        self.agentType = agentType
        self.workingDirectory = workingDirectory
        self.terminalSessionID = terminalSessionID
    }
}

public struct ApprovalGraphNode: Codable, Equatable, Sendable {
    public var id: String
    public var parentID: String?
    public var kind: ApprovalGraphNodeKind
    public var title: String
    public var detail: String?
    public var status: ApprovalGraphNodeStatus

    public init(id: String, parentID: String? = nil, kind: ApprovalGraphNodeKind,
                title: String, detail: String? = nil, status: ApprovalGraphNodeStatus) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.status = status
    }
}

public struct ApprovalGraphProposal: Codable, Equatable, Sendable {
    public var node: ApprovalGraphNode
    public var createdAt: Date

    public init(node: ApprovalGraphNode, createdAt: Date = Date()) {
        self.node = node
        self.createdAt = createdAt
    }
}

public struct ApprovalGraphComment: Codable, Equatable, Sendable {
    public var id: UUID
    public var nodeID: String
    public var kind: ApprovalGraphCommentKind
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), nodeID: String, kind: ApprovalGraphCommentKind,
                text: String, createdAt: Date = Date()) {
        self.id = id
        self.nodeID = nodeID
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
    }
}

public struct ApprovalGraphHandledRequest: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var revision: Int

    public init(fingerprint: String, revision: Int) {
        self.fingerprint = fingerprint
        self.revision = revision
    }
}

public struct ApprovalGraphDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var version: Int
    public var sessionID: String
    public var revision: Int
    public var acceptedNodes: [ApprovalGraphNode]
    public var proposals: [ApprovalGraphProposal]
    public var comments: [ApprovalGraphComment]
    public var handledRequests: [String: ApprovalGraphHandledRequest]

    public init(sessionID: String, revision: Int = 0,
                acceptedNodes: [ApprovalGraphNode] = [],
                proposals: [ApprovalGraphProposal] = [],
                comments: [ApprovalGraphComment] = [],
                handledRequests: [String: ApprovalGraphHandledRequest] = [:]) {
        self.version = Self.schemaVersion
        self.sessionID = sessionID
        self.revision = revision
        self.acceptedNodes = acceptedNodes
        self.proposals = proposals
        self.comments = comments
        self.handledRequests = handledRequests
    }
}

public struct ApprovalGraphRequest: Codable, Equatable, Sendable {
    public var operation: ApprovalGraphOperation
    public var target: ApprovalGraphTarget
    public var baseRevision: Int?
    public var requestID: String?
    public var nodes: [ApprovalGraphNode]?
    public var nodeID: String?
    public var decision: ApprovalGraphDecision?
    public var commentKind: ApprovalGraphCommentKind?
    public var commentText: String?

    public init(operation: ApprovalGraphOperation, target: ApprovalGraphTarget = .init(),
                baseRevision: Int? = nil, requestID: String? = nil,
                nodes: [ApprovalGraphNode]? = nil, nodeID: String? = nil,
                decision: ApprovalGraphDecision? = nil,
                commentKind: ApprovalGraphCommentKind? = nil, commentText: String? = nil) {
        self.operation = operation
        self.target = target
        self.baseRevision = baseRevision
        self.requestID = requestID
        self.nodes = nodes
        self.nodeID = nodeID
        self.decision = decision
        self.commentKind = commentKind
        self.commentText = commentText
    }
}

public enum ApprovalGraphResponseError: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case sessionNotFound = "session_not_found"
    case sessionAmbiguous = "session_ambiguous"
    case staleRevision = "stale_revision"
    case invalidGraph = "invalid_graph"
    case nodeNotFound = "node_not_found"
    case parentNotAccepted = "parent_not_accepted"
    case requestConflict = "request_conflict"
    case persistenceFailed = "persistence_failed"
}

public struct ApprovalGraphResponsePayload: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: ApprovalGraphResponseError?
    public var message: String?
    public var document: ApprovalGraphDocument?

    public init(ok: Bool, error: ApprovalGraphResponseError? = nil,
                message: String? = nil, document: ApprovalGraphDocument? = nil) {
        self.ok = ok
        self.error = error
        self.message = message
        self.document = document
    }

    public static func success(_ document: ApprovalGraphDocument) -> Self {
        .init(ok: true, document: document)
    }

    public static func failure(_ error: ApprovalGraphResponseError, _ message: String) -> Self {
        .init(ok: false, error: error, message: message)
    }
}

public enum ApprovalGraphValidationError: Error, Equatable, Sendable {
    case tooManyNodes
    case tooDeep
    case duplicateID(String)
    case invalidID(String)
    case missingParent(String)
    case parentCycle(String)
    case parentChanged(String)
    case invalidTitle(String)
    case invalidDetail(String)
}

public enum ApprovalGraphValidator {
    public static let maxNodes = 32
    public static let maxDepth = 4
    public static let maxIDBytes = 64
    public static let maxTitleBytes = 256
    public static let maxDetailBytes = 2_048

    private static let allowedID = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")

    /// `allowExternalParents` is used by the stdio bridge, which cannot inspect
    /// the app-owned accepted graph. The app performs the final parent/depth check.
    public static func validate(_ nodes: [ApprovalGraphNode],
                                allowExternalParents: Bool = false) throws {
        guard nodes.count <= maxNodes else { throw ApprovalGraphValidationError.tooManyNodes }
        var byID: [String: ApprovalGraphNode] = [:]
        for node in nodes {
            let id = node.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id == node.id, !id.isEmpty, id.utf8.count <= maxIDBytes,
                  id.unicodeScalars.allSatisfy(allowedID.contains) else {
                throw ApprovalGraphValidationError.invalidID(node.id)
            }
            if node.title.utf8.count > maxTitleBytes {
                throw ApprovalGraphValidationError.invalidTitle("\(node.id):too-long")
            }
            if node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ApprovalGraphValidationError.invalidTitle("\(node.id):empty")
            }
            if node.title.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                throw ApprovalGraphValidationError.invalidTitle("\(node.id):control")
            }
            if let detail = node.detail {
                guard detail.utf8.count <= maxDetailBytes, !detail.utf8.contains(0) else {
                    throw ApprovalGraphValidationError.invalidDetail(node.id)
                }
            }
            guard byID[id] == nil else { throw ApprovalGraphValidationError.duplicateID(id) }
            byID[id] = node
        }
        for node in nodes {
            guard let parent = node.parentID else { continue }
            guard byID[parent] != nil else {
                if allowExternalParents { continue }
                throw ApprovalGraphValidationError.missingParent(parent)
            }
            var cursor: String? = parent
            var depth = 1
            var seen: Set<String> = [node.id]
            while let id = cursor {
                guard seen.insert(id).inserted else { throw ApprovalGraphValidationError.parentCycle(node.id) }
                guard depth <= maxDepth else { throw ApprovalGraphValidationError.tooDeep }
                cursor = byID[id]?.parentID
                depth += 1
            }
        }
    }
}
