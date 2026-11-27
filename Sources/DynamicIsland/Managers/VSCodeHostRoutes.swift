import Foundation

/// VS Code 宿主提供的两类精确入口：
///
/// 1. Claude Code 官方扩展注册的 `vscode://anthropic.claude-code/open?session=<id>`；
/// 2. X Island 自己的伴生扩展 `vscode://meteorkid.xisland-vscode/focus?...`，
///    只把已经存在的集成终端显示出来，不创建终端、不发送命令。
///
/// 两者都必须先确认对应扩展已安装，否则 URL 只会在 VS Code 里报“命令不存在”。
enum VSCodeHostRoutes {
    static let claudeCodeExtensionPrefix = "anthropic.claude-code-"
    static let companionExtensionID = "meteorkid.xisland-vscode"
    static let companionExtensionPrefix = companionExtensionID + "-"
    static let companionMinimumVersion = "1.1.0"
    static var extensionsDirectoryOverrideKey: String { "X_ISLAND_VSCODE_EXTENSIONS_DIR" }

    static func extensionsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment[extensionsDirectoryOverrideKey], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(".vscode/extensions", isDirectory: true)
    }

    static func isClaudeCodeExtensionInstalled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        installedExtensionVersions(prefix: claudeCodeExtensionPrefix,
                                   directory: extensionsDirectory(environment: environment, home: home)).isEmpty == false
    }

    static func isCompanionInstalled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        installedExtensionVersions(prefix: companionExtensionPrefix,
                                   directory: extensionsDirectory(environment: environment, home: home))
            .contains { version(atLeast: companionMinimumVersion, $0) }
    }

    /// 官方扩展已文档化的会话恢复链接。调用方必须已经确认扩展存在。
    static func claudeCodeSessionURL(sessionID: String) -> URL? {
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "anthropic.claude-code"
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "session", value: id)]
        return components.url
    }

    /// 伴生扩展的聚焦请求。只携带终端定位符号与工作目录，不携带会话内容。
    static func companionFocusURL(tty: String, cwd: String) -> URL? {
        guard let path = TerminalSessionNavigator.ttyPath(from: tty),
              cwd.isEmpty || (cwd.hasPrefix("/") && cwd.utf8.count <= 4096
                  && !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = companionExtensionID
        components.path = "/focus"
        var items = [URLQueryItem(name: "tty", value: path)]
        if !cwd.isEmpty { items.append(URLQueryItem(name: "cwd", value: cwd)) }
        components.queryItems = items
        return components.url
    }

    private static func installedExtensionVersions(prefix: String, directory: URL) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents.compactMap { url in
            guard url.lastPathComponent.hasPrefix(prefix),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                return nil
            }
            return String(url.lastPathComponent.dropFirst(prefix.count))
        }
    }

    private static func version(atLeast minimum: String, _ candidate: String) -> Bool {
        let lhs = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return right > left }
        }
        return true
    }
}
