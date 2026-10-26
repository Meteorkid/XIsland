import Foundation
import CoreFoundation

enum AutoCollapseSettings {
    static let enabledKey = "autoCollapseEnabled"
    static let delayKey = "pointerExitCollapseDelay"
    static let defaultDelay: TimeInterval = 3
    static let delayRange: ClosedRange<Double> = 0...600

    /// 只迁移用户实际保存的值，忽略进程共享的注册默认值；保留旧字段以支持回退。
    static func migrate(_ defaults: UserDefaults, domainName: String) {
        let saved = defaults.persistentDomain(forName: domainName) ?? [:]
        let legacyExitDelay = number(saved["expandedInactivityAutoHideDelay"])
        let legacyPrimaryDelay = number(saved["autoCollapseDelay"])
        if saved[enabledKey] == nil {
            // 普通移出曾明确关闭时保留意图；单独关闭交互完成分支并不等于整体关闭。
            defaults.set(legacyExitDelay.map { $0 > 0 } ?? true, forKey: enabledKey)
        }
        if let current = validDelay(saved[delayKey]) {
            if current > delayRange.upperBound { defaults.set(delayRange.upperBound, forKey: delayKey) }
        } else {
            // 统一沿用界面原先名为“自动收起延迟”的显式值，包括用户选择的0秒。
            let delay = validDelay(legacyPrimaryDelay) ?? validDelay(legacyExitDelay) ?? defaultDelay
            defaults.set(min(delay, delayRange.upperBound), forKey: delayKey)
        }
    }

    private static func validDelay(_ value: Any?) -> Double? {
        guard let value = number(value), value >= 0 else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
