import AppKit
import Foundation

// MARK: - 事件

/// 需要触觉反馈的交互事件。
///
/// 为什么刘海类应用特别需要触觉：刘海位于**视线之外**，用户手在触控板上、眼在别处。
/// 权限审批这类关键操作如果只有视觉反馈，用户容易错过。触觉是唯一能「穿透」注意力的通道。
enum IslandHapticEvent: String, CaseIterable, Sendable {
    /// 权限审批卡片弹出——最关键，需要穿透注意力。
    case permissionRequest
    /// 问答 / 计划评审等待输入。
    case inputRequired
    /// 面板展开。
    case panelExpand
    /// 面板收起。
    case panelCollapse
    /// 切换会话。
    case sessionSwitch
    /// 工具调用完成。
    case toolCompletion
    /// 操作失败 / 拒绝。
    case failure

    /// 本地化标题。
    var localizedTitle: String {
        switch self {
        case .permissionRequest: return L10n.hapticEventPermission
        case .inputRequired: return L10n.hapticEventInput
        case .panelExpand: return L10n.hapticEventExpand
        case .panelCollapse: return L10n.hapticEventCollapse
        case .sessionSwitch: return L10n.hapticEventSwitch
        case .toolCompletion: return L10n.hapticEventToolDone
        case .failure: return L10n.hapticEventFailure
        }
    }

    /// 该事件的「显著性」——决定它出现在哪一档强度里。
    ///
    /// 数值越小越关键，越早被低档强度纳入。
    var salience: Int {
        switch self {
        case .permissionRequest: return 0
        case .failure: return 1
        case .inputRequired: return 2
        case .panelExpand, .panelCollapse: return 3
        case .sessionSwitch: return 4
        case .toolCompletion: return 5
        }
    }
}

// MARK: - 强度

/// 触觉反馈强度。
///
/// **实现说明（必须知道的能力边界）**：macOS 公开 API
/// `NSHapticFeedbackManager` 只提供三种 pattern，**无法控制绝对振动强度**。
/// 因此这里的「强度」实际控制的是**事件覆盖范围**——档位越高，纳入反馈的事件越多。
/// 更细腻的强度分级需要私有框架 `HTKMultitouch`，代价是无法上架 App Store 且系统更新可能失效，
/// 本项目当前不采用。
enum IslandHapticIntensity: String, CaseIterable, Sendable {
    case off
    case minimal
    case standard
    case full

    static let defaultValue: Self = .standard

    static func resolve(rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? defaultValue
    }

    /// 纳入反馈的事件最大显著性阈值；`nil` 表示关闭。
    var salienceThreshold: Int? {
        switch self {
        case .off: return nil
        case .minimal: return 1
        case .standard: return 3
        case .full: return 5
        }
    }

    var localizedTitle: String {
        switch self {
        case .off: return L10n.hapticIntensityOff
        case .minimal: return L10n.hapticIntensityMinimal
        case .standard: return L10n.hapticIntensityStandard
        case .full: return L10n.hapticIntensityFull
        }
    }

    var localizedDescription: String {
        switch self {
        case .off: return L10n.hapticIntensityOffDesc
        case .minimal: return L10n.hapticIntensityMinimalDesc
        case .standard: return L10n.hapticIntensityStandardDesc
        case .full: return L10n.hapticIntensityFullDesc
        }
    }
}

// MARK: - 决策（纯函数，可单测）

/// 触觉反馈的触发决策。与副作用分离，便于单元测试。
enum IslandHapticPolicy {

    /// 判断某事件在某强度下是否应触发。
    ///
    /// - Parameters:
    ///   - event: 交互事件。
    ///   - intensity: 用户选择的强度。
    ///   - isIsolated: 是否处于测试隔离环境。测试下必须静默——
    ///     否则测试会触发真实硬件反馈，且不可重复。
    static func shouldFire(
        event: IslandHapticEvent,
        intensity: IslandHapticIntensity,
        isIsolated: Bool
    ) -> Bool {
        guard !isIsolated else { return false }
        guard let threshold = intensity.salienceThreshold else { return false }
        return event.salience <= threshold
    }

    /// 事件到系统 pattern 的映射。
    ///
    /// pattern 选择依据（公开 API 仅此三种）：
    /// - `.alignment`——「对齐/吸附」感，用于导航类轻量切换。
    /// - `.levelChange`——「层级变化」感，用于容器尺寸/层级改变。
    ///   **注意**：`levelChange` 在部分机型上会先发一声听觉提示，因此只用于
    ///   用户主动发起的结构变化（展开/收起），不用于被动通知。
    /// - `.generic`——通用提示，用于需要穿透注意力的通知。
    static func pattern(for event: IslandHapticEvent) -> NSHapticFeedbackManager.FeedbackPattern {
        switch event {
        case .permissionRequest, .failure, .inputRequired:
            return .generic
        case .panelExpand, .panelCollapse:
            return .levelChange
        case .sessionSwitch, .toolCompletion:
            return .alignment
        }
    }

    /// 反馈时机。全部使用 `.now`——这些事件都由已发生的事实驱动，
    /// 不需要 `.default` 的「预测性」提前量。
    static let performanceTime: NSHapticFeedbackManager.PerformanceTime = .now
}

// MARK: - 执行

/// 可替换的执行器。抽成协议是为了：
/// 1. 单元测试可注入记录型实现；
/// 2. 将来若切换到私有 API 增强，只需替换实现，不动调用点。
@MainActor
protocol HapticPerforming {
    func perform(pattern: NSHapticFeedbackManager.FeedbackPattern, time: NSHapticFeedbackManager.PerformanceTime)
}

/// 基于公开 API 的执行器。零上架风险。
@MainActor
struct SystemHapticPerformer: HapticPerforming {
    func perform(pattern: NSHapticFeedbackManager.FeedbackPattern, time: NSHapticFeedbackManager.PerformanceTime) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: time)
    }
}

/// 触觉反馈统一入口。
@MainActor
enum IslandHapticEngine {
    /// 当前执行器。测试可替换。
    static var performer: HapticPerforming = SystemHapticPerformer()

    /// 触发一次触觉反馈。
    ///
    /// 决策与实际执行分离：`IslandHapticPolicy.shouldFire` 是纯函数，
    /// 本方法只负责读偏好并调用执行器。
    static func fire(_ event: IslandHapticEvent) {
        let intensity = IslandHapticIntensity.resolve(
            rawValue: AppPreferences.defaults.string(forKey: "hapticIntensity") ?? IslandHapticIntensity.defaultValue.rawValue
        )
        fire(event, intensity: intensity)
    }

    /// 显式指定强度触发（供测试与内部调用）。
    static func fire(_ event: IslandHapticEvent, intensity: IslandHapticIntensity) {
        guard IslandHapticPolicy.shouldFire(
            event: event,
            intensity: intensity,
            isIsolated: AppPreferences.isIsolated
        ) else { return }

        performer.perform(
            pattern: IslandHapticPolicy.pattern(for: event),
            time: IslandHapticPolicy.performanceTime
        )
    }

    /// 恢复默认执行器（测试清理用）。
    static func resetPerformer() {
        performer = SystemHapticPerformer()
    }
}
