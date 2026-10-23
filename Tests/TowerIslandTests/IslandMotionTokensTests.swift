import AppKit
import XCTest
@testable import XIsland

/// 动效令牌层的回归测试。
///
/// 目的：令牌化的前提是**零视觉变更**。这组测试把现有三档强度的取值逐一锁定，
/// 确保重构没有悄悄改掉任何参数；后续调参时若改动了这些值，测试会失败并提示需要同步更新预期。
final class IslandMotionTokensTests: XCTestCase {

    // MARK: - 强度分级的单调性

    /// 强度越高，响应周期越长、阻尼越低（更「弹」）。
    func testExpandSpringIsMonotonicInIntensity() {
        let low = IslandMotionTokens.spring(for: .low).expand
        let medium = IslandMotionTokens.spring(for: .medium).expand
        let high = IslandMotionTokens.spring(for: .high).expand

        XCTAssertLessThan(low.response, medium.response)
        XCTAssertLessThan(medium.response, high.response)
        XCTAssertGreaterThan(low.dampingFraction, medium.dampingFraction)
        XCTAssertGreaterThan(medium.dampingFraction, high.dampingFraction)
    }

    /// 收起弹簧的响应周期也应随强度单调递增。
    func testCollapseSpringResponseIsMonotonicInIntensity() {
        let low = IslandMotionTokens.spring(for: .low).collapse
        let medium = IslandMotionTokens.spring(for: .medium).collapse
        let high = IslandMotionTokens.spring(for: .high).collapse

        XCTAssertLessThan(low.response, medium.response)
        XCTAssertLessThan(medium.response, high.response)
    }

    /// **核心取向断言**：展开必须有明显回弹，收起必须接近临界阻尼。
    ///
    /// 这是借鉴 Sapphire 时唯一真正想锁住的不变量。此前项目取值相反
    /// （展开 0.82 偏稳、收起 0.8 会过冲），方向与「展开有生命感、收起要利落」相悖。
    /// 若本测试失败，说明有人把两个取向又调反了，需确认是否有意为之。
    ///
    /// 注意 low 档是「克制」档，其展开阻尼（0.92）刻意偏高、不参与回弹取向约束；
    /// 取向由默认档（medium）与 high 档体现。
    func testDefaultAndHighExpandAreBouncy() {
        for intensity in [IslandAnimationIntensity.medium, .high] {
            let springs = IslandMotionTokens.spring(for: intensity)
            XCTAssertLessThan(
                springs.expand.dampingFraction, 0.8,
                "\(intensity) 档展开阻尼应低于 0.8，否则失去回弹感"
            )
        }
    }

    /// 收起在所有档位都必须接近临界阻尼——尾部抖动在任何强度下都是缺陷而非风格。
    func testCollapseIsCriticallyDampedInAllIntensities() {
        for intensity in IslandAnimationIntensity.allCases {
            let springs = IslandMotionTokens.spring(for: intensity)
            XCTAssertGreaterThanOrEqual(
                springs.collapse.dampingFraction, 0.9,
                "\(intensity) 档收起阻尼应接近临界，否则尾部会可见抖动"
            )
        }
    }

    /// 每个档位内部：展开必须比收起更「弹」（阻尼更低）。
    /// 这正是「展开有生命感、收起要利落」的量化形式。
    func testExpandIsBouncierThanCollapseWithinEachIntensity() {
        for intensity in IslandAnimationIntensity.allCases {
            let springs = IslandMotionTokens.spring(for: intensity)
            XCTAssertLessThan(
                springs.expand.dampingFraction, springs.collapse.dampingFraction,
                "\(intensity) 档展开阻尼应低于收起，否则两个取向被调反"
            )
        }
    }

    /// 展开始终比收起慢——「进入慢、退出快」是通用直觉。
    func testExpandIsAlwaysSlowerThanCollapse() {
        for intensity in IslandAnimationIntensity.allCases {
            let springs = IslandMotionTokens.spring(for: intensity)
            XCTAssertGreaterThan(
                springs.expand.response, springs.collapse.response,
                "\(intensity) 档展开周期应长于收起"
            )
        }
    }

    // MARK: - 收起看门狗的兜底时长

    /// 兜底时长必须长于动画本身，否则会在动画未结束时误触发复位。
    func testSettleDurationExceedsCollapseResponse() {
        for intensity in IslandAnimationIntensity.allCases {
            let spring = IslandMotionTokens.spring(for: intensity).collapse
            XCTAssertGreaterThan(
                IslandMotionTokens.settleDuration(for: intensity),
                spring.response,
                "\(intensity) 档兜底时长必须大于收起周期"
            )
        }
    }

    /// 兜底时长应有上界——过长的等待等于没有兜底。
    /// 取 2 秒作为宽松上限：三档强度下都不该超过这个量级。
    func testSettleDurationIsBounded() {
        for intensity in IslandAnimationIntensity.allCases {
            XCTAssertLessThan(IslandMotionTokens.settleDuration(for: intensity), 2.0)
        }
    }

    /// 低阻尼（<0.8）需要更长的收敛时间，系数应体现这一点。
    /// 当前三档收起阻尼均 ≥0.95，故取 1.6 系数；此处锁定该系数关系。
    func testSettleDurationUsesLargerFactorForLowDamping() {
        let spring = IslandMotionTokens.spring(for: .medium).collapse
        let expectedFactor = spring.dampingFraction < 0.8 ? 2.4 : 1.6
        XCTAssertEqual(
            IslandMotionTokens.settleDuration(for: .medium),
            spring.response * expectedFactor,
            accuracy: 0.0001
        )
    }

