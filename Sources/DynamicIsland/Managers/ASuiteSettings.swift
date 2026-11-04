import Foundation

/// A 类功能的偏好项集中定义。
///
/// 与 `CompanionSettings` 同一套约定：键名只在这里出现一次，启动注册默认值，
/// 设置页改动后由 `apply()` 重新读取。所有新能力默认关闭——通知权限、
/// 全局热键、对外网络请求、防休眠断言都属于系统级侵入，必须由用户显式开启。
enum ASuiteSettings {
    // A1 系统通知
    static let notificationsEnabledKey = "asuite.notifications.enabled"
    static let notificationsAllowDecisionsKey = "asuite.notifications.allowDecisions"
    // A2 全局热键已移除（用户决定不做该功能）。原键位不再注册，也不再读写。
    // A3 推送
    static let pushEnabledKey = "asuite.push.enabled"
    static let pushOnlyWhenAwayKey = "asuite.push.onlyWhenAway"
    static let pushConfigurationsKey = "asuite.push.configurations"
    // A4 不打扰
    static let dndSceneMuteEnabledKey = "asuite.dnd.sceneMute"
    static let dndSilencedDirectoriesKey = "asuite.dnd.silencedDirectories"
    static let dndFollowUpEnabledKey = "asuite.dnd.followUp"
    static let dndFollowUpDelayKey = "asuite.dnd.followUpDelay"
    static let dndSuppressSubagentsKey = "asuite.dnd.suppressSubagents"
    // A5 生命周期
    static let lifecycleAutoHideEnabledKey = "asuite.lifecycle.autoHide"
    static let lifecycleReapEnabledKey = "asuite.lifecycle.reapStale"
    // A7 防休眠
    static let keepAwakeModeKey = "asuite.keepAwake.mode"

    /// 复用既有静默时段设置，避免出现两套互不相干的「勿扰时间」。
    static let quietHoursEnabledKey = "quietHoursEnabled"
    static let quietHoursStartKey = "quietHoursStart"
    static let quietHoursEndKey = "quietHoursEnd"

    static func registerDefaults(_ defaults: UserDefaults = AppPreferences.defaults) {
        defaults.register(defaults: [
            notificationsEnabledKey: false,
            notificationsAllowDecisionsKey: false,
            pushEnabledKey: false,
            pushOnlyWhenAwayKey: true,
            pushConfigurationsKey: "[]",
            dndSceneMuteEnabledKey: true,
            dndSilencedDirectoriesKey: "",
            dndFollowUpEnabledKey: false,
            dndFollowUpDelayKey: 600.0,
            dndSuppressSubagentsKey: true,
            lifecycleAutoHideEnabledKey: false,
            lifecycleReapEnabledKey: false,
            keepAwakeModeKey: KeepAwakeMode.off.rawValue,
            quietHoursEnabledKey: false,
            quietHoursStartKey: "22:00",
            quietHoursEndKey: "07:00",
        ])
    }

    // MARK: - 读取（把散落的键组装成策略对象）

    static func dndPolicy(_ defaults: UserDefaults = AppPreferences.defaults) -> DoNotDisturbPolicy {
        DoNotDisturbPolicy(
            quietHoursEnabled: defaults.bool(forKey: quietHoursEnabledKey),
            quietStart: defaults.string(forKey: quietHoursStartKey) ?? "22:00",
            quietEnd: defaults.string(forKey: quietHoursEndKey) ?? "07:00",
            silencedDirectories: DoNotDisturbPolicy.parseDirectories(
                defaults.string(forKey: dndSilencedDirectoriesKey) ?? ""),
            suppressWhenUserActive: defaults.bool(forKey: dndSceneMuteEnabledKey),
            suppressSubagents: defaults.bool(forKey: dndSuppressSubagentsKey),
            followUpEnabled: defaults.bool(forKey: dndFollowUpEnabledKey),
            followUpDelay: defaults.double(forKey: dndFollowUpDelayKey)
        )
    }

    static func pushConfigurations(_ defaults: UserDefaults = AppPreferences.defaults) -> [PushConfiguration] {
        guard let text = defaults.string(forKey: pushConfigurationsKey),
              let data = text.data(using: .utf8),
              let items = try? JSONDecoder().decode([PushConfiguration].self, from: data) else { return [] }
        return items
    }

    static func savePushConfigurations(_ items: [PushConfiguration],
                                       defaults: UserDefaults = AppPreferences.defaults) {
        guard let data = try? JSONEncoder().encode(items),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: pushConfigurationsKey)
    }

    static func keepAwakeMode(_ defaults: UserDefaults = AppPreferences.defaults) -> KeepAwakeMode {
        KeepAwakeMode(rawValue: defaults.string(forKey: keepAwakeModeKey) ?? "") ?? .off
    }

    /// 设置变更后重新应用。由 `UserDefaults.didChangeNotification` 与启动流程共同调用。
    @MainActor
    static func apply(_ defaults: UserDefaults = AppPreferences.defaults) {
        ASuiteEventRouter.shared.applySettings()
    }
}
