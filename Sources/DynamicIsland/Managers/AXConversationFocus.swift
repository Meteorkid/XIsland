import ApplicationServices
import AppKit

/// 在目标客户端的可访问性树里按标题查找并点击**唯一**的会话行/标签。
///
/// 这是没有会话级 deeplink 的客户端的最后兜底。可访问性树没有跨应用统一
/// 语义，因此规则刻意保守：
/// - 只接受可按下、已启用的按钮/行/单元格/列表项/单选按钮/链接/分组；
/// - 标题完全相等优先；包含匹配要求标题至少 4 个字符；
/// - 最佳匹配必须唯一，多个同名行一律视为歧义，绝不点第一个；
/// - 没有辅助功能权限时不弹系统授权框，直接由调用方提示失败。
enum AXConversationFocus {
    enum Outcome: Equatable {
        case focused
        case notFound
        case ambiguous
        case permissionDenied
        case notActionable
    }

    struct Candidate: Equatable {
        let index: Int
        let label: String
        let role: String
        let enabled: Bool
        let canPress: Bool
        let inFocusedWindow: Bool
        /// 会话行/标签必须位于列表、树、表格、标签组或滚动容器内；
        /// 这条约束把同名工具栏按钮排除在外。
        let inConversationContainer: Bool
    }

    enum Selection: Equatable {
        case unique(Int)
        case none
        case ambiguous
    }

    private static let maxVisitedElements = 1_200
    private static let maxDepth = 16
    private static let maxLabelLength = 200

    /// 可点击的会话行/标签角色。`AXGroup` 允许按，因为部分 Electron
    /// 客户端把整行包在 group 里；但它仍必须唯一且可按下。
    private static let eligibleRoles: Set<String> = [
        kAXButtonRole as String,
        kAXRowRole as String,
        kAXCellRole as String,
        "AXListItem",
        kAXRadioButtonRole as String,
        "AXLink",
        kAXGroupRole as String,
    ]

    private static let conversationContainers: Set<String> = [
        kAXListRole as String,
        kAXOutlineRole as String,
        kAXTableRole as String,
        kAXTabGroupRole as String,
        kAXScrollAreaRole as String,
        kAXBrowserRole as String,
        kAXGridRole as String,
    ]

    private static let genericLabels: Set<String> = [
        "chat", "chats", "new chat", "new conversation", "untitled", "untitled chat",
        "home", "settings", "new", "会话", "聊天", "新聊天", "新会话", "未命名",
    ]

    static func focus(title: String, in app: NSRunningApplication) -> Outcome {
        guard AXIsProcessTrusted() else { return .permissionDenied }
        let needle = normalized(title)
        guard validNeedle(needle) else { return .notFound }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        let focusedWindow = elementAttribute(root, kAXFocusedWindowAttribute)
        let scanned = collect(title: needle, root: root, focusedWindow: focusedWindow)
        switch select(title: needle, candidates: scanned.candidates) {
        case .none:
            return .notFound
        case .ambiguous:
            return .ambiguous
        case .unique(let index):
            guard index >= 0, index < scanned.elements.count else { return .notFound }
            return AXUIElementPerformAction(scanned.elements[index], kAXPressAction as CFString) == .success
                ? .focused : .notActionable
        }
    }

    /// Pure matcher, exposed for tests. Exact matches outrank substring matches;
    /// a match in the focused window outranks one in another window; any tie at
    /// the best rank is ambiguous rather than "first wins".
    static func select(title: String, candidates: [Candidate]) -> Selection {
        let needle = normalized(title)
        guard validNeedle(needle) else { return .none }

        var ranked: [(candidate: Candidate, rank: Int)] = []
        for candidate in candidates {
            guard candidate.canPress, candidate.enabled,
                  eligibleRoles.contains(candidate.role),
                  candidate.inConversationContainer else { continue }
            let label = normalized(candidate.label)
            guard !label.isEmpty, label.count <= maxLabelLength else { continue }

            if label == needle {
                ranked.append((candidate, candidate.inFocusedWindow ? 0 : 1))
            } else if needle.count >= 4, label.contains(needle) {
                ranked.append((candidate, candidate.inFocusedWindow ? 2 : 3))
            }
        }
        guard let bestRank = ranked.map(\.rank).min() else { return .none }
        let best = ranked.filter { $0.rank == bestRank }
        guard best.count == 1 else { return .ambiguous }
        return .unique(best[0].candidate.index)
    }

