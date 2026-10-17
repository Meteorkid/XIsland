import AppKit
import CryptoKit
import DIShared
import Foundation

@MainActor
struct IntegrationSetupDiscoveryEntry {
    let agent: AgentType
    let installed: Bool
    let configured: Bool
    let fingerprint: String
    let appURL: URL?
    let codexBinary: URL?
    let detail: String?
    let canAutoConfigure: Bool
}

@MainActor
enum IntegrationSetupDiscovery {
    @MainActor
    struct Environment {
        let homeDirectory: URL
        let path: String
        let applicationURL: (String) -> URL?
        let isExecutable: (URL) -> Bool
        let extensionIDs: Set<String>
        let hasConfiguration: (AgentType) -> Bool

        static var live: Self {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Self(homeDirectory: home, path: ProcessInfo.processInfo.environment["PATH"] ?? "",
                        applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                        isExecutable: { url in
                            var directory: ObjCBool = false
                            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
                                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
                        }, extensionIDs: installedExtensionIDs(home: home),
                        hasConfiguration: { ZeroConfigManager.hasConfiguration(for: $0) })
        }
    }

    static func scan() -> [IntegrationSetupDiscoveryEntry] { scan(environment: .live) }

    static func scan(environment: Environment) -> [IntegrationSetupDiscoveryEntry] {
        let bridge = environment.homeDirectory.appendingPathComponent(".xisland/bin/di-bridge").path
        let extensions = Set(environment.extensionIDs.map { $0.lowercased() })
        return AgentType.allCases.filter(\.isSupported).map { agent in
            let descriptor = IntegrationSetupDescriptor.descriptor(for: agent)
            let appIDs = applicationIDs(for: agent)
            let applications = appIDs.compactMap { id in environment.applicationURL(id).map { (id, $0) } }
            let binary = executable(names: executableNames(for: agent), environment: environment)
            let extensionInstalled = extensionIDs(for: agent).contains { extensions.contains($0) }
            let app = applications.first?.1 ?? (extensionInstalled
                ? environment.applicationURL("com.microsoft.VSCode") ?? environment.applicationURL("com.microsoft.VSCodeInsiders") : nil)
            let codexBinary = agent == .codex ? applications.lazy.flatMap {
                [$0.1.appendingPathComponent("Contents/Resources/codex-cli/bin/codex"),
                 $0.1.appendingPathComponent("Contents/Resources/codex")]
            }.first(where: environment.isExecutable) ?? binary : nil
            var installed = app != nil || binary != nil || extensionInstalled
            var automatic = descriptor.canAutoConfigure
            var detail: String?
            if agent == .glm {
                installed = false
                automatic = false
                detail = "GLM 是模型来源，需要通过已接入的客户端上报。"
            } else if agent == .trae {
                automatic = applications.contains { $0.0 == "cn.trae.app" }
                if installed && !automatic { detail = "已发现 Trae；自动配置仅覆盖 Trae CN。" }
            } else if agent == .copilot {
                // VS Code 宿主本身不证明用户安装了 Copilot。
                installed = extensionInstalled
            } else if agent == .tabnine || agent == .codeBuddy {
                automatic = automatic && binary != nil
                if installed && !automatic { detail = "自动配置需要对应的 CLI，IDE 扩展需单独核对。" }
            } else if agent == .deepseek {
                automatic = binary?.lastPathComponent == "codewhale"
                if installed && !automatic { detail = "自动配置仅覆盖已核对的 Codewhale 发布线。" }
            } else if agent == .amazonQ && binary?.lastPathComponent == "q" {
                detail = "已发现旧 Amazon Q 入口；当前接入仅覆盖 qchat 1.19.7 包装器。"
            }
            let configured = installed && agent != .glm && environment.hasConfiguration(agent)
            let definition = try? expectedDefinition(for: agent, homeDirectory: environment.homeDirectory.path, bridgePath: bridge)
            if definition == nil { automatic = false; detail = "无法生成当前接入定义。" }
            let data = Data("xisland-integration-v1\n\(agent.rawValue)\n\(automatic)\n\(configured)\n\(definition ?? "unavailable")".utf8)
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return IntegrationSetupDiscoveryEntry(agent: agent, installed: installed, configured: configured,
                fingerprint: fingerprint, appURL: app, codexBinary: codexBinary,
                detail: detail, canAutoConfigure: installed && automatic)
        }
    }

    static func automaticAgents(in entries: [IntegrationSetupDiscoveryEntry], requested: Set<AgentType>? = nil) -> Set<AgentType> {
        Set(entries.filter { $0.agent.isSupported && $0.installed && $0.canAutoConfigure
            && (requested?.contains($0.agent) ?? true) }.map(\.agent))
    }

