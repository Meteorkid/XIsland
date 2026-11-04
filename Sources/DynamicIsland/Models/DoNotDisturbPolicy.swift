import Foundation

/// 锁屏 / 屏保 / 显示器睡眠三态独立跟踪。
///
/// 借鉴 CodeIsland：只把「锁屏」与「屏保」算作用户离开（触发离开时推送）；
/// 显示器睡眠是硬性静音——屏幕都灭了，发通知没有意义。
struct SceneMuteState: Equatable, Sendable {
    var isScreenLocked = false
    var isScreensaverActive = false
    var isDisplayAsleep = false

    var isAway: Bool { isScreenLocked || isScreensaverActive }
    var isHardMuted: Bool { isDisplayAsleep }
}

struct DoNotDisturbPolicy: Equatable, Sendable {
    var quietHoursEnabled = false
    var quietStart = "22:00"
    var quietEnd = "07:00"
    var silencedDirectories: [String] = []
    /// 用户正与岛交互（面板展开且近期有操作）时不重复提醒。
    var suppressWhenUserActive = true
    var suppressSubagents = true
    /// 未读完成 / 待办在 N 分钟后追加一次提醒。
    var followUpEnabled = false
    var followUpDelay: TimeInterval = 10 * 60

    /// 是否允许为这个事件发通知或推送。
    func shouldNotify(event: IslandEvent,
                      scene: SceneMuteState,
                      isUserActive: Bool,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> Bool {
        // 后台压缩不能把已完成卡片「唤醒」成一条新提醒。
        if event.kind == .backgroundCompaction { return false }
        if scene.isHardMuted { return false }
        if suppressSubagents, event.isSubagent { return false }
        if isSilenced(event.workingDirectory) { return false }
        if isInQuietHours(now: now, calendar: calendar), !event.requiresUserDecision { return false }
        if suppressWhenUserActive, isUserActive { return false }
        return true
    }

    /// 静默目录：按路径子串匹配，大小写不敏感，空条目忽略。
    func isSilenced(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let lowered = path.lowercased()
        return silencedDirectories.contains { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && lowered.contains(trimmed.lowercased())
        }
    }

    /// 跨午夜：start > end 时视为「晚间 → 次日清晨」。
    func isInQuietHours(now: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled,
              let start = Self.minutes(from: quietStart),
              let end = Self.minutes(from: quietEnd),
              start != end else { return false }
        let current = calendar.component(.hour, from: now) * 60
            + calendar.component(.minute, from: now)
        if start < end { return current >= start && current < end }
        return current >= start || current < end
    }

    func isFollowUpDue(eventOccurredAt: Date, now: Date) -> Bool {
        guard followUpEnabled, followUpDelay > 0 else { return false }
        return now.timeIntervalSince(eventOccurredAt) >= followUpDelay
    }

    /// 解析 "HH:mm"。非法输入返回 nil，不猜测用户意图。
    static func minutes(from text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// 从逗号 / 换行分隔的设置文本解析静默目录。
    static func parseDirectories(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "，" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
