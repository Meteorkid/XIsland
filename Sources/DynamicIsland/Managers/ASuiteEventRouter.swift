import Foundation
import AppKit

/// A 类功能的唯一事件分发点。
///
/// 接线依据：`SessionManager.publishToCompanion()` 已覆盖「新消息 / 关闭 / 超时淘汰」
/// 三条会话变更路径，复用它即可，不再往 SessionManager 里散落第二套通知调用。
/// 状态成员标为 internal 而非 private，是因为实现拆分在两个文件里（见 `+Internals`）。
@MainActor
final class ASuiteEventRouter {
    static let shared = ASuiteEventRouter()

    /// 由 AppDelegate 注入：把系统级动作翻译成 SessionManager / 窗口操作。
    var onNotificationDecision: ((SystemNotificationAction, String, String?) -> Void)?
    var onReapSessionIDs: ((Set<String>) -> Void)?

    let defaults = AppPreferences.defaults
    var previous: [IslandSessionSummary] = []
    var emitted: Set<String> = []
    var scene = SceneMuteState()
    var observers: [NSObjectProtocol] = []
    /// 每个会话一条追提醒。单槽会让多条待办互相取消，先完成的那条永久丢失。
    var followUpWork: [String: DispatchWorkItem] = [:]
    /// 最后一个工作会话结束后的宽限期重算，保证断言一定会被释放。
    var keepAwakeReevaluation: DispatchWorkItem?
    var lastWorkEndedAt: Date?
    var started = false
    /// 设置签名：`UserDefaults.didChangeNotification` 会因任意写入触发，
    /// 没有变化时不应反复注销/重注册全局热键（会让快捷键在拖动滑块时短暂失效）。
    var lastAppliedSignature: String?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        subscribeSceneEvents()
        SystemNotificationCenter.shared.onAction = { [weak self] action, sessionId, requestId in
            self?.onNotificationDecision?(action, sessionId, requestId)
        }
        applySettings()
    }

    func stop() {
        followUpWork.values.forEach { $0.cancel() }
        followUpWork.removeAll()
        keepAwakeReevaluation?.cancel()
        keepAwakeReevaluation = nil
        for token in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            DistributedNotificationCenter.default().removeObserver(token)
        }
        observers.removeAll()
        SessionKeepAwakeController.shared.stop()
        SessionLifecycleGovernor.shared.reset()
        // 重置签名：否则重新 start 时 applySettings 会因签名未变而跳过，
        // 热键与通知配置不会被重新注册。
        lastAppliedSignature = nil
        started = false
    }

    /// 设置变更后重新应用：权限、热键注册、断言释放都在这里收敛。
    func applySettings() {
        let notificationsEnabled = defaults.bool(forKey: ASuiteSettings.notificationsEnabledKey)
        let allowDecisions = defaults.bool(forKey: ASuiteSettings.notificationsAllowDecisionsKey)
        let lifecycleEnabled = defaults.bool(forKey: ASuiteSettings.lifecycleAutoHideEnabledKey)

        // 只对"需要重建系统资源"的键做去重；通知正文与推送开关在投递时实时读取，无需重建。
        let signature = [
            String(notificationsEnabled),
            String(allowDecisions),
            defaults.string(forKey: ASuiteSettings.keepAwakeModeKey) ?? "",
            String(lifecycleEnabled),
        ].joined(separator: "|")
        guard signature != lastAppliedSignature else { return }
        lastAppliedSignature = signature

        // 用户从未开启通知时不要请求权限：首次启动就弹授权框违背「默认关闭」的承诺。
        if notificationsEnabled {
            SystemNotificationCenter.shared.configure(allowsDecisions: allowDecisions)
        } else {
            followUpWork.values.forEach { $0.cancel() }
            followUpWork.removeAll()
        }

        if !lifecycleEnabled {
            SessionLifecycleGovernor.shared.reset()
        }

        // 模式切换后立即评估一次，不必等到下一次会话事件才建立/释放断言。
        applyKeepAwake(previous)
    }

    /// 会话状态变更的唯一入口。由 `SessionManager.publishToCompanion()` 调用。
    func sessionsDidChange(_ sessions: [AgentSession]) {
        let current = IslandSummaryMapper.make(sessions)
        let prior = previous
        let now = Date()

        let events = IslandEventDeriver.derive(previous: prior, current: current,
                                               now: now, emitted: emitted)
        for event in events { emitted.insert(event.deduplicationKey) }
        emitted = IslandEventDeriver.prune(emitted: emitted,
                                           liveSessionIDs: Set(current.map(\.id)))
        previous = current

        retractConsumedNotifications(prior: prior, current: current)

        let dnd = ASuiteSettings.dndPolicy()
        let isUserActive = EnergyGovernor.shared.isPanelExpanded
            && EnergyGovernor.shared.mode == .active

        let notificationsEnabled = defaults.bool(forKey: ASuiteSettings.notificationsEnabledKey)
        let pushEnabled = defaults.bool(forKey: ASuiteSettings.pushEnabledKey)
        let onlyWhenAway = defaults.bool(forKey: ASuiteSettings.pushOnlyWhenAwayKey)
        let configs = ASuiteSettings.pushConfigurations()

        for event in events {
            guard event.kind != .backgroundCompaction else { continue }
            let redacted = EventRedaction.redact(event.detail)
            if notificationsEnabled,
               dnd.shouldNotify(event: event, scene: scene,
                                isUserActive: isUserActive, now: now) {
                SystemNotificationCenter.shared.deliver(event: event, redactedDetail: redacted)
            }
            if pushEnabled {
                for config in configs where PushPolicy.shouldDeliver(
                    event: event, config: config, scene: scene,
                    onlyWhenAway: onlyWhenAway, isUserActive: isUserActive,
                    dnd: dnd, now: now) {
                    PushNotifier.shared.deliver(config: config, event: event,
                                                redactedDetail: redacted)
                }
            }
            scheduleFollowUp(for: event, dnd: dnd,
                             notificationsEnabled: notificationsEnabled)
        }

        applyLifecycle(current)
        applyKeepAwake(current)
    }
}
