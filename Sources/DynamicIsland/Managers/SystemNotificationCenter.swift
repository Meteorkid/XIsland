import Foundation
@preconcurrency import UserNotifications

enum SystemNotificationAction: String, Sendable {
    case allow = "XISLAND_ALLOW"
    case deny = "XISLAND_DENY"
    case review = "XISLAND_REVIEW"
}

/// Delegate 桥。`UNUserNotificationCenterDelegate` 的回调不是 `@MainActor`，
/// 且 `UNNotificationResponse` 不是 Sendable：在回调里就地拆成字符串，只把值类型送到主线程。
private final class NotificationActionRelay: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    let handler: @Sendable (SystemNotificationAction, String, String?) -> Void

    init(handler: @escaping @Sendable (SystemNotificationAction, String, String?) -> Void) {
        self.handler = handler
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let sessionId = info["sessionId"] as? String ?? ""
        let requestId = info["requestId"] as? String
        let action = SystemNotificationAction(rawValue: response.actionIdentifier) ?? .review
        handler(action, sessionId, requestId)
        completionHandler()
    }
}

/// A1：系统通知中心。
///
/// 可用条件刻意收紧：
/// 1. `Bundle.main.bundleIdentifier` 必须存在——SwiftPM 裸可执行文件没有 bundle id，
///    直接调用 `UNUserNotificationCenter.current()` 会抛异常；发行时由打包脚本产出 app bundle；
/// 2. 测试隔离环境不碰通知权限，避免 CI 弹权限框或污染用户通知设置。
@MainActor
final class SystemNotificationCenter {
    static let shared = SystemNotificationCenter()

    static let interactionCategory = "XISLAND_INTERACTION"
    static let infoCategory = "XISLAND_INFO"

    static var isAvailable: Bool {
        !AppPreferences.isIsolated && Bundle.main.bundleIdentifier != nil
    }

    /// 通知按钮回传。由 AppDelegate 接到 SessionManager，并校验 requestID。
    var onAction: ((SystemNotificationAction, String, String?) -> Void)?

    private var isConfigured = false
    private var permissionGranted = false
    private var allowsDecisions = false
    private var relay: NotificationActionRelay?

    private init() {}

    func configure(allowsDecisions: Bool) {
        self.allowsDecisions = allowsDecisions
        guard Self.isAvailable, !isConfigured else { return }
        isConfigured = true

        let relay = NotificationActionRelay(handler: { action, sessionId, requestId in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SystemNotificationCenter.shared.onAction?(action, sessionId, requestId)
                }
            }
        })
        self.relay = relay

        let center = UNUserNotificationCenter.current()
        center.delegate = relay

        let allow = UNNotificationAction(identifier: SystemNotificationAction.allow.rawValue,
                                         title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: SystemNotificationAction.deny.rawValue,
                                        title: "Deny", options: [.destructive])
        let review = UNNotificationAction(identifier: SystemNotificationAction.review.rawValue,
                                          title: "Review", options: [.foreground])
        let interaction = UNNotificationCategory(identifier: Self.interactionCategory,
                                                 actions: [allow, deny, review],
                                                 intentIdentifiers: [], options: [])
        let info = UNNotificationCategory(identifier: Self.infoCategory, actions: [review],
                                          intentIdentifiers: [], options: [])
        center.setNotificationCategories([interaction, info])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SystemNotificationCenter.shared.permissionGranted = granted
                }
            }
        }
    }

    /// `redactedDetail` 必须已由 `EventRedaction.redact` 处理。
    func deliver(event: IslandEvent, redactedDetail: String) {
        guard Self.isAvailable, isConfigured else { return }
        guard event.kind != .backgroundCompaction else { return }
        if permissionGranted {
            post(event: event, redactedDetail: redactedDetail)
            return
        }
        // 用户可能在系统设置里事后授权。投递前刷新一次，否则本次运行会一直静默丢弃。
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SystemNotificationCenter.shared.permissionGranted = granted
                    if granted {
                        SystemNotificationCenter.shared.post(event: event,
                                                             redactedDetail: redactedDetail)
                    }
                }
            }
        }
    }

    private func post(event: IslandEvent, redactedDetail: String) {
        let content = UNMutableNotificationContent()
        content.title = EventRedaction.redact(event.title)
        content.body = redactedDetail
        content.sound = .default
        // 默认只允许「查看」；批准/拒绝按钮必须用户在设置里显式开启。
        content.categoryIdentifier = allowsDecisions && event.requiresUserDecision
            ? Self.interactionCategory : Self.infoCategory
        content.userInfo = [
            "sessionId": event.sessionId,
            "requestId": event.requestId ?? "",
            "kind": event.kind.rawValue,
        ]
        let identifier = "xisland." + event.deduplicationKey
            .replacingOccurrences(of: "|", with: ".")
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        ) { _ in }
    }

    /// 请求被消费后撤回对应通知，避免用户点到已失效的按钮。
    func removeDelivered(sessionId: String, requestId: String? = nil) {
        guard Self.isAvailable, isConfigured else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let ids: [String] = notifications.compactMap { note in
                let info = note.request.content.userInfo
                guard (info["sessionId"] as? String) == sessionId else { return nil }
                if let requestId, (info["requestId"] as? String) != requestId { return nil }
                return note.request.identifier
            }
            guard !ids.isEmpty else { return }
            // 重新取 center，避免在 @Sendable 闭包里捕获非 Sendable 的 UNUserNotificationCenter。
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}
