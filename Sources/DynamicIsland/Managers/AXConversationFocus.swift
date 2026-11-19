import ApplicationServices
import AppKit

/// 在目标客户端的可访问性树里按标题查找会话条目并点击。
///
/// 仅适用于没有会话级 deeplink、但界面条目可被辅助功能读取的客户端（如 Trae 系）。
/// Electron 只有在暴露 a11y 树时才能命中；失败时由调用方回退到窗口级结果。
enum AXConversationFocus {
    static func focus(title: String, in app: NSRunningApplication) -> Bool {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return false }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        var matches: [(element: AXUIElement, rank: Int)] = []

        while !queue.isEmpty, visited < 900 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if let text = label(of: element) {
                if text == needle {
                    matches.append((element, 0))
                } else if text.contains(needle) {
                    matches.append((element, 1))
                }
            }
            guard depth < 14, let children = children(of: element) else { continue }
            for child in children { queue.append((child, depth + 1)) }
        }

        guard let best = matches.min(by: { $0.rank < $1.rank }) else { return false }
        return AXUIElementPerformAction(best.element, kAXPressAction as CFString) == .success
    }

    private static func label(of element: AXUIElement) -> String? {
        let attributes = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
        for attribute in attributes {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let text = value as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        return children
    }
}
