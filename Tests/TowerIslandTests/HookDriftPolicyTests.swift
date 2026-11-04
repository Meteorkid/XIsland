import XCTest
@testable import XIsland

/// 部分 hook 保留策略：用户手动删掉事件后不应被"自动修好"抹掉。
///
/// 借鉴 CodeIsland #182。判定方式刻意不依赖各配置类型的 private `isOwned`，
/// 而是用「移除操作是否改变了配置」来等价判断归属。
final class HookDriftPolicyTests: XCTestCase {

    func testPreservesWhenSomeOwnedEntriesRemain() {
        // 期望 3 个事件，用户只留下 1 个 —— 应视为有意删减。
        let configuration: [String: Any] = [
            "hooks": [
                "SessionStart": [["command": "/Users/x/.xisland/bin/di-bridge --agent trae --hook SessionStart"]],
                "PreToolUse": [["command": "user-script.sh"]],
            ]
        ]
        let result = HookDriftPolicy.shouldPreservePartial(
            configuration,
            events: ["SessionStart", "PreToolUse", "Stop"],
            isOwned: { entry in
                (entry["command"] as? String)?.contains("di-bridge") == true
            }
        )
        XCTAssertTrue(result, "仍有我们注入的条目，剩余缺失应视为用户有意删减")
    }

    func testDoesNotPreserveWhenNothingOfOursRemains() {
        // 一个我们的条目都没有 —— 说明从未安装或已被整体清理，应正常安装。
        let configuration: [String: Any] = [
            "hooks": ["PreToolUse": [["command": "user-script.sh"]]]
        ]
        let result = HookDriftPolicy.shouldPreservePartial(
            configuration,
            events: ["SessionStart", "PreToolUse"],
            isOwned: { entry in
                (entry["command"] as? String)?.contains("di-bridge") == true
            }
        )
        XCTAssertFalse(result)
    }

    func testStaleShapeOverridesUserIntent() {
        // 结构过期是 bug 不是用户意图：必须重写，不能保留。
        let configuration: [String: Any] = [
            "hooks": ["SessionStart": [["command": "di-bridge"]]]
        ]
        let result = HookDriftPolicy.shouldPreservePartial(
            configuration,
            events: ["SessionStart"],
            isOwned: { _ in true },
            hasStaleShape: true
        )
        XCTAssertFalse(result)
    }

    func testEmptyOrMalformedConfigurationIsNotPreserved() {
        XCTAssertFalse(HookDriftPolicy.shouldPreservePartial(
            [:], events: ["Stop"], isOwned: { _ in true }))
        // hooks 不是字典（用户写坏了）→ 不拦修复。
        XCTAssertFalse(HookDriftPolicy.shouldPreservePartial(
            ["hooks": "oops"], events: ["Stop"], isOwned: { _ in true }))
    }

    func testHasAnyOwnedEntryIgnoresUnrelatedEvents() {
        let configuration: [String: Any] = [
            "hooks": ["UnrelatedEvent": [["command": "di-bridge"]]]
        ]
        // 只有不在期望集合里的事件含我们的条目 → 不算"部分保留"。
        XCTAssertFalse(HookDriftPolicy.hasAnyOwnedEntry(
            in: configuration,
            events: ["SessionStart", "Stop"],
            isOwned: { entry in (entry["command"] as? String)?.contains("di-bridge") == true }
        ))
    }

    // MARK: 生产路径使用的重载（基于 removing 结果）

    func testStrippedVariantDetectsOurEntries() {
        // 这是 ZeroConfigManager 实际调用的入口。
        let original: [String: Any] = [
            "hooks": [
                "SessionStart": [["command": "di-bridge --hook SessionStart"]],
                "Stop": [["command": "user.sh"]],
            ]
        ]
        let stripped: [String: Any] = [
            "hooks": ["Stop": [["command": "user.sh"]]]
        ]
        XCTAssertTrue(HookDriftPolicy.shouldPreservePartial(original: original, stripped: stripped),
                      "移除后有变化 → 存在我们的条目 → 视为用户有意删减")
    }

    func testStrippedVariantIsFalseWhenNothingRemoved() {
        let same: [String: Any] = ["hooks": ["Stop": [["command": "user.sh"]]]]
        XCTAssertFalse(HookDriftPolicy.shouldPreservePartial(original: same, stripped: same),
                       "移除后无变化 → 里面没有我们的条目 → 正常安装")
    }

    func testStrippedVariantStillHonoursStaleShape() {
        let original: [String: Any] = ["hooks": ["A": [["command": "di-bridge"]]]]
        XCTAssertFalse(HookDriftPolicy.shouldPreservePartial(
            original: original, stripped: [:], hasStaleShape: true),
            "结构过期必须重写，不能被当成用户意图")
    }
}
