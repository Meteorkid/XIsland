import Foundation

/// 所有展开方式共用一个延迟；禁用与0秒立即触发分开表达。
enum ExpandedAutoCollapsePolicy {
    static func delay(
        state: IslandState,
        protectsInteraction: Bool,
        isEnabled: Bool,
        configuredDelay: TimeInterval
    ) -> TimeInterval? {
        guard isEnabled, state != .collapsed, !protectsInteraction,
              configuredDelay.isFinite, configuredDelay >= 0 else { return nil }
        return configuredDelay
    }
}
