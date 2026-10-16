import Foundation
import CoreFoundation

/// 已核实的原生 command hook 配置；生成配置不代表目标客户端已加载或验收通过。
struct NativeHookProfile {
    enum TimeoutUnit: Equatable {
        case seconds
        case milliseconds
    }

    struct Binding {
        let event: String
        let bridgeHook: String
        /// 使用目标客户端自己的单位，见 profile.timeoutUnit。
        let timeout: Int
    }

    enum MergeError: Error, Equatable, LocalizedError {
        case invalidBridgePath
        case invalidHooksContainer
        case invalidEvent(String)
        case invalidGroup(event: String, index: Int)
        case invalidHook(event: String, group: Int, index: Int)

        var errorDescription: String? {
            switch self {
            case .invalidBridgePath:
                return "bridge 路径必须为不含 NUL 的绝对路径，未修改原配置。"
            case .invalidHooksContainer:
                return "hooks 必须为事件字典，未修改原配置。"
            case .invalidEvent(let event):
                return "\(event) 必须为 hook 分组数组，未修改原配置。"
            case .invalidGroup(let event, let index):
                return "\(event) 的第 \(index + 1) 个 hook 分组格式无效，未修改原配置。"
            case .invalidHook(let event, let group, let index):
                return "\(event) 的第 \(group + 1) 组、第 \(index + 1) 个 hook 格式无效，未修改原配置。"
            }
        }
    }

    let agent: AgentType
    let relativeConfigPath: String
    let hooksAreAtRoot: Bool
    let timeoutUnit: TimeoutUnit
    let bindings: [Binding]

    static func profile(for agent: AgentType) -> NativeHookProfile? {
        switch agent {
        case .claudeCode, .qwen, .qoder:
            let directory: String
            switch agent {
            case .claudeCode: directory = ".claude"
            case .qwen: directory = ".qwen"
            default: directory = ".qoder"
            }
            return NativeHookProfile(
                agent: agent,
                relativeConfigPath: "\(directory)/settings.json",
                hooksAreAtRoot: false,
                timeoutUnit: .seconds,
                bindings: [
                    Binding(event: "SessionStart", bridgeHook: "session_start", timeout: 5),
                    // 提交提示是轮次事件；不能改成 SessionStart 或额外发送一次会话开始。
                    Binding(event: "UserPromptSubmit", bridgeHook: "UserPromptSubmit", timeout: 5),
                    // 仅 Claude 已实现前置问答回传；其他品牌先观察，不擅自接管输入。
                    Binding(event: "PreToolUse", bridgeHook: agent == .claudeCode ? "PreToolUse" : "toolstart",
                            timeout: agent == .claudeCode ? 300 : 5),
                    Binding(event: "PostToolUse", bridgeHook: "PostToolUse", timeout: 5),
                    Binding(event: "PostToolUseFailure", bridgeHook: "PostToolUseFailure", timeout: 5),
                    Binding(event: "PermissionRequest", bridgeHook: "PermissionRequest", timeout: 300),
                    Binding(event: "Notification", bridgeHook: "Notification", timeout: 5),
                    Binding(event: "Stop", bridgeHook: "notification", timeout: 5),
                    Binding(event: "SessionEnd", bridgeHook: "session_end", timeout: 1),
                    Binding(event: "SubagentStart", bridgeHook: "subagent_start", timeout: 5),
                    Binding(event: "SubagentStop", bridgeHook: "subagent_end", timeout: 5),
                    Binding(event: "PreCompact", bridgeHook: "compact", timeout: 5),
                ]
            )
        case .codex:
            return NativeHookProfile(
                agent: agent,
                relativeConfigPath: ".codex/hooks.json",
                hooksAreAtRoot: false,
                timeoutUnit: .seconds,
                bindings: [
                    Binding(event: "SessionStart", bridgeHook: "session_start", timeout: 5),
                    Binding(event: "UserPromptSubmit", bridgeHook: "UserPromptSubmit", timeout: 5),
                    Binding(event: "PreToolUse", bridgeHook: "PreToolUse", timeout: 5),
                    Binding(event: "PostToolUse", bridgeHook: "PostToolUse", timeout: 5),
                    Binding(event: "PermissionRequest", bridgeHook: "PermissionRequest", timeout: 300),
                    Binding(event: "Stop", bridgeHook: "Stop", timeout: 5),
                    Binding(event: "SessionEnd", bridgeHook: "session_end", timeout: 1),
                    Binding(event: "SubagentStart", bridgeHook: "SubagentStart", timeout: 5),
                    Binding(event: "SubagentStop", bridgeHook: "SubagentStop", timeout: 5),
                    Binding(event: "Interrupt", bridgeHook: "Interrupt", timeout: 1),
                    Binding(event: "PreCompact", bridgeHook: "PreCompact", timeout: 5),
                    Binding(event: "PostCompact", bridgeHook: "PostCompact", timeout: 5),
                ]
            )
        case .droid:
            // 独立 hooks.json 优先于 settings.json，顶层直接存储事件映射。
            return NativeHookProfile(
                agent: agent,
                relativeConfigPath: ".factory/hooks.json",
                hooksAreAtRoot: true,
                timeoutUnit: .seconds,
                bindings: [
                    Binding(event: "SessionStart", bridgeHook: "session_start", timeout: 5),
                    Binding(event: "UserPromptSubmit", bridgeHook: "UserPromptSubmit", timeout: 5),
                    Binding(event: "PreToolUse", bridgeHook: "toolstart", timeout: 5),
                    Binding(event: "PostToolUse", bridgeHook: "PostToolUse", timeout: 5),
                    Binding(event: "Notification", bridgeHook: "Notification", timeout: 5),
                    Binding(event: "Stop", bridgeHook: "notification", timeout: 5),
                    Binding(event: "SessionEnd", bridgeHook: "session_end", timeout: 1),
                    Binding(event: "SubagentStop", bridgeHook: "subagent_end", timeout: 5),
                    Binding(event: "PreCompact", bridgeHook: "compact", timeout: 5),
                ]
            )
        case .geminiCli, .tabnine:
            return NativeHookProfile(
                agent: agent,
                relativeConfigPath: agent == .tabnine ? ".tabnine/agent/settings.json" : ".gemini/settings.json",
                hooksAreAtRoot: false,
                timeoutUnit: .milliseconds,
                bindings: [
                    Binding(event: "SessionStart", bridgeHook: "session_start", timeout: 5_000),
                    Binding(event: "BeforeAgent", bridgeHook: "UserPromptSubmit", timeout: 5_000),
                    // 两者的前置工具和权限通知只观察，不接管其原生授权。
                    Binding(event: "BeforeTool", bridgeHook: "toolstart", timeout: 5_000),
                    Binding(event: "AfterTool", bridgeHook: "PostToolUse", timeout: 5_000),
                    Binding(event: "Notification", bridgeHook: "Notification", timeout: 5_000),
                    Binding(event: "AfterAgent", bridgeHook: "notification", timeout: 5_000),
                    Binding(event: "SessionEnd", bridgeHook: "session_end", timeout: 1_000),
                    Binding(event: "PreCompress", bridgeHook: "compact", timeout: 5_000),
                ]
            )
        default:
            // 未核实的品牌不使用“看起来相似”的通用配置模板。
            return nil
        }
    }

