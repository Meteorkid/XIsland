import Foundation

/// 只追加、替换或删除自身的规范区块，不解析后重写第三方 TOML。
enum KimiHookConfiguration {
    static let relativeConfigPath = ".kimi/config.toml"
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "Stop", "StopFailure", "SessionEnd", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "Notification",
    ]

    enum Runtime: CaseIterable, Equatable {
        case legacyPython
        case node

        var relativeConfigPath: String {
            self == .legacyPython ? KimiHookConfiguration.relativeConfigPath : ".kimi-code/config.toml"
        }

        var events: [String] {
            KimiHookConfiguration.events + (self == .node ? [
                "UserPromptQueued", "TurnStarted", "PermissionRequest", "PermissionResult",
                "SessionHeartbeat", "TaskStarted", "Interrupt",
            ] : [])
        }

        fileprivate var markerName: String { self == .legacyPython ? "Kimi" : "KimiCode" }
        fileprivate var beginMarker: String { "# BEGIN XIsland:\(markerName):hooks v1" }
        fileprivate var endMarker: String { "# END XIsland:\(markerName):hooks v1" }
        fileprivate var arguments: String { "--agent kimi" + (self == .node ? " --adapter kimi_code" : "") }
    }

    enum ConfigurationError: Error, Equatable {
        case invalidBridgePath
        case invalidStructure(String)
    }

    static func merging(into configuration: String, bridgePath: String, runtime: Runtime = .legacyPython) throws -> String {
        try validateBridgePath(bridgePath)
        return try removing(from: configuration, runtime: runtime) + block(bridgePath: bridgePath, runtime: runtime)
    }

    static func removing(from configuration: String, runtime: Runtime = .legacyPython) throws -> String {
        try removingLegacyTables(from: removingOwnedBlock(from: configuration, runtime: runtime), runtime: runtime)
    }

    private static func removingOwnedBlock(from configuration: String, runtime: Runtime) throws -> String {
        let lines = try scannedLines(configuration)
        let markers = lines.filter { line in
            Runtime.allCases.contains { candidate in
                line.code.hasPrefix("# BEGIN XIsland:\(candidate.markerName):")
                    || line.code.hasPrefix("# END XIsland:\(candidate.markerName):")
            }
        }
        guard !markers.isEmpty else { return configuration }
        // 新配置文件中只允许升级完整的旧规范块；旧运行时不会认领新版块。
        let allowedRuntimes: [Runtime] = runtime == .node ? [.node, .legacyPython] : [.legacyPython]
        guard markers.count == 2,
              let ownedRuntime = allowedRuntimes.first(where: {
                  markers[0].code == $0.beginMarker && markers[1].code == $0.endMarker
              }), markers[0].start > configuration.startIndex else {
            throw ConfigurationError.invalidStructure("owned hooks markers")
        }
        let start = configuration.index(before: markers[0].start)
        guard configuration[start] == "\n" else { throw ConfigurationError.invalidStructure("owned hooks separator") }
        let owned = String(configuration[start...])
        // 区块必须仍为完整的规范末尾区块；用户追加字段或手改命令时不猜测所有权。
        guard let commandLine = owned.components(separatedBy: "\n").first(where: { $0.hasPrefix("command = ") }),
              let encoded = String(commandLine.dropFirst("command = ".count)).data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed]) as? String else {
            throw ConfigurationError.invalidStructure("owned hooks command")
        }
        let suffix = " \(ownedRuntime.arguments) --hook \(ownedRuntime.events[0]) || true"
        guard command.hasSuffix(suffix) else { throw ConfigurationError.invalidStructure("owned hooks command") }
        let quoted = String(command.dropLast(suffix.count))
        guard quoted.hasPrefix("'"), quoted.hasSuffix("'"), quoted.count >= 2 else {
            throw ConfigurationError.invalidStructure("owned bridge path")
        }
        let bridgePath = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        try validateBridgePath(bridgePath)
        guard shellQuote(bridgePath) == quoted, owned == block(bridgePath: bridgePath, runtime: ownedRuntime) else {
            throw ConfigurationError.invalidStructure("modified owned hooks block")
        }
        let original = String(configuration[..<start])
        _ = try scannedLines(original)
        return original
    }

    /// 旧安装器未引用路径，且移除时只删掉了注释；完整旧表可能重复并散落在配置中。
    private static let legacyHooks: [(event: String, argument: String, timeout: Int)] = [
        ("PreToolUse", "PreToolUse", 5), ("PostToolUse", "PostToolUse", 5),
        ("UserPromptSubmit", "session_start", 5), ("SessionStart", "session_start", 5),
        ("SessionEnd", "session_end", 5), ("Stop", "notification", 5),
        ("SubagentStart", "subagent_start", 5), ("SubagentStop", "subagent_end", 5),
        ("PreCompact", "compact", 5), ("Notification", "Notification", 5),
        ("PermissionRequest", "PermissionRequest", 300),
    ]

    private static func removingLegacyTables(from configuration: String, runtime: Runtime) throws -> String {
        let lines = try scannedLines(configuration)
        let tableIndices = lines.indices.filter { lines[$0].code.hasPrefix("[") }
        var removals: [Range<String.Index>] = []
        for (position, tableIndex) in tableIndices.enumerated() {
            let table = lines[tableIndex]
            let tableEnd = position + 1 < tableIndices.count ? tableIndices[position + 1] : lines.endIndex
            let fields = lines[tableIndex..<tableEnd].filter { !$0.code.isEmpty && !$0.code.hasPrefix("#") }
            // scanner 已拒绝 hooks 子表；其他顶层表中同名字段与文本不属于本适配器。
            guard table.code.hasPrefix("[["), table.code.hasSuffix("]]"),
                  ["hooks", "\"hooks\"", "'hooks'"].contains(table.code.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)) else { continue }
            if runtime == .legacyPython, let range = legacyTableRange(fields, in: configuration) {
                removals.append(range)
                continue
            }
            let eventValues = try fields.dropFirst().compactMap { try eventValue($0.code) }
            guard eventValues.count == 1, let event = eventValues.first, runtime.events.contains(event) else {
                // 无法认领的旧 PermissionRequest 不能悄悄留下，否则 Kimi 拒绝整个 hooks 配置。
                throw ConfigurationError.invalidStructure("unsupported or ambiguous hooks event")
            }
        }
        var result = configuration
        for range in removals.reversed() { result.removeSubrange(range) }
        return result
    }

    private static func legacyTableRange(_ fields: [ScannedLine], in configuration: String) -> Range<String.Index>? {
        guard fields.count == 5, fields[0].code == "[[hooks]]",
              let legacy = legacyHooks.first(where: { fields[1].code == "event = \"\($0.event)\"" }),
              fields[3].code == "matcher = \"*\"", fields[4].code == "timeout = \(legacy.timeout)" else { return nil }
        let commandPrefix = "command = \""
        let commandSuffix = " --agent kimi --hook \(legacy.argument)" + (legacy.timeout == 300 ? "" : " || true") + "\""
        guard fields[2].code.hasPrefix(commandPrefix), fields[2].code.hasSuffix(commandSuffix) else { return nil }
        let bridgePath = String(fields[2].code.dropFirst(commandPrefix.count).dropLast(commandSuffix.count))
        guard bridgePath.hasPrefix("/"), bridgePath.hasSuffix("/di-bridge"),
              !bridgePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !bridgePath.contains(where: { "\"'\\$`;&|<>()".contains($0) }) else { return nil }
        let expected = "[[hooks]]\nevent = \"\(legacy.event)\"\ncommand = \"\(bridgePath) --agent kimi --hook \(legacy.argument)\(legacy.timeout == 300 ? "" : " || true")\"\nmatcher = \"*\"\ntimeout = \(legacy.timeout)\n"
        let range = fields[0].start..<fields[4].end
        // 连续原文也须精确一致；插入注释、修改空白或额外字段后不再认领。
        guard String(configuration[range]) == expected else { return nil }
        return range
    }

    private static func eventValue(_ code: String) throws -> String? {
        let parts = code.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, ["event", "\"event\"", "'event'"].contains(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2, !value.dropFirst().dropLast().contains("'") {
            return String(value.dropFirst().dropLast())
        }
        guard let data = value.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
            throw ConfigurationError.invalidStructure("hooks.event")
        }
        return event
    }

    static func isConfigured(in configuration: String, bridgePath: String, runtime: Runtime = .legacyPython) -> Bool {
        guard (try? validateBridgePath(bridgePath)) != nil,
              let original = try? removing(from: configuration, runtime: runtime) else { return false }
        return original != configuration && configuration == original + block(bridgePath: bridgePath, runtime: runtime)
    }

    private static func block(bridgePath: String, runtime: Runtime) -> String {
        var result = "\n\(runtime.beginMarker)\n"
        for event in runtime.events {
            let command = "\(shellQuote(bridgePath)) \(runtime.arguments) --hook \(event) || true"
            result += "[[hooks]]\nevent = \(tomlString(event))\ncommand = \(tomlString(command))\ntimeout = 5\n\n"
        }
        return result + runtime.endMarker + "\n"
    }

    private static func validateBridgePath(_ value: String) throws {
        guard value.hasPrefix("/"), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConfigurationError.invalidBridgePath
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func tomlString(_ value: String) -> String {
        // 路径不含控制字符，JSON 的这两个转义也是 TOML basic string 的合法转义。
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private struct ScannedLine {
        let start: String.Index
        let end: String.Index
        let code: String
    }

    /// 词法扫描只负责安全插入边界，不宣称是完整 TOML 校验器。
    /// 多行字符串/数组中的 hooks 文本不应误认作顶层定义或认领标记。
    private static func scannedLines(_ text: String) throws -> [ScannedLine] {
        guard !text.utf8.contains(0), !text.contains("\r") || !text.replacingOccurrences(of: "\r\n", with: "").contains("\r") else {
            throw ConfigurationError.invalidStructure("control characters")
        }
        var result: [ScannedLine] = []
        var quote: Character?
        var multiline = false
        var delimiters: [Character] = []
        var root = true
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let raw = String(text[lineStart..<lineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            let isStatement = quote == nil && delimiters.isEmpty
            var code = ""
            let chars = Array(raw)
            var index = 0
            while index < chars.count {
                let char = chars[index]
                if let currentQuote = quote {
                    if currentQuote == "\"", char == "\\" {
                        code.append(char)
                        if index + 1 < chars.count { code.append(chars[index + 1]) }
                        index += 2
                        continue
                    }
                    if char == currentQuote {
                        if multiline {
                            let run = chars[index...].prefix(while: { $0 == currentQuote }).count
                            if run >= 3 {
                                guard run <= 5 else { throw ConfigurationError.invalidStructure("string delimiter") }
                                code += String(repeating: String(currentQuote), count: run)
                                index += run
                                quote = nil
                                multiline = false
                                continue
                            }
                        } else { quote = nil }
                    }
                    code.append(char)
                } else if char == "#" {
                    if index == 0, isStatement { code = raw }
                    break
                } else if char == "\"" || char == "'" {
                    quote = char
                    multiline = index + 2 < chars.count && chars[index + 1] == char && chars[index + 2] == char
                    if multiline { code += String(repeating: String(char), count: 3); index += 3; continue }
                    code.append(char)
                } else {
                    if char == "[" || char == "{" { delimiters.append(char) }
                    if char == "]" || char == "}" {
                        guard delimiters.popLast() == (char == "]" ? "[" : "{") else {
                            throw ConfigurationError.invalidStructure("unbalanced delimiters")
                        }
                    }
                    code.append(char)
                }
                index += 1
            }
            guard quote == nil || multiline else { throw ConfigurationError.invalidStructure("unterminated string") }
            if isStatement {
                code = code.trimmingCharacters(in: .whitespaces)
                result.append(ScannedLine(start: lineStart, end: lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd, code: code))
                if code.hasPrefix("[") {
                    guard quote == nil, delimiters.isEmpty else { throw ConfigurationError.invalidStructure("table header") }
                    let isArray = code.hasPrefix("[[")
                    let width = isArray ? 2 : 1
                    guard code.hasSuffix(isArray ? "]]" : "]") else { throw ConfigurationError.invalidStructure("table header") }
                    let key = String(code.dropFirst(width).dropLast(width)).trimmingCharacters(in: .whitespaces)
                    let first = try firstKey(key)
                    if first == "hooks" {
                        let plainKeys = ["hooks", "\"hooks\"", "'hooks'"]
                        guard isArray, plainKeys.contains(key) else { throw ConfigurationError.invalidStructure("hooks table") }
                    }
                    root = false
                } else if root, !code.isEmpty, !code.hasPrefix("#"), try firstKey(code) == "hooks" {
                    throw ConfigurationError.invalidStructure("inline hooks definition")
                }
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
        }
        guard quote == nil, delimiters.isEmpty else { throw ConfigurationError.invalidStructure("unfinished TOML value") }
        return result
    }

    private static func firstKey(_ value: String) throws -> String {
        guard let first = value.first else { throw ConfigurationError.invalidStructure("empty key") }
        if first == "\"" || first == "'" {
            guard let end = value.dropFirst().firstIndex(of: first) else { throw ConfigurationError.invalidStructure("quoted key") }
            let key = String(value[value.index(after: value.startIndex)..<end])
            // 不解码转义 key；可能把 hooks 藏在 Unicode 转义中，保守拒绝。
            guard !key.contains("\\") else { throw ConfigurationError.invalidStructure("escaped key") }
            return key
        }
        return String(value.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }))
    }
}
