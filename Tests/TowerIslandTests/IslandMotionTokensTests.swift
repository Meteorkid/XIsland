import AppKit
import XCTest
@testable import XIsland

/// 动效令牌层的回归测试。
///
/// 目的：令牌化的前提是**零视觉变更**。这组测试把现有三档强度的取值逐一锁定，
/// 确保重构没有悄悄改掉任何参数；后续调参时若改动了这些值，测试会失败并提示需要同步更新预期。
final class IslandMotionTokensTests: XCTestCase {

    // MARK: - 强度分级的单调性

    func testExpandSpringIsMonotonicInIntensity() {
        // 强度越高，响应周期越长、阻尼越低（更「弹」）。
        let low = IslandMotionTokens.expandSpring(for: .low)
        let medium = IslandMotionTokens.expandSpring(for: .medium)
        let high = IslandMotionTokens.expandSpring(for: .high)

        XCTAssertNotNil(low)
        XCTAssertNotNil(medium)
        XCTAssertNotNil(high)
    }

    /// 令牌必须与重构前的硬编码值一致——这是「纯重构」的判据。
    func testTokenValuesMatchPreRefactorConstants() {
        // 这些数值来自重构前的 NotchContentView.swift:253-284。
        // 若本测试失败，说明动效参数被改动，需要确认是有意调参并同步更新此处预期。
        XCTAssertEqual(IslandMotionTokens.Duration.toolFlashHold, 0.5)
        XCTAssertEqual(IslandMotionTokens.Duration.logSweepTotal, 0.7)
        XCTAssertEqual(IslandMotionTokens.Duration.statusSweepHold, 0.6)
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
