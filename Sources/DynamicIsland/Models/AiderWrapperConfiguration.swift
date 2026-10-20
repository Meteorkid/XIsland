import Foundation

enum AiderWrapperConfiguration {
    static let relativePath = ".xisland/bin/xisland-aider"
    enum ConfigurationError: Error { case invalidPath, userFileConflict }

    static func source(bridgePath: String) throws -> String {
        guard bridgePath.hasPrefix("/"), !bridgePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConfigurationError.invalidPath
        }
        return prefix + quote(bridgePath) + suffix
    }

    static func isOwned(_ text: String) -> Bool {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { return false }
        let quoted = String(text.dropFirst(prefix.count).dropLast(suffix.count))
        guard quoted.hasPrefix("'"), quoted.hasSuffix("'"), quoted.count >= 2 else { return false }
        let path = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        return (try? source(bridgePath: path)) == text
    }

    static func install(at url: URL, bridgePath: String) throws {
        try rejectLink(at: url)
        let expected = try source(bridgePath: bridgePath)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try HookConfigurationFile.updateText(at: url) { original in
            guard (!existed && original.isEmpty) || isOwned(original) else { throw ConfigurationError.userFileConflict }
            return expected
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func remove(at url: URL) throws {
        try Task.checkCancellation()
        try rejectLink(at: url)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard isOwned(text) else { return }
        try Task.checkCancellation()
        try FileManager.default.removeItem(at: url)
    }

    static func isConfigured(at url: URL, bridgePath: String) -> Bool {
        guard (try? rejectLink(at: url)) != nil, let expected = try? source(bridgePath: bridgePath),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text == expected && FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func shouldRepair(at url: URL, bridgePath: String) -> Bool {
        guard (try? rejectLink(at: url)) != nil,
              let text = try? String(contentsOf: url, encoding: .utf8), isOwned(text) else { return false }
        return !isConfigured(at: url, bridgePath: bridgePath)
    }

    private static func rejectLink(at url: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            throw ConfigurationError.userFileConflict
        }
    }

    private static let prefix = "#!/bin/sh\n# XIsland:AiderLauncher:v1\nexec "
    private static let suffix = " aider \"$@\"\n"
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

}
