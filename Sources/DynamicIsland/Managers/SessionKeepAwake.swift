import Foundation
import IOKit.pwr_mgt

enum KeepAwakeMode: String, CaseIterable, Codable, Sendable {
    case off
    case auto
    case always
}

enum KeepAwakePolicy {
    /// 最后一个工作会话结束后，仍保持一段宽限，避免频繁创建/释放断言。
    static let grace: TimeInterval = 120
    static let lowBatteryThreshold = 35

    static func shouldHold(mode: KeepAwakeMode,
                           hasWorkingSession: Bool,
                           batteryPercent: Int?,
                           isCharging: Bool,
                           lastWorkEndedAt: Date?,
                           now: Date,
                           grace: TimeInterval = KeepAwakePolicy.grace) -> Bool {
        switch mode {
        case .off:
            return false
        case .auto:
            let withinGrace = lastWorkEndedAt.map { now.timeIntervalSince($0) < grace } ?? false
            guard hasWorkingSession || withinGrace else { return false }
        case .always:
            break
        }
        // 低电量且未接电源时暂停，避免为了一个后台断言把笔记本耗到关机。
        if let percent = batteryPercent, percent <= lowBatteryThreshold, !isCharging {
            return false
        }
        return true
    }
}

/// A7：只阻止系统空闲睡眠（不阻止手动合盖、关机）。
@MainActor
final class SessionKeepAwakeController {
    static let shared = SessionKeepAwakeController()

    static var isAvailable: Bool { !AppPreferences.isIsolated }

    private(set) var isHolding = false
    private var assertionID: IOPMAssertionID = 0

    private init() {}

    func apply(shouldHold: Bool) {
        guard Self.isAvailable else { return }
        let target = shouldHold
        guard target != isHolding else { return }
        if target {
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "X Island: active agent session" as CFString,
                &assertionID
            )
            isHolding = status == kIOReturnSuccess
            if !isHolding { assertionID = 0 }
        } else {
            if assertionID != 0 { IOPMAssertionRelease(assertionID) }
            assertionID = 0
            isHolding = false
        }
    }

    func stop() { apply(shouldHold: false) }
}
