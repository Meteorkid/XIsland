import CryptoKit
import Darwin
import Foundation
import DIShared

enum ApprovalGraphEngineError: Error, Equatable {
    case invalidGraph(ApprovalGraphValidationError)
    case staleRevision
    case invalidRequest
    case requestConflict
    case nodeNotFound
    case parentNotAccepted

    var response: (ApprovalGraphResponseError, String) {
        switch self {
        case .invalidGraph(let error):
            return (.invalidGraph, String(describing: error))
        case .staleRevision:
            return (.staleRevision, "The graph changed after this revision was read. Fetch it again.")
        case .invalidRequest:
            return (.invalidRequest, "The approval graph request is incomplete or malformed.")
        case .requestConflict:
            return (.requestConflict, "This request_id was already used with a different payload.")
        case .nodeNotFound:
            return (.nodeNotFound, "The requested graph node does not exist.")
        case .parentNotAccepted:
            return (.parentNotAccepted, "Keep the parent node before keeping this child node.")
        }
    }
}

enum ApprovalGraphEngine {
    static func apply(_ request: ApprovalGraphRequest,
                      to input: ApprovalGraphDocument,
                      now: Date = Date()) throws -> ApprovalGraphDocument {
        var document = input
        switch request.operation {
        case .get:
            return document

        case .write:
            guard let revision = request.baseRevision,
                  let requestID = request.requestID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestID.isEmpty, requestID.utf8.count <= 128,
                  let nodes = request.nodes else {
                throw ApprovalGraphEngineError.invalidRequest
            }
            try ApprovalGraphValidator.validate(nodes, allowExternalParents: true)
            let fingerprint = try fingerprint(for: request)
            if let handled = document.handledRequests[requestID] {
                guard handled.fingerprint == fingerprint else { throw ApprovalGraphEngineError.requestConflict }
                return document
            }
            guard revision == document.revision else { throw ApprovalGraphEngineError.staleRevision }

            let acceptedByID = Dictionary(uniqueKeysWithValues: document.acceptedNodes.map { ($0.id, $0) })
            let incomingByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            let allByID = acceptedByID.merging(incomingByID) { _, incoming in incoming }
            guard allByID.count <= ApprovalGraphValidator.maxNodes else {
                throw ApprovalGraphEngineError.invalidGraph(.tooManyNodes)
            }
            for node in nodes {
                if let accepted = acceptedByID[node.id], accepted.parentID != node.parentID {
                    throw ApprovalGraphEngineError.invalidGraph(.parentChanged(node.id))
                }
                if let parentID = node.parentID,
                   acceptedByID[parentID] == nil, incomingByID[parentID] == nil {
                    throw ApprovalGraphEngineError.invalidGraph(.missingParent(parentID))
                }
                var parent = node.parentID
                var depth = 1
                var seen: Set<String> = [node.id]
                while let id = parent {
                    guard seen.insert(id).inserted else {
                        throw ApprovalGraphEngineError.invalidGraph(.parentCycle(node.id))
                    }
                    depth += 1
                    guard depth <= ApprovalGraphValidator.maxDepth else {
                        throw ApprovalGraphEngineError.invalidGraph(.tooDeep)
                    }
                    parent = allByID[id]?.parentID
                }
            }

            var priorProposals = Dictionary(uniqueKeysWithValues: document.proposals.map { ($0.node.id, $0) })
            var proposals: [ApprovalGraphProposal] = []
            for node in nodes {
                if acceptedByID[node.id] == node { continue }
                if let prior = priorProposals.removeValue(forKey: node.id), prior.node == node {
                    proposals.append(prior)
                } else {
                    proposals.append(.init(node: node, createdAt: now))
                }
            }
            let changed = proposals != document.proposals
            document.proposals = proposals
            document.handledRequests[requestID] = .init(
                fingerprint: fingerprint,
                revision: changed ? document.revision + 1 : document.revision
            )
            trimHandledRequests(&document)
            if changed { document.revision += 1 }
            try validateDocument(document)
            return document

        case .resolve:
            guard let revision = request.baseRevision,
                  revision == document.revision,
                  let nodeID = request.nodeID,
                  let decision = request.decision,
                  let index = document.proposals.firstIndex(where: { $0.node.id == nodeID }) else {
                if request.baseRevision != document.revision { throw ApprovalGraphEngineError.staleRevision }
                throw ApprovalGraphEngineError.nodeNotFound
            }
            switch decision {
            case .keep:
                let node = document.proposals[index].node
                if let parentID = node.parentID,
                   !document.acceptedNodes.contains(where: { $0.id == parentID }) {
                    throw ApprovalGraphEngineError.parentNotAccepted
                }
                document.proposals.remove(at: index)
                if let acceptedIndex = document.acceptedNodes.firstIndex(where: { $0.id == node.id }) {
                    document.acceptedNodes[acceptedIndex] = node
                } else {
                    document.acceptedNodes.append(node)
                }
            case .discard:
                var discarded: Set<String> = [nodeID]
                var expanded = true
                while expanded {
                    expanded = false
                    for proposal in document.proposals where !discarded.contains(proposal.node.id) {
                        if let parentID = proposal.node.parentID, discarded.contains(parentID) {
                            discarded.insert(proposal.node.id)
                            expanded = true
                        }
                    }
                }
                document.proposals.removeAll { discarded.contains($0.node.id) }
            }
            document.revision += 1
            try validateDocument(document)
            return document

        case .comment:
            guard request.baseRevision == document.revision else {
                throw ApprovalGraphEngineError.staleRevision
            }
            guard let nodeID = request.nodeID,
                  let kind = request.commentKind,
                  let rawText = request.commentText else {
                throw ApprovalGraphEngineError.invalidRequest
            }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.count <= 2_048, !text.utf8.contains(0) else {
                throw ApprovalGraphEngineError.invalidRequest
            }
            guard document.acceptedNodes.contains(where: { $0.id == nodeID })
                    || document.proposals.contains(where: { $0.node.id == nodeID }) else {
                throw ApprovalGraphEngineError.nodeNotFound
            }
            document.comments.append(.init(nodeID: nodeID, kind: kind, text: text, createdAt: now))
            if document.comments.count > 16 {
                document.comments.removeFirst(document.comments.count - 16)
            }
            document.revision += 1
            try validateDocument(document)
            return document
        }
    }

