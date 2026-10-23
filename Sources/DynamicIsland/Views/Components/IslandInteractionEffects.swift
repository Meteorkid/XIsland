import SwiftUI

// MARK: - 入场级联

/// 卡片依次「上浮落定」的入场动效。
///
/// 借鉴 TO-DO Panel 的 `.home-bento > *` `riseIn`（设计文档 §1.5）：
/// - 每张卡片按 `index * stagger` 延迟依次入场，形成级联而非整体闪现。
/// - **只动 transform / opacity**（合成层），不动 layout 属性——避免触发布局重算。
/// - 关键细节：延迟期间元素必须保持**动画起始态**，否则会先显示再跳。
///   这里用「初始值即起始态 + 延迟后再改」的方式实现，等价于 CSS 的 `animation-fill-mode: backwards`。
///
/// 关闭条件：`reduceMotion` 为真时直接落到终态，不做任何过渡。
struct CardEntranceCascade: ViewModifier {
    /// 在列表中的序号，决定延迟量。
    let index: Int
    let reduceMotion: Bool
    /// 是否启用（受偏好开关控制）。
    let isEnabled: Bool

    @State private var hasEntered = false

    /// 该序号的入场延迟。超出 `cascadeMaxTotal` 后不再累加，避免长列表末尾等待过久。
    static func delay(forIndex index: Int) -> TimeInterval {
        min(Double(max(0, index)) * IslandMotionTokens.Duration.cascadeStagger,
            IslandMotionTokens.Duration.cascadeMaxTotal)
    }

    func body(content: Content) -> some View {
        content
            .opacity(hasEntered ? 1 : 0)
            .scaleEffect(hasEntered ? 1 : IslandMotionTokens.Geometry.cascadeScale, anchor: .top)
            .offset(y: hasEntered ? 0 : IslandMotionTokens.Geometry.cascadeRise)
            .onAppear {
                guard isEnabled, !reduceMotion else {
                    hasEntered = true
                    return
                }
                let delay = Self.delay(forIndex: index)
                if delay <= 0 {
                    withAnimation(IslandMotionTokens.cardLift) { hasEntered = true }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation(IslandMotionTokens.cardLift) { hasEntered = true }
                    }
                }
            }
    }
}

// MARK: - 距离感应隆起

/// 指针距离感应的 Dock 式隆起。
///
/// 借鉴 TO-DO Panel 的 `bindDockSurface`（`app.js:2984-3008`）：
/// `strength = max(0, 1 - distance / radius)²`，**平方衰减**让中心响应强、边缘迅速归零；
/// 且遍历全部元素，因此相邻卡片也会被抬起，形成连续隆起曲线，
/// 而不是「只有悬停的那一张变大」。
///
/// 与 Web 版本的实现差异（必须说明）：
/// 浏览器里 `transform` 由合成层处理，逐帧插值零成本；SwiftUI 没有等价机制，
/// 若把指针位置写进 `@State`，每次移动都会重新求值视图树。因此这里：
/// 1. 指针位置由列表容器**统一持有**，卡片只读不写；
/// 2. 列表用 `LazyVStack`，只有可见卡片参与求值；
/// 3. 仅在位移超过阈值时才更新状态，过滤亚像素抖动；
/// 4. 该特性默认关闭，由用户显式开启后评估。
enum ProximityLift {
    struct Result: Equatable {
        let scale: CGFloat
        let lift: CGFloat
    }

    /// 计算单个元素的距离感应结果。
    ///
    /// - Parameters:
    ///   - pointerY: 指针在容器坐标系中的 y。nil 表示指针不在容器内，返回静止态。
    ///   - itemMidY: 元素中心在容器坐标系中的 y。
    ///   - itemWidth: 元素宽度，用于推导作用半径（宽元素影响范围更大）。
    static func resolve(pointerY: CGFloat?, itemMidY: CGFloat, itemWidth: CGFloat) -> Result {
        let resting = Result(scale: 1, lift: 0)
        guard let pointerY else { return resting }

        // 半径随元素宽度缩放，并钳制在合理区间。
        let radius = min(
            max(IslandMotionTokens.Geometry.proximityMinRadius, itemWidth * 1.1),
            IslandMotionTokens.Geometry.proximityMaxRadius
        )
        let distance = abs(pointerY - itemMidY)
        guard distance < radius else { return resting }

        let normalized = max(0, 1 - distance / radius)
        let strength = normalized * normalized

        return Result(
            scale: 1 + (IslandMotionTokens.Geometry.proximityMaxScale - 1) * strength,
            lift: -IslandMotionTokens.Geometry.proximityMaxLift * strength
        )
    }
}

/// 把距离感应结果应用到卡片上。
struct ProximityLiftModifier: ViewModifier {
    let pointerY: CGFloat?
    let itemMidY: CGFloat
    let itemWidth: CGFloat
    let isEnabled: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let result = isEnabled && !reduceMotion
            ? ProximityLift.resolve(pointerY: pointerY, itemMidY: itemMidY, itemWidth: itemWidth)
            : ProximityLift.Result(scale: 1, lift: 0)

        content
            .scaleEffect(result.scale, anchor: .center)
            .offset(y: result.lift)
    }
}