    private static func collect(
        title needle: String, root: AXUIElement, focusedWindow: AXUIElement?
    ) -> (candidates: [Candidate], elements: [AXUIElement]) {
        var candidates: [Candidate] = []
        var elements: [AXUIElement] = []
        var seenHashes: Set<CFHashCode> = []
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited = 0

        while !queue.isEmpty, visited < maxVisitedElements {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            let label = label(of: element, role: role)
            let labelMatches = label.map {
                normalized($0) == needle || (needle.count >= 4 && normalized($0).contains(needle))
            } ?? false

            if labelMatches, let label, let actionable = actionableElement(startingAt: element),
               let actionRole = stringAttribute(actionable, kAXRoleAttribute),
               eligibleRoles.contains(actionRole) {
                let hash = CFHash(actionable)
                if seenHashes.insert(hash).inserted {
                    let candidate = Candidate(
                        index: elements.count,
                        label: label,
                        role: actionRole,
                        enabled: enabled(actionable),
                        canPress: canPress(actionable),
                        inFocusedWindow: focusedWindow.map { isDescendant(actionable, of: $0) } ?? false,
                        inConversationContainer: isInConversationContainer(
                            actionable, role: actionRole)
                    )
                    candidates.append(candidate)
                    elements.append(actionable)
                }
            }

            guard depth < maxDepth, let children = children(of: element) else { continue }
            for child in children { queue.append((child, depth + 1)) }
        }
        return (candidates, elements)
    }

    private static func isInConversationContainer(_ element: AXUIElement, role: String) -> Bool {
        if role == kAXRowRole as String || role == kAXCellRole as String || role == "AXListItem" {
            return true
        }
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { return false }
            let candidateRole = stringAttribute(candidate, kAXRoleAttribute) ?? ""
            if conversationContainers.contains(candidateRole) { return true }
            if candidateRole == kAXWindowRole as String || candidateRole == kAXApplicationRole as String {
                return false
            }
            current = elementAttribute(candidate, kAXParentAttribute)
        }
        return false
    }

    private static func actionableElement(startingAt element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<4 {
            let role = stringAttribute(current, kAXRoleAttribute) ?? ""
            if role == kAXWindowRole as String || role == kAXApplicationRole as String {
                return nil
            }
            if eligibleRoles.contains(role), canPress(current), enabled(current) {
                return current
            }
            guard let parent = elementAttribute(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    private static func validNeedle(_ needle: String) -> Bool {
        guard needle.count >= 2, needle.count <= maxLabelLength else { return false }
        return !genericLabels.contains(needle)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func label(of element: AXUIElement, role: String) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = stringAttribute(element, attribute), !text.isEmpty { return text }
        }
        // `value` 只在可点击的短标签上读取；聊天正文的 AXValue 可能是整段
        // 消息，拿它做匹配会把正文里的标题当成会话行。
        guard eligibleRoles.contains(role), let text = stringAttribute(element, kAXValueAttribute),
              text.count <= maxLabelLength else { return nil }
        return text
    }

    private static func enabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success,
              let number = value as? NSNumber else { return true }
        return number.boolValue
    }

    private static func canPress(_ element: AXUIElement) -> Bool {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let actions = value as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    private static func isDescendant(_ element: AXUIElement, of ancestor: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { return false }
            if CFEqual(candidate, ancestor) { return true }
            current = elementAttribute(candidate, kAXParentAttribute)
        }
        return false
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement) // swift-safety: allow CFTypeID-checked cast
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        return children
    }
}
