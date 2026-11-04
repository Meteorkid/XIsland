import Foundation
import AppKit

/// `ASuiteEventRouter` 的内部实现。拆分只为控制单文件体积，逻辑仍属于同一个类。
extension ASuiteEventRouter {
    func subscribeSceneEvents() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter

        func add(_ center: NotificationCenter, _ name: Notification.Name,
                 _ update: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { update() }
            }
            observers.append(token)
        }

        add(distributed, Notification.Name("com.apple.screenIsLocked")) {
            ASuiteEventRouter.shared.scene.isScreenLocked = true
        }
        add(distributed, Notification.Name("com.apple.screenIsUnlocked")) {
            ASuiteEventRouter.shared.scene.isScreenLocked = false
        }
        add(distributed, Notification.Name("com.apple.screensaver.didstart")) {
            ASuiteEventRouter.shared.scene.isScreensaverActive = true
        }
        add(distributed, Notification.Name("com.apple.screensaver.didstop")) {
            ASuiteEventRouter.shared.scene.isScreensaverActive = false
        }
        add(workspace, NSWorkspace.screensDidSleepNotification) {
            ASuiteEventRouter.shared.scene.isDisplayAsleep = true
        }
        add(workspace, NSWorkspace.screensDidWakeNotification) {
            ASuiteEventRouter.shared.scene.isDisplayAsleep = false
        }
    }

    func retractConsumedNotifications(prior: [IslandSessionSummary],
                                      current: [IslandSessionSummary]) {
        guard SystemNotificationCenter.isAvailable else { return }
        let live = Set(current.compactMap(\.interactionId))
        for old in prior {
            guard let id = old.interactionId, !live.contains(id) else { continue }
            SystemNotificationCenter.shared.removeDelivered(sessionId: old.id, requestId: id)
        }
    }

    func scheduleFollowUp(for event: IslandEvent,
                          dnd: DoNotDisturbPolicy,
                          notificationsEnabled: Bool) {
        guard notificationsEnabled, dnd.followUpEnabled,
              event.kind == .completed || event.requiresUserDecision else { return }
        followUpWork[event.sessionId]?.cancel()
        let delay = max(1, dnd.followUpDelay)
        let key = event.sessionId
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.followUpWork.removeValue(forKey: key)
                guard self.requestStillPending(event) else { return }
                let reminder = IslandEvent(
                    kind: event.kind, sessionId: event.sessionId,
                    requestId: event.requestId,
                    stableToken: event.stableToken + "-followup",
                    title: event.title, detail: event.detail,
                    workingDirectory: event.workingDirectory,
                    isSubagent: event.isSubagent, occurredAt: Date()
                )
                let policy = ASuiteSettings.dndPolicy()
                guard policy.shouldNotify(event: reminder, scene: self.scene,
                                          isUserActive: false, now: Date()) else { return }
                SystemNotificationCenter.shared.deliver(
                    event: reminder,
                    redactedDetail: ASuiteL10n.t("仍有未处理的事项", "An item is still waiting"))
            }
        }
        followUpWork[event.sessionId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func requestStillPending(_ event: IslandEvent) -> Bool {
        guard let requestId = event.requestId else {
            return previous.contains { $0.id == event.sessionId && $0.needsReview }
        }
        return previous.contains { $0.id == event.sessionId && $0.interactionId == requestId }
    }

    func applyLifecycle(_ current: [IslandSessionSummary]) {
        let now = Date()
        // 自动隐藏与同工作区取代都由同一个开关控制，避免出现"关了开关却还在隐藏"的怪状态。
        let enabled = defaults.bool(forKey: ASuiteSettings.lifecycleAutoHideEnabledKey)
        var hidden: Set<String> = []
        if enabled {
            hidden = Set(current.filter {
                SessionLifecyclePolicy.shouldAutoHide(
                    status: $0.status,
                    hasPendingInteraction: $0.hasPendingInteraction,
                    needsReview: $0.needsReview,
                    lastActivityAt: $0.lastActivityAt, now: now)
            }.map(\.id))
        }
        SessionLifecycleGovernor.shared.update(
            hidden: hidden,
            superseded: enabled ? SessionLifecyclePolicy.supersededSessionIDs(current) : [])

        if defaults.bool(forKey: ASuiteSettings.lifecycleReapEnabledKey) {
            let stale = Set(current.filter {
                $0.isObservationEnded && $0.hasPendingInteraction
                    && now.timeIntervalSince($0.lastActivityAt) >= SessionLifecyclePolicy.reapGrace
            }.map(\.id))
            if !stale.isEmpty { onReapSessionIDs?(stale) }
        }
    }

    func applyKeepAwake(_ current: [IslandSessionSummary]) {
        let mode = ASuiteSettings.keepAwakeMode()
        let hasWorking = IslandSummaryMapper.hasWorkingSession(current)
        if hasWorking {
            lastWorkEndedAt = nil
            keepAwakeReevaluation?.cancel()
            keepAwakeReevaluation = nil
        } else if lastWorkEndedAt == nil {
            lastWorkEndedAt = Date()
            if mode == .auto { scheduleKeepAwakeRelease() }
        }

        var percent: Int?
        var charging = false
        if mode != .off {
            let battery = BatterySnapshot.read()
            percent = battery.percent
            charging = battery.isCharging
        }
        let hold = KeepAwakePolicy.shouldHold(
            mode: mode, hasWorkingSession: hasWorking,
            batteryPercent: percent, isCharging: charging,
            lastWorkEndedAt: lastWorkEndedAt, now: Date())
        SessionKeepAwakeController.shared.apply(shouldHold: hold)
    }

    /// 宽限期结束时重算一次。
    ///
    /// 没有这个定时器，最后一个工作会话结束后不再有事件，断言会一直被持有，
    /// 机器无法进入空闲睡眠——这是「省电功能变成耗电功能」的典型失败模式。
    func scheduleKeepAwakeRelease() {
        keepAwakeReevaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keepAwakeReevaluation = nil
                self.applyKeepAwake(self.previous)
            }
        }
        keepAwakeReevaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + KeepAwakePolicy.grace + 5,
                                      execute: work)
    }
}
