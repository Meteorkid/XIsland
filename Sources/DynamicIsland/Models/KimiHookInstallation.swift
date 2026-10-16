import Foundation

/// 两条发布线只更新各自已经存在的配置，不创建未安装客户端的目录。
enum KimiHookInstallation {
    struct Configuration {
        let runtime: KimiHookConfiguration.Runtime
        let url: URL
    }

    enum ConfigurationError: Error, Equatable {
        case invalidHomeDirectory
        case invalidKimiCodeHome
        case overlappingConfigurations
        case configurationChanged
    }

    static func existingConfigurations(homeDirectory: String, environment: [String: String]) throws -> [Configuration] {
        guard isAbsolutePath(homeDirectory) else { throw ConfigurationError.invalidHomeDirectory }
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        let legacy = home.appendingPathComponent(KimiHookConfiguration.Runtime.legacyPython.relativeConfigPath)
        let node: URL
        if let override = environment["KIMI_CODE_HOME"] {
            guard isAbsolutePath(override) else { throw ConfigurationError.invalidKimiCodeHome }
            node = URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("config.toml")
        } else {
            node = home.appendingPathComponent(KimiHookConfiguration.Runtime.node.relativeConfigPath)
        }
        // 同路径、符号链接和硬链接均不能把两个协议写进同一份配置。
        guard !sameFile(legacy, node) else { throw ConfigurationError.overlappingConfigurations }
        return [Configuration(runtime: .legacyPython, url: legacy), Configuration(runtime: .node, url: node)]
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    @discardableResult
    static func install(homeDirectory: String, bridgePath: String, environment: [String: String]) throws -> Bool {
        try update(homeDirectory: homeDirectory, environment: environment) { text, runtime in
            try KimiHookConfiguration.merging(into: text, bridgePath: bridgePath, runtime: runtime)
        }
    }

    static func remove(homeDirectory: String, environment: [String: String]) throws {
        _ = try update(homeDirectory: homeDirectory, environment: environment) { text, runtime in
            try KimiHookConfiguration.removing(from: text, runtime: runtime)
        }
    }

    static func isConfigured(homeDirectory: String, bridgePath: String, environment: [String: String]) -> Bool {
        guard let configurations = try? existingConfigurations(homeDirectory: homeDirectory, environment: environment),
              !configurations.isEmpty else { return false }
        return configurations.allSatisfy { configuration in
            guard let text = try? String(contentsOf: configuration.url, encoding: .utf8) else { return false }
            return KimiHookConfiguration.isConfigured(in: text, bridgePath: bridgePath, runtime: configuration.runtime)
        }
    }

    static func shouldRepair(homeDirectory: String, bridgePath: String, environment: [String: String]) -> Bool {
        guard let configurations = try? existingConfigurations(homeDirectory: homeDirectory, environment: environment),
              !configurations.isEmpty else { return false }
        var needsRepair = false
        for configuration in configurations {
            guard let text = try? String(contentsOf: configuration.url, encoding: .utf8),
                  let merged = try? KimiHookConfiguration.merging(into: text, bridgePath: bridgePath,
                                                               runtime: configuration.runtime) else { return false }
            needsRepair = needsRepair || merged != text
        }
        return needsRepair
    }

    private static func update(homeDirectory: String, environment: [String: String],
                               transform: (String, KimiHookConfiguration.Runtime) throws -> String) throws -> Bool {
        let configurations = try existingConfigurations(homeDirectory: homeDirectory, environment: environment)
        // 先检查全部目标，任一文件损坏时不留下另一条发布线的部分写入。
        let updates = try configurations.map { configuration -> (url: URL, original: String, updated: String) in
            let original = try String(contentsOf: configuration.url, encoding: .utf8)
            return (configuration.url, original, try transform(original, configuration.runtime))
        }
        for update in updates where update.original != update.updated {
            try HookConfigurationFile.updateText(at: update.url) { current in
                guard FileManager.default.fileExists(atPath: update.url.path), current == update.original else {
                    throw ConfigurationError.configurationChanged
                }
                return update.updated
            }
        }
        return !configurations.isEmpty
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func sameFile(_ first: URL, _ second: URL) -> Bool {
        let first = first.standardizedFileURL.resolvingSymlinksInPath()
        let second = second.standardizedFileURL.resolvingSymlinksInPath()
        if first == second { return true }
        guard let firstAttributes = try? FileManager.default.attributesOfItem(atPath: first.path),
              let secondAttributes = try? FileManager.default.attributesOfItem(atPath: second.path),
              let firstFile = firstAttributes[.systemFileNumber] as? NSNumber,
              let secondFile = secondAttributes[.systemFileNumber] as? NSNumber,
              let firstSystem = firstAttributes[.systemNumber] as? NSNumber,
              let secondSystem = secondAttributes[.systemNumber] as? NSNumber else { return false }
        return firstFile == secondFile && firstSystem == secondSystem
    }
}
