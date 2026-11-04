import Foundation

/// A 类新增设置的文案（第一部分：通用、系统通知、全局快捷键、推送）。
///
/// 范围说明：既有 `L10n` 覆盖简中/英/韩/日/法五语种；本轮新增文案只提供简中与英文，
/// 其余三种语言回退英文。这是有意的折中——与其给出未经校对的机翻，
/// 不如明确标注回退行为，后续国际化时统一补入 `L10n`。
enum ASuiteL10n {
    static func t(_ zh: String, _ en: String) -> String {
        L10n.isChinese ? zh : en
    }

    static var paneTitle: String { t("通知与自动化", "Notifications & Automation") }
    static var paneIntro: String {
        t("所有开关默认关闭。开启系统通知会请求 macOS 通知权限；外部渠道会产生对外网络请求。",
          "All switches are off by default. System notifications require macOS permission; external channels make outbound network requests.")
    }
    static var licenseRequired: String {
        t("这些能力需要有效授权。未授权时只能查看，不能开启。",
          "These features require a valid license. Without one they are read-only.")
    }

    // MARK: A1 系统通知

    static var notificationsSection: String { t("系统通知", "System Notifications") }
    static var notificationsToggle: String { t("发送系统通知", "Deliver system notifications") }
    static var notificationsDesc: String {
        t("会话需要审批、完成或出错时在通知中心提醒。岛内已展开且你正在操作时不再重复提醒。",
          "Notify when a session needs approval, finishes, or fails. Suppressed while the island is expanded and you are interacting.")
    }
    static var allowDecisions: String { t("允许在通知里直接批准 / 拒绝", "Allow approve / deny from notification") }
    static var allowDecisionsDesc: String {
        t("默认关闭。开启后通知按钮会回传决定，且仅在该请求仍然存在、ID 匹配时生效；过期请求一律忽略。",
          "Off by default. When on, notification actions send a decision only if the request still exists and its ID matches. Stale requests are ignored.")
    }
    static var notificationPermissionHint: String {
        t("若系统未授予通知权限，通知会被静默跳过。可在系统设置的通知页中开启。",
          "If macOS notification permission is not granted, delivery is skipped silently. Enable it in System Settings.")
    }

    // MARK: A3 推送与 Webhook

    static var pushSection: String { t("推送与 Webhook", "Push & Webhook") }
    static var pushToggle: String { t("启用外部推送", "Enable outbound push") }
    static var pushDesc: String {
        t("正文出本机前会脱敏（凭据、邮箱、家目录路径、长随机串）。推送只发文本，不代替审批。",
          "Text is redacted before leaving this Mac (credentials, emails, home paths, long random strings). Push is text-only and never replaces approval.")
    }
    static var pushOnlyWhenAway: String { t("仅在锁屏或屏保时推送", "Only push while away") }
    static var pushChannels: String { t("渠道", "Channels") }
    static var pushAdd: String { t("添加渠道", "Add channel") }
    static var pushRemove: String { t("移除", "Remove") }
    static var pushEndpoint: String { t("地址", "Endpoint") }
    static var pushIdentifier: String { t("附加标识", "Identifier") }
    static var pushTest: String { t("发送测试", "Send test") }
    static var pushTestOK: String { t("测试成功", "Test succeeded") }
    static var pushTestFailed: String { t("测试失败", "Test failed") }
    static var pushEvents: String { t("订阅事件", "Subscribed events") }
}