    static func validateDocument(_ document: ApprovalGraphDocument) throws {
        try ApprovalGraphValidator.validate(document.acceptedNodes)
        try ApprovalGraphValidator.validate(document.proposals.map(\.node), allowExternalParents: true)
        var merged = Dictionary(uniqueKeysWithValues: document.acceptedNodes.map { ($0.id, $0) })
        for proposal in document.proposals {
            if let accepted = merged[proposal.node.id], accepted.parentID != proposal.node.parentID {
                throw ApprovalGraphValidationError.parentChanged(proposal.node.id)
            }
            merged[proposal.node.id] = proposal.node
        }
        guard merged.count <= ApprovalGraphValidator.maxNodes else {
            throw ApprovalGraphValidationError.tooManyNodes
        }
        for node in merged.values {
            var parent = node.parentID
            var depth = 1
            var seen: Set<String> = [node.id]
            while let id = parent {
                guard let current = merged[id] else {
                    throw ApprovalGraphValidationError.missingParent(id)
                }
                guard seen.insert(id).inserted else {
                    throw ApprovalGraphValidationError.parentCycle(node.id)
                }
                depth += 1
                guard depth <= ApprovalGraphValidator.maxDepth else {
                    throw ApprovalGraphValidationError.tooDeep
                }
                parent = current.parentID
            }
        }
        guard document.comments.count <= 16 else { throw ApprovalGraphStoreError.invalidDocument }
        let nodeIDs = Set(merged.keys)
        guard document.comments.allSatisfy({ nodeIDs.contains($0.nodeID) }) else {
            throw ApprovalGraphStoreError.invalidDocument
        }
    }

    static func fingerprint(for request: ApprovalGraphRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func trimHandledRequests(_ document: inout ApprovalGraphDocument) {
        guard document.handledRequests.count > 128 else { return }
        let overflow = document.handledRequests.count - 128
        for key in document.handledRequests.keys.sorted().prefix(overflow) {
            document.handledRequests.removeValue(forKey: key)
        }
    }
}

enum ApprovalGraphStoreError: Error, Equatable {
    case invalidSessionID
    case invalidDocument
    case unsafePath
    case documentTooLarge
    case persistenceFailed
}

struct ApprovalGraphStore {
    static let maxFileBytes = 256 * 1024

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static func defaultStore() -> ApprovalGraphStore? {
        guard !AppPreferences.isIsolated else { return nil }
        let url = URL(fileURLWithPath: DISocketConfig.socketDir, isDirectory: true)
            .appendingPathComponent("approval-graphs", isDirectory: true)
        return ApprovalGraphStore(directory: url)
    }

    func load(sessionID: String) throws -> ApprovalGraphDocument? {
        let url = try fileURL(sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard !Self.isSymbolicLink(url.path) else { throw ApprovalGraphStoreError.unsafePath }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ApprovalGraphStoreError.unsafePath
        }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maxFileBytes else {
            throw ApprovalGraphStoreError.documentTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let document = try JSONDecoder().decode(ApprovalGraphDocument.self, from: data)
        guard document.version == ApprovalGraphDocument.schemaVersion,
              document.sessionID == sessionID else {
            throw ApprovalGraphStoreError.invalidDocument
        }
        try ApprovalGraphEngine.validateDocument(document)
        return document
    }

    func save(_ document: ApprovalGraphDocument) throws {
        let url = try fileURL(sessionID: document.sessionID)
        try ensureDirectory()
        if FileManager.default.fileExists(atPath: url.path) {
            guard !Self.isSymbolicLink(url.path) else { throw ApprovalGraphStoreError.unsafePath }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ApprovalGraphStoreError.unsafePath
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maxFileBytes else { throw ApprovalGraphStoreError.documentTooLarge }
        try ApprovalGraphEngine.validateDocument(document)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as ApprovalGraphStoreError {
            throw error
        } catch {
            throw ApprovalGraphStoreError.persistenceFailed
        }
    }

    func delete(sessionID: String) throws {
        let url = try fileURL(sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(sessionID: String) throws -> URL {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 512, !sessionID.utf8.contains(0) else {
            throw ApprovalGraphStoreError.invalidSessionID
        }
        let digest = SHA256.hash(data: Data(sessionID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json", isDirectory: false)
    }

    private func ensureDirectory() throws {
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                guard !Self.isSymbolicLink(directory.path) else {
                    throw ApprovalGraphStoreError.unsafePath
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw ApprovalGraphStoreError.unsafePath
                }
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch let error as ApprovalGraphStoreError {
            throw error
        } catch {
            throw ApprovalGraphStoreError.persistenceFailed
        }
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }
}
