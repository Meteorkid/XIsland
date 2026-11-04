import Foundation

/// A6 诊断包的文本生成（纯函数部分）。
///
/// 白名单策略：只导出布尔/数值型设置与会话摘要，渠道地址、附加标识、
/// 授权信息与完整历史正文一律不进入包内。所有文本再过一遍 `EventRedaction`。
enum DiagnosticsTextBuilder {
    static let preferenceAllowlist: [String] = [
        ASuiteSettings.notificationsEnabledKey,
        ASuiteSettings.notificationsAllowDecisionsKey,
        ASuiteSettings.pushEnabledKey,
        ASuiteSettings.pushOnlyWhenAwayKey,
        ASuiteSettings.dndSceneMuteEnabledKey,
        ASuiteSettings.dndFollowUpEnabledKey,
        ASuiteSettings.dndSuppressSubagentsKey,
        ASuiteSettings.lifecycleAutoHideEnabledKey,
        ASuiteSettings.lifecycleReapEnabledKey,
        ASuiteSettings.keepAwakeModeKey,
        ASuiteSettings.quietHoursEnabledKey,
    ]

    static func snapshotSettings(_ defaults: UserDefaults = AppPreferences.defaults) -> [String: String] {
        var result: [String: String] = [:]
        for key in preferenceAllowlist {
            if let value = defaults.object(forKey: key) {
                result[key] = EventRedaction.redact(String(describing: value))
            }
        }
        return result
    }

    static func manifestText(appVersion: String,
                             osVersion: String,
                             generatedAt: Date,
                             settings: [String: String]) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "X Island diagnostics",
            "generatedAt: \(formatter.string(from: generatedAt))",
            "appVersion: \(EventRedaction.redact(appVersion))",
            "osVersion: \(EventRedaction.redact(osVersion))",
            "note: text is redacted; channel addresses, identifiers and history bodies are excluded",
            "",
            "Settings:",
        ]
        for key in settings.keys.sorted() {
            // 二次脱敏：snapshotSettings 已处理过，但 manifest 也可能被直接调用。
            lines.append("\(key) = \(EventRedaction.redact(settings[key] ?? ""))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func sessionsText(_ summaries: [IslandSessionSummary]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let formatter = ISO8601DateFormatter()
        let redacted = summaries.map { summary in
            [
                "id": EventRedaction.redact(summary.id),
                "status": summary.status,
                "title": EventRedaction.redact(summary.title),
                "detail": EventRedaction.redact(summary.detail),
                "workingDirectory": EventRedaction.redact(path: summary.workingDirectory),
                "isSubagent": String(summary.isSubagent),
                "lastActivityAt": formatter.string(from: summary.lastActivityAt),
                "hasPendingInteraction": String(summary.hasPendingInteraction),
            ]
        }
        guard let data = try? encoder.encode(redacted),
              let text = String(data: data, encoding: .utf8) else { return "[]\n" }
        return text + "\n"
    }
}
