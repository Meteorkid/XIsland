import Foundation

/// Claude Desktop 的 Code / Cowork 会话索引。
///
/// Claude Desktop 自己维护一份“桌面标签 id ↔ CLI 会话 id”的映射：
/// `~/Library/Application Support/Claude/{claude-code-sessions,local-agent-mode-sessions}/
/// <org>/<account>/local_<uuid>.json`。hook 侧拿到的是 CLI 的 `session_id`，
/// 而 `claude://` 只接受桌面侧的 `local_` id，因此必须先查这张表，不能拿 CLI id 拼链接。
///
/// 这里只读应用自己的元数据文件，不读取 transcript，也不猜测缺失的映射。
struct ClaudeDesktopSessionIndex {
    enum Route: String, Equatable, Sendable {
        case code
        case cowork

        var pathComponent: String {
            switch self {
            case .code: "epitaxy"
            case .cowork: "cowork"
            }
        }
    }

    struct Root: Equatable, Sendable {
        let url: URL
        let route: Route
    }

    struct Match: Equatable, Sendable {
        let localSessionID: String
        let route: Route
        let lastActivityAt: Double
    }

    static let bundleIdentifier = "com.anthropic.claudefordesktop"
    static var supportDirectoryOverrideKey: String { "X_ISLAND_CLAUDE_SUPPORT_DIR" }

    let roots: [Root]
    private let fileManager: FileManager

    init(roots: [Root]? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.roots = roots ?? Self.defaultRoots()
    }

    static func defaultRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Root] {
        let base: URL
        if let override = environment[supportDirectoryOverrideKey], override.hasPrefix("/") {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        }
        return [
            Root(url: base.appendingPathComponent("claude-code-sessions", isDirectory: true), route: .code),
            Root(url: base.appendingPathComponent("local-agent-mode-sessions", isDirectory: true), route: .cowork),
        ]
    }

    /// Return the newest live desktop session whose `cliSessionId` is exactly
    /// the hook's native Claude session id. Missing or malformed files are
    /// ignored rather than turned into a guessed URL.
    func match(cliSessionID: String) -> Match? {
        let cli = cliSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cli.isEmpty, cli.utf8.count <= 512,
              !cli.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }

        var best: Match?
        for root in roots {
            for file in metadataFiles(in: root.url) {
                guard let entry = parse(file: file, route: root.route), entry.cliSessionIDs.contains(cli) else {
                    continue
                }
                if let current = best {
                    if entry.match.lastActivityAt > current.lastActivityAt {
                        best = entry.match
                    }
                } else {
                    best = entry.match
                }
            }
        }
        return best
    }

    static func deepLink(for match: Match) -> URL? {
        guard validLocalSessionID(match.localSessionID) else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "claude.ai"
        // The desktop app's own handlers use `/epitaxy/<local id>` for Code
        // tabs and `/cowork/<local id>` for Cowork; `/code/<id>` only reloads
        // the page and can land on the last focused tab.
        components.percentEncodedPath = "/" + match.route.pathComponent + "/" + match.localSessionID
        return components.url
    }

    static func validLocalSessionID(_ id: String) -> Bool {
        guard id.hasPrefix("local_") else { return false }
        let body = id.dropFirst("local_".count)
        guard (1...64).contains(body.count) else { return false }
        return body.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
        }
    }

    // MARK: - Metadata

    private struct Entry {
        let match: Match
        let cliSessionIDs: [String]
    }

    private func metadataFiles(in root: URL) -> [URL] {
        guard let orgs = directories(in: root) else { return [] }
        var files: [URL] = []
        for org in orgs {
            guard let accounts = directories(in: org) else { continue }
            for account in accounts {
                guard let contents = try? fileManager.contentsOfDirectory(
                    at: account,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for file in contents {
                    let name = file.lastPathComponent
                    guard name.hasPrefix("local_"), name.hasSuffix(".json"),
                          let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                          values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    files.append(file)
                }
            }
        }
        return files
    }

    private func directories(in url: URL) -> [URL]? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents.filter {
            let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    private func parse(file: URL, route: Route) -> Entry? {
        // 元数据通常只有几百字节；上限同时防住异常大文件拖慢点击。
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 1_048_576,
              let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let localID = object["sessionId"] as? String,
              Self.validLocalSessionID(localID),
              (object["isArchived"] as? Bool) != true else {
            return nil
        }

        let cliCandidates: [String]
        if let cli = object["cliSessionId"] as? String {
            cliCandidates = [cli]
        } else if let list = object["bridgeSessionIds"] as? [String] {
            cliCandidates = list
        } else {
            cliCandidates = []
        }
        let validCLI = cliCandidates.filter {
            !$0.isEmpty && $0.utf8.count <= 512
                && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard !validCLI.isEmpty else { return nil }

        let lastActivity = (object["lastActivityAt"] as? NSNumber)?.doubleValue
            ?? (object["lastFocusedAt"] as? NSNumber)?.doubleValue
            ?? (object["createdAt"] as? NSNumber)?.doubleValue
            ?? 0
        return Entry(
            match: Match(localSessionID: localID, route: route, lastActivityAt: lastActivity),
            cliSessionIDs: validCLI
        )
    }
}
