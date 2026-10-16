import Foundation

/// Hmbown/Codewhale v0.10.0 的第三方 TUI hooks；不是 DeepSeek 官方客户端协议。
enum DeepSeekHookConfiguration {
    static let supportedVersion = "0.10.0"
    static let relativeConfigPath = ".codewhale/config.toml"
    static let events = [
        "session_start", "session_end", "message_submit", "tool_call_before", "tool_call_after",
        "mode_change", "on_error", "turn_end", "subagent_spawn", "subagent_complete",
        "session_busy", "session_idle", "session_error", "waiting_for_user",
    ]

    enum ConfigurationError: Error, Equatable {
        case invalidBridgePath
        case invalidPath(String)
        case invalidStructure(String)
        case hooksDisabled
    }

    /// 不读取文件或环境。调用方须确认实际客户端版本，并提供其启动环境和 CLI 参数。
    /// 与上游一致，已有 legacy 配置优先于尚不存在的默认新路径，避免遮蔽用户配置。
    static func resolvedConfigPath(
        homeDirectory: String, environment: [String: String], explicitPath: String? = nil,
        currentDirectory: String? = nil, fileExists: (String) -> Bool
    ) throws -> String {
        guard homeDirectory.hasPrefix("/"), !homeDirectory.utf8.contains(0) else {
            throw ConfigurationError.invalidPath("homeDirectory")
        }
        func configFile(_ value: String, field: String, allowRelative: Bool) throws -> String {
            guard !value.isEmpty, !value.utf8.contains(0), !value.hasSuffix("/"),
                  !value.split(separator: "/").contains("..") else { throw ConfigurationError.invalidPath(field) }
            if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL.path }
            guard allowRelative, let directory = currentDirectory, directory.hasPrefix("/") else {
                throw ConfigurationError.invalidPath(field)
            }
            return URL(fileURLWithPath: directory).appendingPathComponent(value).standardizedFileURL.path
        }
        func override(_ key: String) throws -> String? {
            guard let raw = environment[key] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let expanded: String
            if value == "~" { expanded = homeDirectory }
            else if value.hasPrefix("~/") || value.hasPrefix("~\\") {
                expanded = homeDirectory + "/" + value.dropFirst().drop(while: { $0 == "/" || $0 == "\\" })
            } else { expanded = value }
            guard expanded.hasPrefix("/"), !expanded.utf8.contains(0) else { throw ConfigurationError.invalidPath(key) }
            return expanded
        }
        if let explicitPath { return try configFile(explicitPath, field: "explicitPath", allowRelative: true) }
        for key in ["CODEWHALE_CONFIG_PATH", "DEEPSEEK_CONFIG_PATH"] {
            if let value = try override(key) { return try configFile(value, field: key, allowRelative: false) }
        }
        let customHome = try override("CODEWHALE_HOME")
        let primary = URL(fileURLWithPath: customHome ?? homeDirectory + "/.codewhale").appendingPathComponent("config.toml").path
        if customHome != nil || fileExists(primary) { return primary }
        let legacy = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".deepseek/config.toml").path
        return fileExists(legacy) ? legacy : primary
    }

    private static let beginMarker = "# BEGIN XIsland:Codewhale:hooks v1"
    private static let endMarker = "# END XIsland:Codewhale:hooks v1"

    static func merging(into configuration: String, bridgePath: String) throws -> String {
        try validateBridgePath(bridgePath)
        let original = try removing(from: configuration)
        guard try validateStructure(original) else { throw ConfigurationError.hooksDisabled }
        return original + block(bridgePath: bridgePath)
    }

    static func removing(from configuration: String) throws -> String {
        let original = try removingLegacyTables(from: removingOwnedBlock(from: configuration))
        _ = try validateStructure(original)
        return original
    }

    static func isConfigured(in configuration: String, bridgePath: String) -> Bool {
        guard (try? validateBridgePath(bridgePath)) != nil,
              let original = try? removing(from: configuration),
              (try? validateStructure(original)) == true else { return false }
        return original != configuration && configuration == original + block(bridgePath: bridgePath)
    }

    private static func block(bridgePath: String) -> String {
        var result = "\n\(beginMarker)\n"
        // [[hooks.hooks]] 隐式建立父表；反序列化缺省 enabled=true，无需重写用户 [hooks]。
        for event in events {
            let command = "\(shellQuote(bridgePath)) --agent deepseek --hook \(event)"
            // 前置事件须后台运行才能确保没有决策语义；其余事件等待观察命令完成。
            // 上游 UI observer 仍由两个 worker 派发，foreground 不等于跨事件全局有序。
            let background = event == "message_submit" || event == "tool_call_before"
            result += "[[hooks.hooks]]\nname = \(tomlString("xisland_" + event))\nevent = \(tomlString(event))\ncommand = \(tomlString(command))\ncondition = { type = \"always\" }\ntimeout_secs = 5\nbackground = \(background)\ncontinue_on_error = true\n\n"
        }
        return result + endMarker + "\n"
    }

    private static func removingOwnedBlock(from configuration: String) throws -> String {
        let markers = try scannedLines(configuration).filter {
            $0.code.hasPrefix("# BEGIN XIsland:Codewhale:") || $0.code.hasPrefix("# END XIsland:Codewhale:")
        }
        guard !markers.isEmpty else { return configuration }
        guard markers.count == 2, markers[0].code == beginMarker, markers[1].code == endMarker,
              markers[0].start > configuration.startIndex else { throw ConfigurationError.invalidStructure("owned markers") }
        let start = configuration.index(before: markers[0].start)
        guard configuration[start] == "\n" else { throw ConfigurationError.invalidStructure("owned separator") }
        let owned = String(configuration[start...])
        guard let line = owned.components(separatedBy: "\n").first(where: { $0.hasPrefix("command = ") }),
              let command = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(10).utf8), options: [.fragmentsAllowed]) as? String else {
            throw ConfigurationError.invalidStructure("owned command")
        }
        let suffix = " --agent deepseek --hook session_start"
        guard command.hasSuffix(suffix) else { throw ConfigurationError.invalidStructure("owned command") }
        let quoted = String(command.dropLast(suffix.count))
        guard quoted.hasPrefix("'"), quoted.hasSuffix("'"), quoted.count >= 2 else { throw ConfigurationError.invalidStructure("owned path") }
        let bridgePath = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        try validateBridgePath(bridgePath)
        guard quoted == shellQuote(bridgePath), owned == block(bridgePath: bridgePath) else {
            throw ConfigurationError.invalidStructure("modified owned block")
        }
        return String(configuration[..<start])
    }

    private static let legacyHooks = [
        "session_start": "session_start", "session_end": "session_end", "message_submit": "session_start",
        "tool_call_before": "PreToolUse", "tool_call_after": "PostToolUse",
        "mode_change": "notification", "on_error": "notification",
    ]

    private static func removingLegacyTables(from configuration: String) throws -> String {
        let lines = try scannedLines(configuration)
        let tables = lines.indices.filter { lines[$0].code.hasPrefix("[") }
        var removals: [Range<String.Index>] = []
        for (position, index) in tables.enumerated() {
            let end = position + 1 < tables.count ? tables[position + 1] : lines.endIndex
            let fields = lines[index..<end].filter { !$0.code.isEmpty && !$0.code.hasPrefix("#") }
            guard fields.count == 5, fields[0].code == "[[hooks.hooks]]" else { continue }
            for (event, argument) in legacyHooks {
                let prefix = "command = \""
                let suffix = " --agent deepseek --hook \(argument) || true\""
                guard fields[1].code == "name = \"xisland_\(event)\"", fields[2].code == "event = \"\(event)\"",
                      fields[3].code.hasPrefix(prefix), fields[3].code.hasSuffix(suffix), fields[4].code == "condition = \"*\"" else { continue }
                let path = String(fields[3].code.dropFirst(prefix.count).dropLast(suffix.count))
                guard path.hasPrefix("/"), path.hasSuffix("/di-bridge"),
                      !path.contains(where: { "\"'\\$`;&|<>()".contains($0) }),
                      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
                let expected = "[[hooks.hooks]]\nname = \"xisland_\(event)\"\nevent = \"\(event)\"\ncommand = \"\(path) --agent deepseek --hook \(argument) || true\"\ncondition = \"*\"\n"
                let range = fields[0].start..<fields[4].end
                if String(configuration[range]) == expected { removals.append(range) }
            }
        }
        var result = configuration
        for range in removals.reversed() { result.removeSubrange(range) }
        return result
    }

    /// 只接受能安全追加 array-of-tables 的形状；不重新序列化第三方文本。
    private static func validateStructure(_ text: String) throws -> Bool {
        var table: [String] = []
        var hasHooksTable = false
        var enabled: Bool?
        for line in try scannedLines(text) where !line.code.isEmpty && !line.code.hasPrefix("#") {
            if line.code.hasPrefix("[") {
                let array = line.code.hasPrefix("[[")
                let width = array ? 2 : 1
                guard line.code.hasSuffix(array ? "]]" : "]") else { throw ConfigurationError.invalidStructure("table header") }
                table = try keyPath(String(line.code.dropFirst(width).dropLast(width)))
                if table.first == "hooks" {
                    if table == ["hooks"], !array, !hasHooksTable { hasHooksTable = true }
                    else if table != ["hooks", "hooks"] || !array { throw ConfigurationError.invalidStructure("hooks table") }
                }
                continue
            }
            guard let equal = line.code.firstIndex(of: "=") else { throw ConfigurationError.invalidStructure("assignment") }
            let key = try keyPath(String(line.code[..<equal]))
            let value = line.code[line.code.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if table.isEmpty, key.first == "hooks" { throw ConfigurationError.invalidStructure("inline hooks") }
            if table == ["hooks"] {
                if key.first == "hooks" { throw ConfigurationError.invalidStructure("inline hooks array") }
                if key.first == "enabled" {
                    guard key.count == 1, enabled == nil, ["true", "false"].contains(value) else { throw ConfigurationError.invalidStructure("hooks.enabled") }
                    enabled = value == "true"
                }
            }
            if table == ["hooks", "hooks"], key.first == "condition", !value.hasPrefix("{") {
                throw ConfigurationError.invalidStructure("hooks condition requires an object")
            }
        }
        return enabled ?? true
    }

    private static func validateBridgePath(_ value: String) throws {
        guard value.hasPrefix("/"), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConfigurationError.invalidBridgePath
        }
    }

    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func keyPath(_ value: String) throws -> [String] {
        var keys: [String] = []
        var remaining = value.trimmingCharacters(in: .whitespaces)
        while !remaining.isEmpty {
            let key: String
            if remaining.first == "'" || remaining.first == "\"" {
                let quote = remaining.removeFirst()
                guard let end = remaining.firstIndex(of: quote) else { throw ConfigurationError.invalidStructure("quoted key") }
                key = String(remaining[..<end])
                guard !key.contains("\\") else { throw ConfigurationError.invalidStructure("escaped key") }
                remaining = String(remaining[remaining.index(after: end)...])
            } else {
                key = String(remaining.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
                guard !key.isEmpty else { throw ConfigurationError.invalidStructure("key") }
                remaining.removeFirst(key.count)
            }
            keys.append(key)
            remaining = remaining.trimmingCharacters(in: .whitespaces)
            if remaining.isEmpty { break }
            guard remaining.removeFirst() == ".", !remaining.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConfigurationError.invalidStructure("dotted key") }
            remaining = remaining.trimmingCharacters(in: .whitespaces)
        }
        guard !keys.isEmpty else { throw ConfigurationError.invalidStructure("empty key") }
        return keys
    }

    private struct ScannedLine { let start: String.Index; let end: String.Index; let code: String }

    /// 与 Kimi 复用词法思路，但表结构属于 Codewhale 的 [hooks] / [[hooks.hooks]]。
    /// 这只是插入边界扫描器；多行文本中的标记和 table 字样不建立所有权。
    private static func scannedLines(_ text: String) throws -> [ScannedLine] {
        guard !text.utf8.contains(0), !text.replacingOccurrences(of: "\r\n", with: "").contains("\r") else { throw ConfigurationError.invalidStructure("control characters") }
        var result: [ScannedLine] = []
        var quote: Character?
        var multiline = false
        var delimiters: [Character] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let raw = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            let statement = quote == nil && delimiters.isEmpty
            var code = ""
            let chars = Array(raw)
            var index = 0
            while index < chars.count {
                let char = chars[index]
                if let current = quote {
                    if current == "\"", char == "\\" {
                        code.append(char)
                        if index + 1 < chars.count { code.append(chars[index + 1]) }
                        index += 2
                        continue
                    }
                    if char == current {
                        if multiline {
                            let run = chars[index...].prefix { $0 == current }.count
                            if run >= 3 {
                                guard run <= 5 else { throw ConfigurationError.invalidStructure("string delimiter") }
                                code += String(repeating: String(current), count: run)
                                index += run; quote = nil; multiline = false
                                continue
                            }
                        } else { quote = nil }
                    }
                    code.append(char)
                } else if char == "#" {
                    if index == 0, statement { code = raw }
                    break
                } else if char == "\"" || char == "'" {
                    quote = char
                    multiline = index + 2 < chars.count && chars[index + 1] == char && chars[index + 2] == char
                    if multiline { code += String(repeating: String(char), count: 3); index += 3; continue }
                    code.append(char)
                } else {
                    if char == "[" || char == "{" { delimiters.append(char) }
                    if char == "]" || char == "}" {
                        guard delimiters.popLast() == (char == "]" ? "[" : "{") else { throw ConfigurationError.invalidStructure("unbalanced delimiters") }
                    }
                    code.append(char)
                }
                index += 1
            }
            guard quote == nil || multiline else { throw ConfigurationError.invalidStructure("unterminated string") }
            let next = end < text.endIndex ? text.index(after: end) : end
            if statement {
                if code.hasPrefix("["), quote != nil || !delimiters.isEmpty { throw ConfigurationError.invalidStructure("table header") }
                result.append(ScannedLine(start: start, end: next, code: code.trimmingCharacters(in: .whitespaces)))
            }
            start = next
        }
        guard quote == nil, delimiters.isEmpty else { throw ConfigurationError.invalidStructure("unfinished TOML value") }
        return result
    }
}
