import Foundation

/// 判断用户是否**故意**删掉了部分 hook 事件。
///
/// 背景（借鉴 CodeIsland #182）：修复流程的默认行为是"配置不完整就补齐"。
/// 但用户完全可能是有意删掉某个事件——比如某个事件在他的项目里会频繁触发、
/// 干扰工作流。此时"自动修好"等于把用户的编辑反复抹掉，而且他会以为设置没生效。
///
/// 判定原则：
/// - 只要还能找到**至少一个**属于我们的 hook 条目，就认为配置是我们装的、
///   剩下的删减是用户做的 → 保留，不补齐
/// - 一个都找不到 → 说明从未安装或已被整体清理 → 正常安装
///
/// 刻意不做"部分保留"之外的推断：不知道用户为什么删，就不猜。
enum HookDriftPolicy {

    /// 一个 hook 条目是否由我们注入。
    typealias Ownership = ([String: Any]) -> Bool

    /// 是否存在我们注入的条目。
    static func hasAnyOwnedEntry(in configuration: [String: Any],
                                 events: [String],
                                 isOwned: Ownership) -> Bool {
        guard let hooks = configuration["hooks"] as? [String: Any] else { return false }
        for event in events {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            if entries.contains(where: isOwned) { return true }
        }
        return false
    }

    /// 是否应当跳过补齐（基于「移除后配置是否变化」判定）。
    ///
    /// 这是生产路径实际使用的入口：不依赖各配置类型的 private `isOwned`，
    /// 只用它们公开的 `removing`。移除后仍有变化 → 配置里存在我们的条目 →
    /// 剩余缺失视为用户有意删减。
    ///
    /// - Parameters:
    ///   - original: 读到的配置
    ///   - stripped: 应用 `removing` 之后的结果
    ///   - hasStaleShape: 是否存在结构过期的条目。过期条目是 bug 不是用户意图，必须重写。
    static func shouldPreservePartial(original: [String: Any],
                                      stripped: [String: Any],
                                      hasStaleShape: Bool = false) -> Bool {
        if hasStaleShape { return false }
        return !NSDictionary(dictionary: original).isEqual(to: stripped)
    }

    /// 是否应当跳过补齐（基于逐条归属判定）。
    ///
    /// 适用于拿得到 `isOwned` 的场景；拿不到时用上面那个重载。
    ///
    /// - Parameters:
    ///   - configuration: 读到的配置
    ///   - events: 该客户端期望的完整事件集合
    ///   - isOwned: 单条目归属判定
    ///   - hasStaleShape: 是否存在结构过期的条目。
    static func shouldPreservePartial(_ configuration: [String: Any],
                                      events: [String],
                                      isOwned: Ownership,
                                      hasStaleShape: Bool = false) -> Bool {
        // 结构过期优先于"用户意图"：这种配置本身是坏的，保留它只会让 hook 失效。
        if hasStaleShape { return false }
        return hasAnyOwnedEntry(in: configuration, events: events, isOwned: isOwned)
    }
}
