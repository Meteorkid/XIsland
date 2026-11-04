import Foundation

/// A 类新增设置的文案（第二部分：不打扰、生命周期、诊断导出、防休眠）。
extension ASuiteL10n {
    // MARK: A4 不打扰

    static var dndSection: String { t("不打扰策略", "Do Not Disturb") }
    static var dndDesc: String {
        t("锁屏与屏保算「离开」；显示器睡眠为硬性静音。审批、提问、计划审核不受静默时段限制。",
          "Lock screen and screensaver count as away; display sleep is a hard mute. Approvals, questions and plan reviews bypass quiet hours.")
    }
    static var dndSilenced: String { t("静默目录（逗号分隔）", "Silenced directories (comma-separated)") }
    static var dndSilencedPlaceholder: String { t("例如 /tmp, node_modules", "e.g. /tmp, node_modules") }
    static var dndSuppressSubagents: String { t("子会话不提醒", "Suppress subagent alerts") }
    static var dndSuppressWhenActive: String {
        t("岛已展开且你正在操作时不重复提醒", "Suppress while the island is expanded and active")
    }
    static var dndFollowUp: String { t("未读事项追加提醒", "Follow-up reminder for unread items") }
    static var dndFollowUpDelay: String { t("追加提醒延迟", "Follow-up delay") }

    // MARK: A5 会话生命周期

    static var lifecycleSection: String { t("会话生命周期", "Session Lifecycle") }
    static var lifecycleAutoHide: String { t("30 分钟无活动自动隐藏", "Auto-hide after 30 minutes idle") }
    static var lifecycleReap: String { t("进程失联时撤销挂起审批", "Reap stale pending approvals") }
    static var lifecycleDesc: String {
        t("需要人工介入的会话永不自动隐藏；同一工作目录只保留最近活跃的一条。隐藏只影响显示，不删除会话或历史，搜索时可重新找到。",
          "Sessions needing your decision are never hidden; only the most recently active session per workspace stays visible. Hiding affects display only, and search still finds hidden sessions.")
    }

    // MARK: A6 诊断导出

    static var diagnosticsSection: String { t("诊断导出", "Diagnostics") }
    static var diagnosticsDesc: String {
        t("打包应用信息、设置快照、会话状态与近期日志为 zip。导出前会脱敏凭据、邮箱与家目录路径，请先检查内容再分享。",
          "Bundle app info, settings, session state and recent logs into a zip. Credentials, emails and home paths are redacted; review before sharing.")
    }
    static var diagnosticsExport: String { t("导出诊断包…", "Export diagnostics…") }
    static var diagnosticsOK: String { t("已导出", "Exported") }
    static var diagnosticsFailed: String { t("导出失败", "Export failed") }

    // MARK: A7 防休眠

    static var keepAwakeSection: String { t("防休眠", "Keep Awake") }
    static var keepAwakeDesc: String {
        t("仅阻止系统空闲睡眠，不阻止手动合盖或关机。低电量时自动暂停。",
          "Prevents idle system sleep only; never blocks lid close or shutdown. Pauses on low battery.")
    }
    static var keepAwakeMode: String { t("模式", "Mode") }
    static var keepAwakeOff: String { t("关闭", "Off") }
    static var keepAwakeAuto: String { t("有工作会话时", "While sessions work") }
    static var keepAwakeAlways: String { t("始终", "Always") }

    // MARK: 通用

    static var minutes: String { t("分钟", "min") }
    static var enabled: String { t("已启用", "Enabled") }
    static var disabled: String { t("已关闭", "Disabled") }
}