    static func codexExpectedCommands() -> Set<String> {
        codexExpectedCommands(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func codexExpectedCommands(homeDirectory: URL) -> Set<String> {
        guard let profile = NativeHookProfile.profile(for: .codex),
              let config = try? profile.merging(into: [:], bridgePath: homeDirectory.appendingPathComponent(".xisland/bin/di-bridge").path),
              let events = config["hooks"] as? [String: [[String: Any]]] else { return [] }
        return Set(events.values.flatMap { $0 }.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String })
    }

    private static func expectedDefinition(for agent: AgentType, homeDirectory: String, bridgePath: String) throws -> String {
        func json(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        }
        if let profile = ZeroConfigManager.effectiveNativeProfile(for: agent, homeDirectory: homeDirectory) {
            return try json(profile.merging(into: [:], bridgePath: bridgePath))
        }
        switch agent {
        case .devin: return try json(DevinHookConfiguration.merging(into: [:], bridgePath: bridgePath))
        case .windsurf: return try json(WindsurfHookConfiguration.merging(into: [:], bridgePath: bridgePath))
        case .copilotCli: return try json(CopilotCliHookConfiguration.merging(into: [:], bridgePath: bridgePath))
        case .cursor: return try json(CursorHookConfiguration.merging(into: [:], bridgePath: bridgePath))
        case .trae: return try json(TraeHookConfiguration.merging(into: [:], bridgePath: bridgePath))
        case .codeBuddy: return try json(CodeBuddyHookConfiguration.merging(into: [:], bridgePath: bridgePath))
        case .cline: return try ClineHookConfiguration.events.map {
            try ClineHookConfiguration.eventFileContents(event: $0, bridgePath: bridgePath)
        }.joined(separator: "\n")
        case .copilot:
            return try json(VSCodeHookConfiguration.merging(into: [:], bridgePath: bridgePath))
                + VSCodeHookSettings.registering(in: "{}", hookPath: VSCodeHookConfiguration.registeredPath)
        case .kimi:
            return try KimiHookConfiguration.Runtime.allCases.map {
                try KimiHookConfiguration.merging(into: "", bridgePath: bridgePath, runtime: $0)
            }.joined(separator: "\n")
        case .deepseek: return try DeepSeekHookConfiguration.merging(into: "", bridgePath: bridgePath)
        case .openCode: return try OpenCodePluginConfiguration.source(bridgePath: bridgePath)
        case .amp: return try AmpPluginConfiguration.source(bridgePath: bridgePath)
        case .pi: return try PiPluginConfiguration.source(bridgePath: bridgePath)
        case .aider: return try AiderWrapperConfiguration.source(bridgePath: bridgePath)
        case .workBuddy:
            let files = try WorkBuddyPluginConfiguration.files(bridgePath: bridgePath)
            return files.keys.sorted().map { $0 + ":" + String(decoding: files[$0]!, as: UTF8.self) }.joined(separator: "\n")
        case .kiro:
            return try json(KiroHookConfiguration.merging(into: [:], bridgePath: bridgePath,
                cliVersion: KiroHookConfiguration.documentedCLIVersion, engine: "v3"))
        default: return "manual-integration-v1:\(agent.rawValue)"
        }
    }

    private static func executable(names: [String], environment: Environment) -> URL? {
        let home = environment.homeDirectory.path
        let directories = environment.path.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "\(home)/.local/bin",
               "\(home)/.cargo/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin",
               "\(home)/.opencode/bin", "\(home)/.claude/local"]
        for name in names {
            for directory in directories where directory.hasPrefix("/") {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if environment.isExecutable(url) { return url }
            }
        }
        return nil
    }

    private static func executableNames(for agent: AgentType) -> [String] {
        switch agent {
        case .claudeCode: ["claude"]
        case .codex: ["codex"]
        case .geminiCli: ["gemini"]
        case .openCode: ["opencode"]
        case .droid: ["droid"]
        case .qoder: ["qodercli", "qoder"]
        case .codeBuddy: ["codebuddy"]
        case .qwen: ["qwen"]
        case .kimi: ["kimi", "kimi-code"]
        case .deepseek: ["codewhale", "deepseek"]
        case .kiro: ["kiro-cli"]
        case .amp: ["amp"]
        case .pi: ["pi"]
        case .aider: ["aider"]
        case .devin: ["devin"]
        case .amazonQ: ["qchat", "q"]
        case .tabnine: ["tabnine"]
        case .cody: ["cody"]
        case .copilotCli: ["copilot"]
        case .`continue`: ["cn"]
        default: []
        }
    }

    private static func applicationIDs(for agent: AgentType) -> [String] {
        switch agent {
        case .trae: ["cn.trae.app", "com.trae.app", "cn.trae.solo.app", "cn.trae.work.app"]
        case .copilot: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .jetbrainsAi:
            ["com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
             "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.CLion", "com.jetbrains.rider",
             "com.jetbrains.PhpStorm", "com.jetbrains.RubyMine", "com.jetbrains.rustrover"]
        default: agent.bundleIds
        }
    }

    private static func extensionIDs(for agent: AgentType) -> [String] {
        switch agent {
        case .copilot: ["github.copilot", "github.copilot-chat"]
        case .cline: ["saoudrizwan.claude-dev"]
        case .rooCode: ["rooveterinaryinc.roo-cline"]
        case .`continue`: ["continue.continue"]
        case .cody: ["sourcegraph.cody-ai"]
        case .amazonQ: ["amazonwebservices.amazon-q-vscode"]
        case .tabnine: ["tabnine.tabnine-vscode"]
        default: []
        }
    }

    static func installedExtensionIDs(home: URL) -> Set<String> {
        let files = FileManager.default
        var result = Set<String>()
        for relative in [".vscode/extensions", ".vscode-insiders/extensions"] {
            let root = home.appendingPathComponent(relative)
            guard let directories = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for directory in directories {
                let manifest = directory.appendingPathComponent("package.json")
                guard let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 1_048_576, let data = try? Data(contentsOf: manifest),
                      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let publisher = value["publisher"] as? String, let name = value["name"] as? String else { continue }
                result.insert("\(publisher).\(name)".lowercased())
            }
        }
        return result
    }
}
