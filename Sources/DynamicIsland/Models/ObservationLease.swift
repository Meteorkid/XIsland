import Foundation
import DIShared

/// 此身份描述 XIsland 的观察来源，nativeTaskId 仍保留供应商原值。
struct ObservationSource: Hashable {
    let agent: String
    let namespace: String
    let instance: String

    var id: String { "\(agent)-\(namespace)-\(instance)" }

    init?(message: DIMessage) {
        guard let agent = message.agentType, ["roo_code", "pearai"].contains(agent),
              let namespace = message.sourceNamespace, namespace.count == 24,
              namespace.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let instance = message.sourceInstanceId,
              UUID(uuidString: instance)?.uuidString.lowercased() == instance else { return nil }
        self.agent = agent; self.namespace = namespace; self.instance = instance
    }

    func sessionID(task: String) -> String {
        let encoded = Data(task.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return id + "-" + encoded
    }
}

struct ObservationLeaseLedger {
    enum Decision: Equatable { case rejected, event(ObservationSource), heartbeat, ended(ObservationSource) }
    private struct Lease {
        var sequence: Int
        var lastSeen: TimeInterval
        var expired = false
        var ended = false
    }
    private var leases: [ObservationSource: Lease] = [:]
    static let timeout: TimeInterval = 30
    var hasLiveSources: Bool { leases.values.contains { !$0.ended && !$0.expired } }

    mutating func accept(_ message: DIMessage, now: TimeInterval, wallTime: Date) -> Decision {
        guard let source = ObservationSource(message: message),
              let sequence = message.observationSequence, (1...9_007_199_254_740_991).contains(sequence) else { return .rejected }
        let age = wallTime.timeIntervalSince(message.timestamp)
        let isControl = message.type == .observationHeartbeat || message.type == .observationEnded
        guard age >= -5, age <= (message.type == .observationHeartbeat ? 5 : Self.timeout) else { return .rejected }
        if isControl {
            guard message.nativeTaskId == nil, message.sessionId == source.id else { return .rejected }
        } else {
            guard [.sessionStart, .statusUpdate, .subagentStart, .subagentEnd].contains(message.type),
                  let task = message.nativeTaskId, !task.isEmpty, task.utf8.count <= 16_384,
                  !task.unicodeScalars.contains(where: { $0.value < 32 }),
                  message.sessionId == source.sessionID(task: task) else { return .rejected }
            if message.type == .subagentStart || message.type == .subagentEnd {
                guard message.parentSessionId == message.sessionId,
                      let child = message.subagentId, child.hasPrefix(source.id + "-") else { return .rejected }
                let encoded = String(child.dropFirst(source.id.count + 1))
                    .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                guard let data = Data(base64Encoded: padded), let childTask = String(data: data, encoding: .utf8),
                      !childTask.isEmpty, childTask.utf8.count <= 16_384,
                      !childTask.unicodeScalars.contains(where: { $0.value < 32 }),
                      child == source.sessionID(task: childTask) else { return .rejected }
            }
        }
        if let previous = leases[source], previous.ended || sequence <= previous.sequence { return .rejected }
        // 过期控制帧不能重新打开来源；有限保留足以覆盖发送端30秒队列有效期。
        leases = leases.filter { _, lease in
            !(lease.ended && now - lease.lastSeen > 60) && !(lease.expired && now - lease.lastSeen > 300)
        }
        guard leases[source] != nil || leases.count < 1024 else { return .rejected }
        leases[source] = Lease(sequence: sequence, lastSeen: now, ended: message.type == .observationEnded)
        if message.type == .observationEnded { return .ended(source) }
        if message.type == .observationHeartbeat { return .heartbeat }
        return .event(source)
    }

    mutating func expire(now: TimeInterval) -> [ObservationSource] {
        let expired = leases.compactMap { source, lease in
            !lease.ended && !lease.expired && now - lease.lastSeen >= Self.timeout ? source : nil
        }
        for source in expired { leases[source]?.expired = true }
        return expired
    }
}
