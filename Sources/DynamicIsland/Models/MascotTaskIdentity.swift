import CryptoKit
import Foundation
import SwiftUI

struct MascotTaskIdentity {
    struct PaletteToken: Identifiable {
        let id: String
        let hexRGB: UInt32

        var color: Color {
            Color(red: Double((hexRGB >> 16) & 0xff) / 255,
                  green: Double((hexRGB >> 8) & 0xff) / 255,
                  blue: Double(hexRGB & 0xff) / 255)
        }
    }

    /// 顺序属于持久化身份协议，已有 token 不应重排。
    static let palette: [PaletteToken] = [
        PaletteToken(id: "cyan", hexRGB: 0x65BED8),
        PaletteToken(id: "coral", hexRGB: 0xF27D72),
        PaletteToken(id: "violet", hexRGB: 0xB68BDD),
        PaletteToken(id: "gold", hexRGB: 0xDCC65A),
        PaletteToken(id: "mint", hexRGB: 0x69C59A),
        PaletteToken(id: "sky", hexRGB: 0x77A5E8),
        PaletteToken(id: "tangerine", hexRGB: 0xEDA253),
        PaletteToken(id: "orchid", hexRGB: 0xD58BC8),
        PaletteToken(id: "teal", hexRGB: 0x5ABEB5),
        PaletteToken(id: "lime", hexRGB: 0xA4C861),
        PaletteToken(id: "indigo", hexRGB: 0x9795E6),
        PaletteToken(id: "rose", hexRGB: 0xE58FA9),
    ]

    let ordinal: Int
    let paletteIndex: Int

    var paletteToken: PaletteToken { Self.palette[paletteIndex] }
    var color: Color { paletteToken.color }
    var shortLabel: String { String(ordinal) }
}

/// 按聊天/任务标签页固定分配颜色和编号，全部有效映射持久保留。
/// 状态、界面排序和其他任务的数量均不会改变已分配身份。
@MainActor
final class MascotTaskIdentityRegistry {
    static let shared = MascotTaskIdentityRegistry(defaults: AppPreferences.defaults)
    // 沿用已有偏好键以保留历史分配；这里保存完整映射，不执行缓存淘汰。
    static let cacheDefaultsKey = "mascotTaskIdentityCache.v1"
    static let counterDefaultsKey = "mascotTaskIdentityNextOrdinals.v1"

    private struct Entry {
        let agent: String
        let ordinal: Int

        var identity: MascotTaskIdentity {
            MascotTaskIdentity(ordinal: ordinal,
                               paletteIndex: (ordinal - 1) % MascotTaskIdentity.palette.count)
        }
    }

    private let defaults: UserDefaults
    private var entries: [String: Entry] = [:]
    private var nextOrdinals: [String: Int] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let savedCounters = defaults.dictionary(forKey: Self.counterDefaultsKey) ?? [:]
        for agent in AgentType.allCases {
            if let next = savedCounters[agent.rawValue] as? Int, Self.isValidOrdinal(next) {
                nextOrdinals[agent.rawValue] = next
            }
        }

        guard let saved = defaults.dictionary(forKey: Self.cacheDefaultsKey),
              saved["version"] as? Int == 1,
              let records = saved["entries"] as? [[String: Any]] else { return }

        var assignedOrdinals = Set<String>()
        for record in records {
            guard let key = record["key"] as? String, Self.isValidDigest(key),
                  let agent = record["agent"] as? String, AgentType(rawValue: agent) != nil,
                  let ordinal = record["ordinal"] as? Int, Self.isValidOrdinal(ordinal),
                  entries[key] == nil,
                  assignedOrdinals.insert("\(agent):\(ordinal)").inserted else { continue }
            entries[key] = Entry(agent: agent, ordinal: ordinal)
            nextOrdinals[agent] = max(nextOrdinals[agent] ?? 1, ordinal + 1)
        }
    }

    func identity(for session: AgentSession, agentType: AgentType? = nil) -> MascotTaskIdentity {
        let agent = (agentType ?? session.agentType).rawValue
        let key = Self.key(for: session, agent: agent)
        if let entry = entries[key], entry.agent == agent {
            return entry.identity
        }

        let ordinal = nextOrdinals[agent] ?? 1
        nextOrdinals[agent] = ordinal + 1
        let entry = Entry(agent: agent, ordinal: ordinal)
        entries[key] = entry
        persist()
        return entry.identity
    }

    private static func key(for session: AgentSession, agent: String) -> String {
        let components: [String]
        if let namespace = session.sourceNamespace, !namespace.isEmpty,
           let task = session.nativeTaskId, !task.isEmpty {
            // nativeTaskId 跨观察实例保持不变；Roo 扩展重载不应产生新配色。
            components = [agent, "native", namespace, task]
        } else {
            components = [agent, "session", session.id]
        }
        let input = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidOrdinal(_ value: Int) -> Bool {
        // 拒绝损坏偏好中的极大整数，给后续递增保留充足空间。
        value > 0 && value < Int.max / 2
    }

    private static func isValidDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func persist() {
        let records: [[String: Any]] = entries.sorted { $0.key < $1.key }.map {
            ["key": $0.key, "agent": $0.value.agent, "ordinal": $0.value.ordinal]
        }
        // 只在分配新身份时写入；命中及 UI 重排不修改映射或偏好。
        defaults.set(nextOrdinals, forKey: Self.counterDefaultsKey)
        defaults.set(["version": 1, "entries": records], forKey: Self.cacheDefaultsKey)
    }
}
