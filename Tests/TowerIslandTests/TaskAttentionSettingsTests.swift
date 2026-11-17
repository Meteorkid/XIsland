import XCTest
@testable import XIsland

/// 任务提醒的开关分流：总开关优先，完成默认不展开，审批默认展开。
final class TaskAttentionSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "TaskAttentionSettingsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testMasterSwitchDisablesEverything() {
        defaults.set(false, forKey: TaskAttentionSettings.enabledKey)
        XCTAssertFalse(TaskAttentionSettings.shouldPresent(for: .completion, defaults: defaults))
        XCTAssertFalse(TaskAttentionSettings.shouldPresent(for: .permission, defaults: defaults))
        XCTAssertFalse(TaskAttentionSettings.shouldPresent(for: .question, defaults: defaults))
    }

    func testCompletionDefaultsToOnAndCanBeDisabled() {
        XCTAssertTrue(TaskAttentionSettings.shouldPresent(for: .completion, defaults: defaults))
        defaults.set(false, forKey: TaskAttentionSettings.onCompletionKey)
        XCTAssertFalse(TaskAttentionSettings.shouldPresent(for: .completion, defaults: defaults))
    }

    func testInteractionDefaultsToOnAndCanBeDisabledIndependently() {
        XCTAssertTrue(TaskAttentionSettings.shouldPresent(for: .permission, defaults: defaults))
        XCTAssertTrue(TaskAttentionSettings.shouldPresent(for: .question, defaults: defaults))
        XCTAssertTrue(TaskAttentionSettings.shouldPresent(for: .planReview, defaults: defaults))

        defaults.set(false, forKey: TaskAttentionSettings.onInteractionKey)
        XCTAssertFalse(TaskAttentionSettings.shouldPresent(for: .permission, defaults: defaults))

        // 审批关闭不影响完成（完成需要单独开启）。
        defaults.set(true, forKey: TaskAttentionSettings.onCompletionKey)
        XCTAssertTrue(TaskAttentionSettings.shouldPresent(for: .completion, defaults: defaults))
    }

    func testForceAcrossSpacesIsOffByDefault() {
        XCTAssertFalse(TaskAttentionSettings.forcesAcrossSpaces(defaults: defaults))
        defaults.set(true, forKey: TaskAttentionSettings.forceAcrossSpacesKey)
        XCTAssertTrue(TaskAttentionSettings.forcesAcrossSpaces(defaults: defaults))
    }

    /// 减少动态效果、禁用动画只能影响动效，不能阻止提醒展开。
    func testMotionPreferencesDoNotBlockPresentation() {
        defaults.set(true, forKey: "reduceMotion")
        defaults.set(true, forKey: "disableAnimations")
        XCTAssertTrue(TaskAttentionSettings.shouldPresent(for: .completion, defaults: defaults))
        XCTAssertTrue(TaskAttentionSettings.shouldPresent(for: .permission, defaults: defaults))
        XCTAssertTrue(TaskAttentionSettings.shouldPresent(for: .question, defaults: defaults))
        XCTAssertTrue(TaskAttentionSettings.shouldPresent(for: .planReview, defaults: defaults))
    }
}