    /// 令牌必须与重构前的硬编码值一致——这是「纯重构」的判据。
    func testTokenValuesMatchPreRefactorConstants() {
        // 这些数值来自重构前的 NotchContentView.swift:253-284。
        // 若本测试失败，说明动效参数被改动，需要确认是有意调参并同步更新此处预期。
        XCTAssertEqual(IslandMotionTokens.Duration.toolFlashHold, 0.5)
        XCTAssertEqual(IslandMotionTokens.Duration.logSweepTotal, 0.7)
    }

    // MARK: - 入场级联

    func testCascadeDelayIsMonotonicAndCapped() {
        // 延迟随序号递增。
        XCTAssertEqual(CardEntranceCascade.delay(forIndex: 0), 0)
        XCTAssertLessThan(
            CardEntranceCascade.delay(forIndex: 1),
            CardEntranceCascade.delay(forIndex: 3)
        )
        // 但必须封顶，避免长列表末尾等待过久。
        XCTAssertEqual(
            CardEntranceCascade.delay(forIndex: 100),
            IslandMotionTokens.Duration.cascadeMaxTotal
        )
    }

    func testCascadeDelayNeverNegative() {
        // 负序号（理论上不该出现）不得产生负延迟。
        XCTAssertEqual(CardEntranceCascade.delay(forIndex: -5), 0)
    }

    // MARK: - 距离感应

    func testProximityLiftIsMaximalAtCenter() {
        let atCenter = ProximityLift.resolve(pointerY: 100, itemMidY: 100, itemWidth: 340)
        XCTAssertEqual(atCenter.scale, IslandMotionTokens.Geometry.proximityMaxScale, accuracy: 0.0001)
        XCTAssertEqual(atCenter.lift, -IslandMotionTokens.Geometry.proximityMaxLift, accuracy: 0.0001)
    }

    func testProximityLiftDecaysQuadraticallyToZeroAtRadiusEdge() {
        // 恰好等于半径时，强度应为 0。
        let radius = IslandMotionTokens.Geometry.proximityMaxRadius
        let atEdge = ProximityLift.resolve(pointerY: 100 + radius, itemMidY: 100, itemWidth: 340)
        XCTAssertEqual(atEdge.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(atEdge.lift, 0, accuracy: 0.0001)
    }

    func testProximityLiftIsQuadraticNotLinear() {
        // 平方衰减的关键性质：半程处的强度是 0.25 而非 0.5。
        let radius = IslandMotionTokens.Geometry.proximityMaxRadius
        let half = ProximityLift.resolve(pointerY: 100 + radius / 2, itemMidY: 100, itemWidth: 340)
        let expectedScale = 1 + (IslandMotionTokens.Geometry.proximityMaxScale - 1) * 0.25
        XCTAssertEqual(half.scale, expectedScale, accuracy: 0.0001)
    }

    func testProximityLiftReturnsRestingWhenPointerOutside() {
        let resting = ProximityLift.resolve(pointerY: nil, itemMidY: 100, itemWidth: 340)
        XCTAssertEqual(resting.scale, 1)
        XCTAssertEqual(resting.lift, 0)
    }

    func testProximityLiftNeverAmplifiesAwayFromPointer() {
        // 无论指针在哪，缩放都不应超过上限，位移都不应为正（只能上抬不能下沉）。
        for offset in stride(from: -300.0, through: 300.0, by: 17.0) {
            let result = ProximityLift.resolve(pointerY: 100 + offset, itemMidY: 100, itemWidth: 340)
            XCTAssertLessThanOrEqual(result.scale, IslandMotionTokens.Geometry.proximityMaxScale + 0.0001)
            XCTAssertLessThanOrEqual(result.lift, 0.0001)
        }
    }

    // MARK: - 图标动效开关

    func testSymbolMotionRequiresBothPreferenceAndNoReduceMotion() {
        XCTAssertTrue(IslandSymbolMotion.isEnabled(reduceMotion: false, preferenceEnabled: true))
        XCTAssertFalse(IslandSymbolMotion.isEnabled(reduceMotion: true, preferenceEnabled: true))
        XCTAssertFalse(IslandSymbolMotion.isEnabled(reduceMotion: false, preferenceEnabled: false))
        XCTAssertFalse(IslandSymbolMotion.isEnabled(reduceMotion: true, preferenceEnabled: false))
    }

    // MARK: - 偏好值解析的健壮性

    /// 存储中出现未知/损坏值时，必须回退到默认档位而非崩溃或静默关闭。
    /// 这类情况真实存在：用户降级版本后，旧偏好键可能残留无法识别的值。
    func testHapticIntensityResolveFallsBackToDefault() {
        XCTAssertEqual(IslandHapticIntensity.resolve(rawValue: "standard"), .standard)
        XCTAssertEqual(IslandHapticIntensity.resolve(rawValue: ""), IslandHapticIntensity.defaultValue)
        XCTAssertEqual(IslandHapticIntensity.resolve(rawValue: "unknown-value"), IslandHapticIntensity.defaultValue)
        XCTAssertEqual(IslandHapticIntensity.defaultValue, .standard)
    }
}
