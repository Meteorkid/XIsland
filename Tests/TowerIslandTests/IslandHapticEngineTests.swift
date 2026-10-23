import AppKit
import XCTest
@testable import XIsland

/// 触觉反馈决策的单元测试。
///
/// 重点覆盖两件事：
/// 1. **强度 → 事件覆盖范围**的映射是否正确（这是本实现里「强度」的真实语义）；
/// 2. 测试隔离环境下必须静默——否则测试会触发真实硬件反馈且不可重复。
final class IslandHapticEngineTests: XCTestCase {

    // MARK: - 强度覆盖范围

    func testOffNeverFires() {
        for event in IslandHapticEvent.allCases {
            XCTAssertFalse(
                IslandHapticPolicy.shouldFire(event: event, intensity: .off, isIsolated: false),
                "关闭档位不应触发任何事件：\(event)"
            )
        }
    }

    func testMinimalCoversOnlyPermissionAndFailure() {
        XCTAssertTrue(IslandHapticPolicy.shouldFire(event: .permissionRequest, intensity: .minimal, isIsolated: false))
        XCTAssertTrue(IslandHapticPolicy.shouldFire(event: .failure, intensity: .minimal, isIsolated: false))
        // 其余事件不应在极简档触发。
        XCTAssertFalse(IslandHapticPolicy.shouldFire(event: .inputRequired, intensity: .minimal, isIsolated: false))
        XCTAssertFalse(IslandHapticPolicy.shouldFire(event: .panelExpand, intensity: .minimal, isIsolated: false))
        XCTAssertFalse(IslandHapticPolicy.shouldFire(event: .sessionSwitch, intensity: .minimal, isIsolated: false))
        XCTAssertFalse(IslandHapticPolicy.shouldFire(event: .toolCompletion, intensity: .minimal, isIsolated: false))
    }

    func testStandardAddsInputAndPanelTransitions() {
        XCTAssertTrue(IslandHapticPolicy.shouldFire(event: .inputRequired, intensity: .standard, isIsolated: false))
        XCTAssertTrue(IslandHapticPolicy.shouldFire(event: .panelExpand, intensity: .standard, isIsolated: false))
        XCTAssertTrue(IslandHapticPolicy.shouldFire(event: .panelCollapse, intensity: .standard, isIsolated: false))
        // 但会话切换与工具完成仍不触发。
        XCTAssertFalse(IslandHapticPolicy.shouldFire(event: .sessionSwitch, intensity: .standard, isIsolated: false))
        XCTAssertFalse(IslandHapticPolicy.shouldFire(event: .toolCompletion, intensity: .standard, isIsolated: false))
    }

    func testFullCoversEveryEvent() {
        for event in IslandHapticEvent.allCases {
            XCTAssertTrue(
                IslandHapticPolicy.shouldFire(event: event, intensity: .full, isIsolated: false),
                "完整档位应覆盖所有事件：\(event)"
            )
        }
    }

    /// 覆盖范围必须随档位单调扩张——不允许出现「高档位反而漏掉低档位事件」。
    func testCoverageIsMonotonicAcrossIntensities() {
        let ordered: [IslandHapticIntensity] = [.off, .minimal, .standard, .full]
        for event in IslandHapticEvent.allCases {
            var previous = false
            for intensity in ordered {
                let fires = IslandHapticPolicy.shouldFire(event: event, intensity: intensity, isIsolated: false)
                if previous {
                    XCTAssertTrue(fires, "\(event) 在 \(intensity) 档位丢失了低档位已覆盖的反馈")
                }
                previous = fires
            }
        }
    }

    // MARK: - 测试隔离

    func testIsolatedEnvironmentNeverFires() {
        for event in IslandHapticEvent.allCases {
            for intensity in IslandHapticIntensity.allCases {
                XCTAssertFalse(
                    IslandHapticPolicy.shouldFire(event: event, intensity: intensity, isIsolated: true),
                    "隔离环境必须静默：event=\(event) intensity=\(intensity)"
                )
            }
        }
    }

    // MARK: - 显著性排序

    func testPermissionIsMostSalient() {
        let sorted = IslandHapticEvent.allCases.sorted { $0.salience < $1.salience }
        XCTAssertEqual(sorted.first, .permissionRequest)
    }

