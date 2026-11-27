import Foundation
import CryptoKit
import DIShared

/// 一次人工裁决的本地审计记录。它不是授权凭证，也不替代客户端自己的
/// PermissionResult；只回答“谁在什么时候对哪个请求做了什么决定”。
enum ApprovalAuditDecision: String, Codable, CaseIterable, Equatable, Sendable {
    case approved
    case denied
    case deferred
    case expired
    case nativeResolved = "native_resolved"
    /// Claude 的 Stop 已到，原生提示不可能还开着；不区分用户允许/拒绝。
    case nativeTurnEnded = "native_turn_ended"
    case cancelled
}

/// 本地账本的完整性结果。它只证明“从第一行到当前行自洽”，
/// 不能证明文件没有被整体替换；没有外部 witness 时不应把它说成防篡改凭证。
struct ApprovalAuditVerification: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case valid
        case broken
        case unavailable
    }

    let state: State
    let recordCount: Int
    let brokenLine: Int?
    let reason: String?

    static let unavailable = ApprovalAuditVerification(
        state: .unavailable, recordCount: 0, brokenLine: nil,
        reason: "approval audit ledger is unavailable")
}

extension Notification.Name {
    static let xislandApprovalAuditDidChange = Notification.Name("XIslandApprovalAuditDidChange")
}

struct ApprovalAuditRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let sessionID: String
    let agentType: String
    let tool: String
    let originAgentID: String?
    let nativeRequestID: String?
    let decision: ApprovalAuditDecision
    let latencyMilliseconds: Int?
    /// 只存 toolInput 的 SHA-256，不把完整命令/文件内容复制到审计文件。
    let payloadHash: String?
    let previousHash: String
    let hash: String
}

/// append-only JSONL，带前一条记录的哈希。
///
/// 这是应用层可追溯性，不是独立防篡改证据：能改本地文件的人也能重写整条链。
/// 参考 OpenLeash / gate4ai 的做法保留 action 身份、决定和 payload hash，
/// 但不引入 PASETO、签名密钥或外部 witness。
final class ApprovalAuditStore: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var lastHash: String?

    init(url: URL) {
        self.url = url
        self.lastHash = Self.readLastHash(at: url)
    }

    /// 正式运行写入 `~/.xisland/approval-audit.jsonl`；测试隔离默认不落盘。
    static func defaultStore() -> ApprovalAuditStore? {
        guard !AppPreferences.isIsolated else { return nil }
        let url = URL(fileURLWithPath: DISocketConfig.socketDir, isDirectory: true)
            .appendingPathComponent("approval-audit.jsonl")
        return ApprovalAuditStore(url: url)
    }

    @discardableResult
    func append(sessionID: String, agentType: String, tool: String,
                originAgentID: String?, nativeRequestID: String?,
                decision: ApprovalAuditDecision, latencyMilliseconds: Int?,
                toolInput: String?) -> ApprovalAuditRecord? {
        lock.lock()
        defer { lock.unlock() }

        let payloadHash = toolInput.map(Self.sha256)
        let timestamp = Self.normalizedTimestamp(Date())
        let record = ApprovalAuditRecord(
            id: UUID(),
            timestamp: timestamp,
            sessionID: sessionID,
            agentType: agentType,
            tool: tool,
            originAgentID: originAgentID,
            nativeRequestID: nativeRequestID,
            decision: decision,
            latencyMilliseconds: latencyMilliseconds.map { max(0, $0) },
            payloadHash: payloadHash,
            previousHash: lastHash ?? "",
            hash: ""
        )
        let sealed = ApprovalAuditRecord(
            id: record.id, timestamp: record.timestamp, sessionID: record.sessionID,
            agentType: record.agentType, tool: record.tool,
            originAgentID: record.originAgentID, nativeRequestID: record.nativeRequestID,
            decision: record.decision, latencyMilliseconds: record.latencyMilliseconds,
            payloadHash: record.payloadHash, previousHash: record.previousHash,
            hash: Self.hash(record)
        )

        guard let data = try? Self.encoder.encode(sealed),
              var line = String(data: data, encoding: .utf8) else { return nil }
        line.append("\n")
        guard appendLine(line) else { return nil }
        lastHash = sealed.hash
        return sealed
    }

    /// 返回最近的记录；默认 newest-first，便于直接在审批卡里展示。
    func records(sessionID: String? = nil, limit: Int = 20) -> [ApprovalAuditRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0, let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var parsed: [ApprovalAuditRecord] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? Self.decoder.decode(ApprovalAuditRecord.self, from: data) else { continue }
            if let sessionID, record.sessionID != sessionID { continue }
            parsed.append(record)
        }
        return Array(parsed.suffix(limit).reversed())
    }

    /// 校验当前 JSONL 的前序哈希链和每条记录自身的哈希。
    ///
    /// 第一个非空记录允许 `previousHash == ""`；如果它非空，说明前面的行已被删除，
    /// 不能把剩余后缀冒充成完整链，直接报 `missing predecessor`。
    func verify() -> ApprovalAuditVerification {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return ApprovalAuditVerification(state: .valid, recordCount: 0, brokenLine: nil, reason: nil)
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return .unavailable
        }

        var previousHash: String?
        var count = 0
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let lineData = line.data(using: .utf8),
                  let record = try? Self.decoder.decode(ApprovalAuditRecord.self, from: lineData) else {
                return ApprovalAuditVerification(state: .broken, recordCount: count,
                                                 brokenLine: offset + 1, reason: "invalid JSONL record")
            }
            guard Self.hash(record) == record.hash else {
                return ApprovalAuditVerification(state: .broken, recordCount: count,
                                                 brokenLine: offset + 1, reason: "record hash mismatch")
            }
            if let previousHash {
                guard record.previousHash == previousHash else {
                    return ApprovalAuditVerification(state: .broken, recordCount: count,
                                                     brokenLine: offset + 1, reason: "previous hash mismatch")
                }
            } else if !record.previousHash.isEmpty {
                return ApprovalAuditVerification(state: .broken, recordCount: count,
                                                 brokenLine: offset + 1, reason: "missing predecessor")
            }
            previousHash = record.hash
            count += 1
        }
        return ApprovalAuditVerification(state: .valid, recordCount: count, brokenLine: nil, reason: nil)
    }

    /// 把账本复制到用户选择的位置；导出的是原始 JSONL，不重新生成摘要。
    func export(to destination: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try Data(contentsOf: url)
        try data.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: destination.path)
    }

    static func hash(_ record: ApprovalAuditRecord) -> String {
        let canonical = [
            record.id.uuidString,
            String(Int((record.timestamp.timeIntervalSince1970 * 1000).rounded())),
            record.sessionID,
            record.agentType,
            record.tool,
            record.originAgentID ?? "",
            record.nativeRequestID ?? "",
            record.decision.rawValue,
            String(record.latencyMilliseconds ?? -1),
            record.payloadHash ?? "",
            record.previousHash
        ].joined(separator: "|")
        return sha256(canonical)
    }

    static func normalizedTimestamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func appendLine(_ line: String) -> Bool {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil,
                                    attributes: [.posixPermissions: 0o600]) else { return false }
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return false }
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func readLastHash(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let record = try? decoder.decode(ApprovalAuditRecord.self, from: lineData) else { continue }
            return record.hash
        }
        return nil
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
