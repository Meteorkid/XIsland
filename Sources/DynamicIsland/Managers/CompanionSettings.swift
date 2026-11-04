import Foundation

/// 伴端广播的偏好项与开关。
///
/// 单独成文件而不是塞进 AppDelegate：设置界面与启动流程都要用，
/// 键名散落两处迟早会写错一个字母。
enum CompanionSettings {
    /// 是否广播给 iPhone / Watch。默认关闭。
    static let enabledKey = "companionBroadcastEnabled"
    /// 是否允许伴端执行审批。默认关闭，且只在广播开启时有意义。
    static let decisionsKey = "companionRemoteDecisionsEnabled"

    static func registerDefaults(_ defaults: UserDefaults = AppPreferences.defaults) {
        defaults.register(defaults: [
            enabledKey: false,
            decisionsKey: false,
        ])
    }

    /// 应用当前设置到发布器。设置界面改动后调用。
    ///
    /// 读取 `AppPreferences.defaults` 而不是 `UserDefaults.standard`：
    /// 前者是应用与 SwiftUI `@AppStorage` 共用的存储（见 `AppPreferences` 注释），
    /// 用 standard 会读到另一份，表现为"开关拨了没反应"。
    @MainActor
    static func apply(_ defaults: UserDefaults = AppPreferences.defaults) {
        let publisher = CompanionPublisher.shared
        let enabled = defaults.bool(forKey: enabledKey)
        publisher.allowsRemoteDecisions = enabled && defaults.bool(forKey: decisionsKey)
        if enabled {
            publisher.start()
        } else {
            publisher.stop()
        }
    }
}