    /// 只替换本品牌可识别的 di-bridge 调用，保留同组第三方 hook 和所有其他配置。
    /// 任何原有 hook 结构冲突都会整体抛错，安装方不能写入一份仅部分合并的配置。
    func merging(into configuration: [String: Any], bridgePath: String) throws -> [String: Any] {
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0) else { throw MergeError.invalidBridgePath }
        var result = try removing(from: configuration)
        var hooks = hooksAreAtRoot ? result : result["hooks"] as? [String: Any] ?? [:]
        for binding in bindings {
            var groups = hooks[binding.event] as? [Any] ?? []
            groups.append(hookGroup(for: binding, bridgePath: bridgePath))
            hooks[binding.event] = groups
        }

        if hooksAreAtRoot { return hooks }
        result["hooks"] = hooks
        return result
    }

    /// 卸载只移除可证明属于本品牌的调用，混合分组中的其他 handler 原样保留。
    func removing(from configuration: [String: Any]) throws -> [String: Any] {
        var hooks = try eventMap(in: configuration)

        // 同时清掉本应用旧版写入的错误事件名，但不动其他程序的对应事件。
        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [Any] else { continue }
            hooks[event] = groups.compactMap { value -> Any? in
                guard var group = value as? [String: Any], let commands = group["hooks"] as? [Any] else {
                    return value
                }
                let retained = commands.filter { !isOwnedHook($0) }
                guard retained.count != commands.count else { return value }
                guard !retained.isEmpty else { return nil }
                group["hooks"] = retained
                return group
            }
            if let remaining = hooks[event] as? [Any], remaining.isEmpty, !groups.isEmpty {
                hooks.removeValue(forKey: event)
            }
        }

        if hooksAreAtRoot { return hooks }
        guard configuration["hooks"] != nil else { return configuration }
        var result = configuration
        result["hooks"] = hooks
        return result
    }

    /// 配置齐全也只代表文件状态；客户端是否加载和事件是否到达由运行时诊断判断。
    func isConfigured(in configuration: [String: Any], bridgePath: String) -> Bool {
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0) else { return false }
        guard let hooks = try? eventMap(in: configuration) else { return false }
        var ownedCount = 0
        for value in hooks.values {
            for group in value as? [[String: Any]] ?? [] {
                ownedCount += (group["hooks"] as? [Any] ?? []).filter { isOwnedHook($0) }.count
            }
        }
        // 旧事件或重复条目仍在时，不能仅凭新条目也存在就认为配置正确。
        guard ownedCount == bindings.count else { return false }
        return bindings.allSatisfy { binding in
            let expected = hookGroup(for: binding, bridgePath: bridgePath)
            let groups = hooks[binding.event] as? [[String: Any]] ?? []
            return groups.contains { NSDictionary(dictionary: $0).isEqual(to: expected) }
        }
    }

    private func hookGroup(for binding: Binding, bridgePath: String) -> [String: Any] {
        let dialect = agent == .trae ? " --adapter trae_cn" : ""
        let command = "\(Self.shellQuote(bridgePath)) --agent \(agent.rawValue) --hook \(binding.bridgeHook)\(dialect)"
        return [
            "hooks": [[
                "type": "command",
                "command": binding.bridgeHook == "PermissionRequest" ? command : "\(command) || true",
                "timeout": binding.timeout,
            ]] as [[String: Any]],
        ]
    }

    private func eventMap(in configuration: [String: Any]) throws -> [String: Any] {
        if !hooksAreAtRoot, let existing = configuration["hooks"], !(existing is [String: Any]) {
            throw MergeError.invalidHooksContainer
        }
        let hooks = hooksAreAtRoot ? configuration : configuration["hooks"] as? [String: Any] ?? [:]
        try validate(hooks)
        return hooks
    }

    private func validate(_ hooks: [String: Any]) throws {
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { throw MergeError.invalidEvent(event) }
            for (groupIndex, value) in groups.enumerated() {
                guard let group = value as? [String: Any],
                      let commands = group["hooks"] as? [Any],
                      group["matcher"] == nil || group["matcher"] is String else {
                    throw MergeError.invalidGroup(event: event, index: groupIndex)
                }
                for (commandIndex, value) in commands.enumerated() {
                    guard let command = value as? [String: Any],
                          let type = command["type"] as? String ?? (agent == .trae && command["type"] == nil ? "command" : nil),
                          !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw MergeError.invalidHook(event: event, group: groupIndex, index: commandIndex)
                    }
                    let requiredField: String?
                    switch type {
                    case "command": requiredField = "command"
                    case "prompt", "agent": requiredField = "prompt"
                    case "http": requiredField = "url"
                    default: requiredField = nil
                    }
                    if let field = requiredField,
                       (command[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        throw MergeError.invalidHook(event: event, group: groupIndex, index: commandIndex)
                    }
                    if let timeout = command["timeout"] {
                        guard let number = timeout as? NSNumber,
                              CFGetTypeID(number) != CFBooleanGetTypeID(),
                              number.doubleValue.isFinite, number.doubleValue > 0 else {
                            throw MergeError.invalidHook(event: event, group: groupIndex, index: commandIndex)
                        }
                    }
                }
            }
        }
    }

    private func isOwnedHook(_ value: Any) -> Bool {
        guard let hook = value as? [String: Any], hook["type"] as? String == "command", hook["args"] == nil,
              let command = hook["command"] as? String,
              var words = Self.shellWords(command) else { return false }
        if Array(words.suffix(2)) == ["||", "true"] { words.removeLast(2) }
        if agent == .trae, Array(words.suffix(2)) == ["--adapter", "trae_cn"] { words.removeLast(2) }
        guard words.count == 5, (words[0] as NSString).lastPathComponent == "di-bridge",
              words[1] == "--agent", words[2] == agent.rawValue,
              words[3] == "--hook", !words[4].isEmpty else { return false }
        return true
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 仅拆出本应用生成的简单 argv；不执行展开，也不识别包含其他命令的脚本为本应用配置。
    private static func shellWords(_ command: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in command {
            if escaped {
                word.append(character)
                escaped = false
                started = true
            } else if character == "\\", quote != "'" {
                escaped = true
                started = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started {
                    words.append(word)
                    word = ""
                    started = false
                }
            } else {
                word.append(character)
                started = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if started { words.append(word) }
        return words
    }
}