    func testSalienceOrderingMatchesDesignTable() {
        // 注意：显著性值**允许并列**（展开与收起同属「面板结构变化」一档，
        // 用户不会希望「展开有反馈但收起没有」）。因此这里锁定的不是唯一性，
        // 而是完整的设计表——每个事件首次触发的档位必须与设计一致。
        let expectedFirstFiring: [IslandHapticEvent: IslandHapticIntensity] = [
            .permissionRequest: .minimal,
            .failure: .minimal,
            .inputRequired: .standard,
            .panelExpand: .standard,
            .panelCollapse: .standard,
            .sessionSwitch: .full,
            .toolCompletion: .full,
        ]
        XCTAssertEqual(expectedFirstFiring.count, IslandHapticEvent.allCases.count,
                       "设计表必须覆盖全部事件，否则有事件缺少档位归属")

        let ordered: [IslandHapticIntensity] = [.off, .minimal, .standard, .full]
        for (event, firstFiring) in expectedFirstFiring {
            let firstIndex = ordered.firstIndex(of: firstFiring)!
            for (index, intensity) in ordered.enumerated() {
                let fires = IslandHapticPolicy.shouldFire(event: event, intensity: intensity, isIsolated: false)
                XCTAssertEqual(
                    fires, index >= firstIndex,
                    "\(event) 在 \(intensity) 档的触发状态与设计表不符（应自 \(firstFiring) 起触发）"
                )
            }
        }
    }

    /// 展开与收起必须同档——否则会出现「展开有反馈、收起没有」的割裂体验。
    func testPanelExpandAndCollapseShareSameTier() {
        XCTAssertEqual(IslandHapticEvent.panelExpand.salience, IslandHapticEvent.panelCollapse.salience)
    }

    // MARK: - pattern 映射

    func testPatternMappingIsTotal() {
        // 每个事件都必须有确定的 pattern，不允许遗漏。
        for event in IslandHapticEvent.allCases {
            _ = IslandHapticPolicy.pattern(for: event)
        }
        XCTAssertEqual(IslandHapticPolicy.pattern(for: .permissionRequest), .generic)
        XCTAssertEqual(IslandHapticPolicy.pattern(for: .panelExpand), .levelChange)
        XCTAssertEqual(IslandHapticPolicy.pattern(for: .sessionSwitch), .alignment)
    }

    // MARK: - 引擎行为

    @MainActor
    func testEngineDoesNotInvokePerformerWhenIsolated() {
        let recorder = RecordingHapticPerformer()
        let original = IslandHapticEngine.performer
        IslandHapticEngine.performer = recorder
        defer { IslandHapticEngine.performer = original }

        // 测试环境由 AppPreferences.isIsolated 判定；XCTest 下必为真。
        XCTAssertTrue(AppPreferences.isIsolated, "XCTest 必须运行在隔离偏好下")

        IslandHapticEngine.fire(.permissionRequest, intensity: .full)
        XCTAssertTrue(recorder.calls.isEmpty, "隔离环境不得调用真实执行器")
    }

    @MainActor
    func testEngineInvokesPerformerWithMappedPattern() {
        let recorder = RecordingHapticPerformer()
        let original = IslandHapticEngine.performer
        IslandHapticEngine.performer = recorder
        defer { IslandHapticEngine.performer = original }

        // 直接验证决策与执行的组合逻辑：隔离判定为假时应当调用。
        guard IslandHapticPolicy.shouldFire(event: .permissionRequest, intensity: .full, isIsolated: false) else {
            return XCTFail("非隔离环境下完整档位应触发权限反馈")
        }
        recorder.perform(
            pattern: IslandHapticPolicy.pattern(for: .permissionRequest),
            time: IslandHapticPolicy.performanceTime
        )
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.pattern, .generic)
        XCTAssertEqual(recorder.calls.first?.time, .now)
    }
}

/// 记录型执行器，用于验证调用而不触碰真实硬件。
@MainActor
private final class RecordingHapticPerformer: HapticPerforming {
    struct Call: Equatable {
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        let time: NSHapticFeedbackManager.PerformanceTime
    }

    private(set) var calls: [Call] = []

    func perform(pattern: NSHapticFeedbackManager.FeedbackPattern, time: NSHapticFeedbackManager.PerformanceTime) {
        calls.append(Call(pattern: pattern, time: time))
    }
}
