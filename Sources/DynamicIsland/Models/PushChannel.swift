import Foundation

enum PushChannelKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case bark
    case ntfy
    case dingTalk
    case feishu
    case wecom
    case slack
    case telegram
    case webhook

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bark: "Bark"
        case .ntfy: "ntfy"
        case .dingTalk: "DingTalk"
        case .feishu: "Feishu"
        case .wecom: "WeCom"
        case .slack: "Slack"
        case .telegram: "Telegram"
        case .webhook: "Webhook"
        }
    }

    /// 是否需要额外的 secret 字段（签名密钥 / 群机器人密钥 / chat id）。
    var requiresSecret: Bool {
        switch self {
        case .dingTalk, .feishu, .wecom, .telegram: return true
        default: return false
        }
    }
}

struct PushConfiguration: Equatable, Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var kind: PushChannelKind = .webhook
    /// Bark / ntfy 的服务器地址；Webhook / Slack / 群机器人的完整回调 URL。
    var endpoint: String = ""
    /// 签名密钥、chat id 等。**不得**写入诊断导出。
    var secret: String = ""
    var enabledEvents: Set<String> = PushConfiguration.defaultEvents
    var isEnabled: Bool = true

    static let defaultEvents: Set<String> = [
        IslandEventKind.permission.rawValue,
        IslandEventKind.question.rawValue,
        IslandEventKind.planReview.rawValue,
        IslandEventKind.completed.rawValue,
        IslandEventKind.error.rawValue,
    ]

    /// 配置是否足以构造请求。不合法时静默跳过，不重试、不打扰用户。
    var isValid: Bool {
        guard isEnabled, !endpoint.isEmpty else { return false }
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              !(url.host ?? "").isEmpty else { return false }
        if kind.requiresSecret { return !secret.isEmpty }
        return true
    }
}

enum PushPolicy {
    /// 是否把事件投递到某个推送渠道。
    ///
    /// 「推送不代替审批」是硬约束：推送正文只有脱敏文本，没有任何可执行决定，
    /// 用户仍需回到岛内或系统通知里做决定。
    static func shouldDeliver(event: IslandEvent,
                              config: PushConfiguration,
                              scene: SceneMuteState,
                              onlyWhenAway: Bool,
                              isUserActive: Bool,
                              dnd: DoNotDisturbPolicy,
                              now: Date = Date(),
                              calendar: Calendar = .current) -> Bool {
        guard config.isValid, config.enabledEvents.contains(event.kind.rawValue) else { return false }
        // 子会话是否抑制由 `DoNotDisturbPolicy.suppressSubagents` 决定；
        // 这里再硬编码一次会让「允许子会话提醒」的开关失效。
        guard event.kind != .backgroundCompaction else { return false }
        // 默认「仅在离开时推」：人在电脑前，岛已经能提醒，不必再往手机发一条。
        if onlyWhenAway, !scene.isAway { return false }
        return dnd.shouldNotify(event: event, scene: scene,
                                isUserActive: isUserActive, now: now, calendar: calendar)
    }
}
