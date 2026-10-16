import Foundation

enum VSCodeHookInstallation {
    /// 只为已有的 macOS Code / Insiders 用户目录和命名 profile 注册。
    static func settingsURLs(homeDirectory: String) -> [URL] {
        let files = FileManager.default
        return ["Code", "Code - Insiders"].flatMap { product -> [URL] in
            let user = URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent("Library/Application Support/\(product)/User", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: user.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
            var result = [user.appendingPathComponent("settings.json")]
            let profiles = user.appendingPathComponent("profiles", isDirectory: true)
            if let directories = try? files.contentsOfDirectory(at: profiles, includingPropertiesForKeys: [.isDirectoryKey]) {
                for directory in directories.sorted(by: { $0.path < $1.path }) {
                    let settings = directory.appendingPathComponent("settings.json")
                    if (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                       files.fileExists(atPath: settings.path) { result.append(settings) }
                }
            }
            return result
        }
    }

    static func install(homeDirectory: String, bridgePath: String) throws {
        let settings = settingsURLs(homeDirectory: homeDirectory)
        guard !settings.isEmpty else { return }
        let hookURL = URL(fileURLWithPath: homeDirectory).appendingPathComponent(VSCodeHookConfiguration.relativeConfigPath)
        // 先检查所有 profile，损坏 JSONC 或显式禁用时不留下部分配置。
        _ = try VSCodeHookConfiguration.merging(into: HookConfigurationFile.read(at: hookURL), bridgePath: bridgePath)
        for url in settings {
            _ = try VSCodeHookSettings.registering(in: source(at: url), hookPath: VSCodeHookConfiguration.registeredPath)
        }
        try HookConfigurationFile.update(at: hookURL) { try VSCodeHookConfiguration.merging(into: $0, bridgePath: bridgePath) }
        for url in settings {
            let existed = FileManager.default.fileExists(atPath: url.path)
            try HookConfigurationFile.updateText(at: url) {
                try VSCodeHookSettings.registering(in: !existed && $0.isEmpty ? "{}" : $0,
                                                  hookPath: VSCodeHookConfiguration.registeredPath)
            }
        }
    }

    static func remove(homeDirectory: String) throws {
        for url in settingsURLs(homeDirectory: homeDirectory) where FileManager.default.fileExists(atPath: url.path) {
            try HookConfigurationFile.updateText(at: url) {
                try VSCodeHookSettings.removing(from: $0, hookPath: VSCodeHookConfiguration.registeredPath)
            }
        }
        let hookURL = URL(fileURLWithPath: homeDirectory).appendingPathComponent(VSCodeHookConfiguration.relativeConfigPath)
        try HookConfigurationFile.update(at: hookURL) { try VSCodeHookConfiguration.removing(from: $0) }
    }

    static func isConfigured(homeDirectory: String, bridgePath: String) -> Bool {
        let settings = settingsURLs(homeDirectory: homeDirectory)
        guard !settings.isEmpty,
              let configuration = try? HookConfigurationFile.read(at: URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent(VSCodeHookConfiguration.relativeConfigPath)),
              VSCodeHookConfiguration.isConfigured(in: configuration, bridgePath: bridgePath) else { return false }
        return settings.allSatisfy { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return VSCodeHookSettings.isRegistered(in: text, hookPath: VSCodeHookConfiguration.registeredPath)
        }
    }

    static func shouldRepair(homeDirectory: String, bridgePath: String) -> Bool {
        let url = URL(fileURLWithPath: homeDirectory).appendingPathComponent(VSCodeHookConfiguration.relativeConfigPath)
        guard FileManager.default.fileExists(atPath: url.path), !isConfigured(homeDirectory: homeDirectory, bridgePath: bridgePath) else { return false }
        let settings = settingsURLs(homeDirectory: homeDirectory)
        guard !settings.isEmpty else { return false }
        // 显式 false 或损坏文件留给用户处理，轮询不反复覆盖和报错。
        return settings.allSatisfy { url in
            (try? VSCodeHookSettings.registering(in: source(at: url), hookPath: VSCodeHookConfiguration.registeredPath)) != nil
        }
    }

    private static func source(at url: URL) throws -> String {
        FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : "{}"
    }
}
