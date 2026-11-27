import Foundation

/// 摘要模型按 provider 独立存储。
///
/// 旧版只有一个 `summaryModel`，切换 provider 后会把上一个 provider 的模型名带过去；
/// 该键只做一次迁移，迁移后各 provider 互不影响。
enum SummaryModelStore {
    static let legacyKey = "summaryModel"
    static let keyPrefix = "summaryModel."

    static func key(for provider: String) -> String {
        keyPrefix + provider
    }

    static func model(for provider: String, defaults: UserDefaults = AppPreferences.defaults) -> String {
        if let value = defaults.string(forKey: key(for: provider)), !value.isEmpty {
            return value
        }
        // 旧版全局模型只迁移到当前 provider；其他 provider 使用自己的默认值。
        if let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty {
            defaults.set(legacy, forKey: key(for: provider))
            defaults.removeObject(forKey: legacyKey)
            return legacy
        }
        return ""
    }

    static func set(_ model: String, for provider: String, defaults: UserDefaults = AppPreferences.defaults) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key(for: provider))
        } else {
            defaults.set(trimmed, forKey: key(for: provider))
        }
    }
}

/// 摘要功能的隐私同意状态。
///
/// 只有用户明确开启并确认数据会发送到所选后端后，后台摘要才会运行。
enum SummaryConsent {
    static let enabledKey = "llmRecapEnabled"
    static let consentVersionKey = "llmRecapConsentVersion"
    static let consentVersion = 1

    static func isEnabled(defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        guard defaults.bool(forKey: enabledKey) else { return false }
        return defaults.integer(forKey: consentVersionKey) >= consentVersion
    }

    static func accept(defaults: UserDefaults = AppPreferences.defaults) {
        defaults.set(true, forKey: enabledKey)
        defaults.set(consentVersion, forKey: consentVersionKey)
    }

    static func disable(defaults: UserDefaults = AppPreferences.defaults) {
        defaults.set(false, forKey: enabledKey)
    }
}
