import Foundation

/// 审批卡里的参数编辑规则；与 SwiftUI 分离，便于直接验证 Bash 字段保留与 JSON 规范化。
enum PermissionInputEditing {
    static func parsedObject(_ raw: String?) -> [String: Any]? {
        guard let raw, !raw.isEmpty, !raw.utf8.contains(0),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              JSONSerialization.isValidJSONObject(object) else { return nil }
        return object
    }

    /// 只有 Bash 提供命令级编辑；其他工具必须看到完整 JSON，避免漏掉未显示的字段。
    static func command(tool: String, toolInput: String?) -> String? {
        guard tool == "Bash" else { return nil }
        return parsedObject(toolInput)?["command"] as? String
    }

    /// 会话级允许规则只接受完全相同、无通配符、无换行的 Bash 命令。
    /// 含 `*` 的命令会变成更宽的 Bash 规则，不能冒充“完全相同”。
    static func exactBashCommand(toolInput: String?) -> String? {
        guard let command = parsedObject(toolInput)?["command"] as? String,
              isExactBashCommand(command) else { return nil }
        return command
    }

    static func isExactBashCommand(_ command: String) -> Bool {
        !command.isEmpty && !command.utf8.contains(0) && command.utf8.count <= 2_000
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.contains("*")
            && !command.contains("\n") && !command.contains("\r")
    }

    static func prettyJSON(toolInput: String?) -> String {
        guard let raw = toolInput, !raw.isEmpty else { return "{}" }
        guard let object = parsedObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                      options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return raw }
        return text
    }

    /// 替换 command 时保留 description 等其它键；原输入不是 JSON 对象时返回 nil。
    static func replacingCommand(toolInput: String?, command: String) -> String? {
        guard var object = parsedObject(toolInput) else { return nil }
        object["command"] = command
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
