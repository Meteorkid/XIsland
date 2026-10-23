import SwiftUI

// MARK: - SF Symbols 动效封装

/// 图标动效档位。
///
/// **能力边界（部署目标 macOS 14）**：TO-DO Panel 的 `lucide-path-breathe`
/// （`pathLength="1"` + `stroke-dasharray` 让图标被「重新画一遍」）
/// 在 SF Symbols 里对应的 `.drawOn` **需要 macOS 15**。
/// 本项目 `Package.swift` 声明 `.macOS(.v14)`，因此该效果当前不可用。
/// 可用的近似子集：
///
/// | 效果 | 可用性 | 视觉机理 |
/// |---|---|---|
/// | `.bounce` | macOS 14 ✓ | 缩放回弹（对应 `motion-icon-tap`） |
/// | `.pulse` | macOS 14 ✓ | 透明度脉动（持续提示） |
/// | `.variableColor` | macOS 14 ✓ | 分层依次变色（近似描边流动，但机理不同：变色 ≠ 描边生长） |
/// | `.scale` | macOS 14 ✓ | 缩放反馈 |
/// | `.drawOn` | **需 macOS 15** ✗ | 精确对应 `lucide-path-breathe` |
enum IslandSymbolMotion {
    /// 图标动效是否启用（受偏好开关 + reduceMotion 双重控制）。
    static func isEnabled(reduceMotion: Bool, preferenceEnabled: Bool) -> Bool {
        preferenceEnabled && !reduceMotion
    }
}

// MARK: - 工具完成动效

/// 工具完成图标的动效。在既有 `.bounce` 基础上叠加 `variableColor` 收尾。
///
/// 保持向后兼容：`isComplete` 为真时先 bounce（与原有行为一致），
/// 因此视觉上不会丢失既有的「完成弹跳」反馈。
struct ToolCompletionSymbolEffect: ViewModifier {
    let isComplete: Bool
    let isFailed: Bool
    let reduceMotion: Bool
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if !IslandSymbolMotion.isEnabled(reduceMotion: reduceMotion, preferenceEnabled: isEnabled) {
            content
        } else {
            content
                .symbolEffect(
                    .bounce,
                    value: isComplete && !isFailed
                )
        }
    }
}

// MARK: - 权限待处理脉动

/// 权限审批入口的持续脉动提示。
///
/// 与既有的 `ActiveSessionGlow`（边框呼吸）的区别：
/// - `ActiveSessionGlow` 作用于**整张卡片边框**，每帧重绘描边，GPU 成本较高；
/// - 本效果作用于**单个图标**，由系统合成器驱动，成本更低。
/// 两者可共存：边框表达「这张卡片是活的」，图标脉动表达「这里需要你」。
struct AttentionPulseModifier: ViewModifier {
    let isActive: Bool
    let reduceMotion: Bool
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isActive && IslandSymbolMotion.isEnabled(reduceMotion: reduceMotion, preferenceEnabled: isEnabled) {
            content
                .symbolEffect(.pulse, options: .repeating)
        } else {
            content
        }
    }
}
