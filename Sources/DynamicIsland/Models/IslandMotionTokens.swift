import SwiftUI

/// 灵动岛动效令牌单一取值表。
///
/// 设计目标（借鉴 TO-DO Panel 的 `:root` 令牌体系）：
/// 1. **单一取值**——弹簧、时长、缓动只在此处定义，各视图引用而非各自硬编码。
/// 2. **曲线按用途分工**——有回弹的曲线只给「有实体感」的元素（胶囊、勾选、卡片浮起）；
///    无过冲的曲线给「尺寸/位置变形」（窗口、面板展开），避免边缘短暂露出裁切。
/// 3. **强度分级**——所有会随 `IslandAnimationIntensity` 变化的参数在此集中映射，
///    调参时改一处、全局一致。
///
/// 与 TO-DO Panel 的差异说明：对方的 `--d-base: 180ms` 是 CSS transition 时长，
/// 对应预设贝塞尔曲线；本项目的 SwiftUI 弹簧用 `response`（周期，非时长）+ `dampingFraction`。
/// 两者数值**不可直接换算**，因此这里沿用项目既有的三档强度骨架，只把「分工原则」搬过来。
enum IslandMotionTokens {

    // MARK: - 弹簧（按强度分级）

    /// 展开面板的弹簧。
    static func expandSpring(for intensity: IslandAnimationIntensity) -> Animation {
        switch intensity {
        case .low:
            return .spring(response: 0.28, dampingFraction: 0.92)
        case .medium:
            return .spring(response: 0.4, dampingFraction: 0.82)
        case .high:
            return .spring(response: 0.5, dampingFraction: 0.74)
        }
    }

    /// 收起面板的弹簧。收起比展开略快，符合「进入慢、退出快」的通用直觉。
    static func collapseSpring(for intensity: IslandAnimationIntensity) -> Animation {
        switch intensity {
        case .low:
            return .spring(response: 0.24, dampingFraction: 0.9)
        case .medium:
            return .spring(response: 0.35, dampingFraction: 0.8)
        case .high:
            return .spring(response: 0.44, dampingFraction: 0.72)
        }
    }

    /// 展开态内容淡入。
    static func contentFade(for intensity: IslandAnimationIntensity) -> Animation {
        switch intensity {
        case .low:
            return .easeInOut(duration: 0.14)
        case .medium:
            return .easeInOut(duration: 0.2)
        case .high:
            return .easeInOut(duration: 0.28)
        }
    }

    // MARK: - 弹簧（固定用途，不随强度分级）

    /// 悬停果冻形变。刻意使用低阻尼（0.3）制造明显回弹——这是「有实体感」的典型场景。
    static let hoverJellyPop = Animation.spring(response: 0.5, dampingFraction: 0.3)

    /// 悬停果冻回落。阻尼略升，让回弹收敛得更干净。
    static let hoverJellySettle = Animation.spring(response: 0.45, dampingFraction: 0.4)

    /// 磁吸位移跟随。高阻尼、短周期，避免指针移动时产生拖尾。
    static let magneticFollow = Animation.spring(response: 0.3, dampingFraction: 0.7)

    /// 磁吸归零。比跟随稍慢，让脱离时的收束更柔和。
    static let magneticRelease = Animation.spring(response: 0.4, dampingFraction: 0.65)

    /// 活动日志新条目入场。
    static let logEntry = Animation.spring(response: 0.35, dampingFraction: 0.7)

    /// 卡片浮起（入场级联 / 距离感应）。
    /// 用中等阻尼 + 短周期：需要一点「实体落定」感，但不能过冲导致文字抖动。
    static let cardLift = Animation.spring(response: 0.32, dampingFraction: 0.78)

    // MARK: - 缓动（无过冲，用于尺寸/位置变形）

    /// 通用 hover 过渡。对齐 TO-DO Panel 的 `--ease` 用途：日常状态切换。
    static let hoverTransition = Animation.easeInOut(duration: 0.15)

    /// 面板内元素显隐。对齐 `--ease` 的「日常」定位。
    static let elementTransition = Animation.easeInOut(duration: 0.2)

    /// 工具完成闪光消退。用 easeOut 让尾段更快消失，避免残留。
    static let flashDecay = Animation.easeOut(duration: 0.3)

    /// 状态变化扫光。时长较长是因为要覆盖整张卡片宽度。
    static let statusSweep = Animation.easeInOut(duration: 0.6)

    /// 活动日志扫光。
    static let logSweep = Animation.easeInOut(duration: 0.7)

    // MARK: - 时长

    enum Duration {
        /// 工具完成闪光的保持时长。
        static let toolFlashHold: TimeInterval = 0.5
        /// 活动日志扫光的总时长（含等待）。
        static let logSweepTotal: TimeInterval = 0.7
        /// 会话状态扫光触发后的等待。
        static let statusSweepHold: TimeInterval = 0.6
        /// 入场级联的相邻元素间隔。
        static let cascadeStagger: TimeInterval = 0.048
        /// 入场级联单元素的动画时长。
        static let cascadeItem: TimeInterval = 0.34
        /// 入场级联整体上限，超出后不再累加延迟（避免长列表末尾等待过久）。
        static let cascadeMaxTotal: TimeInterval = 0.42
    }

    // MARK: - 几何

    enum Geometry {
        /// 入场级联的起始上浮位移（pt）。对齐 TO-DO Panel 的 `riseIn` 12px。
        static let cascadeRise: CGFloat = 12
        /// 入场级联的起始缩放。
        static let cascadeScale: CGFloat = 0.985
        /// 距离感应的最大缩放增益（1.14 对应 TO-DO Panel 的 Dock 提举）。
        static let proximityMaxScale: CGFloat = 1.035
        /// 距离感应的最大上移量（pt）。
        static let proximityMaxLift: CGFloat = 3
        /// 距离感应的作用半径下限。
        static let proximityMinRadius: CGFloat = 44
        /// 距离感应的作用半径上限。
        static let proximityMaxRadius: CGFloat = 92
    }
}
